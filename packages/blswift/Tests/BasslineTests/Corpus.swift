import Foundation
import Testing
@testable import Bassline

/// The shared corpus in `bassline/corpus`, which every implementation tests against.
///
/// The same 143 records exist three ways: `corpus.blb` (binary, read with our
/// decoder), `corpus.bl` (text, read with our reader) and `corpus.json` (read
/// with Foundation, built by hand). The three are checked against each other,
/// and the cases themselves come from the binary copy.
enum Corpus {
    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent() // BasslineTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // blswift
        .deletingLastPathComponent() // packages
        .deletingLastPathComponent() // bassline
        .appending(path: "corpus")

    private static let binary = Result { try Value.decodeAll(Data(contentsOf: directory.appending(path: "corpus.blb"))) }
    private static let text = Result { try Value.readDocument(String(contentsOf: directory.appending(path: "corpus.bl"), encoding: .utf8)) }
    private static let json = Result { try buildFromJSON() }

    static func records() throws -> [Value] { try binary.get() }
    static func textRecords() throws -> [Value] { try text.get() }
    static func jsonRecords() throws -> [Value] { try json.get() }

    /// Records whose head is the symbol `head`.
    static func cases(_ head: Symbol) throws -> [[Value]] {
        try records().compactMap { $0.head == .symbol(head) ? $0.fields : nil }
    }

    static func ce() throws -> [CECase] {
        try cases("ce").map { CECase(name: $0[0].symbol!.rawValue, value: $0[1], bytes: $0[2].bytes!) }
    }

    static func rejects() throws -> [RejectCase] {
        try cases("reject").map { RejectCase(name: $0[0].symbol!.rawValue, bytes: $0[1].bytes!, reason: $0[2].symbol!.rawValue) }
    }

    static func starved() throws -> [StarvedCase] {
        try cases("starved").map { StarvedCase(name: $0[0].symbol!.rawValue, bytes: $0[1].bytes!) }
    }

    static func reads() throws -> [TextCase] {
        try cases("reads").map { TextCase(source: $0[0].text!, expected: [$0[1]]) }
    }

    static func refuses() throws -> [TextCase] {
        try cases("refuses").map { TextCase(source: $0[0].text!, expected: []) }
    }

    static func incomplete() throws -> [TextCase] {
        try cases("incomplete").map { TextCase(source: $0[0].text!, expected: []) }
    }

    static func documents() throws -> [TextCase] {
        try cases("document").map { TextCase(source: $0[0].text!, expected: $0[1].list!) }
    }
}

struct CECase: Sendable, CustomTestStringConvertible {
    var name: String
    var value: Value
    var bytes: [UInt8]
    var testDescription: String { name }
}

struct RejectCase: Sendable, CustomTestStringConvertible {
    var name: String
    var bytes: [UInt8]
    var reason: String
    var testDescription: String { "\(name) (\(reason))" }
}

struct StarvedCase: Sendable, CustomTestStringConvertible {
    var name: String
    var bytes: [UInt8]
    var testDescription: String { name }
}

struct TextCase: Sendable, CustomTestStringConvertible {
    var source: String
    var expected: [Value]
    var testDescription: String { Value.text(source).description }
}

// MARK: - JSON oracle

extension Corpus {
    /// Builds the records from corpus.json by hand, independent of the decoder
    /// and reader. Dict and set members are inserted in shuffled order so the
    /// collections have to sort them themselves.
    private static func buildFromJSON() throws -> [Value] {
        let data = try Data(contentsOf: directory.appending(path: "corpus.json"))
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        var rng = SplitMix64(seed: 0xB455_11E)
        return try array.map { try fromJSON($0, rng: &rng) }
    }

    struct JSONShapeError: Error { var node: String }

    private static func fromJSON(_ node: Any, rng: inout SplitMix64) throws -> Value {
        guard let object = node as? [String: Any], let kind = object["kind"] as? String else {
            throw JSONShapeError(node: "\(node)")
        }
        let marked = object["mark"] as? Bool ?? false
        let raw = object["value"]
        func members() throws -> [Value] {
            guard let items = raw as? [Any] else { throw JSONShapeError(node: "\(object)") }
            return try items.map { try fromJSON($0, rng: &rng) }
        }

        // switch on "kind" only: NSNumber 0 and 1 also bridge to Bool
        let content: Value.Content
        switch kind {
        case "nil":
            content = .null
        case "number":
            // NSNumber's description is exact here, including the 30-digit decimals
            let spelling = try #require(raw as? NSNumber).description
            content = .integer(try #require(Value.Integer(spelling: spelling)))
        case "text":
            content = .text(try #require(raw as? String))
        case "symbol":
            content = .symbol(Symbol(try #require(raw as? String)))
        case "bytes":
            content = .bytes(try hexBytes(try #require(raw as? String)))
        case "list":
            content = .list(try members())
        case "record":
            let items = try members()
            content = .record(head: try #require(items.first), fields: Array(items.dropFirst()))
        case "set":
            let items = try members()
            let set = Value.Set(items.shuffled(using: &rng))
            #expect(Array(set) == items, "set members should come back in canonical order")
            content = .set(set)
        case "dict":
            guard let pairs = raw as? [[Any]] else { throw JSONShapeError(node: "\(object)") }
            let entries = try pairs.map { (try fromJSON($0[0], rng: &rng), try fromJSON($0[1], rng: &rng)) }
            let dict = Value.Dict(entries.shuffled(using: &rng))
            #expect(Array(dict.keys) == entries.map(\.0), "dict keys should come back in canonical order")
            content = .dict(dict)
        default:
            throw JSONShapeError(node: kind)
        }
        return Value(content, marked: marked)
    }

    private static func hexBytes(_ string: String) throws -> [UInt8] {
        let hex = Array(string.utf8.dropFirst(2))
        guard string.hasPrefix("0x"), hex.count.isMultiple(of: 2) else { throw JSONShapeError(node: string) }
        return try stride(from: 0, to: hex.count, by: 2).map { i in
            try #require(UInt8(String(decoding: hex[i ... i + 1], as: UTF8.self), radix: 16))
        }
    }
}

// MARK: - Test helpers

/// A small seeded generator, so random tests reproduce.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Feeds `bytes` to a fresh decoder and drains it, returning what landed and
/// the error, if any. `chunked` feeds one byte at a time.
func land(_ bytes: [UInt8], chunked: Bool = false, limits: DecodingLimits = .default) -> (values: [Value], error: DecodeError?, pending: Bool) {
    var decoder = StreamDecoder(limits: limits)
    var values: [Value] = []
    do {
        if chunked {
            for byte in bytes {
                decoder.append(byte)
                while let value = try decoder.next() { values.append(value) }
            }
        } else {
            decoder.append(contentsOf: bytes)
            while let value = try decoder.next() { values.append(value) }
        }
    } catch {
        return (values, error, decoder.isPending)
    }
    return (values, nil, decoder.isPending)
}
