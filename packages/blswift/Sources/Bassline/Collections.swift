// Dictionaries and sets keep their members in canonical order at all times,
// so iterating, printing and encoding them is a straight walk, and two equal
// collections always iterate identically (unlike Swift.Dictionary, whose
// order changes from run to run).
//
// Positions use an opaque Index, as Swift.Dictionary does, so that `dict[0]`
// looks up the key `0` rather than the first entry.

/// Binary search for `key` in canonically sorted storage.
private func search<C: RandomAccessCollection<Value>>(_ key: Value, in keys: C) -> (found: Bool, index: C.Index) {
    var low = keys.startIndex, high = keys.endIndex
    while low < high {
        let mid = keys.index(low, offsetBy: keys.distance(from: low, to: high) / 2)
        let c = Value.canonicalCompare(keys[mid], key)
        if c == 0 { return (true, mid) }
        if c < 0 { low = keys.index(after: mid) } else { high = mid }
    }
    return (false, low)
}

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

        private var entries: [Element]

        public init() {
            entries = []
        }

        /// Later pairs win over earlier pairs with the same key.
        public init<S: Sequence>(_ pairs: S) where S.Element == (Value, Value) {
            entries = []
            for (key, value) in pairs { self[key] = value }
        }

        /// Entries the decoder has already checked are strictly ascending.
        init(uncheckedSorted entries: [Element]) {
            assert(isStrictlyAscending(entries.lazy.map(\.key)), "decoder produced out-of-order keys")
            self.entries = entries
        }

        init(literalEntries: [(Value, Value)]) {
            self.init()
            for (key, value) in literalEntries {
                precondition(updateValue(value, forKey: key) == nil, "Dict literal contains duplicate keys")
            }
        }

        public subscript(key: Value) -> Value? {
            get {
                let (found, i) = search(key, in: entries.lazy.map(\.key))
                return found ? entries[i].value : nil
            }
            set {
                if let newValue {
                    updateValue(newValue, forKey: key)
                } else {
                    removeValue(forKey: key)
                }
            }
        }

        /// Sets the value for `key`, returning the value it replaced.
        @discardableResult
        public mutating func updateValue(_ value: Value, forKey key: Value) -> Value? {
            let (found, i) = search(key, in: entries.lazy.map(\.key))
            if found {
                defer { entries[i].value = value }
                return entries[i].value
            }
            entries.insert((key, value), at: i)
            return nil
        }

        @discardableResult
        public mutating func removeValue(forKey key: Value) -> Value? {
            let (found, i) = search(key, in: entries.lazy.map(\.key))
            return found ? entries.remove(at: i).value : nil
        }

        public var keys: LazyMapSequence<[Element], Value> {
            entries.lazy.map(\.key)
        }

        public var values: LazyMapSequence<[Element], Value> {
            entries.lazy.map(\.value)
        }
    }
}

extension Value.Dict: RandomAccessCollection {
    public typealias Index = CanonicalIndex

    public var startIndex: Index { Index(offset: 0) }
    public var endIndex: Index { Index(offset: entries.count) }
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public func index(after i: Index) -> Index { Index(offset: i.offset + 1) }
    public func index(before i: Index) -> Index { Index(offset: i.offset - 1) }
    public func index(_ i: Index, offsetBy distance: Int) -> Index { Index(offset: i.offset + distance) }
    public func distance(from start: Index, to end: Index) -> Int { end.offset - start.offset }

    public subscript(position: Index) -> Element {
        entries[position.offset]
    }
}

extension Value.Dict: Hashable {
    public static func == (a: Value.Dict, b: Value.Dict) -> Bool {
        a.count == b.count && zip(a.entries, b.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(entries.count)
        for (key, value) in entries {
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
        private var members: [Value]

        public init() {
            members = []
        }

        /// Duplicates collapse to one member.
        public init(_ values: some Sequence<Value>) {
            members = Array(values).sorted(by: Value.canonicalOrder)
            var unique: [Value] = []
            unique.reserveCapacity(members.count)
            for member in members where unique.last != member {
                unique.append(member)
            }
            members = unique
        }

        /// Members the decoder has already checked are strictly ascending.
        init(uncheckedSorted members: [Value]) {
            assert(isStrictlyAscending(members), "decoder produced out-of-order members")
            self.members = members
        }

        public func contains(_ member: Value) -> Bool {
            search(member, in: members).found
        }

        @discardableResult
        public mutating func insert(_ member: Value) -> (inserted: Bool, memberAfterInsert: Value) {
            let (found, i) = search(member, in: members)
            if found { return (false, members[i]) }
            members.insert(member, at: i)
            return (true, member)
        }

        @discardableResult
        public mutating func remove(_ member: Value) -> Value? {
            let (found, i) = search(member, in: members)
            return found ? members.remove(at: i) : nil
        }
    }
}

extension Value.Set: RandomAccessCollection {
    public typealias Index = CanonicalIndex

    public var startIndex: Index { Index(offset: 0) }
    public var endIndex: Index { Index(offset: members.count) }
    public var count: Int { members.count }
    public var isEmpty: Bool { members.isEmpty }

    public func index(after i: Index) -> Index { Index(offset: i.offset + 1) }
    public func index(before i: Index) -> Index { Index(offset: i.offset - 1) }
    public func index(_ i: Index, offsetBy distance: Int) -> Index { Index(offset: i.offset + distance) }
    public func distance(from start: Index, to end: Index) -> Int { end.offset - start.offset }

    public subscript(position: Index) -> Value {
        members[position.offset]
    }
}

extension Value.Set: Hashable {
    public static func == (a: Value.Set, b: Value.Set) -> Bool {
        a.members == b.members
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(members)
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
