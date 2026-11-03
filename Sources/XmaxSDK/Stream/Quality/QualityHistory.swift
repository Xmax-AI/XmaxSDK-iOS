//
//  QualityHistory.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// The successfully applied model and directional levels retained for one hour.
struct QualityHistory {

    /// The model identifier isolating quality history.
    let model: String

    /// The preferences storing levels and timestamps.
    var defaults: UserDefaults = .standard

    /// Returns a valid level from the last hour for this model and direction.
    ///
    /// - Parameters:
    ///   - downlink: Whether to read downlink rather than uplink.
    ///   - now: The Unix time, in seconds.
    ///
    /// - Returns: The valid historical level, or L2 if missing, expired, or invalid.
    func read(
        downlink: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> RealtimeQualityLevel {
        let key = key(downlink)
        let savedAt = defaults.double(forKey: key + ".time")
        guard let level = RealtimeQualityLevel(rawValue: defaults.integer(forKey: key)),
            savedAt > 0, now >= savedAt, now - savedAt < 3600
        else {
            return .l2
        }
        return level
    }

    /// Persists a successfully applied model and directional level.
    ///
    /// - Parameters:
    ///   - level: The applied quality level.
    ///   - downlink: Whether to store downlink rather than uplink.
    ///   - now: The Unix time, in seconds.
    func write(
        level: RealtimeQualityLevel,
        downlink: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        defaults.set(
            level.rawValue,
            forKey: key(downlink)
        )
        defaults.set(
            now,
            forKey: key(downlink) + ".time"
        )
    }

    /// Creates a model-specific directional history key.
    ///
    /// - Parameter downlink: Whether this is the downlink direction.
    ///
    /// - Returns: The storage key for the model and direction.
    private func key(
        _ downlink: Bool
    ) -> String {
        "xmax.quality.agora.\(model).\(downlink ? "downlink" : "uplink")"
    }
}
