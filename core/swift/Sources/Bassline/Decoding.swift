// Decoding the canonical encoding.
//
// The decoder distinguishes two outcomes that must never be confused:
// bytes that break a rule are *refused* (a thrown DecodeError), while bytes
// that are only a proper prefix of a value are *starved*: nothing is
// refused, nothing lands, and the decoder waits for more (`next()` → nil).
//
// It is a resumable state machine with an explicit stack of open frames, so
// feeding it one byte at a time costs no more than feeding it everything at
// once, and deep nesting can't overflow the call stack. Checks happen as
// early as the bytes allow, and the first fault in stream order is the one
// reported.

/// The line drawn at a boundary. The decoder refuses values past it, the
/// encoder refuses to produce them, and the text reader refuses text nested
/// past `maxDepth`, so peers that agree on limits never produce what the
/// other refuses.
public struct Limits: Sendable, Hashable {
    /// Frames open at once. The spec asks every decoder to have one.
    public var maxDepth: Int
    /// Largest encoded value. CE can express scalars up to ~4 GiB; a
    /// receiver draws its own line at its boundary.
    public var maxValueBytes: Int

    public init(maxDepth: Int = 64, maxValueBytes: Int = 100 * 1024 * 1024) {
        self.maxDepth = maxDepth
        self.maxValueBytes = maxValueBytes
    }

    public static var `default`: Limits { Limits() }

    /// One-shot decoding already holds all of its input in memory.
    func admitting(_ byteCount: Int) -> Limits {
        var limits = self
        limits.maxValueBytes = max(maxValueBytes, byteCount)
        return limits
    }
}

/// Why bytes were refused, and where.
public struct DecodeError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Raw values are the reason names the shared corpus uses.
    public enum Reason: String, Sendable, CaseIterable {
        case invalidTag = "invalid-tag"
        case endWithBits = "end-with-bits"
        case endAtTop = "end-at-top"
        case lengthBits = "length-bits"
        case nonMinimalLength = "non-minimal-length"
        case badInteger = "bad-integer"
        case badUTF8 = "bad-utf8"
        case emptyRecord = "empty-record"
        case strandedKey = "stranded-key"
        case outOfOrder = "out-of-order"
        case duplicate = "duplicate"
        case tooDeep = "too-deep"
        case tooLarge = "too-large"
        /// Input ended partway through a value.
        case truncated = "truncated"
        /// One value was asked for, and more followed it.
        case trailingBytes = "trailing-bytes"
    }

    public var reason: Reason
    /// Stream offset of the byte the fault was found at: the header of the
    /// offending value, or the END byte for `stranded-key` and `empty-record`.
    public var offset: Int

    public init(_ reason: Reason, at offset: Int) {
        self.reason = reason
        self.offset = offset
    }

    public var description: String { "\(reason.rawValue) at byte \(offset)" }
}

/// Decodes a stream of back-to-back canonically encoded values, however the
/// bytes happen to arrive.
///
/// ```swift
/// var decoder = StreamDecoder()
/// decoder.append(contentsOf: chunk)
/// while let value = try decoder.next() { handle(value) }
/// ```
///
/// Once it throws, the decoder stays failed and rethrows the same error: the
/// encoding has no framing to resynchronise on.
public struct StreamDecoder: Sendable {
    public let limits: Limits

    private var buffer: [UInt8] = []
    /// Index in `buffer` of the first byte not yet part of a landed value or open frame.
    private var position = 0
    /// Stream offset of `buffer[0]`; grows as consumed bytes are dropped.
    private var base = 0
    private var stack: [OpenFrame] = []
    private var failure: DecodeError?

    public init(limits: Limits = .default) {
        self.limits = limits
    }

    /// Stream offset of the next byte that hasn't been decoded yet.
    public var offset: Int { base + position }

    /// Whether some bytes have arrived that don't yet form a whole value.
    public var isPending: Bool { !stack.isEmpty || position < buffer.count }

    public mutating func append(_ byte: UInt8) {
        compact()
        buffer.append(byte)
    }

    public mutating func append(contentsOf bytes: some Sequence<UInt8>) {
        compact()
        buffer.append(contentsOf: bytes)
    }

    public mutating func append(contentsOf bytes: Span<UInt8>) {
        compact()
        buffer.reserveCapacity(buffer.count + bytes.count)
        for i in bytes.indices { buffer.append(bytes[i]) }
    }

    /// The next whole value, or `nil` when more bytes are needed first.
    public mutating func next() throws(DecodeError) -> Value? {
        if let failure { throw failure }
        do {
            return try advance()
        } catch {
            failure = error
            throw error
        }
    }

    /// Declares the end of input: throws `truncated` if a value was left unfinished.
    public func finish() throws(DecodeError) {
        if let failure { throw failure }
        if isPending { throw DecodeError(.truncated, at: base + buffer.count) }
    }

    // MARK: State machine

    private struct OpenFrame: Sendable {
        let kind: Value.Kind
        let marked: Bool
        /// Index of the frame's header in `buffer`.
        let start: Int
        var members: [Value] = []
        var entries: [(key: Value, value: Value)] = []
        /// A dict key still waiting for its value.
        var pendingKey: Value?
        /// Bytes of the previous set member or dict key, for the ordering check.
        var previous: Range<Int>?
    }

    private mutating func advance() throws(DecodeError) -> Value? {
        while position < buffer.count {
            let start = position
            let header = buffer[start]
            let value: Value
            var extent = start ..< start

            if header >> 4 == 0xA {
                // END carries no mark and no length, and closes an open frame
                guard header == Wire.end else { throw fault(.endWithBits, at: start) }
                guard !stack.isEmpty else { throw fault(.endAtTop, at: start) }
                try checkSize(end: start + 1, at: start)
                let frame = stack.removeLast()
                position = start + 1
                value = try close(frame, endAt: start)
                extent = frame.start ..< position
            } else {
                guard let kind = Value.Kind(rawValue: header >> 4) else { throw fault(.invalidTag, at: start) }
                let marked = header & Wire.markBit != 0
                let lengthBits = Int(header & Wire.lengthBits)

                if kind == .null || kind.isFrame {
                    guard lengthBits == 0 else { throw fault(.lengthBits, at: start) }
                    try checkSize(end: start + 1, at: start)
                    position = start + 1
                    if kind.isFrame {
                        guard stack.count < limits.maxDepth else { throw fault(.tooDeep, at: start) }
                        stack.append(OpenFrame(kind: kind, marked: marked, start: start))
                        continue
                    }
                    value = Value(.null, marked: marked)
                } else {
                    guard let length = try scalarLength(at: start, lengthBits: lengthBits) else { return nil }
                    let end = start + length.header + length.payload
                    try checkSize(end: end, at: start)
                    guard end <= buffer.count else { return nil }
                    value = try scalar(kind, marked: marked, payload: start + length.header ..< end, at: start)
                    position = end
                }
                extent = start ..< position
            }

            if stack.isEmpty { return value }
            try attach(value, extent: extent)
        }
        return nil
    }

    /// Header and payload lengths, or `nil` while length bytes are still missing.
    private func scalarLength(at start: Int, lengthBits: Int) throws(DecodeError) -> (header: Int, payload: Int)? {
        if lengthBits < 7 { return (1, lengthBits) }
        guard start + 2 <= buffer.count else { return nil }
        let medium = buffer[start + 1]
        if medium < 7 { throw fault(.nonMinimalLength, at: start) }
        if medium != Wire.largeEscape { return (2, Int(medium)) }
        guard start + 6 <= buffer.count else { return nil }
        var large = 0
        for i in start + 2 ..< start + 6 { large = large << 8 | Int(buffer[i]) }
        if large < 255 { throw fault(.nonMinimalLength, at: start) }
        return (6, large)
    }

    /// Refuses a value whose encoding would reach past the size limit. It is
    /// judged from headers alone, so the verdict doesn't depend on chunking.
    private func checkSize(end: Int, at start: Int) throws(DecodeError) {
        let origin = stack.first?.start ?? start
        if end - origin > limits.maxValueBytes { throw fault(.tooLarge, at: start) }
    }

    private func scalar(_ kind: Value.Kind, marked: Bool, payload: Range<Int>, at start: Int) throws(DecodeError) -> Value {
        let content: Value.Content
        switch kind {
        case .integer:
            let digits = buffer[payload]
            guard Value.Integer.isCanonicalSpelling(digits) else { throw fault(.badInteger, at: start) }
            content = .integer(Value.Integer(canonicalSpelling: String(decoding: digits, as: UTF8.self)))
        case .text:
            content = .text(try text(payload, at: start))
        case .symbol:
            content = .symbol(Symbol(try text(payload, at: start)))
        case .bytes:
            content = .bytes(Array(buffer[payload]))
        default:
            preconditionFailure("\(kind) is not a scalar kind")
        }
        return Value(content, marked: marked)
    }

    /// Well-formed UTF-8, exactly as sent (no normalization, no repair).
    private func text(_ payload: Range<Int>, at start: Int) throws(DecodeError) -> String {
        do {
            return String(copying: try UTF8Span(validating: buffer.span.extracting(payload)))
        } catch {
            throw fault(.badUTF8, at: start)
        }
    }

    private func close(_ frame: OpenFrame, endAt end: Int) throws(DecodeError) -> Value {
        let content: Value.Content
        switch frame.kind {
        case .list:
            content = .list(frame.members)
        case .record:
            guard let head = frame.members.first else { throw fault(.emptyRecord, at: end) }
            content = .record(head: head, fields: Array(frame.members.dropFirst()))
        case .dict:
            guard frame.pendingKey == nil else { throw fault(.strandedKey, at: end) }
            content = .dict(Value.Dict(uncheckedSorted: frame.entries))
        case .set:
            content = .set(Value.Set(uncheckedSorted: frame.members))
        default:
            preconditionFailure("\(frame.kind) is not a frame kind")
        }
        return Value(content, marked: frame.marked)
    }

    private mutating func attach(_ value: Value, extent: Range<Int>) throws(DecodeError) {
        let top = stack.count - 1
        switch stack[top].kind {
        case .set:
            try checkOrder(after: stack[top].previous, extent)
            stack[top].previous = extent
            stack[top].members.append(value)
        case .dict:
            if let key = stack[top].pendingKey {
                stack[top].entries.append((key, value))
                stack[top].pendingKey = nil
            } else {
                try checkOrder(after: stack[top].previous, extent)
                stack[top].previous = extent
                stack[top].pendingKey = value
            }
        default:
            stack[top].members.append(value)
        }
    }

    /// Set members and dict keys must strictly ascend in CE byte order,
    /// which is checked on the bytes as they arrived.
    private func checkOrder(after previous: Range<Int>?, _ current: Range<Int>) throws(DecodeError) {
        guard let previous else { return }
        let a = buffer[previous], b = buffer[current]
        var order = a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
        for (x, y) in zip(a, b) where x != y {
            order = x < y ? -1 : 1
            break
        }
        if order == 0 { throw fault(.duplicate, at: current.lowerBound) }
        if order > 0 { throw fault(.outOfOrder, at: current.lowerBound) }
    }

    private func fault(_ reason: DecodeError.Reason, at index: Int) -> DecodeError {
        DecodeError(reason, at: base + index)
    }

    /// Drops consumed bytes once they are at least half the buffer, and only
    /// between values, so frame offsets never move.
    private mutating func compact() {
        guard stack.isEmpty, position > 0, position * 2 >= buffer.count else { return }
        buffer.removeFirst(position)
        base += position
        position = 0
    }
}

// MARK: - One-shot decoding

extension Value {
    /// Decodes exactly one value from `bytes`.
    public init(decoding bytes: some Collection<UInt8>, limits: Limits = .default) throws(DecodeError) {
        var decoder = StreamDecoder(limits: limits.admitting(bytes.count))
        decoder.append(contentsOf: bytes)
        guard let value = try decoder.next() else {
            try decoder.finish()
            throw DecodeError(.truncated, at: 0)
        }
        // a fault in what follows outranks there merely being more
        let end = decoder.offset
        var more = false
        while try decoder.next() != nil { more = true }
        try decoder.finish()
        if more { throw DecodeError(.trailingBytes, at: end) }
        self = value
    }

    /// Decodes every value in `bytes`, which must end on a value boundary.
    public static func decodeAll(_ bytes: some Collection<UInt8>, limits: Limits = .default) throws(DecodeError) -> [Value] {
        var decoder = StreamDecoder(limits: limits.admitting(bytes.count))
        decoder.append(contentsOf: bytes)
        var values: [Value] = []
        while let value = try decoder.next() { values.append(value) }
        try decoder.finish()
        return values
    }
}
