//
//  RtcProvider.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The RTC transport selected for a realtime manager's lifetime.
public enum RtcProvider: String, Codable, CaseIterable, Sendable {

    /// Agora realtime audio and video.
    case agora

    /// Tencent Cloud realtime audio and video.
    case trtc

    /// The maximum encoding long edge, in pixels; `nil` leaves sizing to the media policy.
    var maximumEncodingLongEdge: Int? { self == .trtc ? 1920 : nil }

    /// The maximum encoding short edge, in pixels; `nil` leaves sizing to the media policy.
    var maximumEncodingShortEdge: Int? { self == .trtc ? 1080 : nil }

    /// The common width and height alignment used to preserve aspect ratio during adaptation.
    var encodingAlignment: Int { self == .trtc ? 8 : 4 }
}

/// Authentication fields kept distinct for each RTC provider.
enum RtcCredentials: Equatable, Sendable {

    /// An Agora channel token for the SDK's configured application.
    case agora(token: String)

    /// TRTC authentication and authorization for a string-ID room.
    case trtc(sdkAppID: UInt32, userSig: String, privateMapKey: String)

    /// The transport accepting these credentials.
    var provider: RtcProvider {
        switch self {
        case .agora: .agora
        case .trtc: .trtc
        }
    }
}
