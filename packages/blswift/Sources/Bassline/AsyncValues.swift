extension AsyncSequence where Element == UInt8 {
    /// The values in a byte stream, decoded as the bytes arrive.
    ///
    /// ```swift
    /// for try await value in url.resourceBytes.basslineValues() { … }
    /// ```
    public func basslineValues(limits: DecodingLimits = .default) -> AsyncBasslineValues<Self> {
        AsyncBasslineValues(base: self, limits: limits)
    }
}

/// Values decoded from an asynchronous byte stream. Throws the stream's own
/// errors, a ``DecodeError`` for refused bytes, or `truncated` if the stream
/// ends partway through a value.
public struct AsyncBasslineValues<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = Value
    public typealias Failure = any Error

    let base: Base
    let limits: DecodingLimits

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), decoder: StreamDecoder(limits: limits))
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var decoder: StreamDecoder
        var finished = false

        public mutating func next(isolation actor: isolated (any Actor)?) async throws(any Error) -> Value? {
            guard !finished else { return nil }
            while true {
                if let value = try decoder.next() { return value }
                guard let byte = try await base.next(isolation: actor) else {
                    finished = true
                    try decoder.finish()
                    return nil
                }
                decoder.append(byte)
            }
        }

        public mutating func next() async throws -> Value? {
            try await next(isolation: nil)
        }
    }
}

extension AsyncBasslineValues: Sendable where Base: Sendable {}
