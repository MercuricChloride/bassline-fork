// Shapes as search: every way a value fills a shape.
//
// `extract` reads one binding and refuses what it can't decide alone: a hole
// used as a dict key or set member is an error there, and so is a repeated
// hole bound two ways. `fillings(of:)` asks instead. It answers every binding
// under which the value fits the example, one binding per pull, and works
// nothing out ahead of a pull, so a shape with holes in set members (which is
// combinatorial) costs only as much as is taken.
//
// The rules are extract's, with these differences:
//
// - a dict key or set member with a hole, or the wild, anywhere inside it is
//   tried against each of the value's actual keys or members in turn, and
//   the search backtracks over them; one with neither is looked up literally,
//   as extract looks it up;
// - a repeated hole bound two different ways is just not a filling, never an
//   error;
// - two parts of the example may be filled from the same key or member: a
//   set example says which members the value has, not how many of them.
//
// A filling binds every hole, so a hole that the example never reaches (one
// missing from it, or only inside another hole) has none. Each binding is
// answered once, in the order the search first finds it.

extension Shape {
    /// Every binding of the holes under which `value` fits the example, as a
    /// stream: one binding per pull, each once, nothing worked out ahead.
    public func fillings(of value: Value) -> Answers<Value.Dict> {
        var seen = Swift.Set<Value.Dict>()
        let count = holes.count
        return fill(example, value, Value.Dict()).filter { binding in
            binding.count == count && seen.insert(binding).inserted
        }
    }

    /// Every binding of the holes in any of `values`, value by value, as a
    /// stream: each binding once, however many values have it. The sequence
    /// is walked only as far as the pulls need, so it may be endless.
    public func fillings(in values: some Sequence<Value>) -> Answers<Value.Dict> {
        var iterator = values.makeIterator()
        var current: Answers<Value.Dict>?
        var seen = Swift.Set<Value.Dict>()
        var done = false
        return Answers {
            while !done {
                if let stream = current {
                    while let binding = stream.next() {
                        if seen.insert(binding).inserted { return binding }
                    }
                    current = nil
                }
                guard let value = iterator.next() else {
                    done = true
                    break
                }
                current = fillings(of: value)
            }
            return nil
        }
    }

    // MARK: Internals

    /// The bindings, extending `bindings`, under which `value` fits `part`.
    /// May answer the same binding more than once; `fillings` keeps one.
    private func fill(_ part: Value, _ value: Value, _ bindings: Value.Dict) -> Answers<Value.Dict> {
        if wild == part { return .just(bindings) }
        if holes.contains(part), part.isMarked == value.isMarked {
            if let bound = bindings[part] { return bound == value ? .just(bindings) : .empty }
            var bound = bindings
            bound[part] = value
            return .just(bound)
        }
        guard part.kind == value.kind, part.isMarked == value.isMarked else { return .empty }

        switch (part.content, value.content) {
        case let (.list(expected), .list(actual)):
            return fillLeading(expected, actual, bindings)
        case let (.record(expectedHead, expected), .record(actualHead, actual)):
            guard actual.count >= expected.count else { return .empty }
            return fill(expectedHead, actualHead, bindings).then { fillLeading(expected, actual, $0) }
        case let (.dict(expected), .dict(actual)):
            var found = Answers.just(bindings)
            for (key, item) in expected {
                if isLiteral(key) {
                    guard let other = actual[key] else { return .empty }
                    found = found.then { fill(item, other, $0) }
                } else {
                    found = found.then { bindings in
                        Answers<(key: Value, value: Value)>(actual).then { entry in
                            fill(key, entry.key, bindings).then { fill(item, entry.value, $0) }
                        }
                    }
                }
            }
            return found
        case let (.set(expected), .set(actual)):
            var found = Answers.just(bindings)
            for member in expected {
                if isLiteral(member) {
                    guard actual.contains(member) else { return .empty }
                } else {
                    found = found.then { bindings in
                        Answers<Value>(actual).then { other in fill(member, other, bindings) }
                    }
                }
            }
            return found
        default:
            return part == value ? .just(bindings) : .empty
        }
    }

    /// The example's members against the value's leading members.
    private func fillLeading(_ expected: [Value], _ actual: [Value], _ bindings: Value.Dict) -> Answers<Value.Dict> {
        guard actual.count >= expected.count else { return .empty }
        var found = Answers.just(bindings)
        for (part, value) in zip(expected, actual) {
            found = found.then { fill(part, value, $0) }
        }
        return found
    }

    /// Whether `part` has no hole and no wild anywhere in it: a key or member
    /// like that is looked up as it is.
    private func isLiteral(_ part: Value) -> Bool {
        if wild == part || holes.contains(part) { return false }
        switch part.content {
        case .list(let items): return items.allSatisfy(isLiteral)
        case .record(let head, let fields): return isLiteral(head) && fields.allSatisfy(isLiteral)
        case .dict(let dict): return dict.allSatisfy { isLiteral($0.key) && isLiteral($0.value) }
        case .set(let set): return set.allSatisfy(isLiteral)
        default: return true
        }
    }
}

extension Answers {
    /// For each answer, every answer of the stream `next` makes of it, in
    /// order: a depth-first search, pulled one answer at a time. A complete
    /// stream is never pulled again.
    fileprivate func then<T>(_ next: @escaping (Element) -> Answers<T>) -> Answers<T> {
        var inner: Answers<T>?
        var done = false
        return Answers<T> {
            while !done {
                if let stream = inner {
                    if let answer = stream.next() { return answer }
                    inner = nil
                }
                guard let element = self.next() else {
                    done = true
                    break
                }
                inner = next(element)
            }
            return nil
        }
    }
}
