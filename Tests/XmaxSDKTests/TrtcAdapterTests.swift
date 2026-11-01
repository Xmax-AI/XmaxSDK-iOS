//
//  TrtcAdapterTests.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import TXLiteAVSDK_TRTC
import XCTest
@testable import XmaxSDK

final class TrtcAdapterTests: XCTestCase {
    func testInputCopiesPaddedPlanesAndMirrorsChromaPairs() throws {
        let frame = try makeFrame()
        let plain = try TrtcVideoFrame(frame: frame, mirrored: false)
        let mirrored = try TrtcVideoFrame(frame: frame, mirrored: true)
        XCTAssertEqual(readPlane(plain.buffer, plane: 0, bytes: 4), [1, 2, 3, 4])
        XCTAssertEqual(readPlane(plain.buffer, plane: 1, bytes: 4), [10, 20, 30, 40])
        XCTAssertEqual(readPlane(mirrored.buffer, plane: 0, bytes: 4), [4, 3, 2, 1])
        XCTAssertEqual(readPlane(mirrored.buffer, plane: 1, bytes: 4), [30, 40, 10, 20])
        XCTAssertEqual(plain.value.timestamp, 1234)
        XCTAssertEqual(plain.value.width, 4)
        XCTAssertEqual(plain.value.height, 2)
        XCTAssertEqual(plain.value.pixelFormat, ._NV12)
    }

    func testInputUpdatesTimingWithoutReplacingOwnedPixels() throws {
        let frame = try makeFrame()
        let native = try TrtcVideoFrame(frame: frame, mirrored: false)
        native.updateMetadata(try frame.updating(timestampUs: 2_999_999, rotation: .rotation90))
        XCTAssertEqual(native.value.timestamp, 2999)
        XCTAssertEqual(native.value.rotation.rawValue, 1)
        XCTAssertEqual(readPlane(native.buffer, plane: 0, bytes: 4), [1, 2, 3, 4])
    }

    func testInputRejectsTruncatedPlanes() throws {
        let frame = try VideoFrame(
            format: VideoFormat(width: 4, height: 2, pixelFormat: .nv12),
            timestampUs: 0,
            planes: [
                VideoFramePlane(data: Data([1, 2, 3, 4]), stride: 4),
                VideoFramePlane(data: Data([1, 2, 3, 4]), stride: 4)
            ]
        )
        XCTAssertThrowsError(try TrtcVideoFrame(frame: frame, mirrored: false))
    }

    func testRemoteVideoOwnsPixelsAndGatesDeliveryOnSubscription() throws {
        let native = try TrtcVideoFrame(frame: makeFrame(), mirrored: false)
        let sink = TrtcRemoteFrameSink()
        let captured = TrtcFrameCapture()
        sink.setVideoListener({ captured.append($0) }, userID: "bot")
        sink.onRenderVideoFrame(native.value, userId: "bot", streamType: .big)
        XCTAssertTrue(captured.frames.isEmpty)
        sink.setSubscription(userID: "bot", video: true, subscribed: true)
        sink.onRenderVideoFrame(native.value, userId: "other", streamType: .big)
        sink.onRenderVideoFrame(native.value, userId: "bot", streamType: .sub)
        XCTAssertTrue(captured.frames.isEmpty)
        sink.onRenderVideoFrame(native.value, userId: "bot", streamType: .big)
        let result = try XCTUnwrap(captured.frames.first)
        XCTAssertEqual(result.presentationTimeStamp, CMTime(value: 1234, timescale: 1000))
        CVPixelBufferLockBaseAddress(native.buffer, [])
        CVPixelBufferGetBaseAddressOfPlane(native.buffer, 0)!.storeBytes(
            of: UInt8(99),
            as: UInt8.self
        )
        CVPixelBufferUnlockBaseAddress(native.buffer, [])
        XCTAssertEqual(readPlane(result.pixelBuffer, plane: 0, bytes: 4), [1, 2, 3, 4])
        sink.close()
        sink.onRenderVideoFrame(native.value, userId: "bot", streamType: .big)
        XCTAssertEqual(captured.frames.count, 1)
    }

    func testRemoteAudioRetainsNativeTimelineAndStopsAfterClose() throws {
        let sink = TrtcRemoteFrameSink()
        let captured = TrtcFrameCapture()
        sink.setAudioListener({ captured.appendAudio($0) }, userID: "bot")
        sink.setSubscription(userID: "bot", video: false, subscribed: true)
        let native = TRTCAudioFrame()
        native.data = Data(repeating: 7, count: 960)
        native.sampleRate = .rate48000
        native.channels = 1
        native.timestamp = 1234
        sink.onRemoteUserAudioFrame(native, userId: "bot")
        native.data = Data(repeating: 9, count: 960)
        let result = try XCTUnwrap(captured.audio.first)
        XCTAssertEqual(result.data, Data(repeating: 7, count: 960))
        XCTAssertEqual(result.renderTimeMs, 1234)
        XCTAssertEqual(result.samplesPerChannel, 480)
        XCTAssertEqual(result.sampleRate, 48000)
        sink.close()
        sink.onRemoteUserAudioFrame(native, userId: "bot")
        XCTAssertEqual(captured.audio.count, 1)
    }

    func testManagerRejectsCredentialsForDifferentProviderBeforeNativeEntry() async throws {
        let manager = RtcManager(provider: .trtc)
        do {
            try await manager.joinRoom(
                configuration: RoomJoinConfiguration(
                    roomID: "room",
                    userID: "user",
                    token: "agora-token"
                )
            )
            XCTFail("Must reject mismatched provider before acquiring native resources")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
    }

    func testNativeEngineAcceptsExactEncodingDimensionsWithoutSession() async throws {
        let lease = try await RtcEngineManager.shared.acquire(provider: .trtc)
        XCTAssertTrue(lease.engine is TrtcRtcPlatform)
        do {
            for (width, height) in [(1080, 1920), (832, 1472), (1056, 1056), (768, 1024)] {
                try lease.engine.configureVideoEncoding(
                    VideoEncodingConfiguration(
                        width: width,
                        height: height,
                        frameRate: 30,
                        minimumBitrate: 1000,
                        maximumBitrate: 5000
                    )
                )
            }
            XCTAssertThrowsError(
                try lease.engine.configureVideoEncoding(
                    VideoEncodingConfiguration(
                        width: 1408,
                        height: 1408,
                        frameRate: 30
                    )
                )
            )
            try await Task.sleep(nanoseconds: 300_000_000)
            try lease.engine.useExternalVideoSource()
            try lease.engine.pushExternalVideoFrame(makeFrame())
        } catch {
            await RtcEngineManager.shared.release(lease)
            throw error
        }
        await RtcEngineManager.shared.release(lease)
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testTRTCQualityCapsOnlyUplinkAndKeepsGenerationBaseline() {
        for (width, height) in [(1080, 1920), (1408, 1408), (1152, 1536), (1536, 1152)] {
            let baseline = RealtimeVideoFormat(width: width, height: height, fps: 30)
            for level in RealtimeQualityLevel.allCases {
                let configuration = QualityConfiguration(
                    baseline: baseline,
                    uplinkLevel: level,
                    downlinkLevel: level,
                    minimumInputPixels: 200000,
                    provider: .trtc
                )
                let uplink = configuration.uplink
                XCTAssertLessThanOrEqual(max(uplink.width, uplink.height), 1920)
                XCTAssertLessThanOrEqual(min(uplink.width, uplink.height), 1080)
                XCTAssertTrue(uplink.width.isMultiple(of: 8))
                XCTAssertTrue(uplink.height.isMultiple(of: 8))
                XCTAssertEqual(uplink.width * height, uplink.height * width)
                XCTAssertEqual(configuration.baseline, baseline)
                XCTAssertEqual(
                    configuration.downlink,
                    QualityVideoFormat.resolve(baseline, level: level, downlink: true)
                )
                let direction = QualityDirection(
                    baseline: baseline,
                    level: level,
                    downlink: false,
                    minimumInputPixels: 200000,
                    provider: .trtc
                )
                XCTAssertEqual(direction.format(at: level), uplink)
            }
        }
    }

    func testCustomMediaSharesNativeClockWithoutReplacingSourceIntervals() {
        var clock = TrtcRtcPlatform.MediaClock()
        XCTAssertEqual(clock.timestamp(sourceUs: 10_000, nativeNowMs: 50_000), 50_000)
        XCTAssertEqual(clock.timestamp(sourceUs: 0, nativeNowMs: 50_003), 49_990)
        XCTAssertEqual(clock.timestamp(sourceUs: 20_000, nativeNowMs: 50_006), 50_010)
        XCTAssertEqual(clock.timestamp(sourceUs: 33_333, nativeNowMs: 50_011), 50_023)
    }

    func testQualityHistoryIsIsolatedBetweenProviders() throws {
        let name = "trtc-quality-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let agora = QualityHistory(model: "x2.1", provider: .agora, defaults: defaults)
        let trtc = QualityHistory(model: "x2.1", provider: .trtc, defaults: defaults)
        agora.write(level: .l5, downlink: false, now: 100)
        XCTAssertEqual(trtc.read(downlink: false, now: 101), .l2)
        trtc.write(level: .l3, downlink: false, now: 101)
        XCTAssertEqual(agora.read(downlink: false, now: 102), .l5)
        XCTAssertEqual(trtc.read(downlink: false, now: 102), .l3)
    }

    func testRoomParametersUseStringIDAndRTCScene() throws {
        let configuration = RoomJoinConfiguration(
            roomID: "00123",
            userID: "rtc-user",
            credentials: .trtc(sdkAppID: 1600126360, userSig: "sig", privateMapKey: "key")
        )
        let parameters = try TrtcRtcRoom.joinParameters(configuration)
        XCTAssertEqual(parameters.roomId, 0)
        XCTAssertEqual(parameters.strRoomId, "00123")
        XCTAssertEqual(parameters.sdkAppId, 1600126360)
        XCTAssertEqual(parameters.userId, "rtc-user")
        XCTAssertEqual(parameters.userSig, "sig")
        XCTAssertEqual(parameters.privateMapKey, "key")
        XCTAssertEqual(TrtcRtcRoom.appScene, .videoCall)
        XCTAssertThrowsError(
            try TrtcRtcRoom.joinParameters(
                RoomJoinConfiguration(roomID: "room", userID: "user", token: "token")
            )
        )
    }

    func testRejoinRestoresCaptureAndLatestEncodingAfterNativeExit() throws {
        let engine = TrtcReentryEngineStub()
        let platform = TrtcRtcPlatform(engine: engine)
        try platform.useExternalVideoSource()
        try platform.configureVideoEncoding(
            VideoEncodingConfiguration(
                width: 1080,
                height: 1920,
                frameRate: 30,
                maximumBitrate: 5000
            )
        )
        try platform.startAudioCapture()
        let first = try platform.createRoom(roomID: "first")
        try first.join(configuration: trtcJoinConfiguration(roomID: "first"))
        try first.publishLocalVideo(true)
        first.destroy()

        // Reconnection setup may run before asynchronous exit finishes and clears native state.
        try platform.configureVideoEncoding(
            VideoEncodingConfiguration(
                width: 832,
                height: 1472,
                frameRate: 24,
                maximumBitrate: 3000
            )
        )
        try platform.startAudioCapture()
        let second = try platform.createRoom(roomID: "second")
        defer {
            second.destroy()
            engine.completeExit()
        }
        try second.join(configuration: trtcJoinConfiguration(roomID: "second"))
        XCTAssertEqual(engine.enteredRooms, ["first"])
        engine.completeExit()

        XCTAssertEqual(engine.enteredRooms, ["first", "second"])
        XCTAssertTrue(engine.externalVideoEnabled)
        XCTAssertTrue(engine.microphoneStarted)
        let encoding = try XCTUnwrap(engine.encoding)
        XCTAssertEqual(encoding["videoWidth"] as? Int, 1472)
        XCTAssertEqual(encoding["videoHeight"] as? Int, 832)
        XCTAssertEqual(encoding["videoFps"] as? Int, 24)
        XCTAssertEqual(encoding["videoBitrate"] as? Int, 3000)
        XCTAssertFalse(engine.publishingVideo)
        try second.publishLocalVideo(true)
        XCTAssertTrue(engine.publishingVideo)
    }

    func testRejoinRestoresExternalAudioWithoutStartingMicrophone() throws {
        let engine = TrtcReentryEngineStub()
        let platform = TrtcRtcPlatform(engine: engine)
        try platform.useExternalVideoSource()
        try platform.startExternalAudioSource()
        let first = try platform.createRoom(roomID: "first")
        try first.join(configuration: trtcJoinConfiguration(roomID: "first"))
        first.destroy()
        engine.completeExit()

        let second = try platform.createRoom(roomID: "second")
        defer {
            second.destroy()
            engine.completeExit()
        }
        try second.join(configuration: trtcJoinConfiguration(roomID: "second"))
        XCTAssertTrue(engine.externalVideoEnabled)
        XCTAssertTrue(engine.externalAudioEnabled)
        XCTAssertFalse(engine.microphoneStarted)
        XCTAssertEqual(engine.microphoneStartCount, 0)
    }

    func testRejoinDoesNotRestoreMicrophoneAfterItWasStopped() throws {
        let engine = TrtcReentryEngineStub()
        let platform = TrtcRtcPlatform(engine: engine)
        try platform.useExternalVideoSource()
        try platform.startAudioCapture()
        let first = try platform.createRoom(roomID: "first")
        try first.join(configuration: trtcJoinConfiguration(roomID: "first"))
        try platform.stopAudioCapture()
        first.destroy()
        engine.completeExit()

        let second = try platform.createRoom(roomID: "second")
        defer {
            second.destroy()
            engine.completeExit()
        }
        try second.join(configuration: trtcJoinConfiguration(roomID: "second"))
        XCTAssertTrue(engine.externalVideoEnabled)
        XCTAssertFalse(engine.microphoneStarted)
        XCTAssertFalse(engine.externalAudioEnabled)
        XCTAssertEqual(engine.microphoneStartCount, 1)
    }

    func testCancelledRejoinDoesNotRestoreOrEnterUntilALaterValidRoom() throws {
        let engine = TrtcReentryEngineStub()
        let platform = TrtcRtcPlatform(engine: engine)
        try platform.useExternalVideoSource()
        let first = try platform.createRoom(roomID: "first")
        try first.join(configuration: trtcJoinConfiguration(roomID: "first"))
        first.destroy()
        let cancelled = try platform.createRoom(roomID: "cancelled")
        try cancelled.join(configuration: trtcJoinConfiguration(roomID: "cancelled"))
        cancelled.destroy()
        engine.completeExit()
        XCTAssertEqual(engine.enteredRooms, ["first"])
        XCTAssertFalse(engine.externalVideoEnabled)

        let third = try platform.createRoom(roomID: "third")
        defer {
            third.destroy()
            engine.completeExit()
        }
        try third.join(configuration: trtcJoinConfiguration(roomID: "third"))
        XCTAssertEqual(engine.enteredRooms, ["first", "third"])
        XCTAssertTrue(engine.externalVideoEnabled)
    }

    private func trtcJoinConfiguration(roomID: String) -> RoomJoinConfiguration {
        RoomJoinConfiguration(
            roomID: roomID,
            userID: "user",
            credentials: .trtc(sdkAppID: 1600126360, userSig: "sig", privateMapKey: "key")
        )
    }

    private func makeFrame() throws -> VideoFrame {
        try VideoFrame(
            format: VideoFormat(width: 4, height: 2, pixelFormat: .nv12),
            timestampUs: 1_234_567,
            planes: [
                VideoFramePlane(
                    data: Data([0, 1, 2, 3, 4, 0, 0, 5, 6, 7, 8, 0, 0]),
                    stride: 6,
                    byteOffset: 1
                ),
                VideoFramePlane(data: Data([0, 10, 20, 30, 40, 0, 0]), stride: 6, byteOffset: 1)
            ]
        )
    }

    private func readPlane(_ buffer: CVPixelBuffer, plane: Int, bytes: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Array(
            UnsafeBufferPointer(
                start: CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(
                    to: UInt8.self
                ),
                count: bytes
            )
        )
    }
}

private final class TrtcFrameCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RealtimeVideoFrame] = []
    private var audioValues: [RtcRemoteAudioFrame] = []
    var frames: [RealtimeVideoFrame] { lock.withLock { values } }
    var audio: [RtcRemoteAudioFrame] { lock.withLock { audioValues } }
    func append(_ frame: RealtimeVideoFrame) { lock.withLock { values.append(frame) } }
    func appendAudio(_ frame: RtcRemoteAudioFrame) { lock.withLock { audioValues.append(frame) } }
}

/// Simulates the native resource reset delivered asynchronously at room exit.
private final class TrtcReentryEngineStub: TRTCCloud {
    private var observers: [any TRTCCloudDelegate] = []
    private var callbackQueue = DispatchQueue(label: "trtc-reentry-test")
    private var exitPending = false
    var externalVideoEnabled = false
    var externalAudioEnabled = false
    var microphoneStarted = false
    var microphoneStartCount = 0
    var publishingVideo = false
    var encoding: [String: Any]?
    var enteredRooms: [String] = []

    override var delegateQueue: DispatchQueue {
        get { callbackQueue }
        set { callbackQueue = newValue }
    }
    override func addDelegate(_ delegate: any TRTCCloudDelegate) { observers.append(delegate) }
    override func removeDelegate(_ delegate: any TRTCCloudDelegate) {
        observers.removeAll { ($0 as AnyObject) === (delegate as AnyObject) }
    }
    override func setDefaultStreamRecvMode(_ autoRecvAudio: Bool, video autoRecvVideo: Bool) {}
    override func muteLocalVideo(_ streamType: TRTCVideoStreamType, mute: Bool) {
        publishingVideo = !mute
    }
    override func muteLocalAudio(_ mute: Bool) {}
    override func setAudioFrameDelegate(_ delegate: (any TRTCAudioFrameDelegate)?) {}
    override func enableCustomVideoCapture(_ streamType: TRTCVideoStreamType, enable: Bool) {
        externalVideoEnabled = enable
    }
    override func enableCustomAudioCapture(_ enable: Bool) { externalAudioEnabled = enable }
    override func startLocalAudio(_ quality: TRTCAudioQuality) {
        microphoneStarted = true
        microphoneStartCount += 1
    }
    override func stopLocalAudio() { microphoneStarted = false }
    override func callExperimentalAPI(_ jsonStr: String) -> String {
        if let object = try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8))
            as? [String: Any]
        {
            encoding = object["params"] as? [String: Any]
        }
        return "{\"code\":0}"
    }
    override func setNetworkQosParam(_ param: TRTCNetworkQosParam) {}
    override func enterRoom(_ param: TRTCParams, appScene scene: TRTCAppScene) {
        enteredRooms.append(param.strRoomId)
        for observer in observers { observer.onEnterRoom?(1) }
    }
    override func exitRoom() { exitPending = true }
    override func stopAllRemoteView() {}

    func completeExit() {
        guard exitPending else { return }
        exitPending = false
        externalVideoEnabled = false
        externalAudioEnabled = false
        microphoneStarted = false
        encoding = nil
        let pending = observers
        for observer in pending { observer.onExitRoom?(0) }
    }
}
