#![forbid(unsafe_code)]

//! Arena-backed, hash-consed Bassline values.
//!
//! This module is intentionally independent of the older `raw_values` and
//! `codec` experiments in this crate. Values live in one explicit local store:
//!
//! - scalar payload bytes are interned in a byte arena;
//! - frame child sequences are interned in an edge arena;
//! - value nodes are fixed-size `(tag + mark, body-id)` records;
//! - public handles carry a store token, while stored edges use compact `u32`
//!   local ids.
//!
//! Hashes are only local candidate selectors. Every payload and child-sequence
//! collision is resolved by comparing the complete arena content. Canonical
//! encoding remains the portable representation and ordering.

use std::cmp::Ordering;
use std::collections::HashMap;
use std::collections::hash_map::RandomState;
use std::error::Error;
use std::fmt;
use std::hash::{BuildHasher, Hasher};
use std::num::NonZeroU32;
use std::slice;
use std::sync::atomic::{AtomicU32, Ordering as AtomicOrdering};

const ACTION_MASK: u8 = 0x08;
const END_BYTE: u8 = 0xA0;
const MAX_SCALAR_LENGTH: usize = u32::MAX as usize;

static NEXT_STORE_TOKEN: AtomicU32 = AtomicU32::new(1);

/// The grammatical mode carried by every value node.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Mark {
    Plain,
    Actionable,
}

impl Mark {
    const fn ce_bit(self) -> u8 {
        match self {
            Self::Plain => 0,
            Self::Actionable => ACTION_MASK,
        }
    }
}

/// The nine closed value kinds in Bassline CE v1.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    Nil,
    Integer,
    Text,
    Symbol,
    Bytes,
    List,
    Record,
    Dictionary,
    Set,
}

impl Kind {
    const fn tag(self) -> u8 {
        match self {
            Self::Nil => 0x1,
            Self::Integer => 0x2,
            Self::Text => 0x3,
            Self::Symbol => 0x4,
            Self::Bytes => 0x5,
            Self::List => 0x6,
            Self::Record => 0x7,
            Self::Dictionary => 0x8,
            Self::Set => 0x9,
        }
    }

    const fn is_atom(self) -> bool {
        matches!(
            self,
            Self::Nil | Self::Integer | Self::Text | Self::Symbol | Self::Bytes
        )
    }

    const fn is_frame(self) -> bool {
        !self.is_atom()
    }
}

/// The typed facts represented by a CE header byte.
///
/// Length bits belong to scalar encoding and are deliberately absent here.
/// Resident nodes therefore cannot contain an invalid or contradictory raw
/// header; the byte representation is produced only at the CE boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct Header {
    kind: Kind,
    mark: Mark,
}

impl Header {
    const fn ce_byte(self) -> u8 {
        (self.kind.tag() << 4) | self.mark.ce_bit()
    }
}

/// A store-scoped value handle.
///
/// Handle equality includes the store token and therefore means "the same
/// resident value in the same store." Canonical value identity across stores
/// is CE equality; the token is only a local safety check and never enters CE.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct ValueId {
    store: NonZeroU32,
    slot: u32,
}

impl ValueId {
    pub const fn store_token(self) -> u32 {
        self.store.get()
    }

    pub const fn slot(self) -> u32 {
        self.slot
    }
}

impl fmt::Debug for ValueId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "ValueId({}:{})", self.store_token(), self.slot())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct LocalId(u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct PayloadId(u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct SequenceId(u32);

#[derive(Debug, Clone, Copy)]
struct Span {
    start: usize,
    len: u32,
}

impl Span {
    fn len(self) -> usize {
        self.len as usize
    }

    fn end(self) -> usize {
        self.start + self.len()
    }
}

#[derive(Debug)]
struct PayloadRecord {
    span: Span,
    next_collision: Option<PayloadId>,
}

#[derive(Debug)]
struct SequenceRecord {
    span: Span,
    next_collision: Option<SequenceId>,
    encoded_body_len: u64,
    max_child_depth: u32,
    contains_mark: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum BodyId {
    None,
    Payload(PayloadId),
    Sequence(SequenceId),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct NodeKey {
    header: Header,
    body: BodyId,
}

#[derive(Debug)]
struct NodeRecord {
    key: NodeKey,
    encoded_len: u64,
    depth: u32,
    contains_mark: bool,
}

/// Observable arena sizes, useful for ensuring that repeated admission really
/// interns rather than merely producing equal values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StoreStats {
    pub payload_bytes: usize,
    pub payloads: usize,
    pub edge_words: usize,
    pub sequences: usize,
    pub atoms: usize,
    pub frames: usize,
    pub values: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoreError {
    ForeignValue {
        expected_store: u32,
        actual_store: u32,
    },
    UnknownValue {
        slot: u32,
    },
    InvalidInteger,
    ScalarTooLarge {
        length: usize,
    },
    DuplicateSetMember {
        member: ValueId,
    },
    DuplicateDictionaryKey {
        key: ValueId,
    },
    IdSpaceExhausted {
        arena: &'static str,
    },
    ArenaLengthOverflow,
    EncodedLengthOverflow,
    DepthOverflow,
    ValueTooLargeForPlatform {
        encoded_len: u64,
    },
    AllocationFailed {
        arena: &'static str,
    },
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ForeignValue {
                expected_store,
                actual_store,
            } => write!(
                f,
                "value belongs to store {actual_store}, expected store {expected_store}"
            ),
            Self::UnknownValue { slot } => write!(f, "unknown value slot {slot}"),
            Self::InvalidInteger => write!(f, "integer is not canonical decimal notation"),
            Self::ScalarTooLarge { length } => {
                write!(f, "scalar payload of {length} bytes exceeds CE v1")
            }
            Self::DuplicateSetMember { member } => {
                write!(f, "duplicate set member {member:?}")
            }
            Self::DuplicateDictionaryKey { key } => {
                write!(f, "duplicate dictionary key {key:?}")
            }
            Self::IdSpaceExhausted { arena } => write!(f, "{arena} id space exhausted"),
            Self::ArenaLengthOverflow => write!(f, "arena length overflow"),
            Self::EncodedLengthOverflow => write!(f, "expanded CE length overflow"),
            Self::DepthOverflow => write!(f, "value depth overflow"),
            Self::ValueTooLargeForPlatform { encoded_len } => write!(
                f,
                "encoded value of {encoded_len} bytes does not fit this platform"
            ),
            Self::AllocationFailed { arena } => {
                write!(f, "unable to reserve space in the {arena} arena")
            }
        }
    }
}

impl Error for StoreError {}

/// An append-only local home for canonical Bassline values.
///
/// `S` hashes payload bytes and child-id sequences into local collision chains.
/// It does not affect value equality or canonical encoding.
///
/// This is a trusted construction store, not an untrusted decoder boundary.
/// A decoder layered over it must enforce its own input-byte, scalar-size,
/// frame-arity, and nesting-depth limits before admission.
pub struct ValueStore<S = RandomState> {
    token: NonZeroU32,
    fingerprint: S,

    payload_bytes: Vec<u8>,
    payloads: Vec<PayloadRecord>,
    payload_heads: HashMap<u64, PayloadId>,

    edges: Vec<LocalId>,
    sequences: Vec<SequenceRecord>,
    sequence_heads: HashMap<u64, SequenceId>,

    nodes: Vec<NodeRecord>,
    node_ids: HashMap<NodeKey, LocalId>,
    atom_count: usize,
    frame_count: usize,
}

impl ValueStore<RandomState> {
    pub fn new() -> Self {
        Self::with_hasher(RandomState::new())
    }
}

impl Default for ValueStore<RandomState> {
    fn default() -> Self {
        Self::new()
    }
}

impl<S: BuildHasher> ValueStore<S> {
    pub fn with_hasher(fingerprint: S) -> Self {
        let token = NEXT_STORE_TOKEN
            .fetch_update(AtomicOrdering::Relaxed, AtomicOrdering::Relaxed, |next| {
                next.checked_add(1)
            })
            .expect("Bassline store token space exhausted");
        let token = NonZeroU32::new(token).expect("store tokens start at one");

        Self {
            token,
            fingerprint,
            payload_bytes: Vec::new(),
            payloads: Vec::new(),
            payload_heads: HashMap::new(),
            edges: Vec::new(),
            sequences: Vec::new(),
            sequence_heads: HashMap::new(),
            nodes: Vec::new(),
            node_ids: HashMap::new(),
            atom_count: 0,
            frame_count: 0,
        }
    }

    pub const fn token(&self) -> u32 {
        self.token.get()
    }

    pub fn stats(&self) -> StoreStats {
        StoreStats {
            payload_bytes: self.payload_bytes.len(),
            payloads: self.payloads.len(),
            edge_words: self.edges.len(),
            sequences: self.sequences.len(),
            atoms: self.atom_count,
            frames: self.frame_count,
            values: self.nodes.len(),
        }
    }

    pub fn get(&self, id: ValueId) -> Result<ValueRef<'_, S>, StoreError> {
        let local = self.localize(id)?;
        Ok(ValueRef { store: self, local })
    }

    pub fn nil(&mut self, mark: Mark) -> Result<ValueId, StoreError> {
        let key = NodeKey {
            header: Header {
                kind: Kind::Nil,
                mark,
            },
            body: BodyId::None,
        };
        self.intern_node(key).map(|id| self.externalize(id))
    }

    /// Admit an arbitrary-precision integer from canonical decimal ASCII.
    pub fn integer(&mut self, decimal: &str, mark: Mark) -> Result<ValueId, StoreError> {
        if !is_canonical_integer(decimal.as_bytes()) {
            return Err(StoreError::InvalidInteger);
        }
        self.intern_scalar(Kind::Integer, decimal.as_bytes(), mark)
    }

    pub fn integer_i64(&mut self, value: i64, mark: Mark) -> Result<ValueId, StoreError> {
        self.integer(&value.to_string(), mark)
    }

    pub fn text(&mut self, text: &str, mark: Mark) -> Result<ValueId, StoreError> {
        self.intern_scalar(Kind::Text, text.as_bytes(), mark)
    }

    pub fn symbol(&mut self, symbol: &str, mark: Mark) -> Result<ValueId, StoreError> {
        self.intern_scalar(Kind::Symbol, symbol.as_bytes(), mark)
    }

    pub fn bytes(&mut self, bytes: &[u8], mark: Mark) -> Result<ValueId, StoreError> {
        self.intern_scalar(Kind::Bytes, bytes, mark)
    }

    pub fn list(&mut self, items: &[ValueId], mark: Mark) -> Result<ValueId, StoreError> {
        let children = self.localize_all(items)?;
        self.intern_frame(Kind::List, &children, mark)
    }

    /// Construct a nonempty headed frame. An empty record is unrepresentable at
    /// this API boundary because the head is a distinct argument.
    pub fn record(
        &mut self,
        head: ValueId,
        fields: &[ValueId],
        mark: Mark,
    ) -> Result<ValueId, StoreError> {
        let mut children = Vec::new();
        children
            .try_reserve_exact(fields.len().saturating_add(1))
            .map_err(|_| StoreError::AllocationFailed {
                arena: "record builder",
            })?;
        children.push(self.localize(head)?);
        for field in fields {
            children.push(self.localize(*field)?);
        }
        self.intern_frame(Kind::Record, &children, mark)
    }

    /// Construct a dictionary from entries in any order. Keys are sorted by
    /// unsigned lexicographic CE order; duplicate keys are an error.
    pub fn dictionary(
        &mut self,
        entries: &[(ValueId, ValueId)],
        mark: Mark,
    ) -> Result<ValueId, StoreError> {
        let mut local_entries = Vec::new();
        local_entries
            .try_reserve_exact(entries.len())
            .map_err(|_| StoreError::AllocationFailed {
                arena: "dictionary builder",
            })?;
        for (key, value) in entries {
            local_entries.push((self.localize(*key)?, self.localize(*value)?));
        }

        let mut compare_stack = Vec::new();
        local_entries.sort_unstable_by(|(left, _), (right, _)| {
            self.compare_local_with_stack(*left, *right, &mut compare_stack)
        });

        for pair in local_entries.windows(2) {
            if pair[0].0 == pair[1].0 {
                return Err(StoreError::DuplicateDictionaryKey {
                    key: self.externalize(pair[1].0),
                });
            }
        }

        let edge_count = local_entries
            .len()
            .checked_mul(2)
            .ok_or(StoreError::ArenaLengthOverflow)?;
        let mut children = Vec::new();
        children
            .try_reserve_exact(edge_count)
            .map_err(|_| StoreError::AllocationFailed {
                arena: "dictionary builder",
            })?;
        for (key, value) in local_entries {
            children.push(key);
            children.push(value);
        }
        self.intern_frame(Kind::Dictionary, &children, mark)
    }

    /// Construct a strict set from members in any order. Duplicate members are
    /// rejected rather than silently normalized.
    pub fn set(&mut self, members: &[ValueId], mark: Mark) -> Result<ValueId, StoreError> {
        self.set_impl(members, mark, false)
    }

    /// Construct the mathematical image of an iterable, explicitly coalescing
    /// equal members. This is a convenience policy, not a canonical decoder:
    /// both set constructors sort their input, so a decoder must separately
    /// reject an incoming representation whose members were out of order.
    pub fn set_coalescing(
        &mut self,
        members: &[ValueId],
        mark: Mark,
    ) -> Result<ValueId, StoreError> {
        self.set_impl(members, mark, true)
    }

    /// Return the same body under a different root mark. Payloads and child
    /// sequences are shared; nested marks are not traversed or changed.
    pub fn with_mark(&mut self, value: ValueId, mark: Mark) -> Result<ValueId, StoreError> {
        let local = self.localize(value)?;
        let old = self.nodes[local.0 as usize].key;
        let key = NodeKey {
            header: Header {
                kind: old.header.kind,
                mark,
            },
            body: old.body,
        };
        self.intern_node(key).map(|id| self.externalize(id))
    }

    pub fn compare(&self, left: ValueId, right: ValueId) -> Result<Ordering, StoreError> {
        let left = self.localize(left)?;
        let right = self.localize(right)?;
        let mut stack = Vec::new();
        Ok(self.compare_local_with_stack(left, right, &mut stack))
    }

    pub fn encode(&self, value: ValueId) -> Result<Vec<u8>, StoreError> {
        let local = self.localize(value)?;
        let encoded_len = self.nodes[local.0 as usize].encoded_len;
        let capacity = usize::try_from(encoded_len)
            .map_err(|_| StoreError::ValueTooLargeForPlatform { encoded_len })?;
        let mut output = Vec::new();
        output
            .try_reserve_exact(capacity)
            .map_err(|_| StoreError::AllocationFailed { arena: "CE output" })?;
        self.encode_local_into(local, &mut output);
        debug_assert_eq!(output.len(), capacity);
        Ok(output)
    }

    /// Append one canonical encoding to an existing sink without constructing
    /// per-node encoded buffers.
    pub fn encode_into(&self, value: ValueId, output: &mut Vec<u8>) -> Result<(), StoreError> {
        let local = self.localize(value)?;
        let encoded_len = self.nodes[local.0 as usize].encoded_len;
        let additional = usize::try_from(encoded_len)
            .map_err(|_| StoreError::ValueTooLargeForPlatform { encoded_len })?;
        output
            .len()
            .checked_add(additional)
            .ok_or(StoreError::ArenaLengthOverflow)?;
        output
            .try_reserve(additional)
            .map_err(|_| StoreError::AllocationFailed { arena: "CE output" })?;
        self.encode_local_into(local, output);
        Ok(())
    }

    fn set_impl(
        &mut self,
        members: &[ValueId],
        mark: Mark,
        coalesce: bool,
    ) -> Result<ValueId, StoreError> {
        let mut locals = self.localize_all(members)?;
        let mut compare_stack = Vec::new();
        locals.sort_unstable_by(|left, right| {
            self.compare_local_with_stack(*left, *right, &mut compare_stack)
        });

        if coalesce {
            locals.dedup();
        } else {
            for pair in locals.windows(2) {
                if pair[0] == pair[1] {
                    return Err(StoreError::DuplicateSetMember {
                        member: self.externalize(pair[1]),
                    });
                }
            }
        }
        self.intern_frame(Kind::Set, &locals, mark)
    }

    fn intern_scalar(
        &mut self,
        kind: Kind,
        bytes: &[u8],
        mark: Mark,
    ) -> Result<ValueId, StoreError> {
        debug_assert!(matches!(
            kind,
            Kind::Integer | Kind::Text | Kind::Symbol | Kind::Bytes
        ));
        if bytes.len() > MAX_SCALAR_LENGTH {
            return Err(StoreError::ScalarTooLarge {
                length: bytes.len(),
            });
        }

        // A duplicate admission is a pure lookup: do not reserve either the
        // node tables or the body arenas when the exact value is resident.
        if let Some(payload) = self.find_payload(bytes) {
            let key = NodeKey {
                header: Header { kind, mark },
                body: BodyId::Payload(payload),
            };
            if let Some(id) = self.node_ids.get(&key) {
                return Ok(self.externalize(*id));
            }
        }

        self.ensure_node_capacity()?;
        let payload = self.intern_payload(bytes)?;
        let key = NodeKey {
            header: Header { kind, mark },
            body: BodyId::Payload(payload),
        };
        self.intern_node(key).map(|id| self.externalize(id))
    }

    fn intern_frame(
        &mut self,
        kind: Kind,
        children: &[LocalId],
        mark: Mark,
    ) -> Result<ValueId, StoreError> {
        debug_assert!(kind.is_frame());
        u32::try_from(children.len()).map_err(|_| StoreError::IdSpaceExhausted {
            arena: "edge sequence",
        })?;

        // As with scalars, exact re-admission must not require spare capacity.
        if let Some(sequence) = self.find_sequence(children) {
            let key = NodeKey {
                header: Header { kind, mark },
                body: BodyId::Sequence(sequence),
            };
            if let Some(id) = self.node_ids.get(&key) {
                return Ok(self.externalize(*id));
            }
        }

        self.ensure_node_capacity()?;
        let sequence = self.intern_sequence(children)?;
        let key = NodeKey {
            header: Header { kind, mark },
            body: BodyId::Sequence(sequence),
        };
        self.intern_node(key).map(|id| self.externalize(id))
    }

    fn intern_payload(&mut self, bytes: &[u8]) -> Result<PayloadId, StoreError> {
        if bytes.len() > MAX_SCALAR_LENGTH {
            return Err(StoreError::ScalarTooLarge {
                length: bytes.len(),
            });
        }

        let hash = self.payload_fingerprint(bytes);
        if let Some(id) = self.find_payload_in_chain(bytes, hash) {
            return Ok(id);
        }

        let id = PayloadId(
            u32::try_from(self.payloads.len())
                .map_err(|_| StoreError::IdSpaceExhausted { arena: "payload" })?,
        );
        let len = u32::try_from(bytes.len()).map_err(|_| StoreError::ScalarTooLarge {
            length: bytes.len(),
        })?;
        let start = self.payload_bytes.len();
        start
            .checked_add(bytes.len())
            .ok_or(StoreError::ArenaLengthOverflow)?;

        self.payload_bytes
            .try_reserve(bytes.len())
            .map_err(|_| StoreError::AllocationFailed {
                arena: "payload byte",
            })?;
        self.payloads
            .try_reserve(1)
            .map_err(|_| StoreError::AllocationFailed { arena: "payload" })?;
        self.payload_heads
            .try_reserve(1)
            .map_err(|_| StoreError::AllocationFailed {
                arena: "payload index",
            })?;

        let next_collision = self.payload_heads.get(&hash).copied();
        self.payload_bytes.extend_from_slice(bytes);
        self.payloads.push(PayloadRecord {
            span: Span { start, len },
            next_collision,
        });
        self.payload_heads.insert(hash, id);
        Ok(id)
    }

    fn intern_sequence(&mut self, children: &[LocalId]) -> Result<SequenceId, StoreError> {
        let len = u32::try_from(children.len()).map_err(|_| StoreError::IdSpaceExhausted {
            arena: "edge sequence",
        })?;
        let hash = self.sequence_fingerprint(children);
        if let Some(id) = self.find_sequence_in_chain(children, hash) {
            return Ok(id);
        }

        let mut encoded_body_len = 0u64;
        let mut max_child_depth = 0u32;
        let mut contains_mark = false;
        for child in children {
            let node = &self.nodes[child.0 as usize];
            encoded_body_len = encoded_body_len
                .checked_add(node.encoded_len)
                .ok_or(StoreError::EncodedLengthOverflow)?;
            max_child_depth = max_child_depth.max(node.depth);
            contains_mark |= node.contains_mark;
        }
        // Every sequence is destined to be a frame body, so reject metadata
        // that could not form a frame before mutating either arena.
        encoded_body_len
            .checked_add(2)
            .ok_or(StoreError::EncodedLengthOverflow)?;
        max_child_depth
            .checked_add(1)
            .ok_or(StoreError::DepthOverflow)?;

        let id = SequenceId(
            u32::try_from(self.sequences.len())
                .map_err(|_| StoreError::IdSpaceExhausted { arena: "sequence" })?,
        );
        let start = self.edges.len();
        start
            .checked_add(children.len())
            .ok_or(StoreError::ArenaLengthOverflow)?;

        self.edges
            .try_reserve(children.len())
            .map_err(|_| StoreError::AllocationFailed { arena: "edge" })?;
        self.sequences
            .try_reserve(1)
            .map_err(|_| StoreError::AllocationFailed { arena: "sequence" })?;
        self.sequence_heads
            .try_reserve(1)
            .map_err(|_| StoreError::AllocationFailed {
                arena: "sequence index",
            })?;

        let next_collision = self.sequence_heads.get(&hash).copied();
        self.edges.extend_from_slice(children);
        self.sequences.push(SequenceRecord {
            span: Span { start, len },
            next_collision,
            encoded_body_len,
            max_child_depth,
            contains_mark,
        });
        self.sequence_heads.insert(hash, id);
        Ok(id)
    }

    fn intern_node(&mut self, key: NodeKey) -> Result<LocalId, StoreError> {
        if let Some(id) = self.node_ids.get(&key) {
            return Ok(*id);
        }
        self.ensure_node_capacity()?;

        let kind = key.header.kind;
        let marked = key.header.mark == Mark::Actionable;
        let (encoded_len, depth, contains_mark) = match (kind, key.body) {
            (Kind::Nil, BodyId::None) => (1, 0, marked),
            (kind, BodyId::Payload(payload)) if kind.is_atom() && kind != Kind::Nil => {
                let payload_len = self.payloads[payload.0 as usize].span.len as u64;
                let prefix_len = scalar_prefix_len(payload_len) as u64;
                (
                    prefix_len
                        .checked_add(payload_len)
                        .ok_or(StoreError::EncodedLengthOverflow)?,
                    0,
                    marked,
                )
            }
            (kind, BodyId::Sequence(sequence)) if kind.is_frame() => {
                let sequence = &self.sequences[sequence.0 as usize];
                let encoded_len = sequence
                    .encoded_body_len
                    .checked_add(2)
                    .ok_or(StoreError::EncodedLengthOverflow)?;
                let depth = sequence
                    .max_child_depth
                    .checked_add(1)
                    .ok_or(StoreError::DepthOverflow)?;
                (encoded_len, depth, marked || sequence.contains_mark)
            }
            _ => unreachable!("private constructors preserve node/body invariants"),
        };

        let id = LocalId(
            u32::try_from(self.nodes.len())
                .map_err(|_| StoreError::IdSpaceExhausted { arena: "value" })?,
        );
        self.nodes.push(NodeRecord {
            key,
            encoded_len,
            depth,
            contains_mark,
        });
        self.node_ids.insert(key, id);
        if kind.is_atom() {
            self.atom_count += 1;
        } else {
            self.frame_count += 1;
        }
        Ok(id)
    }

    fn ensure_node_capacity(&mut self) -> Result<(), StoreError> {
        u32::try_from(self.nodes.len())
            .map_err(|_| StoreError::IdSpaceExhausted { arena: "value" })?;
        self.nodes
            .try_reserve(1)
            .map_err(|_| StoreError::AllocationFailed { arena: "value" })?;
        self.node_ids
            .try_reserve(1)
            .map_err(|_| StoreError::AllocationFailed {
                arena: "value index",
            })?;
        Ok(())
    }

    fn payload_fingerprint(&self, bytes: &[u8]) -> u64 {
        let mut hasher = self.fingerprint.build_hasher();
        hasher.write_u8(0x50);
        hasher.write_usize(bytes.len());
        hasher.write(bytes);
        hasher.finish()
    }

    fn sequence_fingerprint(&self, children: &[LocalId]) -> u64 {
        let mut hasher = self.fingerprint.build_hasher();
        hasher.write_u8(0x53);
        hasher.write_usize(children.len());
        for child in children {
            hasher.write_u32(child.0);
        }
        hasher.finish()
    }

    fn find_payload(&self, bytes: &[u8]) -> Option<PayloadId> {
        self.find_payload_in_chain(bytes, self.payload_fingerprint(bytes))
    }

    fn find_payload_in_chain(&self, bytes: &[u8], hash: u64) -> Option<PayloadId> {
        let mut candidate = self.payload_heads.get(&hash).copied();
        while let Some(id) = candidate {
            let record = &self.payloads[id.0 as usize];
            if self.payload_slice(record.span) == bytes {
                return Some(id);
            }
            candidate = record.next_collision;
        }
        None
    }

    fn find_sequence(&self, children: &[LocalId]) -> Option<SequenceId> {
        self.find_sequence_in_chain(children, self.sequence_fingerprint(children))
    }

    fn find_sequence_in_chain(&self, children: &[LocalId], hash: u64) -> Option<SequenceId> {
        let mut candidate = self.sequence_heads.get(&hash).copied();
        while let Some(id) = candidate {
            let record = &self.sequences[id.0 as usize];
            if self.edge_slice(record.span) == children {
                return Some(id);
            }
            candidate = record.next_collision;
        }
        None
    }

    fn localize(&self, id: ValueId) -> Result<LocalId, StoreError> {
        if id.store != self.token {
            return Err(StoreError::ForeignValue {
                expected_store: self.token.get(),
                actual_store: id.store_token(),
            });
        }
        if id.slot() as usize >= self.nodes.len() {
            return Err(StoreError::UnknownValue { slot: id.slot() });
        }
        Ok(LocalId(id.slot()))
    }

    fn localize_all(&self, values: &[ValueId]) -> Result<Vec<LocalId>, StoreError> {
        let mut locals = Vec::new();
        locals
            .try_reserve_exact(values.len())
            .map_err(|_| StoreError::AllocationFailed {
                arena: "frame builder",
            })?;
        for value in values {
            locals.push(self.localize(*value)?);
        }
        Ok(locals)
    }

    fn externalize(&self, id: LocalId) -> ValueId {
        ValueId {
            store: self.token,
            slot: id.0,
        }
    }

    fn payload_slice(&self, span: Span) -> &[u8] {
        &self.payload_bytes[span.start..span.end()]
    }

    fn edge_slice(&self, span: Span) -> &[LocalId] {
        &self.edges[span.start..span.end()]
    }

    /// Compare canonical encodings without expanding common interned
    /// subtrees. This is equivalent to unsigned lexicographic CE comparison:
    /// scalar prefixes order first by kind/mark and then payload length, while
    /// frame children compare recursively and a longer frame sorts before its
    /// prefix because every value header is below `END_BYTE`.
    fn compare_local_with_stack(
        &self,
        left: LocalId,
        right: LocalId,
        stack: &mut Vec<CompareTask>,
    ) -> Ordering {
        stack.clear();
        stack.push(CompareTask::Node { left, right });

        while let Some(task) = stack.pop() {
            match task {
                CompareTask::Node { left, right } => {
                    if left == right {
                        continue;
                    }

                    let left_node = &self.nodes[left.0 as usize];
                    let right_node = &self.nodes[right.0 as usize];
                    match left_node
                        .key
                        .header
                        .ce_byte()
                        .cmp(&right_node.key.header.ce_byte())
                    {
                        Ordering::Equal => {}
                        ordering => return ordering,
                    }

                    match (left_node.key.body, right_node.key.body) {
                        (BodyId::None, BodyId::None) => {}
                        (BodyId::Payload(left), BodyId::Payload(right)) => {
                            let left = self.payloads[left.0 as usize].span;
                            let right = self.payloads[right.0 as usize].span;
                            match left.len.cmp(&right.len) {
                                Ordering::Equal => {}
                                ordering => return ordering,
                            }
                            match self.payload_slice(left).cmp(self.payload_slice(right)) {
                                Ordering::Equal => {}
                                ordering => return ordering,
                            }
                        }
                        (BodyId::Sequence(left), BodyId::Sequence(right)) => {
                            if left != right {
                                stack.push(CompareTask::Sequence {
                                    left,
                                    right,
                                    next: 0,
                                });
                            }
                        }
                        _ => unreachable!("equal headers imply equal body classes"),
                    }
                }
                CompareTask::Sequence { left, right, next } => {
                    let left_span = self.sequences[left.0 as usize].span;
                    let right_span = self.sequences[right.0 as usize].span;
                    let common_len = left_span.len.min(right_span.len);

                    if next < common_len {
                        let left_child =
                            self.edges[left_span.start + usize::try_from(next).unwrap()];
                        let right_child =
                            self.edges[right_span.start + usize::try_from(next).unwrap()];
                        stack.push(CompareTask::Sequence {
                            left,
                            right,
                            next: next + 1,
                        });
                        stack.push(CompareTask::Node {
                            left: left_child,
                            right: right_child,
                        });
                    } else {
                        match left_span.len.cmp(&right_span.len) {
                            // The shorter frame emits END (0xA0), while the
                            // longer emits another value header (< 0xA0).
                            Ordering::Less => return Ordering::Greater,
                            Ordering::Greater => return Ordering::Less,
                            Ordering::Equal => {}
                        }
                    }
                }
            }
        }

        Ordering::Equal
    }

    fn encode_local_into(&self, local: LocalId, output: &mut Vec<u8>) {
        let mut stack = Vec::new();
        let mut cursor = CeCursor::new(self, local, &mut stack);
        while let Some(byte) = cursor.next_byte() {
            output.push(byte);
        }
    }
}

/// A borrowed, immutable view into one resident value.
pub struct ValueRef<'a, S = RandomState> {
    store: &'a ValueStore<S>,
    local: LocalId,
}

impl<'a, S: BuildHasher> ValueRef<'a, S> {
    pub fn id(&self) -> ValueId {
        self.store.externalize(self.local)
    }

    pub fn kind(&self) -> Kind {
        self.node().key.header.kind
    }

    pub fn mark(&self) -> Mark {
        self.node().key.header.mark
    }

    pub fn is_marked(&self) -> bool {
        self.mark() == Mark::Actionable
    }

    pub fn contains_mark(&self) -> bool {
        self.node().contains_mark
    }

    pub fn depth(&self) -> u32 {
        self.node().depth
    }

    pub fn encoded_len(&self) -> u64 {
        self.node().encoded_len
    }

    pub fn payload(&self) -> Option<&'a [u8]> {
        match self.node().key.body {
            BodyId::Payload(id) => {
                let span = self.store.payloads[id.0 as usize].span;
                Some(self.store.payload_slice(span))
            }
            BodyId::None | BodyId::Sequence(_) => None,
        }
    }

    pub fn text_payload(&self) -> Option<&'a str> {
        match self.kind() {
            Kind::Integer | Kind::Text | Kind::Symbol => {
                Some(std::str::from_utf8(self.payload()?).expect("validated UTF-8 payload"))
            }
            _ => None,
        }
    }

    pub fn children(&self) -> Option<Children<'a>> {
        match self.node().key.body {
            BodyId::Sequence(id) => {
                let span = self.store.sequences[id.0 as usize].span;
                Some(Children {
                    store: self.store.token,
                    inner: self.store.edge_slice(span).iter(),
                })
            }
            BodyId::None | BodyId::Payload(_) => None,
        }
    }

    pub fn head(&self) -> Option<ValueId> {
        if self.kind() != Kind::Record {
            return None;
        }
        self.children()?.next()
    }

    fn node(&self) -> &'a NodeRecord {
        &self.store.nodes[self.local.0 as usize]
    }
}

impl<S> fmt::Debug for ValueRef<'_, S> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ValueRef")
            .field("store", &self.store.token.get())
            .field("slot", &self.local.0)
            .finish()
    }
}

pub struct Children<'a> {
    store: NonZeroU32,
    inner: slice::Iter<'a, LocalId>,
}

impl Iterator for Children<'_> {
    type Item = ValueId;

    fn next(&mut self) -> Option<Self::Item> {
        self.inner.next().map(|local| ValueId {
            store: self.store,
            slot: local.0,
        })
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.inner.size_hint()
    }
}

impl DoubleEndedIterator for Children<'_> {
    fn next_back(&mut self) -> Option<Self::Item> {
        self.inner.next_back().map(|local| ValueId {
            store: self.store,
            slot: local.0,
        })
    }
}

impl ExactSizeIterator for Children<'_> {}
impl std::iter::FusedIterator for Children<'_> {}

#[derive(Debug, Clone, Copy)]
enum CompareTask {
    Node {
        left: LocalId,
        right: LocalId,
    },
    Sequence {
        left: SequenceId,
        right: SequenceId,
        next: u32,
    },
}

#[derive(Debug, Clone, Copy)]
enum EmitTask {
    Node(LocalId),
    Sequence { sequence: SequenceId, next: u32 },
    Payload(PayloadId),
}

#[derive(Debug, Clone, Copy)]
enum Segment {
    Inline { bytes: [u8; 6], len: u8, next: u8 },
    Payload { payload: PayloadId, next: u32 },
}

/// Iterative CE emitter. Its task space is proportional to nesting depth, not
/// frame arity, and it never caches complete encodings on value nodes.
struct CeCursor<'store, 'stack, S> {
    store: &'store ValueStore<S>,
    tasks: &'stack mut Vec<EmitTask>,
    segment: Option<Segment>,
}

impl<'store, 'stack, S: BuildHasher> CeCursor<'store, 'stack, S> {
    fn new(store: &'store ValueStore<S>, root: LocalId, tasks: &'stack mut Vec<EmitTask>) -> Self {
        tasks.clear();
        tasks.push(EmitTask::Node(root));
        Self {
            store,
            tasks,
            segment: None,
        }
    }

    fn next_byte(&mut self) -> Option<u8> {
        loop {
            if let Some(segment) = self.segment.take() {
                match segment {
                    Segment::Inline { bytes, len, next } => {
                        if next < len {
                            let byte = bytes[next as usize];
                            if next + 1 < len {
                                self.segment = Some(Segment::Inline {
                                    bytes,
                                    len,
                                    next: next + 1,
                                });
                            }
                            return Some(byte);
                        }
                    }
                    Segment::Payload { payload, next } => {
                        let record = &self.store.payloads[payload.0 as usize];
                        if next < record.span.len {
                            let byte = self.store.payload_bytes[record.span.start + next as usize];
                            if next + 1 < record.span.len {
                                self.segment = Some(Segment::Payload {
                                    payload,
                                    next: next + 1,
                                });
                            }
                            return Some(byte);
                        }
                    }
                }
            }

            match self.tasks.pop()? {
                EmitTask::Node(id) => {
                    let node = &self.store.nodes[id.0 as usize];
                    let kind = node.key.header.kind;
                    match node.key.body {
                        BodyId::None => return Some(node.key.header.ce_byte()),
                        BodyId::Payload(payload) => {
                            debug_assert!(kind.is_atom() && kind != Kind::Nil);
                            let len = self.store.payloads[payload.0 as usize].span.len;
                            let (prefix, prefix_len) = scalar_prefix(node.key.header, len);
                            self.tasks.push(EmitTask::Payload(payload));
                            self.segment = Some(Segment::Inline {
                                bytes: prefix,
                                len: prefix_len,
                                next: 0,
                            });
                        }
                        BodyId::Sequence(sequence) => {
                            debug_assert!(kind.is_frame());
                            self.tasks.push(EmitTask::Sequence { sequence, next: 0 });
                            return Some(node.key.header.ce_byte());
                        }
                    }
                }
                EmitTask::Sequence { sequence, next } => {
                    let record = &self.store.sequences[sequence.0 as usize];
                    if next < record.span.len {
                        let child = self.store.edges[record.span.start + next as usize];
                        self.tasks.push(EmitTask::Sequence {
                            sequence,
                            next: next + 1,
                        });
                        self.tasks.push(EmitTask::Node(child));
                    } else {
                        return Some(END_BYTE);
                    }
                }
                EmitTask::Payload(payload) => {
                    self.segment = Some(Segment::Payload { payload, next: 0 });
                }
            }
        }
    }
}

fn scalar_prefix(header: Header, len: u32) -> ([u8; 6], u8) {
    let mut bytes = [0u8; 6];
    let base_header = header.ce_byte();
    if len <= 6 {
        bytes[0] = base_header | len as u8;
        (bytes, 1)
    } else if len <= 254 {
        bytes[0] = base_header | 7;
        bytes[1] = len as u8;
        (bytes, 2)
    } else {
        bytes[0] = base_header | 7;
        bytes[1] = 0xFF;
        bytes[2..6].copy_from_slice(&len.to_be_bytes());
        (bytes, 6)
    }
}

const fn scalar_prefix_len(len: u64) -> u8 {
    if len <= 6 {
        1
    } else if len <= 254 {
        2
    } else {
        6
    }
}

fn is_canonical_integer(bytes: &[u8]) -> bool {
    match bytes {
        b"0" => true,
        [b'1'..=b'9', rest @ ..] => rest.iter().all(u8::is_ascii_digit),
        [b'-', b'1'..=b'9', rest @ ..] => rest.iter().all(u8::is_ascii_digit),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const P: Mark = Mark::Plain;
    const A: Mark = Mark::Actionable;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02X}")).collect()
    }

    fn ce<S: BuildHasher>(store: &ValueStore<S>, id: ValueId) -> String {
        hex(&store.encode(id).unwrap())
    }

    #[derive(Clone, Default)]
    struct ZeroBuildHasher;

    struct ZeroHasher;

    impl BuildHasher for ZeroBuildHasher {
        type Hasher = ZeroHasher;

        fn build_hasher(&self) -> Self::Hasher {
            ZeroHasher
        }
    }

    impl Hasher for ZeroHasher {
        fn finish(&self) -> u64 {
            0
        }

        fn write(&mut self, _bytes: &[u8]) {}
    }

    #[test]
    fn handles_and_resident_edges_are_compact() {
        assert_eq!(std::mem::size_of::<ValueId>(), 8);
        assert_eq!(std::mem::size_of::<Option<ValueId>>(), 8);
        assert_eq!(std::mem::size_of::<LocalId>(), 4);
    }

    #[test]
    fn atoms_share_payloads_and_intern_exact_values() {
        let mut store = ValueStore::new();
        let int = store.integer("42", P).unwrap();
        let text = store.text("42", P).unwrap();
        let symbol = store.symbol("42", P).unwrap();
        let bytes = store.bytes(b"42", P).unwrap();
        let marked_text = store.text("42", A).unwrap();

        assert_eq!(store.stats().payloads, 1);
        assert_eq!(store.stats().payload_bytes, 2);
        assert_eq!(store.stats().atoms, 5);
        assert_ne!(int, text);
        assert_ne!(text, symbol);
        assert_ne!(symbol, bytes);
        assert_ne!(text, marked_text);

        let before = store.stats();
        let again = store.text(&String::from("42"), P).unwrap();
        assert_eq!(again, text);
        assert_eq!(store.stats(), before);
    }

    #[test]
    fn sequences_are_interned_independently_of_frame_kind_and_mark() {
        let mut store = ValueStore::new();
        let one = store.integer("1", P).unwrap();
        let list = store.list(&[one], P).unwrap();
        let record = store.record(one, &[], P).unwrap();
        let marked_list = store.list(&[one], A).unwrap();
        let set = store.set(&[one], P).unwrap();

        assert_eq!(store.stats().sequences, 1);
        assert_eq!(store.stats().edge_words, 1);
        assert_ne!(list, record);
        assert_ne!(list, marked_list);
        assert_ne!(list, set);

        let empty_list = store.list(&[], P).unwrap();
        let empty_dict = store.dictionary(&[], P).unwrap();
        let empty_set = store.set(&[], P).unwrap();
        assert_eq!(store.stats().sequences, 2);
        assert_ne!(empty_list, empty_dict);
        assert_ne!(empty_dict, empty_set);

        let before = store.stats();
        assert_eq!(store.list(&[one], P).unwrap(), list);
        assert_eq!(store.stats(), before);
    }

    #[test]
    fn set_and_dictionary_are_insertion_order_independent() {
        let mut store = ValueStore::new();
        let a = store.symbol("a", P).unwrap();
        let b = store.symbol("b", P).unwrap();
        let one = store.integer("1", P).unwrap();
        let two = store.integer("2", P).unwrap();

        let set_ab = store.set(&[a, b], P).unwrap();
        let set_ba = store.set(&[b, a], P).unwrap();
        assert_eq!(set_ab, set_ba);

        let dict_ab = store.dictionary(&[(a, one), (b, two)], P).unwrap();
        let dict_ba = store.dictionary(&[(b, two), (a, one)], P).unwrap();
        assert_eq!(dict_ab, dict_ba);
        assert_eq!(ce(&store, dict_ab), "804161213141622132A0");
    }

    #[test]
    fn duplicate_collection_inputs_are_explicit() {
        let mut store = ValueStore::new();
        let a = store.symbol("a", P).unwrap();
        let one = store.integer("1", P).unwrap();
        let two = store.integer("2", P).unwrap();
        let before = store.stats();

        assert!(matches!(
            store.set(&[a, a], P),
            Err(StoreError::DuplicateSetMember { .. })
        ));
        assert!(matches!(
            store.dictionary(&[(a, one), (a, two)], P),
            Err(StoreError::DuplicateDictionaryKey { .. })
        ));
        assert_eq!(store.stats(), before);

        let coalesced = store.set_coalescing(&[a, a], P).unwrap();
        let singleton = store.set(&[a], P).unwrap();
        assert_eq!(coalesced, singleton);
    }

    #[test]
    fn marking_is_shallow_and_shares_the_body() {
        let mut store = ValueStore::new();
        let x = store.symbol("x", P).unwrap();
        let marked_x = store.with_mark(x, A).unwrap();
        let plain_list = store.list(&[x], P).unwrap();
        let marked_root = store.with_mark(plain_list, A).unwrap();
        let marked_child = store.list(&[marked_x], P).unwrap();

        assert_ne!(marked_root, marked_child);
        assert!(store.get(marked_root).unwrap().is_marked());
        assert!(store.get(marked_root).unwrap().contains_mark());
        assert!(!store.get(plain_list).unwrap().contains_mark());
        assert!(!store.get(marked_child).unwrap().is_marked());
        assert!(store.get(marked_child).unwrap().contains_mark());

        let plain_ce = store.encode(plain_list).unwrap();
        let marked_ce = store.encode(marked_root).unwrap();
        assert_eq!(plain_ce.len(), marked_ce.len());
        assert_eq!(plain_ce[0] ^ marked_ce[0], ACTION_MASK);
        assert_eq!(&plain_ce[1..], &marked_ce[1..]);

        assert_eq!(store.with_mark(marked_root, P).unwrap(), plain_list);
        assert_eq!(store.with_mark(marked_root, A).unwrap(), marked_root);
    }

    #[test]
    fn canonical_encoding_matches_independent_vectors() {
        let mut store = ValueStore::new();
        let nil = store.nil(P).unwrap();
        let marked_nil = store.nil(A).unwrap();
        let zero = store.integer("0", P).unwrap();
        let one = store.integer("1", P).unwrap();
        let neg_one = store.integer("-1", P).unwrap();
        let two_fifty_five = store.integer("255", P).unwrap();
        let seven_digits = store.integer("1234567", P).unwrap();
        let hi = store.text("hi", P).unwrap();
        let foo = store.symbol("foo", P).unwrap();
        let marked_x = store.symbol("x", A).unwrap();
        let ff = store.bytes(&[0xFF], P).unwrap();
        let empty_list = store.list(&[], P).unwrap();
        let list_one = store.list(&[one], P).unwrap();
        let marked_list = store.list(&[one], A).unwrap();
        let record_foo = store.record(foo, &[], P).unwrap();
        let empty_dict = store.dictionary(&[], P).unwrap();
        let empty_set = store.set(&[], P).unwrap();

        let vectors = [
            (nil, "10"),
            (marked_nil, "18"),
            (zero, "2130"),
            (one, "2131"),
            (neg_one, "222D31"),
            (two_fifty_five, "23323535"),
            (seven_digits, "270731323334353637"),
            (hi, "326869"),
            (foo, "43666F6F"),
            (marked_x, "4978"),
            (ff, "51FF"),
            (empty_list, "60A0"),
            (list_one, "602131A0"),
            (marked_list, "682131A0"),
            (record_foo, "7043666F6FA0"),
            (empty_dict, "80A0"),
            (empty_set, "90A0"),
        ];
        for (value, expected) in vectors {
            assert_eq!(ce(&store, value), expected);
            assert_eq!(
                store.get(value).unwrap().encoded_len() as usize,
                expected.len() / 2
            );
        }
    }

    #[test]
    fn scalar_length_tiers_are_exact() {
        let mut store = ValueStore::new();
        for (len, expected_prefix) in [
            (0, "30"),
            (6, "36"),
            (7, "3707"),
            (254, "37FE"),
            (255, "37FF000000FF"),
            (300, "37FF0000012C"),
        ] {
            let value = store.text(&"x".repeat(len), P).unwrap();
            assert!(ce(&store, value).starts_with(expected_prefix));
        }
    }

    #[test]
    fn ce_order_handles_shortlex_mark_and_end_high_rules() {
        let mut store = ValueStore::new();
        let z = store.symbol("z", P).unwrap();
        let aa = store.symbol("aa", P).unwrap();
        let marked_a = store.symbol("a", A).unwrap();
        let one = store.integer("1", P).unwrap();
        let two = store.integer("2", P).unwrap();
        let short = store.list(&[one], P).unwrap();
        let long = store.list(&[one, two], P).unwrap();

        assert_eq!(store.compare(z, aa).unwrap(), Ordering::Less);
        assert_eq!(store.compare(aa, marked_a).unwrap(), Ordering::Less);
        assert_eq!(store.compare(long, short).unwrap(), Ordering::Less);

        for (left, right) in [(z, aa), (aa, marked_a), (long, short)] {
            assert_eq!(
                store.compare(left, right).unwrap(),
                store
                    .encode(left)
                    .unwrap()
                    .cmp(&store.encode(right).unwrap())
            );
        }
    }

    #[test]
    fn comparator_matches_encoded_bytes_for_a_mixed_resident_corpus() {
        let mut store = ValueStore::new();
        let nil = store.nil(P).unwrap();
        let marked_nil = store.nil(A).unwrap();
        let neg = store.integer("-10", P).unwrap();
        let zero = store.integer("0", P).unwrap();
        let seven = store.integer("7", P).unwrap();
        let empty_text = store.text("", P).unwrap();
        let long_text = store.text("seven!!", P).unwrap();
        let z = store.symbol("z", P).unwrap();
        let aa = store.symbol("aa", P).unwrap();
        let marked_symbol = store.symbol("a", A).unwrap();
        let low_bytes = store.bytes(&[0x00], P).unwrap();
        let high_bytes = store.bytes(&[0xFF], P).unwrap();
        let empty_list = store.list(&[], P).unwrap();
        let list_nil = store.list(&[nil], P).unwrap();
        let list_two = store.list(&[nil, seven], P).unwrap();
        let record = store.record(z, &[seven], P).unwrap();
        let dictionary = store.dictionary(&[(aa, zero), (z, seven)], P).unwrap();
        let set = store.set(&[record, list_nil, high_bytes], P).unwrap();

        let values = [
            nil,
            marked_nil,
            neg,
            zero,
            seven,
            empty_text,
            long_text,
            z,
            aa,
            marked_symbol,
            low_bytes,
            high_bytes,
            empty_list,
            list_nil,
            list_two,
            record,
            dictionary,
            set,
        ];

        for left in values {
            for right in values {
                assert_eq!(
                    store.compare(left, right).unwrap(),
                    store
                        .encode(left)
                        .unwrap()
                        .cmp(&store.encode(right).unwrap()),
                    "comparison mismatch for {left:?} and {right:?}"
                );
            }
        }
    }

    #[test]
    fn every_kind_has_an_orthogonal_marked_counterpart() {
        let mut store = ValueStore::new();
        let nil = store.nil(P).unwrap();
        let integer = store.integer("1", P).unwrap();
        let text = store.text("text", P).unwrap();
        let symbol = store.symbol("symbol", P).unwrap();
        let bytes = store.bytes(b"bytes", P).unwrap();
        let list = store.list(&[integer], P).unwrap();
        let record = store.record(symbol, &[text], P).unwrap();
        let dictionary = store.dictionary(&[(symbol, integer)], P).unwrap();
        let set = store.set(&[bytes], P).unwrap();
        let plain_values = [
            nil, integer, text, symbol, bytes, list, record, dictionary, set,
        ];

        let sequence_count = store.stats().sequences;
        let payload_count = store.stats().payloads;
        for plain in plain_values {
            let marked = store.with_mark(plain, A).unwrap();
            let plain_ce = store.encode(plain).unwrap();
            let marked_ce = store.encode(marked).unwrap();
            assert_eq!(
                store.get(marked).unwrap().kind(),
                store.get(plain).unwrap().kind()
            );
            assert_eq!(plain_ce[0] ^ marked_ce[0], ACTION_MASK);
            assert_eq!(&plain_ce[1..], &marked_ce[1..]);
        }
        assert_eq!(store.stats().payloads, payload_count);
        assert_eq!(store.stats().sequences, sequence_count);
    }

    #[test]
    fn set_sorting_uses_full_unsigned_ce() {
        let mut store = ValueStore::new();
        let b80 = store.bytes(&[0x80], P).unwrap();
        let ba0 = store.bytes(&[0xA0], P).unwrap();
        let high = store.set(&[ba0, b80], P).unwrap();
        assert_eq!(ce(&store, high), "90518051A0A0");

        let one = store.integer("1", P).unwrap();
        let two = store.integer("2", P).unwrap();
        let short = store.list(&[one], P).unwrap();
        let long = store.list(&[one, two], P).unwrap();
        let framed = store.set(&[short, long], P).unwrap();
        assert_eq!(ce(&store, framed), "906021312132A0602131A0A0");
    }

    #[test]
    fn collision_chains_compare_complete_payloads_and_sequences() {
        let mut store = ValueStore::with_hasher(ZeroBuildHasher);
        let a = store.bytes(b"a", P).unwrap();
        let b = store.bytes(b"b", P).unwrap();
        let c = store.bytes(b"c", P).unwrap();
        assert_ne!(a, b);
        assert_ne!(b, c);
        assert_eq!(store.bytes(b"a", P).unwrap(), a);

        let ab = store.list(&[a, b], P).unwrap();
        let ac = store.list(&[a, c], P).unwrap();
        assert_ne!(ab, ac);
        assert_eq!(store.list(&[a, b], P).unwrap(), ab);
        assert_eq!(store.stats().payloads, 3);
        assert_eq!(store.stats().sequences, 2);
    }

    #[test]
    fn handles_are_store_scoped_but_ce_is_not() {
        let mut left = ValueStore::new();
        let mut right = ValueStore::new();
        let left_one = left.integer("1", P).unwrap();
        let left_head = left.symbol("point", P).unwrap();
        let left_value = left.record(left_head, &[left_one], P).unwrap();
        let right_one = right.integer("1", P).unwrap();
        let right_head = right.symbol("point", P).unwrap();
        let right_value = right.record(right_head, &[right_one], P).unwrap();

        assert_ne!(left_value, right_value);
        assert_eq!(
            left.encode(left_value).unwrap(),
            right.encode(right_value).unwrap()
        );
        assert!(matches!(
            left.encode(right_value),
            Err(StoreError::ForeignValue { .. })
        ));

        let forged = ValueId {
            store: left.token,
            slot: u32::MAX,
        };
        assert_eq!(
            left.get(forged).unwrap_err(),
            StoreError::UnknownValue { slot: u32::MAX }
        );
    }

    #[test]
    fn caller_mutation_cannot_reach_resident_values() {
        let mut store = ValueStore::new();
        let mut source = vec![1u8, 2, 3];
        let bytes = store.bytes(&source, P).unwrap();
        let before = store.encode(bytes).unwrap();
        source.fill(9);
        assert_eq!(store.encode(bytes).unwrap(), before);

        let one = store.integer("1", P).unwrap();
        let two = store.integer("2", P).unwrap();
        let mut children = vec![one];
        let list = store.list(&children, P).unwrap();
        children[0] = two;
        assert_eq!(ce(&store, list), "602131A0");

        let mut handed_out = store.encode(list).unwrap();
        handed_out.fill(0);
        assert_eq!(ce(&store, list), "602131A0");
    }

    #[test]
    fn arena_reallocation_never_invalidates_old_ids() {
        let mut store = ValueStore::new();
        let first = store.text("first", P).unwrap();
        let first_ce = store.encode(first).unwrap();
        for i in 0..20_000 {
            let value = store.text(&format!("value-{i}"), P).unwrap();
            let _ = store.list(&[value], P).unwrap();
        }
        assert_eq!(store.encode(first).unwrap(), first_ce);
        assert_eq!(store.text("first", P).unwrap(), first);
    }

    #[test]
    fn deep_values_encode_iteratively() {
        let mut store = ValueStore::new();
        let mut value = store.integer("1", P).unwrap();
        let depth = 10_000usize;
        for _ in 0..depth {
            value = store.list(&[value], P).unwrap();
        }

        let encoded = store.encode(value).unwrap();
        assert_eq!(encoded.len(), 2 * depth + 2);
        assert_eq!(encoded[0], 0x60);
        assert_eq!(encoded[encoded.len() - 1], END_BYTE);
        assert_eq!(store.get(value).unwrap().depth(), depth as u32);

        let marked = store.with_mark(value, A).unwrap();
        assert_eq!(store.compare(value, marked).unwrap(), Ordering::Less);
    }

    #[test]
    fn comparison_skips_an_exponentially_large_shared_prefix() {
        let mut store = ValueStore::new();
        let mut common = store.list(&[], P).unwrap();
        for _ in 0..40 {
            common = store.list(&[common, common], P).unwrap();
        }

        let one = store.integer("1", P).unwrap();
        let two = store.integer("2", P).unwrap();
        let left = store.list(&[common, one], P).unwrap();
        let right = store.list(&[common, two], P).unwrap();

        assert!(store.get(common).unwrap().encoded_len() > 1_000_000_000_000);
        assert_eq!(store.compare(left, right).unwrap(), Ordering::Less);
        let set = store.set(&[right, left], P).unwrap();
        assert_eq!(
            store
                .get(set)
                .unwrap()
                .children()
                .unwrap()
                .collect::<Vec<_>>(),
            vec![left, right]
        );
    }

    #[test]
    fn expanded_length_overflow_is_failure_atomic() {
        let mut store = ValueStore::new();
        let mut value = store.list(&[], P).unwrap();
        for _ in 0..62 {
            value = store.list(&[value, value], P).unwrap();
        }
        assert_eq!(store.get(value).unwrap().encoded_len(), u64::MAX - 1);

        let before = store.stats();
        assert_eq!(
            store.list(&[value], P),
            Err(StoreError::EncodedLengthOverflow)
        );
        assert_eq!(store.stats(), before);
    }

    #[test]
    fn encode_into_reserves_before_mutating_the_sink() {
        let mut store = ValueStore::new();
        let one = store.integer("1", P).unwrap();
        let mut output = vec![0xFF];
        store.encode_into(one, &mut output).unwrap();
        assert_eq!(output, vec![0xFF, 0x21, b'1']);

        let mut enormous = store.list(&[], P).unwrap();
        for _ in 0..62 {
            enormous = store.list(&[enormous, enormous], P).unwrap();
        }
        let before = output.clone();
        assert!(matches!(
            store.encode_into(enormous, &mut output),
            Err(StoreError::ValueTooLargeForPlatform { .. })
                | Err(StoreError::AllocationFailed { arena: "CE output" })
                | Err(StoreError::ArenaLengthOverflow)
        ));
        assert_eq!(output, before);
    }

    #[test]
    fn integer_validation_is_strict() {
        let mut store = ValueStore::new();
        for invalid in ["", "+1", "-0", "00", "01", "-01", "1.0", "a"] {
            assert_eq!(store.integer(invalid, P), Err(StoreError::InvalidInteger));
        }
        for valid in ["0", "1", "-1", "999999999999999999999999999999"] {
            assert!(store.integer(valid, P).is_ok());
        }
    }

    #[test]
    fn borrowed_views_expose_structure_without_mutability() {
        let mut store = ValueStore::new();
        let head = store.symbol("point", P).unwrap();
        let x = store.integer("3", P).unwrap();
        let y = store.integer("4", A).unwrap();
        let point = store.record(head, &[x, y], P).unwrap();
        let view = store.get(point).unwrap();

        assert_eq!(view.kind(), Kind::Record);
        assert_eq!(view.head(), Some(head));
        assert!(!view.is_marked());
        assert!(view.contains_mark());
        assert_eq!(
            view.children().unwrap().collect::<Vec<_>>(),
            vec![head, x, y]
        );
        assert_eq!(store.get(head).unwrap().text_payload(), Some("point"));
    }
}
