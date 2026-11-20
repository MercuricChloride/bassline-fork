// A copy-on-write B-tree in canonical order: the storage behind Value.Dict and
// Value.Set.
//
// Nodes are classes, but the tree has value semantics. A mutation first makes
// the path it touches uniquely referenced, copying only those nodes (each a
// shallow copy: its elements and its child references). Every other node stays
// shared with any other copy of the tree. So copying a tree is O(1), and
// mutating a shared copy is O(log n) rather than a full copy.
//
// Each node also records how many elements its subtree holds, so the tree can
// find the element at an offset in O(log n). That lets Dict and Set keep plain
// integer positions.
//
// Small trees are a single leaf, which behaves exactly like a sorted array.

/// Something kept in a canonical tree, ordered by a key.
protocol CanonicalKeyed: Sendable {
    var canonicalKey: Value { get }
}

extension Value: CanonicalKeyed {
    var canonicalKey: Value { self }
}

struct CanonicalTree<Element: CanonicalKeyed>: Sendable {
    /// Nodes are only mutated while uniquely referenced, the same discipline
    /// Array's storage follows, which is what makes sharing them across
    /// threads safe.
    final class Node: @unchecked Sendable {
        var elements: [Element]
        /// Empty for a leaf; otherwise one more than `elements`.
        var children: [Node]
        /// Elements in this whole subtree.
        var count: Int

        init(elements: [Element] = [], children: [Node] = [], count: Int? = nil) {
            self.elements = elements
            self.children = children
            self.count = count ?? elements.count + children.reduce(0) { $0 + $1.count }
        }

        var isLeaf: Bool { children.isEmpty }

        func copy() -> Node {
            Node(elements: elements, children: children, count: count)
        }

        /// Whether `key` is in this node, and where it is or would go.
        func search(_ key: Value) -> (found: Bool, index: Int) {
            var low = 0, high = elements.count
            while low < high {
                let mid = (low + high) / 2
                let c = Value.canonicalCompare(elements[mid].canonicalKey, key)
                if c == 0 { return (true, mid) }
                if c < 0 { low = mid + 1 } else { high = mid }
            }
            return (false, low)
        }

        /// Splits an overfull node around its median, returning the median
        /// and the new right-hand node.
        func split() -> (median: Element, right: Node) {
            let mid = elements.count / 2
            let median = elements[mid]
            let right = Node(elements: Array(elements[(mid + 1)...]),
                             children: isLeaf ? [] : Array(children[(mid + 1)...]))
            elements.removeSubrange(mid...)
            if !isLeaf { children.removeSubrange((mid + 1)...) }
            count -= right.count + 1
            return (median, right)
        }
    }

    private(set) var root: Node
    /// Maximum children per node.
    let order: Int

    var maxElements: Int { order - 1 }
    var minElements: Int { (order + 1) / 2 - 1 }

    init(order: Int = 64) {
        precondition(order >= 3, "a B-tree needs an order of at least 3")
        self.order = order
        self.root = Node()
    }

    /// Builds from strictly ascending elements in O(n), without comparing
    /// them, packing nodes as full as the invariants allow.
    init(ascending elements: [Element], order: Int = 64) {
        self.init(order: order)
        assert(zip(elements, elements.dropFirst()).allSatisfy {
            Value.canonicalCompare($0.canonicalKey, $1.canonicalKey) < 0
        }, "elements are not strictly ascending")
        root = Self.packed(elements, order: order)
    }

    /// Bottom-up construction: split the elements into leaves with one
    /// separator between each pair, then group each level's nodes under
    /// parents the same way. Even distribution keeps every node at or above
    /// the minimum.
    private static func packed(_ elements: [Element], order: Int) -> Node {
        guard elements.count >= order else { return Node(elements: elements) }

        var nodes: [Node] = [], separators: [Element] = []
        let leaves = (elements.count + order) / order            // ⌈(n + 1) / order⌉
        let leafElements = elements.count - (leaves - 1)
        var start = 0
        for leaf in 0 ..< leaves {
            let size = leafElements / leaves + (leaf < leafElements % leaves ? 1 : 0)
            nodes.append(Node(elements: Array(elements[start ..< start + size])))
            start += size
            if leaf < leaves - 1 {
                separators.append(elements[start])
                start += 1
            }
        }

        while nodes.count > 1 {
            let parents = (nodes.count + order - 1) / order        // ⌈k / order⌉
            var level: [Node] = [], upper: [Element] = []
            var first = 0
            for parent in 0 ..< parents {
                let size = nodes.count / parents + (parent < nodes.count % parents ? 1 : 0)
                level.append(Node(elements: Array(separators[first ..< first + size - 1]),
                                  children: Array(nodes[first ..< first + size])))
                first += size
                if parent < parents - 1 { upper.append(separators[first - 1]) }
            }
            nodes = level
            separators = upper
        }
        return nodes[0]
    }

    var count: Int { root.count }
    var isEmpty: Bool { root.count == 0 }

    private static func makeUnique(_ node: inout Node) {
        if !isKnownUniquelyReferenced(&node) { node = node.copy() }
    }

    // MARK: Lookup

    func find(_ key: Value) -> Element? {
        var node = root
        while true {
            let (found, i) = node.search(key)
            if found { return node.elements[i] }
            if node.isLeaf { return nil }
            node = node.children[i]
        }
    }

    /// The element at `offset` in canonical order.
    func element(at offset: Int) -> Element {
        precondition(offset >= 0 && offset < count, "offset out of range")
        var node = root, offset = offset
        descend: while !node.isLeaf {
            for (i, child) in node.children.enumerated() {
                if offset < child.count {
                    node = child
                    continue descend
                }
                offset -= child.count
                if offset == 0 { return node.elements[i] }
                offset -= 1
            }
        }
        return node.elements[offset]
    }

    // MARK: Insertion

    /// Inserts `element`, or replaces the one with the same key and returns it.
    @discardableResult
    mutating func insert(_ element: Element) -> Element? {
        let (replaced, split) = Self.insert(element, into: &root, maxElements: maxElements)
        if let split {
            root = Node(elements: [split.median], children: [root, split.right])
        }
        return replaced
    }

    private static func insert(_ element: Element, into node: inout Node, maxElements: Int)
        -> (replaced: Element?, split: (median: Element, right: Node)?) {
        makeUnique(&node)
        let (found, i) = node.search(element.canonicalKey)
        if found {
            defer { node.elements[i] = element }
            return (node.elements[i], nil)
        }
        if node.isLeaf {
            node.elements.insert(element, at: i)
        } else {
            let (replaced, split) = insert(element, into: &node.children[i], maxElements: maxElements)
            if replaced != nil { return (replaced, nil) }
            if let split {
                node.elements.insert(split.median, at: i)
                node.children.insert(split.right, at: i + 1)
            }
        }
        node.count += 1
        return (nil, node.elements.count > maxElements ? node.split() : nil)
    }

    // MARK: In-place edits

    /// Passes the element with `key` to `body` in place, copying only the
    /// shared nodes on its path. `body` must not change the element's key.
    mutating func modify<R>(key: Value, _ body: (inout Element) -> R) -> R? {
        guard find(key) != nil else { return nil }
        return Self.modify(key, in: &root, body)
    }

    private static func modify<R>(_ key: Value, in node: inout Node, _ body: (inout Element) -> R) -> R {
        makeUnique(&node)
        let (found, i) = node.search(key)
        if found { return body(&node.elements[i]) }
        return modify(key, in: &node.children[i], body)
    }

    // MARK: Removal

    @discardableResult
    mutating func remove(_ key: Value) -> Element? {
        guard find(key) != nil else { return nil }
        let removed = Self.remove(key, from: &root, minElements: minElements)
        if root.elements.isEmpty, !root.isLeaf { root = root.children[0] }
        return removed
    }

    /// Removes `key`, which is known to be under `node`.
    private static func remove(_ key: Value, from node: inout Node, minElements: Int) -> Element {
        makeUnique(&node)
        node.count -= 1
        let (found, i) = node.search(key)
        if found {
            if node.isLeaf { return node.elements.remove(at: i) }
            // swap in the predecessor, the largest element of the left subtree
            let removed = node.elements[i]
            node.elements[i] = removeLast(from: &node.children[i], minElements: minElements)
            rebalance(node, at: i, minElements: minElements)
            return removed
        }
        let removed = remove(key, from: &node.children[i], minElements: minElements)
        rebalance(node, at: i, minElements: minElements)
        return removed
    }

    private static func removeLast(from node: inout Node, minElements: Int) -> Element {
        makeUnique(&node)
        node.count -= 1
        if node.isLeaf { return node.elements.removeLast() }
        let last = node.children.count - 1
        let element = removeLast(from: &node.children[last], minElements: minElements)
        rebalance(node, at: last, minElements: minElements)
        return element
    }

    /// Tops up `node.children[i]` if it fell below the minimum, by borrowing
    /// from a sibling or merging with one. `node` is already unique.
    private static func rebalance(_ node: Node, at i: Int, minElements: Int) {
        guard node.children[i].elements.count < minElements else { return }

        if i > 0, node.children[i - 1].elements.count > minElements {
            // rotate right: parent separator down, left sibling's last up
            makeUnique(&node.children[i - 1])
            makeUnique(&node.children[i])
            let left = node.children[i - 1], child = node.children[i]
            child.elements.insert(node.elements[i - 1], at: 0)
            node.elements[i - 1] = left.elements.removeLast()
            var moved = 1
            if !left.isLeaf {
                let subtree = left.children.removeLast()
                child.children.insert(subtree, at: 0)
                moved += subtree.count
            }
            left.count -= moved
            child.count += moved
        } else if i + 1 < node.children.count, node.children[i + 1].elements.count > minElements {
            // rotate left: parent separator down, right sibling's first up
            makeUnique(&node.children[i + 1])
            makeUnique(&node.children[i])
            let right = node.children[i + 1], child = node.children[i]
            child.elements.append(node.elements[i])
            node.elements[i] = right.elements.removeFirst()
            var moved = 1
            if !right.isLeaf {
                let subtree = right.children.removeFirst()
                child.children.append(subtree)
                moved += subtree.count
            }
            right.count -= moved
            child.count += moved
        } else {
            // merge with a sibling around their separator
            let l = i > 0 ? i - 1 : i
            makeUnique(&node.children[l])
            let left = node.children[l], right = node.children[l + 1]
            left.elements.append(node.elements.remove(at: l))
            left.elements.append(contentsOf: right.elements)
            left.children.append(contentsOf: right.children)
            left.count += 1 + right.count
            node.children.remove(at: l + 1)
        }
    }
}

// MARK: - Iteration

extension CanonicalTree: Sequence {
    /// In-order traversal. It holds its own references to the nodes, so it
    /// keeps seeing the tree as it was even if the tree is mutated meanwhile.
    struct Iterator: IteratorProtocol {
        /// The leaf being walked, and the next position in it.
        private var leaf: [Element] = []
        private var index = 0
        /// Internal nodes above the leaf, each with the next separator to yield.
        private var ancestors: [(node: Node, next: Int)] = []

        init(root: Node) {
            descend(from: root)
        }

        private mutating func descend(from node: Node) {
            var node = node
            while !node.isLeaf {
                ancestors.append((node, 0))
                node = node.children[0]
            }
            leaf = node.elements
            index = 0
        }

        mutating func next() -> Element? {
            if index < leaf.count {
                defer { index += 1 }
                return leaf[index]
            }
            while let top = ancestors.last {
                let (node, i) = (top.node, top.next)
                if i < node.elements.count {
                    ancestors[ancestors.count - 1].next = i + 1
                    descend(from: node.children[i + 1])
                    return node.elements[i]
                }
                ancestors.removeLast()
            }
            return nil
        }
    }

    func makeIterator() -> Iterator {
        Iterator(root: root)
    }

    var underestimatedCount: Int { count }
}
