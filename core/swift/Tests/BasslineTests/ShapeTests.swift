import Testing
@testable import Bassline

private func shape(_ text: String) throws -> Shape {
    try Shape(bassline: Value(reading: text))
}

private func value(_ text: String) throws -> Value {
    try Value(reading: text)
}

private func bindings(_ text: String) throws -> Value.Dict {
    try #require(value(text).dict)
}

@Suite("shapes: extract")
struct ShapeExtractTests {
    @Test func holesBindAndLiteralsMustMatch() throws {
        let file = try shape("(shape (file name digest) {name digest})")
        #expect(try file.extract(from: value(#"(file "a.txt" 0xff)"#)) == bindings(#"{name: "a.txt" digest: 0xff}"#))
        #expect(try file.extract(from: value(#"(dir "a.txt" 0xff)"#)) == nil)
        #expect(try file.extract(from: value(#"[file "a.txt" 0xff]"#)) == nil)
    }

    @Test func trailingMembersAreIgnoredButMissingOnesFail() throws {
        let file = try shape("(shape (file name) {name})")
        #expect(try file.extract(from: value(#"(file "a" 0xff)"#)) == bindings(#"{name: "a"}"#))
        #expect(try file.extract(from: value("(file)")) == nil)
        #expect(try shape("(shape [] {})").matches(value("[1 2 3]")))
        #expect(try !shape("(shape [1 2] {})").matches(value("[1]")))
    }

    @Test func aRepeatedHoleMustAgree() throws {
        let twice = try shape("(shape [x y x] {x y})")
        #expect(try twice.extract(from: value("[1 2 1]")) == bindings("{x: 1 y: 2}"))
        #expect(throws: ShapeError(.mismatchedHole, .symbol("x"))) { try twice.extract(from: value("[1 2 3]")) }
    }

    @Test func aHoleBindsOnlyValuesWithItsMark() throws {
        let plain = try shape("(shape (op x) {x})")
        #expect(try plain.extract(from: value("(op go)")) == bindings("{x: go}"))
        #expect(try plain.extract(from: value("(op go!)")) == nil)

        let marked = try shape("(shape (op x!) {x!})")
        #expect(try marked.extract(from: value("(op go!)")) == bindings("{x!: go!}"))
        #expect(try marked.extract(from: value("(op go)")) == nil)
        #expect(try marked.extract(from: value("(op !(do it))")) == bindings("{x!: !(do it)}"))
    }

    @Test func marksAreOtherwiseLiteral() throws {
        let command = try shape("(shape !(f x) {x})")
        #expect(try command.extract(from: value("!(f 1)")) == bindings("{x: 1}"))
        #expect(try command.extract(from: value("(f 1)")) == nil)

        let go = try shape("(shape (op go!) {})")
        #expect(try go.matches(value("(op go!)")))
        #expect(try !go.matches(value("(op go)")))
    }

    @Test func theWildBindsNothing() throws {
        let last = try shape("(shape [_ _ z] {z} _)")
        #expect(try last.extract(from: value("[1 (two) 3]")) == bindings("{z: 3}"))
        // the wild wins over a hole of the same name, which is then never bound
        #expect(try shape("(shape (f x) {x} x)").extract(from: value("(f 1)")) == nil)
    }

    @Test func everyHoleMustBeBound() throws {
        #expect(try shape("(shape (f x) {x y})").extract(from: value("(f 1)")) == nil)
    }

    @Test func dictsNeedTheirKeysAndIgnoreExtras() throws {
        let entry = try shape("(shape {k: v extra: 1} {v})")
        #expect(try entry.extract(from: value("{k: [1 2] extra: 1 more: 0}")) == bindings("{v: [1 2]}"))
        #expect(try entry.extract(from: value("{k: [1 2] extra: 2}")) == nil)
        #expect(try entry.extract(from: value("{j: 1 extra: 1}")) == nil)
        #expect(try shape("(shape [{x: [h]} 1] {h})").extract(from: value("[{x: [5]} 1]")) == bindings("{h: 5}"))
    }

    @Test func setsNeedTheirMembersAndIgnoreExtras() throws {
        let tags = try shape("(shape {a b} {})")
        #expect(try tags.extract(from: value("{a b c}")) == Value.Dict())
        #expect(try tags.extract(from: value("{a}")) == nil)
    }

    @Test func holesAsKeysOrMembersCantBeExtracted() throws {
        // looked up literally first; an error only when found
        let keyed = try shape("(shape {k: 1} {k})")
        #expect(try keyed.extract(from: value("{j: 1}")) == nil)
        #expect(throws: ShapeError(.holeInKey, .symbol("k"))) { try keyed.extract(from: value("{k: 1}")) }

        let membered = try shape("(shape {a b} {b})")
        #expect(try membered.extract(from: value("{a}")) == nil)
        #expect(throws: ShapeError(.holeInMember, .symbol("b"))) { try membered.extract(from: value("{a b}")) }
    }

    @Test func holesInsideKeysOrMembersNeverBind() throws {
        // the key is looked up whole; the x inside it isn't bound to itself
        #expect(try shape("(shape {(k x): 1} {x})").extract(from: value("{(k x): 1}")) == nil)
        #expect(try shape("(shape {(m x)} {x})").extract(from: value("{(m x)}")) == nil)
        #expect(try shape("(shape [{(k x): 1} x] {x})").extract(from: value("[{(k x): 1} 5]")) == bindings("{x: 5}"))
    }

    @Test func aHoleIsAtomic() throws {
        let nested = try shape("(shape (foo x (k x)) {x (k x)})")
        #expect(try nested.extract(from: value("(foo bar (a b))")) == bindings("{x: bar (k x): (a b)}"))
    }

    @Test func aHeadCanBeAHole() throws {
        #expect(try shape("(shape (h 1) {h})").extract(from: value("(foo 1)")) == bindings("{h: foo}"))
    }

    @Test func worksAsAPatternInSwitch() throws {
        let note = try shape("(shape (note text) {text})")
        let link = try shape("(shape (link url) {url})")
        let twice = try shape("(shape [x x] {x})")
        func describe(_ value: Value) -> String {
            switch value {
            case note: "note"
            case link: "link"
            case twice: "twice"
            default: "something else"
            }
        }
        #expect(try describe(value(#"(link "https://example.com")"#)) == "link")
        #expect(try describe(value("(board)")) == "something else")
        #expect(try describe(value("[1 2]")) == "something else")    // a shape error doesn't match
    }
}

@Suite("shapes: inject")
struct ShapeInjectTests {
    @Test func fillsEveryHole() throws {
        let file = try shape("(shape (file name digest) {name digest})")
        #expect(try file.inject(bindings(#"{name: "a" digest: 0xff}"#)) == value(#"(file "a" 0xff)"#))
        #expect(try file.inject(bindings(#"{name: "a" digest: 1 unrelated: 2}"#)) == value(#"(file "a" 1)"#))
    }

    @Test func aMissingBindingIsAnError() throws {
        let file = try shape("(shape (file name digest) {name digest})")
        #expect(throws: ShapeError(.unboundHole, .symbol("digest"))) { try file.inject(bindings(#"{name: "a"}"#)) }
        #expect(throws: ShapeError.self) { try file.inject([:]) }
        // including holes that never occur in the example
        #expect(throws: ShapeError(.unboundHole, .symbol("y"))) { try shape("(shape (f x) {x y})").inject(bindings("{x: 1}")) }
    }

    @Test func fillsEveryPositionKeysAndMembersToo() throws {
        #expect(try shape("(shape {k: v} {k v})").inject(bindings("{k: a v: 1}")) == value("{a: 1}"))
        #expect(try shape("(shape {x 3} {x})").inject(bindings("{x: 1}")) == value("{1 3}"))
        #expect(try shape("(shape !(f x) {x})").inject(bindings("{x: [1]}")) == value("!(f [1])"))
        #expect(try shape("(shape {title: t tags: {a} count: [n]} {t n})").inject(bindings(#"{t: "hi" n: 2}"#))
            == value(#"{title: "hi" tags: {a} count: [2]}"#))
    }
}

@Suite("shapes: as values")
struct ShapeValueTests {
    @Test(arguments: ["(shape x)", "(shape x [x])", "(form x {x})", "!(shape x {x})", "(shape x {x} _ extra)"])
    func otherFormsAreNotShapes(_ text: String) {
        #expect(throws: ValueConversionError.self) { try shape(text) }
    }

    @Test func roundTripsAsAValue() throws {
        let bookmark = try shape("(shape (bookmark url title note) {url title note})")
        #expect(bookmark.description == "(shape (bookmark url title note) {url note title})")
        #expect(try Shape(bassline: bookmark.basslineValue) == bookmark)
        #expect(try shape("(shape [_ x] {x} _)").basslineValue == value("(shape [_ x] {x} _)"))
    }
}

// MARK: - Laws on generated values

/// Punches holes into some atoms in list and record positions and dict
/// values, naming them in order and giving each the mark of what it
/// replaced; what they replaced goes to `expected`.
private func punch(_ value: Value, _ expected: inout Value.Dict, _ rng: inout SplitMix64) -> Value {
    func maybeHole(_ part: Value, _ expected: inout Value.Dict, _ rng: inout SplitMix64) -> Value {
        if !part.kind.isFrame, Int.random(in: 0 ..< 10, using: &rng) < 4 {
            let hole = Value(.symbol(Symbol("hole-\(expected.count)")), marked: part.isMarked)
            expected[hole] = part
            return hole
        }
        return punch(part, &expected, &rng)
    }
    var result = value
    switch value.content {
    case .list(let items):
        result.content = .list(items.map { maybeHole($0, &expected, &rng) })
    case .record(let head, let fields):
        let head = maybeHole(head, &expected, &rng)
        result.content = .record(head: head, fields: fields.map { maybeHole($0, &expected, &rng) })
    case .dict(let dict):
        result.content = .dict(Value.Dict(dict.map { ($0.key, maybeHole($0.value, &expected, &rng)) }))
    default:
        break
    }
    return result
}

/// Adds trailing members to lists and records, keys to dicts, and members
/// to sets, everywhere a shape reads by position.
private func extend(_ value: Value) -> Value {
    var result = value
    switch value.content {
    case .list(let items):
        result.content = .list(items.map(extend) + [.symbol("extra")])
    case .record(let head, let fields):
        result.content = .record(head: extend(head), fields: fields.map(extend) + [.symbol("extra")])
    case .dict(var dict):
        for (key, item) in dict { dict[key] = extend(item) }
        if dict[.symbol("extra-key")] == nil { dict[.symbol("extra-key")] = 1 }
        result.content = .dict(dict)
    case .set(var set):
        set.insert(.symbol("extra-member"))
        result.content = .set(set)
    default:
        break
    }
    return result
}

@Suite("shapes: laws")
struct ShapeLawTests {
    @Test func punchExtractInject() throws {
        var generator = ValueGenerator(rng: SplitMix64(seed: 2024))
        var rng = SplitMix64(seed: 5)
        var totalHoles = 0
        for _ in 0 ..< 400 {
            let original = Value.record("case", generator.value(), generator.value(), generator.value())
            var expected = Value.Dict()
            let punched = punch(original, &expected, &rng)
            let shape = Shape(punched, holes: Value.Set(expected.keys))
            totalHoles += expected.count

            // extract from the original gives back what was punched out
            #expect(try shape.extract(from: original) == expected, "\(shape) on \(original)")
            // and injecting it rebuilds the original
            #expect(try shape.inject(expected) == original)
            // extras don't change what binds
            #expect(try shape.extract(from: extend(original)) == expected, "\(shape) on \(extend(original))")
            // every hole must be bound to inject
            if let hole = expected.keys.first {
                var missing = expected
                missing[hole] = nil
                #expect(throws: ShapeError(.unboundHole, hole)) { try shape.inject(missing) }
            }
            // and a shape survives being written as a value
            #expect(try Shape(bassline: Value(reading: shape.basslineValue.description)) == shape)
        }
        #expect(totalHoles > 300, "only \(totalHoles) holes")
    }
}
