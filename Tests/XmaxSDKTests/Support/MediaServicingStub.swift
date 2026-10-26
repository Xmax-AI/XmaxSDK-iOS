//
//  MediaServicingStub.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
import Foundation
@testable import XmaxSDK

final class MediaServicingStub: MediaServicing, @unchecked Sendable {

    // 测试配置
    let model: RealtimeModel
    private let resolvedSize: CGSize
    private let resolvedGenerationSize: CGSize?
    private let resolutionError: (any Error)?
    private let frameInterpolationSupported: Bool

    // 并发状态
    private let lock = NSLock()
    private var storedRequestedSizes: [CGSize] = []

    init(
        resolvedSize: CGSize,
        resolvedGenerationSize: CGSize? = nil,
        model: RealtimeModel = .x2_1,
        resolutionError: (any Error)? = nil,
        frameInterpolationSupported: Bool = false
    ) {
        self.resolvedSize = resolvedSize
        self.resolvedGenerationSize = resolvedGenerationSize
        self.model = model
        self.resolutionError = resolutionError
        self.frameInterpolationSupported = frameInterpolationSupported
    }

    var requestedSizes: [CGSize] {
        lock.withLock { storedRequestedSizes }
    }

    func resolveMediaSize(_ sourceMediaSize: CGSize, source: RealtimeMediaSource) throws -> CGSize {
        try lock.withLock {
            storedRequestedSizes.append(sourceMediaSize)
            if let resolutionError {
                throw resolutionError
            }
            return source == .camera ? resolvedSize : try MediaService(model: model).resolveMediaSize(sourceMediaSize, source: source)
        }
    }

    func resolveGenerationSize(
        _ resolvedMediaSize: CGSize
    ) throws -> CGSize {
        if let resolvedGenerationSize {
            return resolvedGenerationSize
        }
        return try MediaService(model: model).resolveGenerationSize(resolvedMediaSize)
    }

    func resolveTargetSize(_ resolvedMediaSize: CGSize, maximumSize: CGSize, frameInterpolationEnabled: Bool) throws -> CGSize {
        try MediaService(model: model).resolveTargetSize(
            resolvedMediaSize,
            maximumSize: maximumSize,
            frameInterpolationEnabled: frameInterpolationEnabled
        )
    }

    func supportsFrameInterpolation(for size: CGSize) -> Bool {
        frameInterpolationSupported
    }
}
