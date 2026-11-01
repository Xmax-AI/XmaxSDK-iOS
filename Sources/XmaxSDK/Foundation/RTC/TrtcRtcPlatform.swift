//
//  TrtcRtcPlatform.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
@preconcurrency import TXLiteAVSDK_TRTC

/// Adapts TRTC capture and encoding to the shared RTC frame pipeline.
final class TrtcRtcPlatform: RtcPlatform, @unchecked Sendable {

    /// The native engine protected by the exclusive RTC lease.
    let engine: TRTCCloud

    /// Serializes native operations with room state updates.
    let lock = NSRecursiveLock()

    /// The current room adapter.
    private weak var room: TrtcRtcRoom?

    /// Keeps the native exit observer alive until the previous room has left.
    private var exitObserver: TrtcRoomExitObserver?

    /// The next entry request, delayed until native room exit completes.
    private var pendingEntry: (() -> Void)?

    /// Whether native room teardown invalidated capture or encoding configuration.
    private var needsMediaRestoration = false

    /// Whether the retained local media source supplies custom video.
    private var usesExternalVideo = false

    /// The desired audio input for the retained local media source.
    private var audioSource = AudioSource.none

    /// The latest requested encoder settings, including changes made while exit is still pending.
    private var videoConfiguration: VideoEncodingConfiguration?

    /// Whether the active room currently publishes local audio.
    var publishesAudio = false

    /// Whether the active room currently publishes local video.
    var publishesVideo = false

    /// Whether front-camera pixels must be mirrored for publication.
    private var mirrored = false

    /// Maps the shared source timeline onto TRTC's native clock for audio/video synchronization.
    private var mediaClock = MediaClock()

    /// The last explicitly reusable input frame.
    private var cachedFrame: (id: UUID, frame: TrtcVideoFrame)?

    /// Creates a platform without starting camera or microphone capture.
    init(
        engine: TRTCCloud
    ) {
        self.engine = engine
        engine.delegateQueue = DispatchQueue(label: "ai.xmax.rtc.trtc.events")
        engine.setDefaultStreamRecvMode(false, video: false)
        engine.muteLocalVideo(.big, mute: true)
        engine.muteLocalAudio(true)
    }

    /// Creates TRTC without session credentials; authentication is supplied at room entry.
    static func create(
        appID: String
    ) -> (any RtcPlatform)? {
        TRTCCloud.setConsoleEnabled(false)
        TRTCCloud.setLogLevel(.warn)
        return TrtcRtcPlatform(engine: TRTCCloud.sharedInstance())
    }

    /// Destroys the native singleton after its exclusive lease is released.
    static func destroyEngine() {
        TRTCCloud.destroySharedInstance()
    }

    /// Applies exact SDK dimensions through TRTC's extended encoder parameters.
    func configureVideoEncoding(
        _ configuration: VideoEncodingConfiguration
    ) throws {
        let limits = RtcProvider.trtc
        guard configuration.width > 0, configuration.height > 0, configuration.frameRate > 0,
            configuration.width.isMultiple(of: limits.encodingAlignment),
            configuration.height.isMultiple(of: limits.encodingAlignment),
            max(configuration.width, configuration.height) <= limits.maximumEncodingLongEdge!,
            min(configuration.width, configuration.height) <= limits.maximumEncodingShortEdge!
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message:
                    "TRTC encoding dimensions must be 8-aligned with long edge <= 1920 and short edge <= 1080"
            )
        }
        try lock.withLock {
            let parameters: [String: Any] = [
                "api": "setVideoEncodeParamEx",
                "params": [
                    "videoWidth": max(configuration.width, configuration.height),
                    "videoHeight": min(configuration.width, configuration.height),
                    "videoFps": configuration.frameRate,
                    "videoBitrate": max(
                        1,
                        configuration.maximumBitrate > 0 ? configuration.maximumBitrate : 2000
                    ),
                    "minVideoBitrate": configuration.minimumBitrate,
                    "streamType": 0,
                    "resolutionMode": configuration.height > configuration.width ? 1 : 0,
                    "enableAdjustRes": false
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: parameters)
            let response = engine.callExperimentalAPI(String(decoding: data, as: UTF8.self))
            if let json = response.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                let code = object["code"] as? Int, code != 0
            {
                throw XmaxError(
                    code: .rtcError,
                    message: "TRTC rejected video encoding configuration (\(code))"
                )
            }
            let qos = TRTCNetworkQosParam()
            qos.preference =
                configuration.encoderPreference == .maintainFramerate ? .smooth : .clear
            engine.setNetworkQosParam(qos)
            videoConfiguration = configuration
        }
    }

    /// Enables SDK-owned external video and clears any previous mirror setting.
    func useExternalVideoSource() throws {
        lock.withLock {
            mirrored = false
            cachedFrame = nil
            mediaClock = MediaClock()
            usesExternalVideo = true
            engine.enableCustomVideoCapture(.big, enable: true)
            engine.muteLocalVideo(.big, mute: !publishesVideo)
        }
    }

    /// Mirrors camera pixels before native encoding.
    func configureLocalVideoMirror(
        for position: CameraPosition
    ) throws {
        lock.withLock {
            mirrored = position == .front
            cachedFrame = nil
        }
    }

    /// Selects microphone capture while retaining the current publication state.
    func startAudioCapture() throws {
        lock.withLock {
            engine.enableCustomAudioCapture(false)
            engine.startLocalAudio(.default)
            engine.muteLocalAudio(!publishesAudio)
            audioSource = .microphone
        }
    }

    /// Stops native microphone capture.
    func stopAudioCapture() throws {
        lock.withLock {
            engine.stopLocalAudio()
            if audioSource == .microphone { audioSource = .none }
        }
    }

    /// Selects custom PCM input without microphone capture.
    func startExternalAudioSource() throws {
        lock.withLock {
            engine.stopLocalAudio()
            engine.enableCustomAudioCapture(true)
            engine.muteLocalAudio(!publishesAudio)
            audioSource = .external
        }
    }

    /// Disables custom PCM input.
    func stopExternalAudioSource() throws {
        lock.withLock {
            engine.enableCustomAudioCapture(false)
            if audioSource == .external { audioSource = .none }
        }
    }

    /// Submits an owned frame, retaining its pixel buffer through the native call.
    func pushExternalVideoFrame(
        _ frame: VideoFrame
    ) throws {
        try lock.withLock {
            let converted: TrtcVideoFrame
            if let id = frame.bufferReuseID, let cachedFrame, cachedFrame.id == id {
                converted = cachedFrame.frame
                converted.updateMetadata(frame)
            } else {
                converted = try TrtcVideoFrame(frame: frame, mirrored: mirrored)
                cachedFrame = frame.bufferReuseID.map { ($0, converted) }
            }
            converted.value.timestamp = mediaClock.timestamp(
                sourceUs: frame.timestampUs,
                nativeNowMs: TRTCCloud.generateCustomPTS()
            )
            withExtendedLifetime(converted) {
                engine.sendCustomVideoData(.big, frame: converted.value)
            }
        }
    }

    /// Submits 10 ms mono PCM with the shared media timestamp converted to milliseconds.
    func pushExternalAudioFrame(
        _ frame: AudioFrame
    ) throws {
        guard frame.timestampUs >= 0, frame.data.count == AudioFrame.samplesPerFrame * 2 else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Invalid TRTC external audio frame"
            )
        }
        lock.withLock {
            let value = TRTCAudioFrame()
            value.data = frame.data
            value.sampleRate = .rate48000
            value.channels = 1
            value.timestamp = mediaClock.timestamp(
                sourceUs: frame.timestampUs,
                nativeNowMs: TRTCCloud.generateCustomPTS()
            )
            engine.sendCustomAudioData(value)
        }
    }

    /// Defers room entry until TRTC confirms that the previous room has left.
    func enterWhenReady(
        _ entry: @escaping () -> Void
    ) {
        lock.withLock {
            if exitObserver == nil { entry() } else { pendingEntry = entry }
        }
    }

    /// Observes native exit without retaining the old room or allowing its callbacks into a new room.
    func leaveNativeRoom() {
        lock.withLock {
            guard exitObserver == nil else { return }
            needsMediaRestoration = true
            let observer = TrtcRoomExitObserver { [weak self] in self?.finishNativeExit() }
            exitObserver = observer
            engine.addDelegate(observer)
            engine.exitRoom()
        }
    }

    /// Releases the exit observer and starts the still-valid pending entry.
    private func finishNativeExit() {
        lock.withLock {
            guard let observer = exitObserver else { return }
            engine.removeDelegate(observer)
            exitObserver = nil
            let entry = pendingEntry
            pendingEntry = nil
            entry?()
        }
    }

    /// Restores retained media only after the previous native room has fully released its resources.
    ///
    /// Reconnection setup can race with native exit, so replay the latest desired state immediately
    /// before entering the next room rather than relying on settings applied during teardown.
    func restoreMediaForRoomEntry() throws {
        try lock.withLock {
            guard needsMediaRestoration else { return }
            engine.muteLocalVideo(.big, mute: true)
            engine.muteLocalAudio(true)
            if usesExternalVideo {
                engine.enableCustomVideoCapture(.big, enable: true)
            }
            switch audioSource {
            case .none:
                engine.stopLocalAudio()
                engine.enableCustomAudioCapture(false)
            case .microphone:
                engine.enableCustomAudioCapture(false)
                engine.startLocalAudio(.default)
            case .external:
                engine.stopLocalAudio()
                engine.enableCustomAudioCapture(true)
            }
            if let videoConfiguration {
                try configureVideoEncoding(videoConfiguration)
            }
            engine.muteLocalAudio(true)
            mediaClock = MediaClock()
            needsMediaRestoration = false
        }
    }

    /// The local audio input retained across RTC room connections.
    private enum AudioSource {

        /// No microphone or custom PCM input is requested.
        case none

        /// Native microphone capture is requested.
        case microphone

        /// External PCM input is requested.
        case external
    }

    /// Anchors both custom media tracks to the same native millisecond timeline.
    struct MediaClock {

        /// The source and native timestamps observed at first submission.
        private var origin: (sourceMs: Int64, nativeMs: UInt64)?

        /// Preserves relative source timing, including audio arriving before an earlier video frame.
        mutating func timestamp(
            sourceUs: Int64,
            nativeNowMs: UInt64
        ) -> UInt64 {
            let sourceMs = sourceUs / 1000
            if origin == nil { origin = (sourceMs, max(1, nativeNowMs)) }
            let origin = origin!
            let delta = sourceMs - origin.sourceMs
            if delta >= 0 { return origin.nativeMs + UInt64(delta) }
            return origin.nativeMs - min(origin.nativeMs - 1, UInt64(-delta))
        }
    }

    /// Creates one room adapter for this engine lease.
    func createRoom(
        roomID: String
    ) throws -> any RtcRoom {
        try lock.withLock {
            guard room == nil || room?.isClosed == true else {
                throw XmaxError(code: .rtcError, message: "TRTC room already exists")
            }
            let room = TrtcRtcRoom(platform: self, roomID: roomID)
            self.room = room
            return room
        }
    }
}

/// Observes only completion of native teardown, independent of a room's invalidated listeners.
private final class TrtcRoomExitObserver: NSObject, TRTCCloudDelegate {

    /// Resumes any pending entry after native exit.
    private let completion: () -> Void

    /// Creates a teardown observer.
    init(
        completion: @escaping () -> Void
    ) {
        self.completion = completion
    }

    /// Completes teardown regardless of the native exit reason.
    func onExitRoom(
        _ reason: Int
    ) {
        completion()
    }
}
