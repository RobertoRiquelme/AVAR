import Foundation

/// Framing for payloads too large for one SharePlay message.
///
/// A diagram that fails to arrive looks, on a headset, exactly like sharing being broken — so
/// what is pinned here is that every payload comes back byte for byte whatever order its frames
/// arrive in, that no frame ever approaches the message limit, and that damaged or stray frames
/// are refused instead of producing a wrong payload.
@main
struct PayloadFramingTests {
    static func main() {
        testSmallPayloadsAreSentUntouched()
        testJustOverTheLimitIsFramedAndRestored()
        testIncompressibleDataNeedsSeveralFrames()
        testOutOfOrderAndDuplicateFrames()
        testInterleavedMessagesAndSenders()
        testTailWithoutHeadNeverCompletesAndIsBounded()
        testDamagedFramesAreRejected()
        testBadFramesAreRefusedImmediately()
        testFramesThatDisagreeAreRejected()
        print("PayloadFramingTests ✅")
    }

    static let sender = UUID()

    /// Deterministic, so a failure reproduces.
    static func noise(_ count: Int, seed: UInt64 = 0x9E3779B97F4A7C15) -> Data {
        var state = seed
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
        return Data(bytes)
    }

    static func text(_ count: Int) -> Data {
        Data(String(repeating: #"{"id":"node","position":[1.5,2.5,3.5]},"#, count: count / 38 + 1).utf8.prefix(count))
    }

    static func reassemble(_ frames: [Data], from sender: UUID = sender) -> PayloadReassembler.Outcome {
        var reassembler = PayloadReassembler()
        var last = PayloadReassembler.Outcome.incomplete
        for frame in frames { last = reassembler.receive(frame, from: sender) }
        return last
    }

    static func testSmallPayloadsAreSentUntouched() {
        for size in [0, 1, 1000, PayloadFraming.passthroughLimit] {
            let payload = text(size)
            let frames = PayloadFraming.frames(for: payload)
            assert(frames == [payload], "\(size) bytes must go out as-is")
        }
        // An ordinary envelope can never be mistaken for a frame.
        assert(!PayloadFraming.isFrame(Data(#"{"type":"diagram"}"#.utf8)))
        assert(!PayloadFraming.isFrame(Data()))
    }

    static func testJustOverTheLimitIsFramedAndRestored() {
        let payload = text(PayloadFraming.passthroughLimit + 1)
        let frames = PayloadFraming.frames(for: payload)
        assert(frames.allSatisfy(PayloadFraming.isFrame), "everything over the limit is framed")
        assert(frames.count == 1, "JSON this size compresses into one frame, got \(frames.count)")
        assert(frames[0].count < payload.count / 2, "expected real compression")
        assert(reassemble(frames) == .complete(payload))
    }

    /// Worst case for the size guarantee: data that does not compress at all.
    static func testIncompressibleDataNeedsSeveralFrames() {
        for size in [PayloadFraming.passthroughLimit + 1, PayloadFraming.chunkSize * 2,
                     PayloadFraming.chunkSize * 2 + 1, 1_000_000] {
            let payload = noise(size)
            let frames = PayloadFraming.frames(for: payload)
            assert(frames.count == (size + PayloadFraming.chunkSize - 1) / PayloadFraming.chunkSize,
                   "\(size) bytes → \(frames.count) frames")
            assert(frames.allSatisfy { $0.count <= PayloadFraming.maxFrameSize }, "a frame is over the size cap")
            assert(PayloadFraming.maxFrameSize * 4 / 3 < 200 * 1024, "even base64-encoded, a frame must stay well under 256 KB")
            assert(reassemble(frames) == .complete(payload), "\(size) bytes did not round-trip")
        }
    }

    static func testOutOfOrderAndDuplicateFrames() {
        let payload = noise(PayloadFraming.chunkSize * 4 + 123)
        let frames = PayloadFraming.frames(for: payload)
        assert(frames.count == 5)
        assert(reassemble(frames.reversed()) == .complete(payload), "reverse order")
        assert(reassemble([frames[2], frames[0], frames[4], frames[1], frames[3]]) == .complete(payload))

        var reassembler = PayloadReassembler()
        for frame in [frames[0], frames[0], frames[1], frames[1], frames[2], frames[3], frames[2]] {
            assert(reassembler.receive(frame, from: sender) == .incomplete, "duplicates must not complete or break it")
        }
        assert(reassembler.receive(frames[4], from: sender) == .complete(payload))
        assert(reassembler.partialCount == 0, "a finished message is released")
        // A straggler after completion starts a new partial rather than corrupting anything.
        assert(reassembler.receive(frames[1], from: sender) == .incomplete)
    }

    /// Two diagrams sent back to back, and two people sending at once.
    static func testInterleavedMessagesAndSenders() {
        let a = noise(PayloadFraming.chunkSize * 2 + 5, seed: 1)
        let b = noise(PayloadFraming.chunkSize * 2 + 9, seed: 2)
        let sharedID = UUID()
        let fa = PayloadFraming.frames(for: a, messageID: sharedID)
        let fb = PayloadFraming.frames(for: b, messageID: UUID())
        let alice = UUID(), bob = UUID()

        var reassembler = PayloadReassembler()
        assert(reassembler.receive(fa[0], from: alice) == .incomplete)
        assert(reassembler.receive(fb[0], from: alice) == .incomplete)
        assert(reassembler.receive(fa[1], from: alice) == .incomplete)
        assert(reassembler.receive(fb[1], from: alice) == .incomplete)
        assert(reassembler.receive(fb[2], from: alice) == .complete(b))
        assert(reassembler.receive(fa[2], from: alice) == .complete(a))

        // The same message id from two senders must not be mixed into one payload.
        let c = noise(PayloadFraming.chunkSize * 2 + 5, seed: 3)
        let fc = PayloadFraming.frames(for: c, messageID: sharedID)
        var mixed = PayloadReassembler()
        assert(mixed.receive(fa[0], from: alice) == .incomplete)
        assert(mixed.receive(fc[0], from: bob) == .incomplete)
        assert(mixed.receive(fa[1], from: alice) == .incomplete)
        assert(mixed.receive(fc[1], from: bob) == .incomplete)
        assert(mixed.receive(fc[2], from: bob) == .complete(c))
        assert(mixed.receive(fa[2], from: alice) == .complete(a))
    }

    /// Someone who joins while a diagram is in flight receives its last frames only.
    static func testTailWithoutHeadNeverCompletesAndIsBounded() {
        var reassembler = PayloadReassembler()
        for i in 0..<40 {
            let frames = PayloadFraming.frames(for: noise(PayloadFraming.chunkSize * 3, seed: UInt64(i + 1)))
            assert(reassembler.receive(frames[2], from: sender) == .incomplete)
            assert(reassembler.receive(frames[1], from: sender) == .incomplete)
            assert(reassembler.partialCount <= PayloadReassembler.maxPartialMessages, "partials must be bounded")
        }
        // The newest is still completable; old ones were dropped to make room.
        let payload = noise(PayloadFraming.chunkSize * 3, seed: 999)
        let frames = PayloadFraming.frames(for: payload)
        assert(reassembler.receive(frames[1], from: sender) == .incomplete)
        assert(reassembler.receive(frames[0], from: sender) == .incomplete)
        assert(reassembler.receive(frames[2], from: sender) == .complete(payload))

        reassembler.reset()
        assert(reassembler.partialCount == 0)
    }

    static func rejected(_ outcome: PayloadReassembler.Outcome) -> Bool {
        if case .rejected = outcome { return true }
        return false
    }

    static func testDamagedFramesAreRejected() {
        let payload = text(400_000)
        let frames = PayloadFraming.frames(for: payload)
        assert(frames.count >= 1)
        var reassembler = PayloadReassembler()

        // Truncated header.
        assert(rejected(reassembler.receive(frames[0].prefix(PayloadFraming.headerSize - 1), from: sender)))
        // Not a frame at all.
        assert(rejected(reassembler.receive(Data("hello".utf8), from: sender)))

        // Index beyond the count.
        var badIndex = frames[0]
        badIndex[21] = 0xFF; badIndex[22] = 0xFF
        assert(rejected(reassembler.receive(badIndex, from: sender)))

        // Declared length absurdly large.
        var huge = frames[0]
        huge[25] = 0x7F
        assert(rejected(reassembler.receive(huge, from: sender)))

        // Body does not decompress: flip bytes in the middle of a compressed single-frame message.
        let single = PayloadFraming.frames(for: text(PayloadFraming.passthroughLimit + 10))
        assert(single.count == 1)
        var corrupt = single[0]
        for i in stride(from: PayloadFraming.headerSize + 10, to: corrupt.count, by: 7) { corrupt[i] ^= 0xA5 }
        let outcome = reassembler.receive(corrupt, from: sender)
        assert(outcome != .complete(text(PayloadFraming.passthroughLimit + 10)), "corrupt data must not be returned as the payload")
        assert(rejected(outcome), "got \(outcome)")

        // A short frame makes the total wrong.
        let multi = PayloadFraming.frames(for: noise(PayloadFraming.chunkSize * 2))
        var r2 = PayloadReassembler()
        assert(r2.receive(multi[0].dropLast(10), from: sender) == .incomplete)
        assert(rejected(r2.receive(multi[1], from: sender)), "length mismatch must be refused")
        assert(r2.partialCount == 0)
    }

    /// Bad frames must be refused the moment they arrive — not parked as "incomplete", where
    /// they would hold memory and, for a wrong index, poison a message that is otherwise fine.
    static func testBadFramesAreRefusedImmediately() {
        let payload = noise(PayloadFraming.chunkSize * 3, seed: 11)
        let frames = PayloadFraming.frames(for: payload)
        assert(frames.count == 3)

        // An index past the end, in the middle of a good message: refused, and the message
        // still completes from its real frames.
        var reassembler = PayloadReassembler()
        assert(reassembler.receive(frames[0], from: sender) == .incomplete)
        var strayIndex = frames[1]
        strayIndex[21] = 0x00; strayIndex[22] = 0x07     // index 7 of 3
        assert(rejected(reassembler.receive(strayIndex, from: sender)), "an out-of-range index must be refused at once")
        assert(reassembler.receive(frames[1], from: sender) == .incomplete)
        assert(reassembler.receive(frames[2], from: sender) == .complete(payload), "the real frames still complete")

        // A header claiming gigabytes must not be allowed to start accumulating.
        var claimsTooMuch = frames[0]
        claimsTooMuch[25] = 0x7F
        var r2 = PayloadReassembler()
        assert(rejected(r2.receive(claimsTooMuch, from: sender)), "an over-limit length must be refused at once")
        assert(r2.partialCount == 0)

        // Frames that together exceed what they declared are dropped as soon as they do.
        func declaring(_ length: Int, _ frame: Data) -> Data {
            var f = frame
            f[25] = UInt8(length >> 24 & 0xFF); f[26] = UInt8(length >> 16 & 0xFF)
            f[27] = UInt8(length >> 8 & 0xFF);  f[28] = UInt8(length & 0xFF)
            return f
        }
        var r3 = PayloadReassembler()
        assert(r3.receive(declaring(PayloadFraming.chunkSize, frames[0]), from: sender) == .incomplete)
        assert(rejected(r3.receive(declaring(PayloadFraming.chunkSize, frames[1]), from: sender)),
               "bytes beyond the declared length must be refused at once")
        assert(r3.partialCount == 0)
    }

    static func testFramesThatDisagreeAreRejected() {
        let id = UUID()
        let a = PayloadFraming.frames(for: noise(PayloadFraming.chunkSize * 3, seed: 5), messageID: id)
        let b = PayloadFraming.frames(for: noise(PayloadFraming.chunkSize * 4, seed: 6), messageID: id)
        var reassembler = PayloadReassembler()
        assert(reassembler.receive(a[0], from: sender) == .incomplete)
        assert(rejected(reassembler.receive(b[1], from: sender)), "a frame with a different count must not join the message")
        assert(reassembler.partialCount == 0, "the damaged message is dropped whole")
    }
}
