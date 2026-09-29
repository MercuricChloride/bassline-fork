// Identity and canonical order.
//
// Values are ordered by their canonical encodings, compared byte by byte.
// Rather than encoding, the comparison walks the structure the same way the
// bytes would compare:
//
// - the header byte leads, so the kind tag decides first, then the mark bit;
// - scalars of one kind and mark compare shortlex on their payload (the
//   length tiers grow monotonically: inline 0–6, then 7…254, then the 0xFF
//   escape with a u32 of at least 255);
// - frames compare member by member, and since every encoding is
//   self-delimiting the first differing member decides. When one frame's
//   members are a prefix of the other's, the shorter frame sorts *after*:
//   its END byte (0xA0) is greater than every header (0x10–0x9F).
//
// Value deliberately isn't Comparable: this order puts `-1` after `9`,
// which would make `max`, ranges and `sorted()` quietly misleading.

extension Value {
    /// Three-way comparison in canonical (CE byte) order: negative when `a`
    /// sorts first, zero when equal, positive when `b` sorts first.
    public static func canonicalCompare(_ a: Value, _ b: Value) -> Int {
        let ka = a.kind.rawValue, kb = b.kind.rawValue
        if ka != kb { return ka < kb ? -1 : 1 }
        if a.isMarked != b.isMarked { return a.isMarked ? 1 : -1 }

        switch (a.content, b.content) {
        case (.null, .null):
            return 0
        case let (.integer(x), .integer(y)):
            return Integer.canonicalCompare(x, y)
        case let (.text(x), .text(y)):
            return shortlex(x.utf8, y.utf8)
        case let (.symbol(x), .symbol(y)):
            return shortlex(x.rawValue.utf8, y.rawValue.utf8)
        case let (.bytes(x), .bytes(y)):
            return shortlex(x, y)
        case let (.list(x), .list(y)):
            return compareMembers(x, y)
        case let (.record(hx, fx), .record(hy, fy)):
            let c = canonicalCompare(hx, hy)
            return c != 0 ? c : compareMembers(fx, fy)
        case let (.dict(x), .dict(y)):
            for (ex, ey) in zip(x, y) {
                let k = canonicalCompare(ex.key, ey.key)
                if k != 0 { return k }
                let v = canonicalCompare(ex.value, ey.value)
                if v != 0 { return v }
            }
            return compareCounts(x.count, y.count)
        case let (.set(x), .set(y)):
            return compareMembers(x, y)
        default:
            preconditionFailure("kinds already compared equal")
        }
    }

    /// `canonicalCompare(a, b) < 0`, for `sorted(by: Value.canonicalOrder)`.
    public static func canonicalOrder(_ a: Value, _ b: Value) -> Bool {
        canonicalCompare(a, b) < 0
    }

    private static func compareMembers(_ x: some Collection<Value>, _ y: some Collection<Value>) -> Int {
        for (a, b) in zip(x, y) {
            let c = canonicalCompare(a, b)
            if c != 0 { return c }
        }
        return compareCounts(x.count, y.count)
    }

    /// With equal leading members, more members sort first (END outranks any header).
    private static func compareCounts(_ x: Int, _ y: Int) -> Int {
        x == y ? 0 : (x > y ? -1 : 1)
    }
}

extension Value: Hashable {
    /// Canonical equality: the same encoded bytes.
    public static func == (a: Value, b: Value) -> Bool {
        a.isMarked == b.isMarked && a.kind == b.kind && canonicalCompare(a, b) == 0
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind.rawValue)
        hasher.combine(isMarked)
        switch content {
        case .null:
            break
        case .integer(let integer):
            hasher.combine(integer)
        case .text(let text):
            hashUTF8(text, into: &hasher)
        case .symbol(let symbol):
            hasher.combine(symbol)
        case .bytes(let bytes):
            hasher.combine(bytes)
        case .list(let items):
            hasher.combine(items)
        case .record(let head, let fields):
            hasher.combine(head)
            hasher.combine(fields)
        case .dict(let dict):
            hasher.combine(dict)
        case .set(let set):
            hasher.combine(set)
        }
    }
}

/// Shortlex: shorter first, then byte by byte.
func shortlex(_ a: some Collection<UInt8>, _ b: some Collection<UInt8>) -> Int {
    let ca = a.count, cb = b.count
    if ca != cb { return ca < cb ? -1 : 1 }
    for (x, y) in zip(a, b) where x != y {
        return x < y ? -1 : 1
    }
    return 0
}

/// Hashes a string's UTF-8 bytes (Swift's own String hash is normalization-insensitive).
func hashUTF8(_ string: String, into hasher: inout Hasher) {
    let utf8 = string.utf8
    hasher.combine(utf8.count)
    let hashed: Void? = utf8.withContiguousStorageIfAvailable { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    if hashed == nil {
        for byte in utf8 { hasher.combine(byte) }
    }
}
