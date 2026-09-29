// The canonical binary encoding.
//
// Every value starts with one header byte: | tag (4) | mark (1) | length (3) |.
// Scalars state their payload length; frames list their members and close
// with END (0xA0). A Value is canonical by construction (dicts and sets are
// kept sorted, integers are validated), so encoding is a single walk.

enum Wire {
    static let end: UInt8 = 0xA0
    static let markBit: UInt8 = 0x08
    static let lengthBits: UInt8 = 0x07
    /// Length byte that escapes to a four-byte length.
    static let largeEscape: UInt8 = 0xFF
}

extension Value {
    /// The canonical encoding: the bytes that are this value's identity.
    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        encode(into: &out)
        return out
    }

    /// Appends the canonical encoding to `out`. Values written back to back
    /// form a stream that ``StreamDecoder`` reads one at a time.
    ///
    /// This does not enforce a depth limit; a receiver may refuse values
    /// nested deeper than its own limit (64 by default here and in blnim).
    public func encode(into out: inout [UInt8]) {
        let header = kind.rawValue << 4 | (isMarked ? Wire.markBit : 0)
        switch content {
        case .null:
            out.append(header)
        case .integer(let integer):
            if case .big(let spelling) = integer {
                precondition(Integer.isCanonicalSpelling(spelling.utf8), "non-canonical integer spelling: \(spelling)")
            }
            Self.appendScalar(header, integer.spelling.utf8, to: &out)
        case .text(let text):
            Self.appendScalar(header, text.utf8, to: &out)
        case .symbol(let symbol):
            Self.appendScalar(header, symbol.rawValue.utf8, to: &out)
        case .bytes(let bytes):
            Self.appendScalar(header, bytes, to: &out)
        case .list(let items):
            out.append(header)
            for item in items { item.encode(into: &out) }
            out.append(Wire.end)
        case .record(let head, let fields):
            out.append(header)
            head.encode(into: &out)
            for field in fields { field.encode(into: &out) }
            out.append(Wire.end)
        case .dict(let dict):
            out.append(header)
            for (key, value) in dict {
                key.encode(into: &out)
                value.encode(into: &out)
            }
            out.append(Wire.end)
        case .set(let set):
            out.append(header)
            for member in set { member.encode(into: &out) }
            out.append(Wire.end)
        }
    }

    /// Header, length in the smallest form that fits, then the payload.
    private static func appendScalar(_ header: UInt8, _ payload: some Collection<UInt8>, to out: inout [UInt8]) {
        let length = payload.count
        precondition(length <= Int(UInt32.max), "scalar payload over 4 GiB can't be encoded")
        if length < 7 {
            out.append(header | UInt8(length))
        } else if length < 255 {
            out.append(header | Wire.lengthBits)
            out.append(UInt8(length))
        } else {
            out.append(header | Wire.lengthBits)
            out.append(Wire.largeEscape)
            let n = UInt32(length)
            out.append(contentsOf: [UInt8(n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                                    UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
        }
        out.append(contentsOf: payload)
    }
}
