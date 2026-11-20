extension Value {
    /// An arbitrary-precision signed integer.
    ///
    /// Held as an `Int64` whenever it fits, and otherwise as its canonical
    /// decimal spelling. Everything in this library produces the `.int` form
    /// for in-range values; a hand-built `.big` must be canonical (no sign
    /// but `-`, no leading zeros, no `-0`).
    public enum Integer: Sendable {
        case int(Int64)
        /// The canonical decimal spelling of an integer outside `Int64`.
        case big(String)
    }
}

extension Value.Integer {
    public init(_ source: some BinaryInteger) {
        if let n = Int64(exactly: source) {
            self = .int(n)
        } else {
            self = .big(String(source))
        }
    }

    /// Reads a canonical decimal spelling, refusing anything else
    /// (`+5`, `-0`, `007`, non-ASCII digits, whitespace).
    public init?(spelling: some StringProtocol) {
        guard Self.isCanonicalSpelling(spelling.utf8) else { return nil }
        self.init(canonicalSpelling: String(spelling))
    }

    init(canonicalSpelling spelling: String) {
        if let n = Int64(spelling) {
            self = .int(n)
        } else {
            self = .big(spelling)
        }
    }

    /// The one spelling this integer has anywhere in the system.
    public var spelling: String {
        switch self {
        case .int(let n): String(n)
        case .big(let s): s
        }
    }

    /// `.int` whenever the value fits, whatever form it was built in.
    var normalized: Value.Integer {
        if case .big(let s) = self, let n = Int64(s) { return .int(n) }
        return self
    }

    /// Whether `bytes` is `0`, or an optional `-` then digits with no leading zero.
    static func isCanonicalSpelling(_ bytes: some Collection<UInt8>) -> Bool {
        var i = bytes.startIndex
        guard i != bytes.endIndex else { return false }
        if bytes[i] == UInt8(ascii: "-") {
            i = bytes.index(after: i)
            guard i != bytes.endIndex, bytes[i] != UInt8(ascii: "0") else { return false }
        } else if bytes[i] == UInt8(ascii: "0") {
            return bytes.index(after: i) == bytes.endIndex
        }
        return bytes[i...].allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }

    /// Length of the decimal spelling of `n`, without formatting it.
    static func spellingLength(_ n: Int64) -> Int {
        var magnitude = n.magnitude
        var length = n < 0 ? 2 : 1
        while magnitude >= 10 {
            magnitude /= 10
            length += 1
        }
        return length
    }

    /// Order of the canonical encodings: shortlex over the spellings, so
    /// `1 < 9 < -1 < 10`. This is identity order, not numeric order.
    static func canonicalCompare(_ a: Value.Integer, _ b: Value.Integer) -> Int {
        switch (a.normalized, b.normalized) {
        case let (.int(x), .int(y)):
            let lx = spellingLength(x), ly = spellingLength(y)
            if lx != ly { return lx < ly ? -1 : 1 }
            if (x < 0) != (y < 0) { return x < 0 ? -1 : 1 }
            return x.magnitude == y.magnitude ? 0 : (x.magnitude < y.magnitude ? -1 : 1)
        case let (x, y):
            return shortlex(x.spelling.utf8, y.spelling.utf8)
        }
    }
}

extension Value.Integer: Hashable {
    public static func == (a: Value.Integer, b: Value.Integer) -> Bool {
        switch (a.normalized, b.normalized) {
        case let (.int(x), .int(y)): x == y
        case let (.big(x), .big(y)): x.utf8.elementsEqual(y.utf8)
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch normalized {
        case .int(let n): hasher.combine(n)
        case .big(let s): hashUTF8(s, into: &hasher)
        }
    }
}

extension Value.Integer: Comparable {
    /// Numeric order (unlike the canonical order of values).
    public static func < (a: Value.Integer, b: Value.Integer) -> Bool {
        switch (a.normalized, b.normalized) {
        case let (.int(x), .int(y)):
            return x < y
        case let (.big(x), .int):
            return x.hasPrefix("-")
        case let (.int, .big(y)):
            return !y.hasPrefix("-")
        case let (.big(x), .big(y)):
            let nx = x.hasPrefix("-"), ny = y.hasPrefix("-")
            if nx != ny { return nx }
            let c = shortlex(x.utf8, y.utf8)
            return nx ? c > 0 : c < 0
        }
    }
}

extension Value.Integer: LosslessStringConvertible {
    public init?(_ description: String) {
        self.init(spelling: description)
    }

    public var description: String { spelling }
}

extension Value.Integer: ExpressibleByIntegerLiteral {
    /// Literals of any size: past `Int64` the literal's words are spelled out.
    public init(integerLiteral literal: StaticBigInt) {
        if literal.bitWidth <= 64 {
            var bits: UInt64 = 0
            for i in 0 ..< 64 / UInt.bitWidth {
                bits |= UInt64(truncatingIfNeeded: literal[i]) << UInt64(i * UInt.bitWidth)
            }
            self = .int(Int64(bitPattern: bits))
        } else {
            self = .big(Self.decimalSpelling(literal))
        }
    }

    private static func decimalSpelling(_ literal: StaticBigInt) -> String {
        let negative = literal.signum() < 0
        let count = (literal.bitWidth + UInt.bitWidth - 1) / UInt.bitWidth
        var words = (0 ..< count).map { literal[$0] }
        if negative {
            // two's complement → magnitude
            var carry = true
            for i in words.indices {
                words[i] = ~words[i]
                if carry { (words[i], carry) = words[i].addingReportingOverflow(1) }
            }
        }
        // peel off base-1e9 chunks, least significant first
        let chunk: UInt = 1_000_000_000
        var chunks: [UInt] = []
        while words.contains(where: { $0 != 0 }) {
            var remainder: UInt = 0
            for i in words.indices.reversed() {
                (words[i], remainder) = chunk.dividingFullWidth((high: remainder, low: words[i]))
            }
            chunks.append(remainder)
        }
        var spelling = negative ? "-" : ""
        spelling += String(chunks.last ?? 0)
        for part in chunks.dropLast().reversed() {
            let digits = String(part)
            spelling += String(repeating: "0", count: 9 - digits.count) + digits
        }
        return spelling
    }
}

extension FixedWidthInteger {
    /// The integer as `Self`, or `nil` when it doesn't fit.
    public init?(exactly integer: Value.Integer) {
        switch integer.normalized {
        case .int(let n): self.init(exactly: n)
        case .big(let s): self.init(s, radix: 10)
        }
    }
}
