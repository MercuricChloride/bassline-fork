// Bridging Swift types to values.
//
// Codable isn't the foundation on purpose: its model is string-keyed
// containers plus Bool and Double, with no mark, no symbol/text or
// record/list distinction, and optionals that go silent instead of stating
// absence. Instead each type says what it means in bassline itself —
// which head its record has, which fields, whether it is marked.
//
// Conversions back are strict: a marked value is never read as its
// unmarked counterpart, since the mark changes what the value says.

/// A type that can express itself as a bassline value.
public protocol ValueRepresentable {
    var basslineValue: Value { get }
}

/// A type that can also be read back from a value.
public protocol ValueConvertible: ValueRepresentable {
    init(bassline value: Value) throws
}

/// A value didn't have the shape a Swift type needed.
public struct ValueConversionError: Error, CustomStringConvertible {
    public var expected: String
    public var found: Value

    public init(expected: String, found: Value) {
        self.expected = expected
        self.found = found
    }

    public var description: String { "expected \(expected), found \(found)" }
}

extension Value {
    public init(_ representable: some ValueRepresentable) {
        self = representable.basslineValue
    }
}

// MARK: - Bassline's own types

extension Value: ValueConvertible {
    public var basslineValue: Value { self }

    public init(bassline value: Value) {
        self = value
    }
}

extension Symbol: ValueConvertible {
    public var basslineValue: Value { .symbol(self) }

    public init(bassline value: Value) throws {
        guard !value.isMarked, let symbol = value.symbol else {
            throw ValueConversionError(expected: "a symbol", found: value)
        }
        self = symbol
    }
}

extension Value.Integer: ValueConvertible {
    public var basslineValue: Value { .integer(self) }

    public init(bassline value: Value) throws {
        guard !value.isMarked, let integer = value.integer else {
            throw ValueConversionError(expected: "an integer", found: value)
        }
        self = integer
    }
}

// MARK: - Standard library
//
// No Bool or Double: the data model leaves them to dialects. And [UInt8]
// is a list like any other array; bytes are always explicit via `.bytes(_:)`.

extension String: ValueConvertible {
    public var basslineValue: Value { .text(self) }

    public init(bassline value: Value) throws {
        guard !value.isMarked, let text = value.text else {
            throw ValueConversionError(expected: "text", found: value)
        }
        self = text
    }
}

extension ValueConvertible where Self: FixedWidthInteger {
    public var basslineValue: Value { .integer(Value.Integer(self)) }

    public init(bassline value: Value) throws {
        guard !value.isMarked, let integer = value.integer, let exact = Self(exactly: integer) else {
            throw ValueConversionError(expected: "an integer that fits \(Self.self)", found: value)
        }
        self = exact
    }
}

extension Int: ValueConvertible {}
extension Int8: ValueConvertible {}
extension Int16: ValueConvertible {}
extension Int32: ValueConvertible {}
extension Int64: ValueConvertible {}
extension Int128: ValueConvertible {}
extension UInt: ValueConvertible {}
extension UInt8: ValueConvertible {}
extension UInt16: ValueConvertible {}
extension UInt32: ValueConvertible {}
extension UInt64: ValueConvertible {}
extension UInt128: ValueConvertible {}

extension Array: ValueRepresentable where Element: ValueRepresentable {
    public var basslineValue: Value { .list(map(\.basslineValue)) }
}

extension Array: ValueConvertible where Element: ValueConvertible {
    public init(bassline value: Value) throws {
        guard !value.isMarked, let items = value.list else {
            throw ValueConversionError(expected: "a list", found: value)
        }
        self = try items.map(Element.init(bassline:))
    }
}

/// `nil` states absence (`.null`) rather than going silent.
extension Optional: ValueRepresentable where Wrapped: ValueRepresentable {
    public var basslineValue: Value { self?.basslineValue ?? .null }
}

extension Optional: ValueConvertible where Wrapped: ValueConvertible {
    public init(bassline value: Value) throws {
        self = value == .null ? nil : try Wrapped(bassline: value)
    }
}

extension Swift.Set: ValueRepresentable where Element: ValueRepresentable {
    public var basslineValue: Value { .set(Value.Set(map(\.basslineValue))) }
}

extension Swift.Set: ValueConvertible where Element: ValueConvertible {
    /// Throws if distinct members collapse under Swift's equality (for
    /// example the same text in NFC and NFD).
    public init(bassline value: Value) throws {
        guard !value.isMarked, let members = value.set else {
            throw ValueConversionError(expected: "a set", found: value)
        }
        self = Swift.Set(try members.map(Element.init(bassline:)))
        guard count == members.count else {
            throw ValueConversionError(expected: "members that stay distinct as \(Element.self)", found: value)
        }
    }
}

extension Dictionary: ValueRepresentable where Key: ValueRepresentable, Value: ValueRepresentable {
    public var basslineValue: Bassline.Value {
        .dict(Bassline.Value.Dict(map { ($0.key.basslineValue, $0.value.basslineValue) }))
    }
}

extension Dictionary: ValueConvertible where Key: ValueConvertible, Value: ValueConvertible {
    /// Throws if distinct keys collapse under Swift's equality.
    public init(bassline value: Bassline.Value) throws {
        guard !value.isMarked, let dict = value.dict else {
            throw ValueConversionError(expected: "a dict", found: value)
        }
        self = [:]
        for (key, item) in dict {
            self[try Key(bassline: key)] = try Value(bassline: item)
        }
        guard count == dict.count else {
            throw ValueConversionError(expected: "keys that stay distinct as \(Key.self)", found: value)
        }
    }
}
