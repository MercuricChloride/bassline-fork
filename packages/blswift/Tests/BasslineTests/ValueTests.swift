import Testing
@testable import Bassline

@Suite("values")
struct ValueTests {
    // MARK: Identity

    @Test func unicodeNormalizationFormsAreDistinctValues() throws {
        let nfc = "\u{e9}", nfd = "e\u{301}"
        #expect(nfc == nfd, "Swift's String equality treats these as the same")

        #expect(Value.text(nfc) != Value.text(nfd))
        #expect(try Value.text(nfc).encoded() != Value.text(nfd).encoded())
        #expect(Symbol(nfc) != Symbol(nfd))
        let set = Value.Set([.text(nfc), .text(nfd)])
        #expect(set.count == 2)
        #expect(Swift.Set([Value.text(nfc), Value.text(nfd)]).count == 2)
    }

    @Test func markIsOneBitAndNeverEqualToUnmarked() throws {
        let go = Value.symbol("go")
        #expect(go != go.marked)
        #expect(go.marked.unmarked == go)
        let (a, b) = (try go.encoded(), try go.marked.encoded())
        #expect(a[0] ^ b[0] == 0x08)
        #expect(a.dropFirst() == b.dropFirst())
    }

    @Test func canonicalOrderOfIntegersIsBytewise() {
        let values: [Value] = [10, 9, -1, 1]
        #expect(values.sorted(by: Value.canonicalOrder) == [1, 9, -1, 10])
    }

    // MARK: Integers

    @Test func integerForms() throws {
        #expect(Value.Integer(Int64.min) == .int(.min))
        #expect(Value.Integer(UInt64.max) == .big("18446744073709551615"))
        #expect(Value.Integer(Int128.min).spelling == "-170141183460469231731687303715884105728")
        #expect(Value.Integer.big("5") == .int(5))
        #expect(Value.Integer.big("5").hashValue == Value.Integer.int(5).hashValue)
    }

    @Test func integerConversions() throws {
        let big = Value.Integer(Int128.max)
        #expect(Int128(exactly: big) == .max)
        #expect(Int64(exactly: big) == nil)
        #expect(Int8(exactly: Value.Integer.int(127)) == 127)
        #expect(Int8(exactly: Value.Integer.int(128)) == nil)
        #expect(UInt8(exactly: Value.Integer.int(-1)) == nil)
        #expect(UInt64(exactly: Value.Integer(UInt64.max)) == .max)
        #expect(try Value(decoding: try Value.integer(Int128.min).encoded()).integer == Value.Integer(Int128.min))
    }

    @Test(arguments: ["+5", "-0", "007", "0_0", "", "-", " 5", "5 ", "1.5", "\u{661}", "-01"])
    func nonCanonicalSpellingsAreRefused(_ spelling: String) {
        #expect(Value.Integer(spelling: spelling) == nil)
    }

    @Test func integerLiteralsOfAnySize() {
        let big: Value = 123456789012345678901234567890
        #expect(big.integer == .big("123456789012345678901234567890"))
        let negative: Value = -123456789012345678901234567890
        #expect(negative.integer == .big("-123456789012345678901234567890"))
        let min: Value = -9223372036854775808
        #expect(min.integer == .int(.min))
        let justPast: Value = 9223372036854775808
        #expect(justPast.integer == .big("9223372036854775808"))
        let huge: Value.Integer = 1_000_000_000_000_000_000_000_000_000_000_000_000_000
        #expect(huge.spelling == "1" + String(repeating: "0", count: 39))
    }

    @Test func integersCompareNumerically() {
        let ordered: [Value.Integer] = [-123456789012345678901234567890, -9223372036854775809, -10, -1, 0, 9, 10,
                                        9223372036854775808, 123456789012345678901234567890]
        #expect(ordered.shuffled().sorted() == ordered)
    }

    // MARK: Construction

    @Test func constructionHelpers() {
        #expect(Value.list([1, 2]).list?.count == 2)
        #expect(Value.list(1, 2).list?.count == 2)
        #expect(Value.set([1, 2]).set?.count == 2)
        #expect(Value.record("point", 1, 2).description == "(point 1 2)")
        #expect(Value.record("point", [1, 2]).description == "(point [1 2])")
        #expect(Value.record(head: "title").description == "(\"title\")")
        let literal: Value = ["name": "alice", "tags": .set([.symbol("a")])]
        #expect(literal.description == "{\"name\": \"alice\" \"tags\": {a}}")
    }

    // MARK: Collections

    @Test func dictSubscriptLooksUpKeysNotPositions() {
        let dict: Value.Dict = [1: "one", 0: "zero"]
        #expect(dict[0] == "zero")
        #expect(dict.first?.key == 0)
        #expect(dict[2] == nil)
    }

    @Test func silenceAndStatedAbsence() {
        var dict: Value.Dict = ["a": 1, "b": 2]
        dict["a"] = nil
        dict["b"] = .null
        #expect(dict.count == 1)
        #expect(dict["a"] == nil)
        #expect(dict["b"] == .null)
        #expect(dict.description == "{\"b\": nil}")
    }

    @Test func collectionsKeepCanonicalOrder() throws {
        var dict = Value.Dict()
        dict[.symbol("ab")] = 2
        dict[.symbol("b")] = 1
        #expect(Array(dict.keys) == [.symbol("b"), .symbol("ab")])
        #expect(try Value.dict(dict).encoded() == [0x80, 0x41, 0x62, 0x21, 0x31, 0x42, 0x61, 0x62, 0x21, 0x32, 0xA0])

        var set: Value.Set = [3, 1]
        #expect(set.insert(2).inserted)
        #expect(!set.insert(2).inserted)
        #expect(Array(set) == [1, 2, 3])
        #expect(set.contains(2) && !set.contains(4))
        #expect(set.remove(1) == 1)
        #expect(Array(set) == [2, 3])
    }

    @Test func duplicateDictLiteralKeysTrap() async {
        await #expect(processExitsWith: .failure) {
            let dict: Value.Dict = [1: 1, 1: 2]
            _ = dict
        }
    }

    // MARK: Bridge

    @Test func bridgeRoundTrips() throws {
        #expect(Value(42) == 42)
        #expect(try Int(bassline: 42) == 42)
        #expect(try [Int](bassline: Value([1, 2, 3])) == [1, 2, 3])
        #expect(try String(bassline: "hi") == "hi")
        #expect(try Symbol(bassline: .symbol("go")) == "go")
        #expect(try Int128(bassline: Value(Int128.max)) == .max)

        let maybe: Int? = nil
        #expect(Value(maybe) == .null)
        #expect(try Int?(bassline: .null) == nil)
        #expect(try Int?(bassline: 3) == 3)

        let scores = ["alice": 3, "bob": 5]
        #expect(try [String: Int](bassline: Value(scores)) == scores)
        let tags: Swift.Set<Symbol> = ["red", "blue"]
        #expect(Value(tags) == .set([.symbol("blue"), .symbol("red")]))
        #expect(try Swift.Set<Symbol>(bassline: Value(tags)) == tags)
    }

    @Test func bridgeIsStrict() {
        #expect(throws: ValueConversionError.self) { try Int8(bassline: 128) }
        #expect(throws: ValueConversionError.self) { try Int(bassline: Value(1).marked) }
        #expect(throws: ValueConversionError.self) { try String(bassline: .symbol("go")) }
        // NFC and NFD are two members in bassline but one in Swift
        #expect(throws: ValueConversionError.self) {
            try Swift.Set<String>(bassline: .set([.text("\u{e9}"), .text("e\u{301}")]))
        }
    }
}
