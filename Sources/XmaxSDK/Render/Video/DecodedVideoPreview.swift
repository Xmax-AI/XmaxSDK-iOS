//
//  DecodedVideoPreview.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Presents decoded frames in an attached SDK video view.
@MainActor
final class DecodedVideoPreviewPresenter {

    /// The local preview video view.
    private weak var view: XmaxRealtimeVideoView?

    /// The local video content mode.
    private var contentMode = VideoContentMode.fill

    /// Whether local preview is horizontally mirrored.
    private var mirrored = false

    /// Attaches a video view with its content mode and mirror setting.
    ///
    /// - Parameters:
    ///   - view: The SDK video view receiving decoded frames.
    ///   - contentMode: The video content mode.
    func attach(
        to view: XmaxRealtimeVideoView,
        contentMode: VideoContentMode
    ) {
        self.view = view
        self.contentMode = contentMode
        view.prepareDecodedVideoPreview(contentMode: contentMode)
        view.setDecodedVideoPreviewMirrored(mirrored)
    }

    /// Clears and detaches decoded preview from a view.
    ///
    /// - Parameter view: The view to detach.
    func detach(
        from view: XmaxRealtimeVideoView
    ) {
        view.clearDecodedVideoPreview()
        if self.view === view {
            self.view = nil
        }
    }

    /// Presents a decoded frame in the attached view.
    ///
    /// - Parameter frame: The video frame to display.
    func display(
        _ frame: VideoFrame
    ) {
        view?.displayDecodedVideoFrame(
            frame,
            contentMode: contentMode
        )
    }

    /// Updates preview mirroring.
    ///
    /// - Parameter mirrored: Whether to mirror video horizontally.
    func setMirrored(
        _ mirrored: Bool
    ) {
        self.mirrored = mirrored
        view?.setDecodedVideoPreviewMirrored(mirrored)
    }

    /// Clears preview and releases the view binding.
    func clear() {
        view?.clearDecodedVideoPreview()
        view = nil
    }
}

/// Coalesces pending preview frames, retaining only the latest.
final class DecodedVideoPreviewDispatcher: @unchecked Sendable {

    /// The video preview presenter.
    private let presenter: DecodedVideoPreviewPresenter

    /// The lock protecting pending frames and main-actor delivery.
    private let lock = NSLock()

    /// The latest frame awaiting main-actor delivery.
    private var pendingFrame: VideoFrame?

    /// Whether a main-actor delivery is pending.
    private var isDeliveryScheduled = false

    /// Creates a coalescing preview frame dispatcher.
    init(
        presenter: DecodedVideoPreviewPresenter
    ) {
        self.presenter = presenter
    }

    /// Submits the latest frame for main-actor preview.
    ///
    /// - Parameter frame: The latest displayable video frame.
    func enqueue(
        _ frame: VideoFrame
    ) {
        let shouldSchedule = lock.withLock { () -> Bool in
            pendingFrame = frame
            guard !isDeliveryScheduled else {
                return false
            }
            isDeliveryScheduled = true
            return true
        }
        if shouldSchedule {
            scheduleDelivery()
        }
    }

    /// Discards a pending preview frame.
    func reset() {
        lock.withLock {
            pendingFrame = nil
        }
    }

    /// Schedules main-actor frame delivery.
    private func scheduleDelivery() {
        Task { @MainActor [weak self] in
            self?.deliverLatestFrame()
        }
    }

    /// Presents the latest pending frame.
    @MainActor
    private func deliverLatestFrame() {
        let frame = lock.withLock { () -> VideoFrame? in
            let frame = pendingFrame
            pendingFrame = nil
            return frame
        }
        if let frame {
            presenter.display(frame)
        }

        let shouldScheduleAgain = lock.withLock { () -> Bool in
            if pendingFrame == nil {
                isDeliveryScheduled = false
                return false
            }
            return true
        }
        if shouldScheduleAgain {
            scheduleDelivery()
        }
    }
}
