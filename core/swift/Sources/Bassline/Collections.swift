// Dictionaries and sets keep their members in canonical order at all times,
// so iterating, printing and encoding them is a straight walk, and two equal
// collections always iterate identically (unlike Swift.Dictionary, whose
// order changes from run to run).
//
// Both are backed by a copy-on-write B-tree (CanonicalTree): lookups,
// inserts and removals are O(log n), copies are O(1), and mutating a shared
// copy only copies the nodes on the path it touches.
//
// Positions use an opaque Index, as Swift.Dictionary does, so that `dict[0]`
// looks up the key `0` rather than the first entry. Reaching a position is
// O(log n); iterating is O(1) per element.

private func isStrictlyAscending(_ values: some Sequence<Value>) -> Bool {
    var previous: Value?
    for value in values {
        if let previous, Value.canonicalCompare(previous, value) >= 0 { return false }
        previous = value
    }
    return true
}

/// An opaque position in a ``Value/Dict`` or ``Value/Set``.
public struct CanonicalIndex: Comparable, Hashable, Sendable {
    fileprivate var offset: Int

    public static func < (a: CanonicalIndex, b: CanonicalIndex) -> Bool {
        a.offset < b.offset
    }
}

// MARK: - Dict

extension Value {
    /// Associations from key to value, kept in canonical key order.
    ///
    /// `dict[key] = nil` removes the key (silence); `dict[key] = .null`
    /// states that the value is absent.
    public struct Dict: Sendable {
        public typealias Element = (key: Value, value: Value)

        struct Entry: CanonicalKeyed {
            var key: Value
            var value: Value
            var canonicalKey: Value { key }
        }

        private var tree: CanonicalTree<Entry>

        public init() {
            tree = CanonicalTree()
        }

        /// Later pairs win over earlier pairs with the same key. O(n log n).
        public init<S: Sequence>(_ pairs: S) where S.Element == (Value, Value) {
            tree = CanonicalTree()
            for (key, value) in pairs { tree.insert(Entry(key: key, value: value)) }
        }

        /// Entries the decoder has already checked are strictly ascending. O(n).
        init(uncheckedSorted entries: [Element]) {
            assert(isStrictlyAscending(entries.lazy.map(\.key)), "decoder produced out-of-order keys")
            tree = CanonicalTree(ascending: entries.map { Entry(key: $0.key, value: $0.value) })
        }

        init(literalEntries: [(Value, Value)]) {
            self.init()
            for (key, value) in literalEntries {
                precondition(updateValue(value, forKey: key) == nil, "Dict literal contains duplicate keys")
            }
        }

        /// The value for `key`. Edits through this subscript happen in place:
        /// `dict[key]?.withList { $0.append(1) }` doesn't copy the list.
        public subscript(key: Value) -> Value? {
            get {
                tree.find(key)?.value
            }
            set {
                if let newValue {
                    tree.insert(Entry(key: key, value: newValue))
                } else {
                    tree.remove(key)
                }
            }
            _modify {
                // Move the value out of the tree, so the caller edits the
                // only reference to it, then put back whatever they leave.
                var slot = tree.modify(key: key) { entry in
                    var taken = Value.null
                    swap(&taken, &entry.value)
                    return taken
                }
                let existed = slot != nil
                defer {
                    switch (existed, slot) {
                    case (true, let value?):
                        tree.modify(key: key) { $0.value = value }
                    case (true, nil):
                        tree.remove(key)
                    case (false, let value?):
                        tree.insert(Entry(key: key, value: value))
                    case (false, nil):
                        break
                    }
                }
                yield &slot
            }
        }

        /// Sets the value for `key`, returning the value it replaced.
        @discardableResult
        public mutating func updateValue(_ value: Value, forKey key: Value) -> Value? {
            tree.insert(Entry(key: key, value: value))?.value
        }

        @discardableResult
        public mutating func removeValue(forKey key: Value) -> Value? {
            tree.remove(key)?.value
        }

        public var keys: LazyMapSequence<Dict, Value> {
            lazy.map(\.key)
        }

        public var values: LazyMapSequence<Dict, Value> {
            lazy.map(\.value)
        }
    }
}

extension Value.Dict: RandomAccessCollection {
    public typealias Index = CanonicalIndex

    public struct Iterator: IteratorProtocol {
        fileprivate var base: CanonicalTree<Entry>.Iterator

        public mutating func next() -> Element? {
            base.next().map { ($0.key, $0.value) }
        }
    }

    public func makeIterator() -> Iterator { Iterator(base: tree.makeIterator()) }

    public var startIndex: Index { Index(offset: 0) }
    public var endIndex: Index { Index(offset: tree.count) }
    public var count: Int { tree.count }
    public var isEmpty: Bool { tree.isEmpty }
    public var underestimatedCount: Int { tree.count }

    public func index(after i: Index) -> Index { Index(offset: i.offset + 1) }
    public func index(before i: Index) -> Index { Index(offset: i.offset - 1) }
    public func index(_ i: Index, offsetBy distance: Int) -> Index { Index(offset: i.offset + distance) }
    public func distance(from start: Index, to end: Index) -> Int { end.offset - start.offset }

    /// O(log n).
    public subscript(position: Index) -> Element {
        let entry = tree.element(at: position.offset)
        return (entry.key, entry.value)
    }
}

extension Value.Dict: Hashable {
    public static func == (a: Value.Dict, b: Value.Dict) -> Bool {
        a.count == b.count && a.elementsEqual(b) { $0.key == $1.key && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        for (key, value) in self {
            hasher.combine(key)
            hasher.combine(value)
        }
    }
}

extension Value.Dict: ExpressibleByDictionaryLiteral {
    /// Traps on duplicate keys, like `Swift.Dictionary`.
    public init(dictionaryLiteral elements: (Value, Value)...) {
        self.init(literalEntries: elements)
    }
}

// MARK: - Set

extension Value {
    /// Unique members, kept in canonical order.
    public struct Set: Sendable {
        private var tree: CanonicalTree<Value>

        public init() {
            tree = CanonicalTree()
        }

        /// Duplicates collapse to one member. O(n log n).
        public init(_ values: some Sequence<Value>) {
            tree = CanonicalTree()
            for member in values where tree.find(member) == nil { tree.insert(member) }
        }

        /// Members the decoder has already checked are strictly ascending. O(n).
        init(uncheckedSorted members: [Value]) {
            assert(isStrictlyAscending(members), "decoder produced out-of-order members")
            tree = CanonicalTree(ascending: members)
        }

        public func contains(_ member: Value) -> Bool {
            tree.find(member) != nil
        }

        @discardableResult
        public mutating func insert(_ member: Value) -> (inserted: Bool, memberAfterInsert: Value) {
            if let existing = tree.find(member) { return (false, existing) }
            tree.insert(member)
            return (true, member)
        }

        @discardableResult
        public mutating func remove(_ member: Value) -> Value? {
            tree.remove(member)
        }
    }
}

extension Value.Set: RandomAccessCollection {
    public typealias Index = CanonicalIndex

    public struct Iterator: IteratorProtocol {
        fileprivate var base: CanonicalTree<Value>.Iterator

        public mutating func next() -> Value? { base.next() }
    }

    public func makeIterator() -> Iterator { Iterator(base: tree.makeIterator()) }

    public var startIndex: Index { Index(offset: 0) }
    public var endIndex: Index { Index(offset: tree.count) }
    public var count: Int { tree.count }
    public var isEmpty: Bool { tree.isEmpty }
    public var underestimatedCount: Int { tree.count }

    public func index(after i: Index) -> Index { Index(offset: i.offset + 1) }
    public func index(before i: Index) -> Index { Index(offset: i.offset - 1) }
    public func index(_ i: Index, offsetBy distance: Int) -> Index { Index(offset: i.offset + distance) }
    public func distance(from start: Index, to end: Index) -> Int { end.offset - start.offset }

    /// O(log n).
    public subscript(position: Index) -> Value {
        tree.element(at: position.offset)
    }
}

extension Value.Set: Hashable {
    public static func == (a: Value.Set, b: Value.Set) -> Bool {
        a.count == b.count && a.elementsEqual(b)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        for member in self { hasher.combine(member) }
    }
}

extension Value.Set: ExpressibleByArrayLiteral {
    /// Traps on duplicate members, as the textual syntax refuses `{1 1}`.
    public init(arrayLiteral members: Value...) {
        self.init()
        for member in members {
            precondition(insert(member).inserted, "Set literal contains duplicate members")
        }
    }
}
