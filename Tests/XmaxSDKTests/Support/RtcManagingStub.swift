//
//  RtcManagingStub.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import CoreMedia
import CoreVideo
@testable import XmaxSDK

enum RtcManagingCall: Equatable {
    case initialize
    case destroy
    case configureVideoEncoding(VideoEncodingConfiguration)
    case startAudioCapture
    case stopAudioCapture
    case configureLocalVideoMirror(CameraPosition)
    case useExternalVideoSource
    case startExternalAudioSource
    case stopExternalAudioSource
    case pushExternalVideoFrame
    case pushExternalAudioFrame(AudioFrame)
    case publishLocalVideo
    case unpublishLocalVideo
    case publishLocalAudio
    case unpublishLocalAudio
    case subscribeRemoteVideo(userID: String, subscribe: Bool)
    case subscribeRemoteAudio(userID: String, subscribe: Bool)
    case setRemoteAudioVolume(Int, userID: String)
    case joinRoom(RoomJoinConfiguration)
    case leaveRoom
    case sendRoomMessage(String)
    case setRemoteVideoFrameListener(RemoteStream, enabled: Bool)
    case setRemoteAudioFrameListener(RemoteStream, enabled: Bool)
}

final class RtcManagingStub: RtcManaging, @unchecked Sendable {

    typealias JoinRoomHandler = @Sendable (
        RoomJoinConfiguration
    ) async throws -> Void
    typealias LeaveRoomHandler = @Sendable () async -> Void

    // 测试配置
    private let encodingError: (any Error)?
    private let initializationError: (any Error)?
    private let initializationHandler: (@Sendable () async throws -> Void)?
    private let destroyHandler: (@Sendable () async -> Void)?
    private let startAudioCaptureError: (any Error)?
    private let stopAudioCaptureError: (any Error)?
    private let publishLocalVideoError: (any Error)?
    private let unpublishLocalVideoError: (any Error)?
    private let publishLocalAudioError: (any Error)?
    private let unpublishLocalAudioError: (any Error)?
    private let subscribeRemoteVideoError: (any Error)?
    private let subscribeRemoteAudioError: (any Error)?
    private let setRemoteAudioVolumeError: (any Error)?
    private let joinRoomError: (any Error)?
    private var sendRoomMessageError: (any Error)?
    private let joinRoomHandler: JoinRoomHandler?
    private let leaveRoomHandler: LeaveRoomHandler?
    private let setRemoteVideoFrameListenerError: (any Error)?
    private let setRemoteAudioFrameListenerError: (any Error)?
    var commandSendHandler: (@Sendable () async throws -> Void)?
    var flushHandler: (@Sendable () async throws -> Void)?

    // 并发状态
    private let lock = NSLock()
    private var storedCalls: [RtcManagingCall] = []
    private var storedReplacementKeys: [String?] = []
    private var storedDiscardedKeys: [String?] = []
    private var roomMessageListener: (@Sendable (String, Data) -> Void)?
    private weak var storedEventListener: (any RtcEventListener)?
    private weak var storedQualityListener: (any RtcQualityListener)?
    private var storedRemoteVideoFrameStream: RemoteStream?
    private var storedRemoteVideoFrameListener:
        RtcRemoteVideoFrameListener?
    private var storedRemoteAudioFrameStream: RemoteStream?
    private var storedRemoteAudioFrameListener: RtcRemoteAudioFrameListener?
    private var nextAudioRemovalError: (any Error)?

    init(
        initializationError: (any Error)? = nil,
        initializationHandler: (@Sendable () async throws -> Void)? = nil,
        destroyHandler: (@Sendable () async -> Void)? = nil,
        encodingError: (any Error)? = nil,
        startAudioCaptureError: (any Error)? = nil,
        stopAudioCaptureError: (any Error)? = nil,
        publishLocalVideoError: (any Error)? = nil,
        unpublishLocalVideoError: (any Error)? = nil,
        publishLocalAudioError: (any Error)? = nil,
        unpublishLocalAudioError: (any Error)? = nil,
        subscribeRemoteVideoError: (any Error)? = nil,
        subscribeRemoteAudioError: (any Error)? = nil,
        setRemoteAudioVolumeError: (any Error)? = nil,
        joinRoomError: (any Error)? = nil,
        sendRoomMessageError: (any Error)? = nil,
        joinRoomHandler: JoinRoomHandler? = nil,
        leaveRoomHandler: LeaveRoomHandler? = nil,
        setRemoteVideoFrameListenerError: (any Error)? = nil,
        setRemoteAudioFrameListenerError: (any Error)? = nil
    ) {
        self.initializationError = initializationError
        self.initializationHandler = initializationHandler
        self.destroyHandler = destroyHandler
        self.encodingError = encodingError
        self.startAudioCaptureError = startAudioCaptureError
        self.stopAudioCaptureError = stopAudioCaptureError
        self.publishLocalVideoError = publishLocalVideoError
        self.unpublishLocalVideoError = unpublishLocalVideoError
        self.publishLocalAudioError = publishLocalAudioError
        self.unpublishLocalAudioError = unpublishLocalAudioError
        self.subscribeRemoteVideoError = subscribeRemoteVideoError
        self.subscribeRemoteAudioError = subscribeRemoteAudioError
        self.setRemoteAudioVolumeError = setRemoteAudioVolumeError
        self.joinRoomError = joinRoomError
        self.sendRoomMessageError = sendRoomMessageError
        self.joinRoomHandler = joinRoomHandler
        self.leaveRoomHandler = leaveRoomHandler
        self.setRemoteVideoFrameListenerError =
            setRemoteVideoFrameListenerError
        self.setRemoteAudioFrameListenerError = setRemoteAudioFrameListenerError
    }

    func setRoomMessageListener(_ listener: (@Sendable (String, Data) -> Void)?) {
        lock.withLock { roomMessageListener = listener }
    }

    func emitRoomMessage(sender: String, message: String) {
        let callback = lock.withLock { roomMessageListener }
        callback?(sender, Data(message.utf8))
    }

    var calls: [RtcManagingCall] {
        lock.withLock { storedCalls }
    }

    var encodingConfigurations: [VideoEncodingConfiguration] {
        calls.compactMap { call in
            guard case let .configureVideoEncoding(configuration) = call else {
                return nil
            }
            return configuration
        }
    }

    func initialize() async throws {
        try lock.withLock {
            storedCalls.append(.initialize)
            if let initializationError {
                throw initializationError
            }
        }
        try await initializationHandler?()
    }

    func destroy() async {
        lock.withLock {
            storedCalls.append(.destroy)
        }
        await destroyHandler?()
    }

    func configureVideoEncoding(
        _ configuration: VideoEncodingConfiguration
    ) throws {
        try lock.withLock {
            storedCalls.append(.configureVideoEncoding(configuration))
            if let encodingError {
                throw encodingError
            }
        }
    }

    func useExternalVideoSource() throws {
        lock.withLock {
            storedCalls.append(.useExternalVideoSource)
        }
    }

    func startAudioCapture() throws {
        try record(.startAudioCapture, error: startAudioCaptureError)
    }

    func stopAudioCapture() throws {
        try record(.stopAudioCapture, error: stopAudioCaptureError)
    }

    func startExternalAudioSource() throws {
        lock.withLock {
            storedCalls.append(.startExternalAudioSource)
        }
    }

    func stopExternalAudioSource() throws {
        lock.withLock {
            storedCalls.append(.stopExternalAudioSource)
        }
    }

    func configureLocalVideoMirror(
        for position: CameraPosition
    ) throws {
        lock.withLock { storedCalls.append(.configureLocalVideoMirror(position)) }
    }

    func pushExternalVideoFrame(_ frame: VideoFrame) throws {
        lock.withLock {
            storedCalls.append(.pushExternalVideoFrame)
        }
    }

    func pushExternalAudioFrame(_ frame: AudioFrame) throws {
        lock.withLock {
            storedCalls.append(.pushExternalAudioFrame(frame))
        }
    }

    func joinRoom(
        configuration: RoomJoinConfiguration
    ) async throws {
        try record(.joinRoom(configuration), error: joinRoomError)
        try await joinRoomHandler?(configuration)
    }

    func leaveRoom() async {
        lock.withLock {
            storedCalls.append(.leaveRoom)
        }
        await leaveRoomHandler?()
    }

    func publishLocalVideo() throws {
        try record(.publishLocalVideo, error: publishLocalVideoError)
    }

    func unpublishLocalVideo() throws {
        try record(.unpublishLocalVideo, error: unpublishLocalVideoError)
    }

    func publishLocalAudio() throws {
        try record(.publishLocalAudio, error: publishLocalAudioError)
    }

    func unpublishLocalAudio() throws {
        try record(.unpublishLocalAudio, error: unpublishLocalAudioError)
    }

    func subscribeRemoteVideo(
        userID: String,
        subscribe: Bool
    ) throws {
        try record(
            .subscribeRemoteVideo(userID: userID, subscribe: subscribe),
            error: subscribeRemoteVideoError
        )
    }

    func subscribeRemoteAudio(
        userID: String,
        subscribe: Bool
    ) throws {
        try record(
            .subscribeRemoteAudio(userID: userID, subscribe: subscribe),
            error: subscribeRemoteAudioError
        )
    }

    func setRemoteAudioVolume(
        _ volume: Int,
        for userID: String
    ) throws {
        try record(
            .setRemoteAudioVolume(volume, userID: userID),
            error: setRemoteAudioVolumeError
        )
    }

    func setRemoteVideoFrameListener(
        _ listener: RtcRemoteVideoFrameListener?,
        for stream: RemoteStream
    ) throws {
        try lock.withLock {
            storedCalls.append(
                .setRemoteVideoFrameListener(
                    stream,
                    enabled: listener != nil
                )
            )
            if let setRemoteVideoFrameListenerError {
                throw setRemoteVideoFrameListenerError
            }
            if let listener {
                storedRemoteVideoFrameStream = stream
                storedRemoteVideoFrameListener = listener
            } else if storedRemoteVideoFrameStream == stream {
                storedRemoteVideoFrameStream = nil
                storedRemoteVideoFrameListener = nil
            }
        }
    }

    func setRemoteAudioFrameListener(
        _ listener: RtcRemoteAudioFrameListener?,
        for stream: RemoteStream
    ) throws {
        try lock.withLock {
            storedCalls.append(.setRemoteAudioFrameListener(stream, enabled: listener != nil))
            if listener == nil, let error = nextAudioRemovalError {
                nextAudioRemovalError = nil
                throw error
            }
            if let setRemoteAudioFrameListenerError { throw setRemoteAudioFrameListenerError }
            if let listener {
                storedRemoteAudioFrameStream = stream
                storedRemoteAudioFrameListener = listener
            } else if storedRemoteAudioFrameStream == stream {
                storedRemoteAudioFrameStream = nil
                storedRemoteAudioFrameListener = nil
            }
        }
    }

    func emitRemoteAudioFrame(
        _ frame: RtcRemoteAudioFrame
    ) {
        let callback = lock.withLock { storedRemoteAudioFrameListener }
        callback?(frame)
    }

    func failNextAudioListenerRemoval(
        _ error: any Error
    ) {
        lock.withLock { nextAudioRemovalError = error }
    }

    @discardableResult
    func sendRoomMessage(
        _ message: String,
        reportFailure: Bool = true,
        replacingPendingMessage key: String? = nil
    ) throws -> Task<Void, any Error> {
        try lock.withLock {
            storedCalls.append(.sendRoomMessage(message))
            storedReplacementKeys.append(key)
            if let sendRoomMessageError {
                throw sendRoomMessageError
            }
        }
        let handler = commandSendHandler
        return Task { try await handler?() }
    }

    var replacementKeys: [String?] { lock.withLock { storedReplacementKeys } }
    var discardedKeys: [String?] { lock.withLock { storedDiscardedKeys } }

    func discardPendingMessages(key: String?) {
        lock.withLock { storedDiscardedKeys.append(key) }
    }

    func setSendRoomMessageError(_ error: (any Error)?) {
        lock.withLock {
            sendRoomMessageError = error
        }
    }

    func setEventListener(_ listener: (any RtcEventListener)?) {
        lock.withLock {
            storedEventListener = listener
        }
    }

    func awaitPendingMessages() async throws {
        try await flushHandler?()
    }

    func setQualityListener(_ listener: (any RtcQualityListener)?) {
        lock.withLock {
            storedQualityListener = listener
        }
    }
}

extension RtcManagingStub {
    @MainActor
    func emitRemoteVideoPublished(
        userID: String,
        published: Bool
    ) {
        let listener = lock.withLock { storedEventListener }
        listener?.onRemoteVideoPublished(
            userID: userID,
            published: published
        )
    }

    @MainActor
    func emitUplinkVideoStatistics(_ statistics: UplinkVideoStatistics) {
        let listener = lock.withLock { storedQualityListener }
        listener?.onUplinkVideoStatistics(statistics)
    }

    @MainActor
    func emitDownlinkVideoStatistics(_ statistics: DownlinkVideoStatistics) {
        let listener = lock.withLock { storedQualityListener }
        listener?.onDownlinkVideoStatistics(statistics)
    }

    @MainActor
    func emitNetworkQuality(
        uplink: RtcQualityLevel,
        downlink: RtcQualityLevel
    ) {
        let listener = lock.withLock { storedQualityListener }
        listener?.onNetworkQuality(
            uplink: uplink,
            downlink: downlink
        )
    }

    @MainActor
    func emitPerformanceAlarm(
        limited: Bool,
        suggestedWidth: Int,
        suggestedHeight: Int,
        suggestedFrameRate: Int
    ) {
        let listener = lock.withLock { storedQualityListener }
        listener?.onPerformanceAlarm(
            limited: limited,
            suggestedWidth: suggestedWidth,
            suggestedHeight: suggestedHeight,
            suggestedFrameRate: suggestedFrameRate
        )
    }

    @MainActor
    func emitRemoteVideoAvailable(stream: RemoteStream) {
        let listener = lock.withLock { storedEventListener }
        listener?.onRemoteVideoPublished(userID: stream.userID, published: true)
    }

    @MainActor
    func emitRtcFailure(_ error: XmaxError) {
        let listener = lock.withLock { storedEventListener }
        listener?.onRtcFailure(error)
    }

    @discardableResult
    func emitRemoteVideoFrame(
        width: Int = 16,
        height: Int = 16,
        presentationTimeStamp: CMTime = .zero
    ) throws -> CVPixelBuffer {
        let listener = lock.withLock { storedRemoteVideoFrameListener }
        guard let listener else {
            throw XmaxError(
                code: .internalError,
                message: "Remote video frame listener is unavailable"
            )
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw XmaxError(
                code: .internalError,
                message: "Failed to create a remote test video frame"
            )
        }
        listener(
            RealtimeVideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: presentationTimeStamp
            )
        )
        return pixelBuffer
    }
}

private extension RtcManagingStub {
    func record(
        _ call: RtcManagingCall,
        error: (any Error)?
    ) throws {
        try lock.withLock {
            storedCalls.append(call)
            if let error {
                throw error
            }
        }
    }
}
