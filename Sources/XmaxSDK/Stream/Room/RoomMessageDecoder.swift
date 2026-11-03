//
//  RoomMessageDecoder.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Reassembles incoming room commands and receipts; owned by the room actor.
struct RoomMessageDecoder {

    /// Fields used for receipt validation and provider fragment envelopes.
    struct Message: Decodable {
        /// The business or provider-fragment event name.
        let event: String?
        /// The logical command identifier acknowledged by the service.
        let xid: String?
        /// The receipt count or total number of provider fragments.
        let count: Int?
        /// The optional intended local RTC recipient.
        let targetUserID: String?
        /// The identifier grouping fragments from one sender.
        let eventId: String?
        /// The zero-based fragment position.
        let index: Int?
        /// The original JSON slice in a provider fragment.
        let data: String?

        /// Maps the server recipient field without exposing wire naming to callers.
        enum CodingKeys: String, CodingKey {
            case event, xid, count, eventId, index, data
            case targetUserID = "user_id"
        }
    }

    /// Separates fragments from different senders even when their event IDs collide.
    private struct Key: Hashable {
        /// The remote sender owning the partial message.
        let userID: String
        /// The provider fragment identifier.
        let eventID: String
    }

    /// A bounded partial message with its insertion order for eviction.
    private struct Record {
        /// The expected number of pieces.
        let count: Int
        /// The insertion sequence used to evict the oldest partial message.
        let order: UInt64
        /// The received pieces indexed by position.
        var parts: [Int: String] = [:]
        /// The total UTF-8 payload retained by this partial message.
        var bytes = 0
    }

    /// Partial messages bounded by record count, per-message size, and total bytes.
    private var records: [Key: Record] = [:]
    /// The insertion order for bounded eviction.
    private var sequence: UInt64 = 0
    /// The aggregate retained UTF-8 bytes across incomplete messages.
    private var bytes = 0

    /// Decodes plain JSON or completed, possibly out-of-order Agora fragments.
    mutating func decode(sender: String, data: Data) -> Message? {
        guard data.count <= 262144,
            let message = try? JSONDecoder().decode(Message.self, from: data)
        else { return nil }
        guard message.event == "__agora_chunk__" else {
            return message
        }
        guard let eventID = message.eventId, !eventID.isEmpty,
            let index = message.index, let count = message.count,
            count > 0, count <= 512, index >= 0, index < count,
            let part = message.data
        else { return nil }
        let key = Key(userID: sender, eventID: eventID)
        sequence &+= 1
        var record = records[key] ?? Record(count: count, order: sequence)
        guard record.count == count else { return nil }
        let added = part.utf8.count - (record.parts[index]?.utf8.count ?? 0)
        guard record.bytes + added <= 262144 else {
            bytes -= records.removeValue(forKey: key)?.bytes ?? 0
            return nil
        }
        record.parts[index] = part
        record.bytes += added
        bytes += added
        records[key] = record
        while records.count > 1000 || bytes > 32 * 1024 * 1024 {
            guard let oldest = records.min(by: { $0.value.order < $1.value.order })?.key else {
                break
            }
            bytes -= records.removeValue(forKey: oldest)?.bytes ?? 0
        }
        guard records[key] != nil, record.parts.count == count else { return nil }
        records.removeValue(forKey: key)
        bytes -= record.bytes
        let joined = (0..<count).compactMap { record.parts[$0] }.joined()
        return try? JSONDecoder().decode(Message.self, from: Data(joined.utf8))
    }

    /// Releases all partial messages when the room is invalidated.
    mutating func reset() {
        records.removeAll()
        bytes = 0
    }
}
