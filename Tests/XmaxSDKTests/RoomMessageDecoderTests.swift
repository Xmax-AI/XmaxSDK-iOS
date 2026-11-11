import Foundation
import XCTest
@testable import XmaxSDK

final class RoomMessageDecoderTests: XCTestCase {
    func testPlainAckAndInvalidCounts() throws {
        var decoder = RoomMessageDecoder()
        let value = decoder.decode(sender: "bot", data: Data(#"{"event":"xid_ack","xid":"one","count":1}"#.utf8))
        XCTAssertEqual(value?.message.xid, "one")
        XCTAssertEqual(value?.message.count, 1)
        for count in ["true", "1.5", "\"1\"", "90071992547409920000000"] {
            XCTAssertNil(decoder.decode(sender: "bot", data: Data("{\"event\":\"xid_ack\",\"count\":\(count)}".utf8)))
        }
    }

    func testFormatsVideoStoppedWithAStructuredPayload() throws {
        var decoder = RoomMessageDecoder()
        let data = Data(#"{"event":"video_stopped","uid":"old-task","data":{"status":"complete","access_token":"private-value"}}"#.utf8)
        let signal = try XCTUnwrap(decoder.decode(sender: "bot", data: data))
        XCTAssertEqual(signal.message.event, "video_stopped")
        XCTAssertEqual(signal.payload, data)

        let log = RoomController.formatSignalLog(signal.payload, direction: .inbound)
        XCTAssertTrue(log.hasPrefix("接收房间信令 (Inbound Room Signaling)\n├─ "))
        XCTAssertTrue(log.contains(#""uid" : "old-task""#))
        XCTAssertTrue(log.contains(#""status" : "complete""#))
        XCTAssertTrue(log.contains(#""access_token" : "[REDACTED]""#))
        XCTAssertFalse(log.contains("private-value"))
    }

    func testOutOfOrderFragmentsAreIsolatedBySenderAndResetOnLeave() throws {
        var decoder = RoomMessageDecoder()
        let raw = "{\"event\":\"xid_ack\",\"xid\":\"one\",\"count\":2,\"unused\":\"\(String(repeating: "x", count: 1800))\"}"
        let parts = try RtcMessageCodec.encode(raw)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertNil(decoder.decode(sender: "other", data: parts[0]))
        for part in parts.dropFirst().reversed() {
            XCTAssertNil(decoder.decode(sender: "bot", data: part))
        }
        let message = decoder.decode(sender: "bot", data: parts[0])
        XCTAssertEqual(message?.message.xid, "one")
        XCTAssertEqual(message?.message.count, 2)
        XCTAssertEqual(message?.payload, Data(raw.utf8))
        decoder.reset()
        XCTAssertNil(decoder.decode(sender: "other", data: parts.last!))
    }

    func testRejectsInconsistentOrOversizedFragmentEnvelope() {
        var decoder = RoomMessageDecoder()
        for raw in [
            #"{"event":"__agora_chunk__","eventId":"id","index":-1,"count":1,"data":"{}"}"#,
            #"{"event":"__agora_chunk__","eventId":"id","index":0,"count":513,"data":"{}"}"#,
            #"{"event":"__agora_chunk__","eventId":"id","index":0,"count":2,"data":"{"}"#,
            #"{"event":"__agora_chunk__","eventId":"id","index":1,"count":3,"data":"}"}"#
        ] {
            XCTAssertNil(decoder.decode(sender: "bot", data: Data(raw.utf8)))
        }
    }
}
