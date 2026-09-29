import Testing
@testable import Bassline

@Suite("streaming decoder")
struct StreamingTests {
    @Test func depthLimit() throws {
        func nested(_ depth: Int) -> [UInt8] {
            Array(repeating: 0x60, count: depth) + Array(repeating: 0xA0, count: depth)
        }
        #expect(try Value.decodeAll(nested(64)).count == 1)
        #expect(throws: DecodeError(.tooDeep, at: 64)) { try Value.decodeAll(nested(65)) }
        #expect(try Value.decodeAll(nested(65), limits: DecodingLimits(maxDepth: 65)).count == 1)
    }

    @Test func encoderDoesNotEnforceDepth() throws {
        var value: Value = []
        for _ in 0 ..< 100 { value = [value] }
        #expect(throws: DecodeError.self) { try Value(decoding: value.encoded()) }
        #expect(try Value(decoding: value.encoded(), limits: DecodingLimits(maxDepth: 101)) == value)
    }

    @Test func oversizeScalarIsRefusedFromItsHeader() {
        let limits = DecodingLimits(maxValueBytes: 4096)
        // bytes header claiming 4097 bytes of payload, with no payload behind it
        let header: [UInt8] = [0x57, 0xFF, 0x00, 0x00, 0x10, 0x01]
        let whole = land(header, limits: limits)
        #expect(whole.error == DecodeError(.tooLarge, at: 0))
        #expect(land(header, chunked: true, limits: limits).error == whole.error)
    }

    @Test func unclosedFrameIsRefusedIdenticallyHoweverItArrives() {
        let limits = DecodingLimits(maxValueBytes: 4096)
        let stream: [UInt8] = [0x60] + Array(repeating: 0x10, count: 4096)
        let whole = land(stream, limits: limits)
        #expect(whole.error?.reason == .tooLarge)
        #expect(land(stream, chunked: true, limits: limits).error == whole.error)
    }

    @Test func valueUnderTheCapDecodes() throws {
        let value = Value.bytes(Array(repeating: 7, count: 2048))
        let landed = land(value.encoded(), limits: DecodingLimits(maxValueBytes: 4096))
        #expect(landed.values == [value])
    }

    @Test func oneShotAdmitsInputItAlreadyHolds() throws {
        let value = Value.bytes(Array(repeating: 7, count: 5000))
        #expect(try Value(decoding: value.encoded(), limits: DecodingLimits(maxValueBytes: 4096)) == value)
    }

    @Test func failedDecoderStaysFailed() {
        var decoder = StreamDecoder()
        decoder.append(0x00)
        #expect(throws: DecodeError(.invalidTag, at: 0)) { try decoder.next() }
        decoder.append(0x10)
        #expect(throws: DecodeError(.invalidTag, at: 0)) { try decoder.next() }
        #expect(throws: DecodeError(.invalidTag, at: 0)) { try decoder.finish() }
    }

    @Test func offsetsStayAbsoluteAcrossCompaction() throws {
        var decoder = StreamDecoder()
        var count = 0
        for _ in 0 ..< 10_000 {
            decoder.append(0x10)
            while try decoder.next() != nil { count += 1 }
        }
        #expect(count == 10_000)
        #expect(decoder.offset == 10_000)
        decoder.append(contentsOf: [0x60, 0x21, 0x31, 0xB0])
        #expect(throws: DecodeError(.invalidTag, at: 10_003)) { try decoder.next() }
    }

    @Test func oneShotReasons() {
        #expect(throws: DecodeError(.truncated, at: 0)) { try Value(decoding: [UInt8]()) }
        #expect(throws: DecodeError(.trailingBytes, at: 1)) { try Value(decoding: [0x10, 0x10]) }
        // a fault after the value outranks there merely being more
        #expect(throws: DecodeError(.endAtTop, at: 2)) { try Value(decoding: [0x60, 0xA0, 0xA0]) }
        #expect(throws: DecodeError(.truncated, at: 3)) { try Value(decoding: [0x60, 0x21, 0x31]) }
    }

    @Test(arguments: [(6, [0x56]), (7, [0x57, 0x07]), (254, [0x57, 0xFE]), (255, [0x57, 0xFF, 0, 0, 0, 0xFF])] as [(Int, [UInt8])])
    func lengthTiers(length: Int, header: [UInt8]) throws {
        let value = Value.bytes(Array(repeating: 0xAB, count: length))
        let bytes = value.encoded()
        #expect(Array(bytes.prefix(header.count)) == header)
        #expect(bytes.count == header.count + length)
        #expect(try Value(decoding: bytes) == value)
    }

    @Test func acceptsSpans() throws {
        let bytes = Value.record("point", 1, 2).encoded()
        var decoder = StreamDecoder()
        decoder.append(contentsOf: bytes.span)
        #expect(try decoder.next() == .record("point", 1, 2))
        #expect(!decoder.isPending)
    }

    @Test func asyncByteStream() async throws {
        let values: [Value] = [1, "two", .record("three", .symbol("go").marked), [:], .set([4, 5])]
        var bytes: [UInt8] = []
        for value in values { value.encode(into: &bytes) }

        let stream = AsyncStream<UInt8> { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
        var landed: [Value] = []
        for try await value in stream.basslineValues() { landed.append(value) }
        #expect(landed == values)
    }

    @Test func asyncStreamEndingMidValueThrows() async {
        let stream = AsyncStream<UInt8> { continuation in
            for byte in [0x10, 0x60, 0x21] as [UInt8] { continuation.yield(byte) }
            continuation.finish()
        }
        var landed: [Value] = []
        await #expect(throws: DecodeError(.truncated, at: 3)) {
            for try await value in stream.basslineValues() { landed.append(value) }
        }
        #expect(landed == [.null])
    }
}
