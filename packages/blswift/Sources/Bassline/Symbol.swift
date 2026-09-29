/// A name. Like text, but an identifier rather than a sequence of characters.
///
/// Symbols compare by their UTF-8 bytes, not by Swift string equality.
public struct Symbol: RawRepresentable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ name: String) {
        self.rawValue = name
    }
}

extension Symbol: ExpressibleByStringLiteral {
    public init(stringLiteral name: String) {
        self.rawValue = name
    }
}

extension Symbol: Hashable {
    public static func == (a: Symbol, b: Symbol) -> Bool {
        a.rawValue.utf8.elementsEqual(b.rawValue.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hashUTF8(rawValue, into: &hasher)
    }
}

extension Symbol: CustomStringConvertible {
    public var description: String { rawValue }
}
