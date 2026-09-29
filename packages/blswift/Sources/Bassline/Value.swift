/// A bassline value: an atom or a frame, either of which may carry a mark.
///
/// Identity is the canonical encoding (CE): two values are equal exactly when
/// they encode to the same bytes. Text and symbols compare by their UTF-8
/// bytes, so strings Swift considers equal (`"\u{e9}"` and `"e\u{301}"`) are
/// distinct values here, as the data model asks for no normalization.
///
/// Silence and stated absence are different things: a missing `Value?`
/// (`nil`) says nothing, while ``Value/null`` states that something is absent.
public struct Value: Sendable {
    public var content: Content
    /// The mark shifts a value from "something" to "something to do".
    public var isMarked: Bool

    public init(_ content: Content, marked: Bool = false) {
        self.content = content
        self.isMarked = marked
    }
}

extension Value {
    /// The closed set of kinds. There is deliberately no boolean and no
    /// non-integer number: those are vocabulary, and belong to dialects.
    public enum Content: Sendable {
        case null
        case integer(Integer)
        case text(String)
        case symbol(Symbol)
        case bytes([UInt8])
        case list([Value])
        /// A record always has a head; the fields say something about it.
        indirect case record(head: Value, fields: [Value])
        case dict(Dict)
        case set(Set)
    }

    /// A value's kind, whose raw value is its tag in the canonical encoding.
    public enum Kind: UInt8, Sendable, CaseIterable {
        case null = 0x1, integer, text, symbol, bytes, list, record, dict, set

        public var isFrame: Bool { rawValue >= Kind.list.rawValue }
    }

    public var kind: Kind {
        switch content {
        case .null: .null
        case .integer: .integer
        case .text: .text
        case .symbol: .symbol
        case .bytes: .bytes
        case .list: .list
        case .record: .record
        case .dict: .dict
        case .set: .set
        }
    }

    /// This value with its mark set.
    public var marked: Value {
        var copy = self
        copy.isMarked = true
        return copy
    }

    /// This value with its mark cleared.
    public var unmarked: Value {
        var copy = self
        copy.isMarked = false
        return copy
    }
}

// MARK: - Construction

extension Value {
    /// Stated absence.
    public static let null = Value(.null)

    public static func integer(_ integer: Integer) -> Value {
        Value(.integer(integer))
    }

    public static func integer(_ integer: some BinaryInteger) -> Value {
        Value(.integer(Integer(integer)))
    }

    public static func text(_ text: String) -> Value {
        Value(.text(text))
    }

    public static func symbol(_ symbol: Symbol) -> Value {
        Value(.symbol(symbol))
    }

    public static func bytes(_ bytes: some Sequence<UInt8>) -> Value {
        Value(.bytes(Array(bytes)))
    }

    public static func list(_ items: [Value]) -> Value {
        Value(.list(items))
    }

    public static func list(_ items: Value...) -> Value {
        Value(.list(items))
    }

    /// `.record("point", 1, 2)` is `(point 1 2)`.
    public static func record(_ head: Symbol, _ fields: Value...) -> Value {
        Value(.record(head: .symbol(head), fields: fields))
    }

    public static func record(head: Value, fields: [Value] = []) -> Value {
        Value(.record(head: head, fields: fields))
    }

    public static func dict(_ dict: Dict) -> Value {
        Value(.dict(dict))
    }

    public static func set(_ set: Set) -> Value {
        Value(.set(set))
    }
}

// MARK: - Projections

extension Value {
    public var isNull: Bool {
        if case .null = content { true } else { false }
    }

    public var integer: Integer? {
        if case .integer(let integer) = content { integer } else { nil }
    }

    public var text: String? {
        if case .text(let text) = content { text } else { nil }
    }

    public var symbol: Symbol? {
        if case .symbol(let symbol) = content { symbol } else { nil }
    }

    public var bytes: [UInt8]? {
        if case .bytes(let bytes) = content { bytes } else { nil }
    }

    public var list: [Value]? {
        if case .list(let items) = content { items } else { nil }
    }

    /// The head of a record.
    public var head: Value? {
        if case .record(let head, _) = content { head } else { nil }
    }

    /// The fields of a record.
    public var fields: [Value]? {
        if case .record(_, let fields) = content { fields } else { nil }
    }

    public var dict: Dict? {
        if case .dict(let dict) = content { dict } else { nil }
    }

    public var set: Set? {
        if case .set(let set) = content { set } else { nil }
    }
}

// MARK: - Literals
//
// No boolean, float or nil literals: the data model leaves those out on
// purpose, so `let v: Value = true` or `1.5` does not compile.

extension Value: ExpressibleByIntegerLiteral {
    /// Any size of literal works: `123456789012345678901234567890` is fine.
    public init(integerLiteral literal: StaticBigInt) {
        self.init(.integer(Integer(integerLiteral: literal)))
    }
}

extension Value: ExpressibleByStringLiteral {
    /// A string literal is text. Use ``Symbol`` (or `.symbol("name")`) for names.
    public init(stringLiteral text: String) {
        self.init(.text(text))
    }
}

extension Value: ExpressibleByArrayLiteral {
    public init(arrayLiteral items: Value...) {
        self.init(.list(items))
    }
}

extension Value: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral entries: (Value, Value)...) {
        self.init(.dict(Dict(literalEntries: entries)))
    }
}
