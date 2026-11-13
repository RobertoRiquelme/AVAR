//
//  PayloadFraming.swift
//  AVAR2
//
//  Carries payloads that are too large for one SharePlay message.
//
//  SharePlay's messenger takes "small messages … up to 256 kilobytes". A diagram is sent as one
//  JSON envelope, and a 1000-node diagram encodes to about 660 KB, so it never arrived. This file
//  compresses such a payload and, if it is still too large, splits it into frames that are
//  reassembled on the other side.
//
//  Three deliberate choices:
//
//  - **Anything that already fits is sent exactly as before.** Poses, removals and ordinary
//    diagrams are untouched, so the traffic known to work on hardware does not change.
//  - **Frames are far smaller than the limit.** The limit applies to the *encoded* message and how
//    the messenger encodes `Data` is not documented; base64 alone would add a third. 96 KB leaves
//    room for that and more.
//  - **This is not `GroupSessionJournal`**, which is what Apple points to for large data. The
//    journal cannot be exercised without a live session, and it changes who receives what when.
//    Framing rides on the messenger path that already works and can be tested exhaustively here.
//
//  Used for SharePlay only. Multipeer has no such limit and never sees a frame.
//

import Foundation

enum PayloadFraming {
    /// Payloads up to this size go out untouched, as a single ordinary message.
    static let passthroughLimit = 96 * 1024
    /// Maximum body bytes per frame.
    static let chunkSize = 96 * 1024
    /// Largest frame this file ever produces, header included.
    static let maxFrameSize = chunkSize + headerSize

    // Layout: magic(4) flags(1) messageID(16) index(2) count(2) bodyLength(4) | body
    static let magic: [UInt8] = [0x41, 0x56, 0x46, 0x31]   // "AVF1" — an envelope is JSON and starts with "{"
    static let headerSize = 4 + 1 + 16 + 2 + 2 + 4
    static let compressedFlag: UInt8 = 0x01

    struct Header: Equatable {
        var flags: UInt8
        var messageID: UUID
        var index: Int
        var count: Int
        /// Length of the whole reassembled body (compressed, if it was).
        var bodyLength: Int

        var isCompressed: Bool { flags & PayloadFraming.compressedFlag != 0 }
    }

    static func isFrame(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count).elementsEqual(magic)
    }

    /// What to send for `payload`: the payload itself when it fits, otherwise its frames in order.
    static func frames(for payload: Data, messageID: UUID = UUID()) -> [Data] {
        guard payload.count > passthroughLimit else { return [payload] }

        var body = payload
        var flags: UInt8 = 0
        if let compressed = try? (payload as NSData).compressed(using: .zlib) as Data,
           compressed.count < payload.count {
            body = compressed
            flags |= compressedFlag
        }

        let count = max(1, (body.count + chunkSize - 1) / chunkSize)
        // The count travels as 16 bits. 65 535 frames is over 6 GB; nothing legitimate gets here.
        guard count <= Int(UInt16.max) else { return [] }

        return (0..<count).map { index in
            let start = body.startIndex + index * chunkSize
            let end = min(start + chunkSize, body.endIndex)
            var frame = Data(capacity: headerSize + (end - start))
            frame.append(contentsOf: magic)
            frame.append(flags)
            frame.append(contentsOf: withUnsafeBytes(of: messageID.uuid) { Array($0) })
            frame.append(contentsOf: bigEndian(UInt16(index)))
            frame.append(contentsOf: bigEndian(UInt16(count)))
            frame.append(contentsOf: bigEndian(UInt32(body.count)))
            frame.append(body[start..<end])
            return frame
        }
    }

    /// Splits a frame into header and body, or returns `nil` if it is not a well-formed frame.
    static func parse(_ frame: Data) -> (header: Header, body: Data)? {
        guard isFrame(frame), frame.count >= headerSize else { return nil }
        let bytes = [UInt8](frame.prefix(headerSize))
        let uuid = bytes[5..<21].withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        let index = Int(bytes[21]) << 8 | Int(bytes[22])
        let count = Int(bytes[23]) << 8 | Int(bytes[24])
        let bodyLength = Int(bytes[25]) << 24 | Int(bytes[26]) << 16 | Int(bytes[27]) << 8 | Int(bytes[28])
        guard count >= 1, index < count else { return nil }
        return (Header(flags: bytes[4], messageID: UUID(uuid: uuid), index: index, count: count,
                       bodyLength: bodyLength),
                Data(frame.dropFirst(headerSize)))
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
}

/// Puts frames back together. One per session; `reset()` when the session ends.
struct PayloadReassembler {
    enum Outcome: Equatable {
        /// More frames are needed.
        case incomplete
        /// The original payload, byte for byte.
        case complete(Data)
        /// The frame was unusable. The reason is for the diagnostics panel.
        case rejected(String)
    }

    /// Largest reassembled body accepted. A real 3000-node diagram compresses to well under 1 MB.
    static let maxBodyBytes = 32 * 1024 * 1024
    /// Messages that may be in progress at once before the oldest is dropped.
    static let maxPartialMessages = 8

    /// Used when the transport does not identify the sender.
    static let unknownSender = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private struct Key: Hashable {
        let sender: UUID
        let messageID: UUID
    }

    private struct Partial {
        var header: PayloadFraming.Header
        var parts: [Int: Data] = [:]
        var bytes = 0
    }

    private var partials: [Key: Partial] = [:]
    /// Oldest first, for eviction.
    private var order: [Key] = []

    var partialCount: Int { partials.count }

    mutating func reset() {
        partials.removeAll()
        order.removeAll()
    }

    /// Feeds one frame. Frames may arrive out of order or more than once, and messages from
    /// different senders — or several from one sender — may be interleaved.
    mutating func receive(_ frame: Data, from sender: UUID) -> Outcome {
        guard let (header, body) = PayloadFraming.parse(frame) else {
            return .rejected("malformed frame")
        }
        guard header.bodyLength <= Self.maxBodyBytes else {
            return .rejected("payload of \(header.bodyLength) bytes is over the limit")
        }
        guard body.count <= PayloadFraming.chunkSize else {
            return .rejected("oversized frame")
        }

        let key = Key(sender: sender, messageID: header.messageID)
        var partial: Partial
        if let existing = partials[key] {
            // Every frame of a message repeats its count, flags and length. A mismatch means the
            // frames do not belong together, so nothing built from them can be trusted.
            guard existing.header.count == header.count, existing.header.flags == header.flags,
                  existing.header.bodyLength == header.bodyLength else {
                drop(key)
                return .rejected("frames disagree about the message")
            }
            partial = existing
        } else {
            partial = Partial(header: header)
            order.append(key)
            // A joiner who arrives mid-transfer receives a tail with no head, which can never
            // complete. Dropping the oldest keeps those from accumulating.
            while order.count > Self.maxPartialMessages {
                drop(order[0])
            }
        }

        if partial.parts[header.index] == nil {
            partial.parts[header.index] = body
            partial.bytes += body.count
        }
        guard partial.bytes <= header.bodyLength else {
            drop(key)
            return .rejected("frames exceed the declared length")
        }
        guard partial.parts.count == header.count else {
            partials[key] = partial
            return .incomplete
        }

        drop(key)
        var assembled = Data(capacity: partial.bytes)
        for index in 0..<header.count {
            guard let part = partial.parts[index] else { return .rejected("missing frame \(index)") }
            assembled.append(part)
        }
        guard assembled.count == header.bodyLength else {
            return .rejected("reassembled \(assembled.count) bytes, expected \(header.bodyLength)")
        }
        guard header.isCompressed else { return .complete(assembled) }
        guard let payload = try? (assembled as NSData).decompressed(using: .zlib) as Data else {
            return .rejected("could not decompress")
        }
        return .complete(payload)
    }

    private mutating func drop(_ key: Key) {
        partials.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }
}
