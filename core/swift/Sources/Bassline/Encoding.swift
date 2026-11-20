// The canonical binary encoding.
//
// Every value starts with one header byte: | tag (4) | mark (1) | length (3) |.
// Scalars state their payload length; frames list their members and close
// with END (0xA0). A Value is canonical by construction (dicts and sets are
// kept sorted, integers are validated), so encoding is a single walk.
//
// The encoder holds itself to the same Limits as the decoder: it refuses to
// produce any value that a decoder with those limits would refuse.

enum Wire {
    static let end: UInt8 = 0xA0
    static let markBit: UInt8 = 0x08
    static let lengthBits: UInt8 = 0x07
    /// Length byte that escapes to a four-byte length.
    static let largeEscape: UInt8 = 0xFF
}

/// Why a value couldn't be encoded.
public struct EncodeError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Reason: String, Sendable, CaseIterable {
        /// Frames nested past `Limits.maxDepth`.
        case tooDeep = "too-deep"
        /// An encoding longer than `Limits.maxValueBytes`, or a scalar past the 4 GiB format ceiling.
        case tooLarge = "too-large"
    }

    public var reason: Reason

    public init(_ reason: Reason) {
        self.reason = reason
    }

    public var description: String { reason.rawValue }
}

extension Value {
    /// The canonical encoding: the bytes that are this value's identity.
    public func encoded(limits: Limits = .default) throws(EncodeError) -> [UInt8] {
        var out: [UInt8] = []
        try encode(into: &out, limits: limits)
        return out
    }

    /// Appends the canonical encoding to `out`. Values written back to back
    /// form a stream that ``StreamDecoder`` reads one at a time.
    ///
    /// Throws, leaving `out` as it was, for a value a decoder with the same
    /// `limits` would refuse.
    public func encode(into out: inout [UInt8], limits: Limits = .default) throws(EncodeError) {
        let writer = CanonicalWriter(limits: limits, start: out.count)
        do {
            try writer.write(self, into: &out, depth: 0)
        } catch {
            out.removeSubrange(writer.start...)
            throw error
        }
    }
}

private struct CanonicalWriter {
    let limits: Limits
    /// Where this value's encoding began in the output.
    let start: Int

    func write(_ value: Value, into out: inout [UInt8], depth: Int) throws(EncodeError) {
        let header = value.kind.rawValue << 4 | (value.isMarked ? Wire.markBit : 0)
        switch value.content {
        case .null:
            try reserve(1, in: out)
            out.append(header)
        case .integer(let integer):
            if case .big(let spelling) = integer {
                precondition(Value.Integer.isCanonicalSpelling(spelling.utf8), "non-canonical integer spelling: \(spelling)")
            }
            try scalar(header, integer.spelling.utf8, into: &out)
        case .text(let text):
            try scalar(header, text.utf8, into: &out)
        case .symbol(let symbol):
            try scalar(header, symbol.rawValue.utf8, into: &out)
        case .bytes(let bytes):
            try scalar(header, bytes, into: &out)
        case .list(let items):
            try open(header, depth: depth, into: &out)
            for item in items { try write(item, into: &out, depth: depth + 1) }
            try close(into: &out)
        case .record(let head, let fields):
            try open(header, depth: depth, into: &out)
            try write(head, into: &out, depth: depth + 1)
            for field in fields { try write(field, into: &out, depth: depth + 1) }
            try close(into: &out)
        case .dict(let dict):
            try open(header, depth: depth, into: &out)
            for (key, item) in dict {
                try write(key, into: &out, depth: depth + 1)
                try write(item, into: &out, depth: depth + 1)
            }
            try close(into: &out)
        case .set(let set):
            try open(header, depth: depth, into: &out)
            for member in set { try write(member, into: &out, depth: depth + 1) }
            try close(into: &out)
        }
    }

    /// `depth` counts the frames around this one, as the decoder's stack
    /// does, and the checks run in the decoder's order: size, then depth.
    private func open(_ header: UInt8, depth: Int, into out: inout [UInt8]) throws(EncodeError) {
        try reserve(1, in: out)
        guard depth < limits.maxDepth else { throw EncodeError(.tooDeep) }
        out.append(header)
    }

    private func close(into out: inout [UInt8]) throws(EncodeError) {
        try reserve(1, in: out)
        out.append(Wire.end)
    }

    /// Header, length in the smallest form that fits, then the payload.
    private func scalar(_ header: UInt8, _ payload: some Collection<UInt8>, into out: inout [UInt8]) throws(EncodeError) {
        let length = payload.count
        guard length <= Int(UInt32.max) else { throw EncodeError(.tooLarge) }
        let headerLength = length < 7 ? 1 : length < 255 ? 2 : 6
        try reserve(headerLength + length, in: out)

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

    /// The decoder's size rule, applied before writing: the value's whole
    /// encoding may not pass `maxValueBytes`.
    private func reserve(_ count: Int, in out: [UInt8]) throws(EncodeError) {
        if out.count - start + count > limits.maxValueBytes { throw EncodeError(.tooLarge) }
    }
}
