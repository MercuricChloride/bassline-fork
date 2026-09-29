// Shapes: an example value with holes, after blnim's rewrite.nim.
//
// A shape reads values that look like its example, binding each hole to the
// part of the value in its position (`extract`), and builds values by putting
// a binding into every hole (`inject`). As a value it is written
//
//     (shape example {holes})  or  (shape example {holes} wild)
//
// where `wild` matches anything and binds nothing.
//
// Matching is by example:
//
// - a hole binds the value in its position when their marks agree; a hole
//   that occurs twice must bind equal values, and binding it to two
//   different values is an error;
// - everything else matches literally: kinds and marks must agree, and atoms
//   must be equal;
// - lists and records match position by position (a record's head too), and
//   the value may have more trailing members than the example;
// - dicts need every key in the example, and match their values; extra keys
//   are ignored;
// - sets need every member in the example; extra members are ignored.
//
// Dict keys and set members are found by equality, not position, so they're
// looked up literally and nothing inside them binds. One that is itself a
// hole isn't supported when extracting: if it's there, that's an error.
// Injecting fills them like any other position.

/// An example value with holes, for reading values that look like it and
/// building new ones.
public struct Shape: Sendable, Hashable {
    public let example: Value
    public let holes: Value.Set
    /// Matches anything and binds nothing.
    public let wild: Value?

    public init(_ example: Value, holes: Value.Set = [], wild: Value? = nil) {
        self.example = example
        self.holes = holes
        self.wild = wild
    }

    // MARK: Reading

    /// The bindings for every hole, or `nil` if `value` doesn't fit the
    /// example or leaves a hole unbound.
    ///
    /// Throws when a repeated hole would bind two different values, or when
    /// matching reaches a hole used as a dict key or set member.
    public func extract(from value: Value) throws(ShapeError) -> Value.Dict? {
        var bindings = Value.Dict()
        guard try bind(example, to: value, &bindings), bindings.count == holes.count else { return nil }
        return bindings
    }

    public func matches(_ value: Value) throws(ShapeError) -> Bool {
        try extract(from: value) != nil
    }

    /// `case someShape:` in a `switch` over values. A shape that throws
    /// while matching doesn't match.
    public static func ~= (shape: Shape, value: Value) -> Bool {
        (try? shape.matches(value)) ?? false
    }

    // MARK: Building

    /// The example with every hole replaced by its binding, wherever it sits
    /// (dict keys and set members included). Every hole needs a binding;
    /// bindings for other names are ignored.
    public func inject(_ bindings: Value.Dict) throws(ShapeError) -> Value {
        for hole in holes where bindings[hole] == nil {
            throw ShapeError(.unboundHole, hole)
        }
        return substitute(example, bindings)
    }

    // MARK: Internals

    private func isWild(_ part: Value) -> Bool {
        wild.map { $0 == part } ?? false
    }

    private func bind(_ part: Value, to value: Value, _ bindings: inout Value.Dict) throws(ShapeError) -> Bool {
        if isWild(part) { return true }
        if holes.contains(part), part.isMarked == value.isMarked {
            if let bound = bindings[part] {
                guard bound == value else { throw ShapeError(.mismatchedHole, part) }
            } else {
                bindings[part] = value
            }
            return true
        }
        guard part.kind == value.kind, part.isMarked == value.isMarked else { return false }

        switch (part.content, value.content) {
        case let (.list(expected), .list(actual)):
            return try bindLeading(expected, to: actual, &bindings)
        case let (.record(expectedHead, expected), .record(actualHead, actual)):
            guard try bind(expectedHead, to: actualHead, &bindings) else { return false }
            return try bindLeading(expected, to: actual, &bindings)
        case let (.dict(expected), .dict(actual)):
            for (key, item) in expected {
                guard let other = actual[key] else { return false }
                guard !holes.contains(key) else { throw ShapeError(.holeInKey, key) }
                guard try bind(item, to: other, &bindings) else { return false }
            }
            return true
        case let (.set(expected), .set(actual)):
            for member in expected {
                guard actual.contains(member) else { return false }
                guard !holes.contains(member) else { throw ShapeError(.holeInMember, member) }
            }
            return true
        default:
            return part == value
        }
    }

    /// The example's members against the value's leading members.
    private func bindLeading(_ expected: [Value], to actual: [Value], _ bindings: inout Value.Dict) throws(ShapeError) -> Bool {
        guard actual.count >= expected.count else { return false }
        for (part, value) in zip(expected, actual) where try !bind(part, to: value, &bindings) {
            return false
        }
        return true
    }

    private func substitute(_ part: Value, _ bindings: Value.Dict) -> Value {
        if holes.contains(part), let binding = bindings[part] { return binding }
        var result = part
        switch part.content {
        case .list(let items):
            result.content = .list(items.map { substitute($0, bindings) })
        case .record(let head, let fields):
            result.content = .record(head: substitute(head, bindings), fields: fields.map { substitute($0, bindings) })
        case .dict(let dict):
            // keys may be holes too, so the entries are sorted again
            result.content = .dict(Value.Dict(dict.map { (substitute($0.key, bindings), substitute($0.value, bindings)) }))
        case .set(let set):
            result.content = .set(Value.Set(set.map { substitute($0, bindings) }))
        default:
            break
        }
        return result
    }
}

/// Why a shape couldn't extract or inject.
public struct ShapeError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Reason: String, Sendable, CaseIterable {
        /// A repeated hole would bind two different values.
        case mismatchedHole = "mismatched-hole"
        /// Extracting reached a hole used as a dict key.
        case holeInKey = "hole-in-key"
        /// Extracting reached a hole used as a set member.
        case holeInMember = "hole-in-member"
        /// Injecting without a binding for this hole.
        case unboundHole = "unbound-hole"
    }

    public var reason: Reason
    /// The hole at fault.
    public var hole: Value

    public init(_ reason: Reason, _ hole: Value) {
        self.reason = reason
        self.hole = hole
    }

    public var description: String { "\(reason.rawValue): \(hole)" }
}

extension Shape: ValueConvertible {
    public var basslineValue: Value {
        var fields: [Value] = [example, .set(holes)]
        if let wild { fields.append(wild) }
        return .record(head: .symbol("shape"), fields: fields)
    }

    /// Reads `(shape example {holes})` or `(shape example {holes} wild)`.
    public init(bassline value: Value) throws {
        guard !value.isMarked, value.head == .symbol("shape"), let fields = value.fields,
              fields.count == 2 || fields.count == 3, !fields[1].isMarked, let holes = fields[1].set else {
            throw ValueConversionError(expected: "(shape example {holes}) or (shape example {holes} wild)", found: value)
        }
        self.init(fields[0], holes: holes, wild: fields.count == 3 ? fields[2] : nil)
    }
}

extension Shape: CustomStringConvertible {
    public var description: String { basslineValue.description }
}
