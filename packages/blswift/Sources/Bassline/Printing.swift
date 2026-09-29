// Printing values in the textual syntax, on one line.
//
// Strings are walked by Unicode scalar, never by Character: "\r\n" is a
// single Character, and so is a quote followed by a combining accent, and
// matching on Characters would miss both.

extension Value: CustomStringConvertible {
    /// The value in textual syntax; `Value(reading: v.description) == v`.
    public var description: String {
        var out = ""
        write(to: &out)
        return out
    }

    func write(to out: inout String) {
        // frames are marked in front, atoms behind
        if isMarked && kind.isFrame { out += "!" }
        switch content {
        case .null:
            out += "nil"
        case .integer(let integer):
            out += integer.spelling
        case .text(let text):
            Self.quote(text, with: "\"", into: &out)
        case .symbol(let symbol):
            if Self.isBareSpelling(symbol.rawValue) {
                out += symbol.rawValue
            } else {
                Self.quote(symbol.rawValue, with: "'", into: &out)
            }
        case .bytes(let bytes):
            out += "0x"
            for byte in bytes {
                out.unicodeScalars.append(Self.hexDigits[Int(byte >> 4)])
                out.unicodeScalars.append(Self.hexDigits[Int(byte & 0xF)])
            }
        case .list(let items):
            out += "["
            Self.write(items, to: &out)
            out += "]"
        case .record(let head, let fields):
            out += "("
            head.write(to: &out)
            if !fields.isEmpty { out += " " }
            Self.write(fields, to: &out)
            out += ")"
        case .dict(let dict):
            if dict.isEmpty {
                out += "{:}"
            } else {
                out += "{"
                for (i, (key, value)) in dict.enumerated() {
                    if i > 0 { out += " " }
                    key.write(to: &out)
                    out += ": "
                    value.write(to: &out)
                }
                out += "}"
            }
        case .set(let set):
            out += "{"
            Self.write(set, to: &out)
            out += "}"
        }
        if isMarked && !kind.isFrame { out += "!" }
    }

    private static let hexDigits: [Unicode.Scalar] = Array("0123456789abcdef".unicodeScalars)

    private static func write(_ values: some Sequence<Value>, to out: inout String) {
        var first = true
        for value in values {
            if !first { out += " " }
            value.write(to: &out)
            first = false
        }
    }

    private static func quote(_ string: String, with quote: Unicode.Scalar, into out: inout String) {
        out.unicodeScalars.append(quote)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case quote:
                out += "\\"
                out.unicodeScalars.append(quote)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out.unicodeScalars.append(quote)
    }

    /// Whether a symbol reads back as itself without quotes: not empty, not
    /// `nil`, not number-like, and free of delimiters and control characters.
    static func isBareSpelling(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard let first = scalars.first, !name.utf8.elementsEqual("nil".utf8) else { return false }
        if ("0" ... "9").contains(first) { return false }
        if first == "-", let second = scalars.dropFirst().first, ("0" ... "9").contains(second) { return false }
        return scalars.allSatisfy { scalar in
            !(scalar.isASCII && TextSyntax.isDelimiter(UInt8(scalar.value)))
                && scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }
}

extension Value.Dict: CustomStringConvertible {
    public var description: String { Value(.dict(self)).description }
}

extension Value.Set: CustomStringConvertible {
    public var description: String { Value(.set(self)).description }
}
