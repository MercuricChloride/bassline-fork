import Testing
@testable import Bassline

private func shape(_ text: String) throws -> Shape {
    try Shape(bassline: Value(reading: text))
}

private func value(_ text: String) throws -> Value {
    try Value(reading: text)
}

private func bindings(_ texts: String...) throws -> Swift.Set<Value.Dict> {
    Swift.Set(try texts.map { try #require(value($0).dict) })
}

private func all(_ answers: Answers<Value.Dict>) -> Swift.Set<Value.Dict> {
    Swift.Set(answers)
}

@Suite("shapes: fillings")
struct ShapeFillingTests {
    @Test func aPlainShapeFillsAsExtractReads() throws {
        let file = try shape("(shape (file name digest) {name digest})")
        #expect(try Array(file.fillings(of: value(#"(file "a.txt" 0xff extra)"#))) == [#require(value(#"{name: "a.txt" digest: 0xff}"#).dict)])
        #expect(try Array(file.fillings(of: value(#"(dir "a.txt" 0xff)"#))).isEmpty)
        #expect(try Array(file.fillings(of: value("(file)"))).isEmpty)
    }

    @Test func aRepeatedHoleBoundTwoWaysYieldsNothing() throws {
        let twice = try shape("(shape [x y x] {x y})")
        #expect(try all(twice.fillings(of: value("[1 2 1]"))) == bindings("{x: 1 y: 2}"))
        // extract throws here; a search just has no filling
        #expect(try Array(twice.fillings(of: value("[1 2 3]"))).isEmpty)
    }

    @Test func aHoleInASetMemberBacktracksOverTheMembers() throws {
        let tagged = try shape("(shape {(tag t)} {t})")
        #expect(try all(tagged.fillings(of: value("{(tag a) (tag b) (other c)}"))) == bindings("{t: a}", "{t: b}"))
        let member = try shape("(shape {a x} {x})")
        #expect(try all(member.fillings(of: value("{a b c}"))) == bindings("{x: a}", "{x: b}", "{x: c}"))
        #expect(try Array(member.fillings(of: value("{b c}"))).isEmpty, "a literal member is still needed")
        // two members of the example may fill from the same member
        let pair = try shape("(shape {[x] [y]} {x y})")
        #expect(try all(pair.fillings(of: value("{[1] [2]}"))) == bindings("{x: 1 y: 1}", "{x: 1 y: 2}", "{x: 2 y: 1}", "{x: 2 y: 2}"))
    }

    @Test func aHoleInADictKeyBacktracksOverTheEntries() throws {
        let any = try shape("(shape {k: v} {k v})")
        #expect(try all(any.fillings(of: value("{a: 1 b: 2}"))) == bindings("{k: a v: 1}", "{k: b v: 2}"))
        // the key's hole and the value's must agree
        let same = try shape("(shape {k: k} {k})")
        #expect(try all(same.fillings(of: value("{a: b c: c 1: 1}"))) == bindings("{k: c}", "{k: 1}"))
        // a hole inside a key binds, unlike extract, which looks keys up whole
        let inside = try shape("(shape {(k x): 1} {x})")
        #expect(try all(inside.fillings(of: value("{(k 5): 1 (k 6): 2 (j 7): 1}"))) == bindings("{x: 5}"))
        #expect(try shape("(shape {(k x): 1} {x})").extract(from: value("{(k 5): 1}")) == nil)
    }

    @Test func marksMustAgreeAndTheWildMatchesAnything() throws {
        let plain = try shape("(shape {(op x)} {x})")
        #expect(try all(plain.fillings(of: value("{(op go) (op go!)}"))) == bindings("{x: go}"))
        let marked = try shape("(shape {(op x!)} {x!})")
        #expect(try all(marked.fillings(of: value("{(op go) (op go!)}"))) == bindings("{x!: go!}"))
        let command = try shape("(shape !(f x) {x})")
        #expect(try Array(command.fillings(of: value("(f 1)"))).isEmpty)
        // the wild in a member matches any member, and binds nothing
        let wild = try shape("(shape {(p x) (q _)} {x} _)")
        #expect(try all(wild.fillings(of: value("{(p 1) (q 1) (q 2)}"))) == bindings("{x: 1}"))
        #expect(try Array(wild.fillings(of: value("{(p 1)}"))).isEmpty)
        // each binding once, though two members of the value fit the wild
        #expect(try Array(wild.fillings(of: value("{(p 1) (q 1) (q 2)}"))).count == 1)
    }

    @Test func everyHoleMustBeBound() throws {
        #expect(try Array(shape("(shape (f x) {x y})").fillings(of: value("(f 1)"))).isEmpty)
        // a hole only inside another hole is never reached
        #expect(try Array(shape("(shape [(k x)] {x (k x)})").fillings(of: value("[(k 1)]"))).isEmpty)
    }

    @Test func fillingsInManyValues() throws {
        let row = try shape("(shape (row label n) {label n})")
        let rows = try ["(row a 1)", "(note x)", "(row b 2)", "(row a 1)"].map(value)
        #expect(Array(row.fillings(in: rows)) == [try #require(value("{label: a n: 1}").dict), try #require(value("{label: b n: 2}").dict)])
        // walked only as far as pulled: an endless sequence is fine
        let numbers = (0...).lazy.map { Value.integer($0) }
        #expect(try shape("(shape x {x})").fillings(in: numbers).take(3) == [try #require(value("{x: 0}").dict), try #require(value("{x: 1}").dict),
                                                                            try #require(value("{x: 2}").dict)])
    }

    @Test func nothingIsWorkedOutAheadOfAPull() throws {
        // two hundred members, three member holes: eight million fillings,
        // and taking three costs three
        let members = Value.Set((0 ..< 200).map { Value.list([.integer($0)]) })
        let three = try shape("(shape {[x] [y] [z]} {x y z})")
        let first = three.fillings(of: .set(members)).take(3)
        #expect(first.count == 3)
        #expect(Swift.Set(first).count == 3)
    }

    @Test func extractIsUnchanged() throws {
        // still throws where it threw
        #expect(throws: ShapeError(.mismatchedHole, .symbol("x"))) { try shape("(shape [x x] {x})").extract(from: value("[1 2]")) }
        #expect(throws: ShapeError(.holeInMember, .symbol("b"))) { try shape("(shape {a b} {b})").extract(from: value("{a b}")) }
    }
}

// MARK: - Against a brute-force search

/// What a filling is, said directly: `binding` (every hole bound) makes
/// `value` fit `part`. Written apart from `fillings`, as quantifiers over
/// the value's actual keys and members, so the two can check each other.
private func fits(_ shape: Shape, _ part: Value, _ value: Value, _ binding: Value.Dict) -> Bool {
    if shape.wild == part { return true }
    if shape.holes.contains(part) { return part.isMarked == value.isMarked && binding[part] == value }
    guard part.kind == value.kind, part.isMarked == value.isMarked else { return false }
    switch (part.content, value.content) {
    case let (.list(p), .list(v)):
        return v.count >= p.count && zip(p, v).allSatisfy { fits(shape, $0, $1, binding) }
    case let (.record(ph, p), .record(vh, v)):
        return v.count >= p.count && fits(shape, ph, vh, binding) && zip(p, v).allSatisfy { fits(shape, $0, $1, binding) }
    case let (.dict(p), .dict(v)):
        return p.allSatisfy { key, item in
            literal(shape, key) ? v[key].map { fits(shape, item, $0, binding) } ?? false
                : v.contains { fits(shape, key, $0.key, binding) && fits(shape, item, $0.value, binding) }
        }
    case let (.set(p), .set(v)):
        return p.allSatisfy { member in
            literal(shape, member) ? v.contains(member) : v.contains { fits(shape, member, $0, binding) }
        }
    default:
        return part == value
    }
}

private func literal(_ shape: Shape, _ part: Value) -> Bool {
    subvalues(part).allSatisfy { shape.wild != $0 && !shape.holes.contains($0) }
}

/// Whether matching ever reaches `hole` in `part`: not under the wild, and
/// not inside another hole.
private func reaches(_ shape: Shape, _ hole: Value, _ part: Value) -> Bool {
    if shape.wild == part { return false }
    if shape.holes.contains(part) { return part == hole }
    switch part.content {
    case .list(let items): return items.contains { reaches(shape, hole, $0) }
    case .record(let head, let fields): return reaches(shape, hole, head) || fields.contains { reaches(shape, hole, $0) }
    case .dict(let dict): return dict.contains { reaches(shape, hole, $0.key) || reaches(shape, hole, $0.value) }
    case .set(let set): return set.contains { reaches(shape, hole, $0) }
    default: return false
    }
}

/// A value and everything inside it, keys and heads included.
private func subvalues(_ value: Value) -> [Value] {
    var found = [value]
    switch value.content {
    case .list(let items): found += items.flatMap(subvalues)
    case .record(let head, let fields): found += subvalues(head) + fields.flatMap(subvalues)
    case .dict(let dict): found += dict.flatMap { subvalues($0.key) + subvalues($0.value) }
    case .set(let set): found += set.flatMap(subvalues)
    default: break
    }
    return found
}

/// Every filling, found by trying every assignment of the value's parts to
/// the holes: a hole binds what's at its place, so a part it is.
private func bruteForce(_ shape: Shape, _ value: Value) -> Swift.Set<Value.Dict> {
    let holes = Array(shape.holes)
    guard holes.allSatisfy({ reaches(shape, $0, shape.example) }) else { return [] }
    let candidates = Array(Swift.Set(subvalues(value)))
    var found = Swift.Set<Value.Dict>()
    func assign(_ i: Int, _ binding: Value.Dict) {
        if i == holes.count {
            if fits(shape, shape.example, value, binding) { found.insert(binding) }
            return
        }
        for candidate in candidates {
            var next = binding
            next[holes[i]] = candidate
            assign(i + 1, next)
        }
    }
    assign(0, Value.Dict())
    return found
}

/// Small values from a small alphabet, so that parts repeat and shapes
/// find several ways to fill: sets and dicts of a few members, a mark now
/// and then.
private struct SmallValues {
    var rng: SplitMix64

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func chance(_ n: Int) -> Bool { int(1 ... n) == 1 }

    mutating func atom() -> Value {
        var atom: Value = switch int(0 ... 3) {
        case 0: .integer(int(0 ... 2))
        case 1: .symbol(["a", "b", "c"][int(0 ... 2)])
        case 2: .text(["", "t"][int(0 ... 1)])
        default: .null
        }
        if chance(8) { atom.isMarked = true }
        return atom
    }

    mutating func value(depth: Int = 0) -> Value {
        guard depth < 3, !chance(depth == 0 ? 6 : 3) else { return atom() }
        let count = int(0 ... 3)
        var made: Value
        switch int(0 ... 3) {
        case 0: made = .list((0 ..< count).map { _ in value(depth: depth + 1) })
        case 1: made = .record(head: chance(3) ? atom() : .symbol(["p", "q"][int(0 ... 1)]),
                               fields: (0 ..< count).map { _ in value(depth: depth + 1) })
        case 2: made = .dict(Value.Dict((0 ..< count).map { _ in (value(depth: depth + 2), value(depth: depth + 1)) }))
        default: made = .set(Value.Set((0 ..< count).map { _ in value(depth: depth + 1) }))
        }
        if chance(10) { made.isMarked = true }
        return made
    }

    /// A shape made from `value` by putting holes (some repeated) and the
    /// wild in place of some of its parts, anywhere: keys, members and
    /// heads too. A hole usually takes the mark of what it replaced.
    mutating func shape(from value: Value) -> Shape {
        let names: [Symbol] = ["x", "y", "z"]
        var holes = Swift.Set<Value>()
        func punch(_ part: Value, depth: Int) -> Value {
            if depth > 0, chance(4) {
                if chance(5) { return .symbol("_") }
                var hole = Value.symbol(names[int(0 ... 2)])
                hole.isMarked = chance(6) ? !part.isMarked : part.isMarked
                holes.insert(hole)
                return hole
            }
            var result = part
            switch part.content {
            case .list(let items): result.content = .list(items.map { punch($0, depth: depth + 1) })
            case .record(let head, let fields):
                result.content = .record(head: punch(head, depth: depth + 1), fields: fields.map { punch($0, depth: depth + 1) })
            case .dict(let dict): result.content = .dict(Value.Dict(dict.map { (punch($0.key, depth: depth + 1), punch($0.value, depth: depth + 1)) }))
            case .set(let set): result.content = .set(Value.Set(set.map { punch($0, depth: depth + 1) }))
            default: break
            }
            return result
        }
        let example = punch(value, depth: 0)
        // now and then a hole the example never reaches
        if chance(15) { holes.insert(.symbol("never")) }
        return Shape(example, holes: Value.Set(holes), wild: .symbol("_"))
    }
}

@Suite("shapes: fillings against brute force")
struct ShapeFillingSearchTests {
    @Test func completeAndCorrectOnGeneratedValues() throws {
        var values = SmallValues(rng: SplitMix64(seed: 909))
        var cases = 0
        var withSeveral = 0
        var inKeysOrMembers = 0
        for _ in 0 ..< 600 {
            let original = values.value()
            let shape = values.shape(from: original)
            if shape.holes.count > 3 { continue }
            for target in [original, values.value(), original] {
                let answered = Array(shape.fillings(of: target))
                let expected = bruteForce(shape, target)
                #expect(Swift.Set(answered) == expected, "\(shape) on \(target): \(answered) vs \(expected)")
                #expect(Swift.Set(answered).count == answered.count, "each filling once: \(shape) on \(target)")
                cases += 1
                if expected.count > 1 { withSeveral += 1 }
                if expected.count > 0, !literalKeysAndMembers(shape) { inKeysOrMembers += 1 }
                // where extract can decide, they agree
                if literalKeysAndMembers(shape) {
                    if let binding = try? shape.extract(from: target) {
                        #expect(answered == [binding], "\(shape) on \(target)")
                    } else {
                        #expect(answered.isEmpty, "\(shape) on \(target): \(answered)")
                    }
                }
            }
        }
        #expect(cases > 1000, "only \(cases) cases")
        #expect(withSeveral > 50, "only \(withSeveral) cases with several fillings")
        #expect(inKeysOrMembers > 30, "only \(inKeysOrMembers) cases filled through keys or members")
    }
}

/// Whether every dict key and set member in the example is literal, so
/// extract decides as the search does.
private func literalKeysAndMembers(_ shape: Shape) -> Bool {
    func check(_ part: Value) -> Bool {
        if shape.wild == part || shape.holes.contains(part) { return true }
        switch part.content {
        case .list(let items): return items.allSatisfy(check)
        case .record(let head, let fields): return check(head) && fields.allSatisfy(check)
        case .dict(let dict): return dict.allSatisfy { literal(shape, $0.key) && check($0.value) }
        case .set(let set): return set.allSatisfy { literal(shape, $0) }
        default: return true
        }
    }
    return check(shape.example)
}
