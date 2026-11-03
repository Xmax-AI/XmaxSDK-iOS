//
//  QualityController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Converts RTC quality events and notifies realtime listeners.
final class QualityController: QualityControlling, RtcQualityListener,
    @unchecked Sendable
{

    /// The lock protecting quality listeners and statistics validity.
    private let listenerLock = NSLock()

    /// The uplink and downlink quality listener.
    private var networkQualityListener: RealtimeNetworkQualityListener?

    /// The local encoding performance alarm listener.
    private var performanceAlarmListener: RealtimePerformanceAlarmListener?

    /// The uplink video statistics listener.
    private var uplinkStatisticsListener: UplinkVideoStatisticsListener?

    /// The downlink video statistics listener.
    private var downlinkStatisticsListener: DownlinkVideoStatisticsListener?

    /// Whether uplink statistics are delivered.
    private var uplinkStatisticsEnabled = false

    /// The remote user for downlink statistics.
    private var downlinkStatisticsUser: String?

    /// The revision rejecting stale uplink callbacks.
    private var uplinkStatisticsVersion = 0

    /// The revision rejecting stale downlink callbacks.
    private var downlinkStatisticsVersion = 0

    /// The uplink sampling and adaptation policy.
    private var uplinkQuality: QualityDirection?

    /// The downlink sampling and adaptation policy.
    private var downlinkQuality: QualityDirection?

    /// The current model's quality history.
    private var history: QualityHistory?

    /// The network sample and timestamp handler.
    private var adaptiveListener: (@Sendable (RealtimeNetworkQuality, TimeInterval) -> Void)?

    /// The preferences storing quality history.
    private let historyDefaults: UserDefaults

    /// Creates a quality controller and registers RTC events.
    ///
    /// - Parameters:
    ///   - rtcManager: The RTC quality and media statistics provider.
    ///   - historyDefaults: The preferences storing model-specific quality history.
    init(
        rtcManager: any RtcManaging,
        historyDefaults: UserDefaults = .standard
    ) {
        self.historyDefaults = historyDefaults
        rtcManager.setQualityListener(self)
    }

    /// The current media baseline and quality levels.
    var qualityConfiguration: QualityConfiguration? {
        listenerLock.withLock {
            configuration()
        }
    }

    /// Prepares initial transport quality from the media baseline and model history.
    ///
    /// - Parameters:
    ///   - baseline: The resolved local media baseline, unchanged by adaptation.
    ///   - model: The model identifier isolating quality history.
    ///   - minimumInputPixels: The model's minimum uplink area, in pixels.
    ///   - isAdaptiveQualityEnabled: Whether to adapt quality. Disabled connections start at L1
    ///     without using history.
    ///
    /// - Returns: The initial directional quality configuration.
    func prepareQuality(
        baseline: RealtimeVideoFormat,
        model: String,
        minimumInputPixels: Int = 0,
        isAdaptiveQualityEnabled: Bool
    ) -> QualityConfiguration {
        listenerLock.withLock {
            let history =
                isAdaptiveQualityEnabled
                ? QualityHistory(
                    model: model,
                    defaults: historyDefaults
                )
                : nil
            self.history = history
            uplinkQuality = QualityDirection(
                baseline: baseline,
                level: history?.read(downlink: false) ?? .l1,
                downlink: false,
                minimumInputPixels: minimumInputPixels
            )
            downlinkQuality = QualityDirection(
                baseline: baseline,
                level: history?.read(downlink: true) ?? .l1,
                downlink: true
            )

            return configuration()!
        }
    }

    /// Sets the internal adaptation listener independently of your app's network listener.
    ///
    /// - Parameter listener: The quality and monotonic sample time handler, or `nil` to remove it.
    func setAdaptiveQualityListener(
        _ listener: (@Sendable (RealtimeNetworkQuality, TimeInterval) -> Void)?
    ) {
        listenerLock.withLock {
            adaptiveListener = listener
        }
    }

    /// Proposes quality levels without committing them.
    ///
    /// - Parameters:
    ///   - quality: The current directional network quality.
    ///   - sampledAt: The monotonic sample time, in seconds.
    ///
    /// - Returns: The candidate levels satisfying sample and cooldown requirements.
    func proposeQuality(
        _ quality: RealtimeNetworkQuality,
        sampledAt: TimeInterval
    ) -> QualityChange {
        listenerLock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            return QualityChange(
                uplink: uplinkQuality?.observe(
                    quality.uplink,
                    sampledAt: sampledAt,
                    now: now
                ),
                downlink: downlinkQuality?.observe(
                    quality.downlink,
                    sampledAt: sampledAt,
                    now: now
                )
            )
        }
    }

    /// Commits an adjustment result, persisting successful levels only.
    ///
    /// - Parameters:
    ///   - downlink: Whether this is downlink rather than uplink.
    ///   - level: The attempted quality level.
    ///   - success: Whether configuration succeeded.
    func completeQuality(
        downlink: Bool,
        level: RealtimeQualityLevel,
        success: Bool
    ) {
        listenerLock.withLock {
            let now = ProcessInfo.processInfo.systemUptime

            if downlink {
                downlinkQuality?.complete(
                    level: level,
                    success: success,
                    now: now
                )
            } else {
                uplinkQuality?.complete(
                    level: level,
                    success: success,
                    now: now
                )
            }

            if success {
                history?.write(
                    level: level,
                    downlink: downlink
                )
            }
        }
    }

    /// Clears consecutive samples collected while adaptation was unavailable.
    func resetQualitySamples() {
        listenerLock.withLock {
            uplinkQuality?.resetSamples()
            downlinkQuality?.resetSamples()
        }
    }

    /// Releases connection quality state and its internal sample listener.
    func resetQuality() {
        listenerLock.withLock {
            uplinkQuality = nil
            downlinkQuality = nil
            history = nil
            adaptiveListener = nil
        }
    }

    /// Returns configuration when both directions are prepared.
    ///
    /// - Returns: The baseline and levels, or `nil` if not prepared.
    private func configuration() -> QualityConfiguration? {
        guard let uplinkQuality, let downlinkQuality else {
            return nil
        }
        return QualityConfiguration(
            baseline: uplinkQuality.baseline,
            uplinkLevel: uplinkQuality.level,
            downlinkLevel: downlinkQuality.level,
            minimumInputPixels: uplinkQuality.minimumInputPixels
        )
    }

    /// Sets the uplink video statistics listener.
    ///
    /// - Parameter listener: The main-actor handler, receiving `nil` when unpublished or
    ///   disconnected. Pass `nil` to remove it.
    func setUplinkVideoStatisticsListener(
        _ listener: UplinkVideoStatisticsListener?
    ) {
        listenerLock.withLock {
            uplinkStatisticsVersion &+= 1
            uplinkStatisticsListener = listener
        }
    }

    /// Sets the downlink video statistics listener.
    ///
    /// - Parameter listener: The main-actor handler, receiving `nil` when the result stream clears.
    ///   Pass `nil` to remove it.
    func setDownlinkVideoStatisticsListener(
        _ listener: DownlinkVideoStatisticsListener?
    ) {
        listenerLock.withLock {
            downlinkStatisticsVersion &+= 1
            downlinkStatisticsListener = listener
        }
    }

    /// Updates uplink statistics availability and clears previous statistics.
    ///
    /// - Parameter enabled: Whether local video is published.
    func setUplinkVideoStatisticsEnabled(
        _ enabled: Bool
    ) {
        let version = listenerLock.withLock {
            uplinkStatisticsVersion &+= 1
            uplinkStatisticsEnabled = enabled
            return uplinkStatisticsVersion
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let listener = listenerLock.withLock {
                uplinkStatisticsVersion == version ? uplinkStatisticsListener : nil
            }
            listener?(nil)
        }
    }

    /// Changes the downlink statistics target and clears previous statistics.
    ///
    /// - Parameter userID: The result user identifier, or `nil` to stop delivery.
    func setDownlinkVideoStatisticsUser(
        _ userID: String?
    ) {
        let version = listenerLock.withLock {
            downlinkStatisticsVersion &+= 1
            downlinkStatisticsUser = userID
            return downlinkStatisticsVersion
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let listener = listenerLock.withLock {
                downlinkStatisticsVersion == version ? downlinkStatisticsListener : nil
            }
            listener?(nil)
        }
    }

    /// Receives local uplink video statistics.
    ///
    /// - Parameter statistics: The current uplink statistics.
    @MainActor
    func onUplinkVideoStatistics(
        _ statistics: UplinkVideoStatistics
    ) {
        let listener = listenerLock.withLock {
            uplinkStatisticsEnabled ? uplinkStatisticsListener : nil
        }
        listener?(statistics)
    }

    /// Receives remote downlink video statistics.
    ///
    /// - Parameter statistics: The current downlink statistics.
    @MainActor
    func onDownlinkVideoStatistics(
        _ statistics: DownlinkVideoStatistics
    ) {
        let listener = listenerLock.withLock {
            statistics.userID == downlinkStatisticsUser ? downlinkStatisticsListener : nil
        }
        listener?(statistics)
    }

    /// Sets the network quality listener.
    ///
    /// - Parameter listener: The main-actor quality handler, or `nil` to remove it.
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    ) {
        listenerLock.withLock {
            networkQualityListener = listener
        }
    }

    /// Sets the device performance alarm listener.
    ///
    /// - Parameter listener: The main-actor performance handler, or `nil` to remove it.
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    ) {
        listenerLock.withLock {
            performanceAlarmListener = listener
        }
    }

    /// Receives uplink and downlink network quality.
    ///
    /// - Parameters:
    ///   - uplink: The local sending direction's quality.
    ///   - downlink: The remote receiving direction's quality.
    @MainActor
    func onNetworkQuality(
        uplink: RtcQualityLevel,
        downlink: RtcQualityLevel
    ) {
        let listener = listenerLock.withLock {
            networkQualityListener
        }

        let quality = RealtimeNetworkQuality(
            uplink: Self.networkQualityLevel(uplink),
            downlink: Self.networkQualityLevel(downlink)
        )
        let adaptive = listenerLock.withLock {
            adaptiveListener
        }

        adaptive?(
            quality,
            ProcessInfo.processInfo.systemUptime
        )
        listener?(quality)
    }

    /// Receives performance limitation or recovery events.
    ///
    /// - Parameters:
    ///   - limited: Whether performance is currently limited.
    ///   - suggestedWidth: The suggested width, in pixels.
    ///   - suggestedHeight: The suggested height, in pixels.
    ///   - suggestedFrameRate: The suggested frame rate, in frames per second.
    @MainActor
    func onPerformanceAlarm(
        limited: Bool,
        suggestedWidth: Int,
        suggestedHeight: Int,
        suggestedFrameRate: Int
    ) {
        let listener = listenerLock.withLock {
            performanceAlarmListener
        }

        listener?(
            RealtimePerformanceAlarm(
                status: limited ? .limited : .recovered,
                suggestedVideoFormat: Self.suggestedVideoFormat(
                    width: suggestedWidth,
                    height: suggestedHeight,
                    frameRate: suggestedFrameRate
                )
            )
        )
    }
}

private extension QualityController {

    /// Maps RTC network quality to the public rating.
    ///
    /// - Parameter level: The RTC network quality rating.
    ///
    /// - Returns: The public network quality rating.
    static func networkQualityLevel(
        _ level: RtcQualityLevel
    ) -> RealtimeNetworkQualityLevel {
        switch level {
        case .unknown:
            .unknown
        case .excellent:
            .excellent
        case .good:
            .good
        case .poor:
            .poor
        case .bad:
            .bad
        case .veryBad:
            .veryBad
        case .down:
            .down
        }
    }

    /// Resolves a valid video format from a performance suggestion.
    ///
    /// - Parameters:
    ///   - width: The suggested width.
    ///   - height: The suggested height.
    ///   - frameRate: The suggested frame rate, in frames per second.
    ///
    /// - Returns: The suggested format if all values are positive, otherwise `nil`.
    static func suggestedVideoFormat(
        width: Int,
        height: Int,
        frameRate: Int
    ) -> RealtimeVideoFormat? {
        guard width > 0, height > 0, frameRate > 0 else {
            return nil
        }
        return RealtimeVideoFormat(
            width: width,
            height: height,
            fps: frameRate
        )
    }
}
