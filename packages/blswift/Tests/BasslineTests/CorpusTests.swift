import Foundation
import Testing
@testable import Bassline

@Suite("corpus files")
struct CorpusFileTests {
    @Test func binaryHoldsEveryRecord() throws {
        let records = try Corpus.records()
        #expect(records.count == 143)
        #expect(records.allSatisfy { $0.kind == .record })
    }

    @Test func jsonAgreesWithBinary() throws {
        let binary = try Corpus.records(), json = try Corpus.jsonRecords()
        try #require(json.count == binary.count)
        for (b, j) in zip(binary, json) {
            #expect(b == j, "\(b)")
        }
    }

    @Test func textAgreesWithBinary() throws {
        let binary = try Corpus.records(), text = try Corpus.textRecords()
        try #require(text.count == binary.count)
        for (b, t) in zip(binary, text) {
            #expect(b == t, "\(b)")
        }
    }

    @Test func reencodingTheRecordsGivesTheFileBack() throws {
        var out: [UInt8] = []
        for record in try Corpus.records() { record.encode(into: &out) }
        let file = try Array(Data(contentsOf: Corpus.directory.appending(path: "corpus.blb")))
        #expect(out == file)
    }
}

@Suite("corpus: binary")
struct BinaryCorpusTests {
    @Test(arguments: try Corpus.ce())
    func ce(_ c: CECase) throws {
        #expect(c.value.encoded() == c.bytes)
        #expect(try Value(decoding: c.bytes) == c.value)

        // one byte at a time: nothing lands until the last byte, then exactly one value
        var decoder = StreamDecoder()
        var landed: [Value] = []
        for (i, byte) in c.bytes.enumerated() {
            decoder.append(byte)
            while let value = try decoder.next() { landed.append(value) }
            if i < c.bytes.count - 1 {
                #expect(landed.isEmpty)
                #expect(decoder.isPending)
            }
        }
        #expect(landed == [c.value])
        #expect(!decoder.isPending)

        #expect(try Value(reading: c.value.description) == c.value)
    }

    @Test(arguments: try Corpus.rejects())
    func reject(_ c: RejectCase) {
        let whole = land(c.bytes)
        #expect(whole.error?.reason.rawValue == c.reason)

        let chunked = land(c.bytes, chunked: true)
        #expect(chunked.error == whole.error)

        #expect(throws: DecodeError.self) { try Value.decodeAll(c.bytes) }
    }

    @Test(arguments: try Corpus.starved())
    func starved(_ c: StarvedCase) {
        for chunked in [false, true] {
            let landed = land(c.bytes, chunked: chunked)
            #expect(landed.error == nil)
            #expect(landed.values.isEmpty)
            #expect(landed.pending)
        }
        #expect(throws: DecodeError(.truncated, at: c.bytes.count)) { try Value(decoding: c.bytes) }
    }
}

@Suite("corpus: text")
struct TextCorpusTests {
    @Test(arguments: try Corpus.reads())
    func reads(_ c: TextCase) throws {
        #expect(try Value(reading: c.source) == c.expected[0])
    }

    @Test(arguments: try Corpus.refuses())
    func refuses(_ c: TextCase) {
        let error = #expect(throws: ReadError.self) { try Value(reading: c.source) }
        #expect(error?.isIncomplete == false)
    }

    @Test(arguments: try Corpus.incomplete())
    func incomplete(_ c: TextCase) {
        let error = #expect(throws: ReadError.self) { try Value(reading: c.source) }
        #expect(error?.isIncomplete == true)
    }

    @Test(arguments: try Corpus.documents())
    func document(_ c: TextCase) throws {
        #expect(try Value.readDocument(c.source) == c.expected)
    }
}
