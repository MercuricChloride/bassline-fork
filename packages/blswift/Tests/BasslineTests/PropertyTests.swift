import Testing
@testable import Bassline

/// Random values covering every kind, marks, the length tiers, big integers,
/// and text that stresses the printer (escapes, NFD, controls, CRLF).
struct ValueGenerator {
    var rng: SplitMix64

    static let scalars: [String] = [
        "a", "b", "z", "A", " ", "\n", "\r", "\r\n", "\t", "\\", "\"", "'", "!", ":", ";", "[", "]", "{", "}",
        "(", ")", "0", "5", "-", "_", "x", "\u{e9}", "e\u{301}", "\u{301}", "😀", "\u{0}", "\u{7}", "\u{7F}",
        "\u{A0}", "\u{2028}",
    ]
    static let names: [String] = ["", "nil", "go", "a b", "0x", "5", "-5", "-", "->", "+5", "_5", "nilx", "é"]

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func chance(_ n: Int) -> Bool { int(1 ... n) == 1 }

    mutating func string() -> String {
        let length = chance(20) ? int(200 ... 300) : int(0 ... 10)
        return (0 ..< length).map { _ in Self.scalars.randomElement(using: &rng)! }.joined()
    }

    mutating func integer() -> Value.Integer {
        switch int(0 ... 3) {
        case 0: return Value.Integer([0, 1, -1, 9, 10, -10, Int64.max, Int64.min].randomElement(using: &rng)!)
        case 1: return Value.Integer(Int64.random(in: .min ... .max, using: &rng))
        case 2: return Value.Integer(int(-1000 ... 1000))
        default:
            let digits = (0 ..< int(19 ... 40)).map { _ in String(int(0 ... 9)) }.joined()
            let spelling = (chance(2) ? "-" : "") + String(int(1 ... 9)) + digits
            return Value.Integer(spelling: spelling)!
        }
    }

    mutating func value(depth: Int = 0) -> Value {
        let atomsOnly = depth >= 3
        let kind = Value.Kind.allCases.filter { !atomsOnly || !$0.isFrame }.randomElement(using: &rng)!
        let members = { (g: inout ValueGenerator) in (0 ..< g.int(0 ... 4)).map { _ in g.value(depth: depth + 1) } }
        let content: Value.Content
        switch kind {
        case .null: content = .null
        case .integer: content = .integer(integer())
        case .text: content = .text(string())
        case .symbol: content = .symbol(Symbol(chance(2) ? Self.names.randomElement(using: &rng)! : string()))
        case .bytes: content = .bytes((0 ..< (chance(10) ? int(250 ... 300) : int(0 ... 9))).map { _ in UInt8(int(0 ... 255)) })
        case .list: content = .list(members(&self))
        case .record: content = .record(head: value(depth: depth + 1), fields: members(&self))
        case .dict: content = .dict(Value.Dict(zip(members(&self), members(&self)).map { ($0, $1) }))
        case .set: content = .set(Value.Set(members(&self)))
        }
        return Value(content, marked: chance(4))
    }
}

/// Byte order of two encodings as -1/0/1.
func byteOrder(_ a: [UInt8], _ b: [UInt8]) -> Int {
    a == b ? 0 : (a.lexicographicallyPrecedes(b) ? -1 : 1)
}

@Suite("properties")
struct PropertyTests {
    static let values: [Value] = {
        var generator = ValueGenerator(rng: SplitMix64(seed: 42))
        return (0 ..< 400).map { _ in generator.value() }
    }()

    @Test func roundTrips() throws {
        for value in Self.values {
            let bytes = value.encoded()
            #expect(try Value(decoding: bytes) == value)
            #expect(try Value(decoding: bytes).encoded() == bytes)

            let text = value.description
            #expect(!text.utf8.contains(0x0A) && !text.utf8.contains(0x0D), "printer emitted a raw line break")
            #expect(try Value(reading: text) == value, "\(text)")
        }
    }

    @Test func streamOfManyValues() throws {
        var stream: [UInt8] = []
        for value in Self.values { value.encode(into: &stream) }
        #expect(try Value.decodeAll(stream) == Self.values)

        // and in ragged chunks
        var rng = SplitMix64(seed: 7)
        var decoder = StreamDecoder()
        var landed: [Value] = []
        var i = 0
        while i < stream.count {
            let n = Int.random(in: 1 ... 64, using: &rng)
            decoder.append(contentsOf: stream[i ..< min(i + n, stream.count)])
            while let value = try decoder.next() { landed.append(value) }
            i += n
        }
        try decoder.finish()
        #expect(landed == Self.values)
    }

    @Test func canonicalOrderIsByteOrder() {
        let values = Self.values
        let encoded = values.map { $0.encoded() }
        for i in values.indices {
            for j in [i, (i + 1) % values.count, (i * 7 + 3) % values.count, (i * 13 + 5) % values.count] {
                #expect(Value.canonicalCompare(values[i], values[j]).signum() == byteOrder(encoded[i], encoded[j]),
                        "\(values[i]) vs \(values[j])")
            }
        }
        let sorted = values.sorted(by: Value.canonicalOrder).map { $0.encoded() }
        #expect(sorted == encoded.sorted { $0.lexicographicallyPrecedes($1) })
    }

    @Test func equalityAndHashingFollowTheBytes() throws {
        for value in Self.values {
            let copy = try Value(decoding: value.encoded())
            #expect(value == copy)
            #expect(value.hashValue == copy.hashValue)
            #expect(value != value.marked || value.isMarked)
        }
        let distinct = Swift.Set(Self.values.map { $0.encoded() })
        #expect(Swift.Set(Self.values).count == distinct.count)
    }
}
