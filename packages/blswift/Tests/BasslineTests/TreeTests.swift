import Testing
@testable import Bassline

/// Keys whose canonical order is their numeric order (same-length symbols).
private func key(_ n: Int) -> Value {
    let digits = String(n)
    return .symbol(Symbol("k" + String(repeating: "0", count: 5 - digits.count) + digits))
}

extension CanonicalTree {
    /// Checks every B-tree invariant: sorted keys within their bounds, node
    /// sizes, uniform leaf depth, and subtree counts.
    func checkInvariants(sourceLocation: SourceLocation = #_sourceLocation) {
        _ = check(root, isRoot: true, lower: nil, upper: nil, sourceLocation)
    }

    private func check(_ node: Node, isRoot: Bool, lower: Value?, upper: Value?,
                       _ location: SourceLocation) -> Int {
        let keys = node.elements.map(\.canonicalKey)
        for (a, b) in zip(keys, keys.dropFirst()) {
            #expect(Value.canonicalCompare(a, b) < 0, "keys out of order", sourceLocation: location)
        }
        if let lower, let first = keys.first {
            #expect(Value.canonicalCompare(lower, first) < 0, "key below its bound", sourceLocation: location)
        }
        if let upper, let last = keys.last {
            #expect(Value.canonicalCompare(last, upper) < 0, "key above its bound", sourceLocation: location)
        }
        #expect(node.elements.count <= maxElements, "overfull node", sourceLocation: location)
        if !isRoot {
            #expect(node.elements.count >= minElements, "underfull node", sourceLocation: location)
        }
        if node.isLeaf {
            #expect(node.count == node.elements.count, "leaf count", sourceLocation: location)
            return 1
        }
        #expect(node.children.count == node.elements.count + 1, "child count", sourceLocation: location)
        var heights: [Int] = []
        for (i, child) in node.children.enumerated() {
            heights.append(check(child, isRoot: false,
                                 lower: i == 0 ? lower : keys[i - 1],
                                 upper: i == keys.count ? upper : keys[i], location))
        }
        #expect(Swift.Set(heights).count == 1, "leaves at different depths", sourceLocation: location)
        #expect(node.count == node.elements.count + node.children.reduce(0) { $0 + $1.count },
                "subtree count", sourceLocation: location)
        return heights[0] + 1
    }

    /// Identities of every node, for checking structural sharing.
    var nodeIdentities: Swift.Set<ObjectIdentifier> {
        var ids: Swift.Set<ObjectIdentifier> = []
        var pending = [root]
        while let node = pending.popLast() {
            ids.insert(ObjectIdentifier(node))
            pending.append(contentsOf: node.children)
        }
        return ids
    }
}

@Suite("canonical tree")
struct CanonicalTreeTests {
    @Test(arguments: [3, 4, 5, 8, 64])
    func matchesASortedArrayModel(order: Int) {
        var rng = SplitMix64(seed: UInt64(order))
        var tree = CanonicalTree<Value>(order: order)
        var model: [Int] = []

        for step in 0 ..< 4000 {
            let n = Int.random(in: 0 ..< 500, using: &rng)
            switch Int.random(in: 0 ..< 10, using: &rng) {
            case 0 ..< 5:
                let replaced = tree.insert(key(n))
                #expect((replaced != nil) == model.contains(n))
                if replaced == nil { model.insert(n, at: model.firstIndex { $0 > n } ?? model.count) }
            case 5 ..< 8:
                let removed = tree.remove(key(n))
                #expect((removed != nil) == model.contains(n))
                model.removeAll { $0 == n }
            default:
                #expect((tree.find(key(n)) != nil) == model.contains(n))
            }

            #expect(tree.count == model.count)
            if step % 200 == 0 || step == 3999 {
                tree.checkInvariants()
                #expect(Array(tree) == model.map(key))
                for (offset, n) in model.enumerated() where offset % 7 == 0 {
                    #expect(tree.element(at: offset) == key(n))
                }
            }
        }
    }

    @Test(arguments: [3, 4, 64])
    func removingEverythingEmptiesTheTree(order: Int) {
        var tree = CanonicalTree<Value>(ascending: (0 ..< 300).map(key), order: order)
        tree.checkInvariants()
        var rng = SplitMix64(seed: 3)
        for n in Array(0 ..< 300).shuffled(using: &rng) {
            #expect(tree.remove(key(n)) == key(n))
        }
        #expect(tree.isEmpty)
        #expect(tree.root.isLeaf)
        tree.checkInvariants()
    }

    @Test(arguments: [3, 4, 5, 7, 64])
    func packedBuildHoldsTheInvariantsAtEverySize(order: Int) {
        for n in 0 ... 400 {
            let tree = CanonicalTree<Value>(ascending: (0 ..< n).map(key), order: order)
            tree.checkInvariants()
            #expect(tree.count == n)
            #expect(Array(tree) == (0 ..< n).map(key))
        }
    }

    @Test func bulkBuildMatchesInsertion() {
        let built = CanonicalTree<Value>(ascending: (0 ..< 1000).map(key), order: 4)
        built.checkInvariants()
        var inserted = CanonicalTree<Value>(order: 4)
        for n in (0 ..< 1000).reversed() { inserted.insert(key(n)) }
        #expect(Array(built) == Array(inserted))
    }

    @Test func copiesShareEverythingOffThePathOfAnEdit() {
        let original = CanonicalTree<Value>(ascending: (0 ..< 2000).map(key), order: 8)
        var copy = original
        copy.insert(key(99_999))
        copy.remove(key(1000))

        #expect(Array(original) == (0 ..< 2000).map(key))
        #expect(copy.count == 2000)
        original.checkInvariants()
        copy.checkInvariants()

        let shared = original.nodeIdentities.intersection(copy.nodeIdentities)
        #expect(shared.count > original.nodeIdentities.count * 9 / 10)
        #expect(original.root !== copy.root)
    }

    @Test func iteratorSeesTheTreeAsItWas() {
        var tree = CanonicalTree<Value>(ascending: (0 ..< 100).map(key), order: 4)
        var iterator = tree.makeIterator()
        for n in 0 ..< 100 { tree.remove(key(n)) }
        var seen = 0
        while iterator.next() != nil { seen += 1 }
        #expect(seen == 100)
        #expect(tree.isEmpty)
    }
}

@Suite("in-place edits")
struct InPlaceEditTests {
    @Test func dictSubscriptEditsInPlaceAndKeepsValueSemantics() {
        var dict: Value.Dict = [.symbol("list"): [1, 2]]
        let snapshot = dict
        dict[.symbol("list")]?.withList { $0.append(3) }
        #expect(dict[.symbol("list")] == [1, 2, 3])
        #expect(snapshot[.symbol("list")] == [1, 2])

        // editing a missing key does nothing
        dict[.symbol("missing")]?.withList { $0.append(1) }
        #expect(dict.count == 1)
    }

    @Test func dictSubscriptModifyCanInsertAndRemove() {
        func set(_ slot: inout Value?, to value: Value?) { slot = value }
        var dict: Value.Dict = ["a": 1]
        set(&dict["b"], to: 2)
        set(&dict["a"], to: nil)
        set(&dict["c"], to: nil)
        #expect(dict == ["b": 2])
    }

    @Test func nestedEditsThroughValue() {
        var value: Value = [.symbol("users"): [], .symbol("count"): 0]
        let before = value
        for n in 1 ... 3 {
            value.withDict { dict in
                dict[.symbol("users")]?.withList { $0.append(.record("user", .integer(n))) }
                dict[.symbol("count")] = .integer(n)
            }
        }
        #expect(value.description == "{count: 3 users: [(user 1) (user 2) (user 3)]}")
        #expect(before.description == "{count: 0 users: []}")
    }

    @Test func mutatorsKeepTheMarkAndSkipOtherKinds() {
        var request = Value.record("insert", 1).marked
        request.withRecord { _, fields in fields.append(2) }
        #expect(request == Value.record("insert", 1, 2).marked)

        var text: Value = "not a list"
        #expect(text.withList { $0.append(1) } == nil)
        #expect(text == "not a list")
    }

    @Test func largeCollectionsRoundTrip() throws {
        let entries = (0 ..< 5000).map { (key($0), Value.integer($0)) }
        var rng = SplitMix64(seed: 11)
        let dict = Value.Dict(entries.shuffled(using: &rng))
        #expect(Array(dict.keys) == entries.map(\.0))
        #expect(dict[key(4321)] == 4321)
        #expect(dict[dict.index(dict.startIndex, offsetBy: 1234)].key == key(1234))

        let value = Value.dict(dict)
        #expect(try Value(decoding: value.encoded()) == value)
        #expect(try Value(reading: value.description) == value)

        let set = Value.Set(entries.map(\.0).shuffled(using: &rng) + entries.map(\.0))
        #expect(set.count == 5000)
        #expect(Array(set) == entries.map(\.0))
    }
}
