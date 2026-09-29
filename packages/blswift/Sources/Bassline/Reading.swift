// Reading the textual syntax.
//
// The text is a human-friendly way to write values; it is not an encoding
// and has no say in identity. Every delimiter is ASCII, so the reader
// tokenizes the UTF-8 bytes directly without ever splitting a character.
//
// Reading distinguishes text that is wrong (refused) from text that simply
// stops too early (incomplete), so a REPL or editor can keep asking for more.

/// Why text couldn't be read, and where.
public struct ReadError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The text ended where more could still make it valid (`[1 2`, `"open`).
    /// Otherwise the text is refused outright.
    public var isIncomplete: Bool
    public var message: String
    /// UTF-8 byte offset into the text.
    public var offset: Int
    /// 1-based line.
    public var line: Int
    /// 1-based column, counted in Unicode scalars.
    public var column: Int

    public var description: String {
        "line \(line), column \(column): \(message)\(isIncomplete ? " (incomplete)" : "")"
    }
}

extension Value {
    /// Reads exactly one value from `text`.
    public init(reading text: String) throws(ReadError) {
        var reader = TextReader(text)
        let values = try reader.document()
        guard values.count == 1 else {
            throw reader.refusal("expected exactly one value, found \(values.count)",
                                 at: reader.valueStarts.dropFirst().first ?? 0)
        }
        self = values[0]
    }

    /// Reads every value in `text`, in order. Empty text is an empty document.
    public static func readDocument(_ text: String) throws(ReadError) -> [Value] {
        var reader = TextReader(text)
        return try reader.document()
    }
}

enum TextSyntax {
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Whitespace, or a character that does structural work.
    static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D: true
        case UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: ":"), UInt8(ascii: "!"),
             UInt8(ascii: "'"), UInt8(ascii: "\""), UInt8(ascii: ";"): true
        default: false
        }
    }
}

private extension UInt8 {
    func `is`(_ scalar: Unicode.Scalar) -> Bool { self == UInt8(ascii: scalar) }

    var isDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }

    var hexValue: UInt8? {
        switch self {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): self - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): self - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): self - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    var isFrameOpener: Bool { self.is("(") || self.is("[") || self.is("{") }
}

struct TextReader {
    private let bytes: [UInt8]
    private var position = 0
    /// Frames open at once, so deep text can't exhaust the call stack.
    let maxDepth = 64
    /// Where each top-level value began.
    private(set) var valueStarts: [Int] = []

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    private var atEnd: Bool { position >= bytes.count }

    mutating func document() throws(ReadError) -> [Value] {
        var values: [Value] = []
        while true {
            skipWhitespace()
            if atEnd { return values }
            valueStarts.append(position)
            values.append(try value(depth: 0))
        }
    }

    // MARK: Values

    private mutating func value(depth: Int) throws(ReadError) -> Value {
        skipWhitespace()
        guard !atEnd else { throw incomplete("expected a value") }

        // a mark in front belongs to a frame and must touch its bracket
        var markedInFront = false
        if bytes[position].is("!") {
            position += 1
            guard !atEnd else { throw incomplete("a mark with no value after it") }
            let next = bytes[position]
            if next.is("!") { throw refusal("repeated mark") }
            if TextSyntax.isWhitespace(next) || next.is(";") { throw refusal("a mark must touch its value") }
            if !next.isFrameOpener { throw refusal("an atom is marked behind (x!); only a frame is marked in front") }
            markedInFront = true
        }

        let isFrame = bytes[position].isFrameOpener
        var value = try datum(depth: depth)

        // a mark behind belongs to an atom, touches it, and ends at a delimiter
        if !atEnd, bytes[position].is("!") {
            if isFrame { throw refusal("a frame is marked in front: !(…)") }
            position += 1
            if !atEnd, !TextSyntax.isDelimiter(bytes[position]) {
                throw refusal("a marked atom must end at a delimiter")
            }
            value.isMarked = true
        } else if markedInFront {
            value.isMarked = true
        }
        return value
    }

    private mutating func datum(depth: Int) throws(ReadError) -> Value {
        let byte = bytes[position]
        switch Unicode.Scalar(byte) {
        case "[":
            try enter(depth)
            position += 1
            return .list(try members(closedBy: "]", depth: depth))
        case "(":
            try enter(depth)
            position += 1
            skipWhitespace()
            guard !atEnd else { throw incomplete("unclosed (") }
            if bytes[position].is(")") { throw refusal("a record needs a head") }
            let head = try value(depth: depth + 1)
            return .record(head: head, fields: try members(closedBy: ")", depth: depth))
        case "{":
            try enter(depth)
            position += 1
            return try braces(depth: depth)
        case "\"":
            return .text(try quoted())
        case "'":
            return .symbol(Symbol(try quoted()))
        case ")", "]", "}", ":", "!":
            throw refusal("unexpected \(Unicode.Scalar(byte))")
        default:
            return try token()
        }
    }

    private func enter(_ depth: Int) throws(ReadError) {
        if depth >= maxDepth { throw refusal("nested deeper than \(maxDepth) frames") }
    }

    private mutating func members(closedBy close: Unicode.Scalar, depth: Int) throws(ReadError) -> [Value] {
        var items: [Value] = []
        while true {
            skipWhitespace()
            guard !atEnd else { throw incomplete("unclosed frame, expected \(close)") }
            if bytes[position].is(close) {
                position += 1
                return items
            }
            items.append(try value(depth: depth + 1))
        }
    }

    /// `{}` is the empty set and `{:}` the empty dict; otherwise a `:` after
    /// the first element makes a dict and every element must be an entry.
    private mutating func braces(depth: Int) throws(ReadError) -> Value {
        skipWhitespace()
        guard !atEnd else { throw incomplete("unclosed {") }
        if bytes[position].is("}") {
            position += 1
            return .set(Value.Set())
        }
        if bytes[position].is(":") {
            position += 1
            skipWhitespace()
            guard !atEnd else { throw incomplete("unclosed {") }
            guard bytes[position].is("}") else { throw refusal("'{:' is the empty dict; expected '}'") }
            position += 1
            return .dict(Value.Dict())
        }

        var start = position
        let first = try value(depth: depth + 1)
        skipWhitespace()
        guard !atEnd else { throw incomplete("unclosed {") }

        if bytes[position].is(":") {
            position += 1
            var dict = Value.Dict()
            var key = first
            while true {
                if dict[key] != nil { throw refusal("duplicate key \(key)", at: start) }
                dict[key] = try value(depth: depth + 1)
                skipWhitespace()
                guard !atEnd else { throw incomplete("unclosed {") }
                if bytes[position].is("}") {
                    position += 1
                    return .dict(dict)
                }
                start = position
                key = try value(depth: depth + 1)
                skipWhitespace()
                guard !atEnd else { throw incomplete("a dict entry needs ':' after its key") }
                guard bytes[position].is(":") else { throw refusal("a dict entry needs ':' after its key") }
                position += 1
            }
        }

        var set = Value.Set()
        var member = first
        while true {
            guard set.insert(member).inserted else { throw refusal("duplicate member \(member)", at: start) }
            skipWhitespace()
            guard !atEnd else { throw incomplete("unclosed {") }
            if bytes[position].is("}") {
                position += 1
                return .set(set)
            }
            if bytes[position].is(":") { throw refusal("':' in a set; a dict is {key: value}") }
            start = position
            member = try value(depth: depth + 1)
        }
    }

    // MARK: Atoms

    /// `"text"` or `'symbol'`; escapes are `\\ \n \t \r` and the own quote.
    private mutating func quoted() throws(ReadError) -> String {
        let quote = bytes[position]
        let what = quote.is("\"") ? "string" : "symbol"
        position += 1
        var out: [UInt8] = []
        while true {
            guard !atEnd else { throw incomplete("unterminated \(what)") }
            let byte = bytes[position]
            if byte == quote {
                position += 1
                return String(decoding: out, as: UTF8.self)
            }
            guard byte.is("\\") else {
                out.append(byte)
                position += 1
                continue
            }
            guard position + 1 < bytes.count else { throw incomplete("unterminated \(what)") }
            let escaped = bytes[position + 1]
            switch escaped {
            case quote: out.append(quote)
            case UInt8(ascii: "\\"): out.append(escaped)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            default: throw refusal("unknown escape in \(what); escapes are \\\\ \\n \\t \\r and the quote")
            }
            position += 2
        }
    }

    /// A maximal run of non-delimiters: bytes, a number, nil, or a symbol.
    private mutating func token() throws(ReadError) -> Value {
        let start = position
        while !atEnd, !TextSyntax.isDelimiter(bytes[position]) { position += 1 }
        let token = bytes[start ..< position]

        if token.count >= 2, token[start].is("0"), token[start + 1].is("x") {
            return try bytestring(token)
        }
        if token[start].isDigit || (token.count >= 2 && token[start].is("-") && token[start + 1].isDigit) {
            return try number(token)
        }
        if token.elementsEqual("nil".utf8) {
            return .null
        }
        return .symbol(Symbol(String(decoding: token, as: UTF8.self)))
    }

    /// `0x` then an even count of hex digits, with `_` allowed between two digits.
    private func bytestring(_ token: ArraySlice<UInt8>) throws(ReadError) -> Value {
        var nibbles: [UInt8] = []
        for i in token.startIndex + 2 ..< token.endIndex {
            let byte = token[i]
            if byte.is("_") {
                guard token[i - 1].hexValue != nil, i + 1 < token.endIndex, token[i + 1].hexValue != nil else {
                    throw refusal("'_' goes between two hex digits", at: i)
                }
            } else if let nibble = byte.hexValue {
                nibbles.append(nibble)
            } else {
                throw refusal("not a hex digit in bytes", at: i)
            }
        }
        guard nibbles.count.isMultiple(of: 2) else {
            throw refusal("bytes need an even count of hex digits", at: token.startIndex)
        }
        return .bytes(stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] })
    }

    /// Decimal digits with `_` allowed between two digits, then the one canonical spelling.
    private func number(_ token: ArraySlice<UInt8>) throws(ReadError) -> Value {
        var digits: [UInt8] = []
        for i in token.indices {
            let byte = token[i]
            if byte.is("_") {
                guard i > token.startIndex, token[i - 1].isDigit, i + 1 < token.endIndex, token[i + 1].isDigit else {
                    throw refusal("'_' goes between two digits", at: i)
                }
            } else {
                digits.append(byte)
            }
        }
        guard Value.Integer.isCanonicalSpelling(digits) else {
            throw refusal("not a canonical integer (no leading zeros, no -0, no fractions, ends at a delimiter)",
                          at: token.startIndex)
        }
        return .integer(Value.Integer(canonicalSpelling: String(decoding: digits, as: UTF8.self)))
    }

    // MARK: Whitespace and errors

    /// Skips whitespace and `;` comments.
    private mutating func skipWhitespace() {
        while !atEnd {
            let byte = bytes[position]
            if byte.is(";") {
                while !atEnd, !bytes[position].is("\n") { position += 1 }
            } else if TextSyntax.isWhitespace(byte) {
                position += 1
            } else {
                return
            }
        }
    }

    func refusal(_ message: String, at offset: Int? = nil) -> ReadError {
        error(message, at: offset ?? position, incomplete: false)
    }

    private func incomplete(_ message: String) -> ReadError {
        error(message, at: bytes.count, incomplete: true)
    }

    private func error(_ message: String, at offset: Int, incomplete: Bool) -> ReadError {
        var line = 1, column = 1
        for byte in bytes[..<min(offset, bytes.count)] {
            if byte.is("\n") {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
        }
        return ReadError(isIncomplete: incomplete, message: message, offset: offset, line: line, column: column)
    }
}
