import Testing
@testable import Bassline

@Suite("text syntax")
struct TextTests {
    @Test(arguments: [
        (Value.symbol("nil"), "'nil'"),
        (.symbol(""), "''"),
        (.symbol("a b"), "'a b'"),
        (.symbol("5"), "'5'"),
        (.symbol("-5"), "'-5'"),
        (.symbol("-"), "-"),
        (.symbol("+5"), "+5"),
        (.symbol("it's"), "'it\\'s'"),
        (Value.null.marked, "nil!"),
        (.record("go", 1).marked, "!(go 1)"),
        (.dict([:]), "{:}"),
        (.set([]), "{}"),
        (.bytes([0xDE, 0xAD, 0xBE, 0xEF]), "0xdeadbeef"),
        (.bytes([]).marked, "0x!"),
        (.text("a\nb\"c\\"), "\"a\\nb\\\"c\\\\\""),
        (.text("\r\n"), "\"\\r\\n\""),
        (-5, "-5"),
        (Value.integer(-5).marked, "-5!"),
    ] as [(Value, String)])
    func printedSpellings(_ value: Value, _ text: String) throws {
        #expect(value.description == text)
        #expect(try Value(reading: text) == value)
    }

    @Test func quoteBeforeCombiningMarkStaysEscaped() throws {
        // `"` + U+0301 is one Character; printing must still escape the quote
        let value = Value.text("\"\u{301}")
        #expect(value.description.unicodeScalars.elementsEqual("\"\\\"\u{301}\"".unicodeScalars))
        #expect(try Value(reading: value.description) == value)
    }

    @Test func commentsAndWhitespace() throws {
        #expect(try Value(reading: "; heading\n[1 ; one\n\t2\r\n]") == [1, 2])
        #expect(try Value.readDocument("; nothing but a comment") == [])
    }

    @Test func rawNewlinesInsideStrings() throws {
        #expect(try Value(reading: "\"a\nb\"") == "a\nb")
    }

    @Test func emptyTextIsNotOneValue() {
        let error = #expect(throws: ReadError.self) { try Value(reading: "") }
        #expect(error?.isIncomplete == false)
    }

    @Test func unknownEscapeIsRefused() {
        let error = #expect(throws: ReadError.self) { try Value(reading: #""\q""#) }
        #expect(error?.isIncomplete == false)
    }

    @Test func depthLimit() throws {
        let deep = { (n: Int) in String(repeating: "[", count: n) + String(repeating: "]", count: n) }
        #expect(throws: Never.self) { try Value(reading: deep(64)) }
        let error = #expect(throws: ReadError.self) { try Value(reading: deep(65)) }
        #expect(error?.isIncomplete == false)
    }

    @Test func errorPositions() {
        let error = #expect(throws: ReadError.self) { try Value(reading: "[1\n  2 )") }
        #expect(error?.line == 2)
        #expect(error?.column == 5)
        #expect(error?.offset == 7)

        // columns count scalars, not bytes
        let accented = #expect(throws: ReadError.self) { try Value(reading: "[é )") }
        #expect(accented?.column == 4)
        #expect(accented?.offset == 4)
    }

    @Test func documentOfMarkedValues() throws {
        let values = try Value.readDocument("!(insert {(person alice) (person bob)}) go! 0x! '' !{}")
        #expect(values == [
            .record("insert", .set([.record("person", .symbol("alice")), .record("person", .symbol("bob"))])).marked,
            Value.symbol("go").marked,
            Value.bytes([]).marked,
            .symbol(""),
            Value.set([]).marked,
        ])
    }
}
