//
//  XmaxRealtimeVideoView.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import UIKit

/// A UIKit view displaying a single local or remote video track.
///
/// Portrait-landscape window changes disconnect a local track's realtime session while retaining
/// preview.
@MainActor
public final class XmaxRealtimeVideoView: UIView {

    /// The shared context converting image frames for display.
    private static let imageContext = CIContext()

    /// The displayed video track.
    public var track: RealtimeVideoTrack? {
        didSet {
            guard oldValue !== track else {
                return
            }
            displayOrientation = nil
            detach(track: oldValue)
            attachCurrentTrackIfNeeded()
            updateOrientationObservation()
            updateWindowOrientation()
        }
    }

    /// The video content mode.
    public var videoContentMode: VideoContentMode = .fill {
        didSet {
            guard oldValue != videoContentMode else {
                return
            }
            attachCurrentTrackIfNeeded()
        }
    }

    /// Whether remote trajectory interaction is enabled.
    ///
    /// Interaction defaults to enabled; trajectories are sent only during generation.
    public var isInteractionEnabled = true {
        didSet {
            guard oldValue != isInteractionEnabled else {
                return
            }
            trajectoryOverlayView.setRequestedInteractionEnabled(
                isInteractionEnabled
            )
        }
    }

    /// The custom trajectory effect, or `nil` for the built-in effect.
    ///
    /// Custom rendering changes appearance only, not sampling, coordinate mapping, or signaling.
    public var trajectoryRenderer: (any TrajectoryEffectRendering)? {
        get {
            customTrajectoryRenderer
        }
        set {
            customTrajectoryRenderer = newValue
            trajectoryOverlayView.setRenderer(
                newValue ?? DefaultTrajectoryEffectRenderer()
            )
        }
    }

    /// The track attached for rendering.
    private weak var attachedTrack: RealtimeVideoTrack?

    /// The track attached for trajectory interaction.
    private weak var attachedTrajectoryTrack: RealtimeVideoTrack?

    /// The view's trajectory interaction binding.
    private var attachedTrajectoryBinding: TrajectoryBinding?

    /// The custom trajectory renderer.
    private var customTrajectoryRenderer: (any TrajectoryEffectRendering)?

    /// The internal handler after a valid frame is submitted.
    var frameDisplayHandler: (() -> Void)?

    /// The window's current interface orientation.
    private(set) var displayOrientation: UIInterfaceOrientation?

    /// The window orientation observer.
    private var orientationObserver: VideoOrientationObserver?

    /// The decoded frame display layer.
    private var decodedVideoLayer: AVSampleBufferDisplayLayer?

    /// The decoded preview playback timebase.
    private var decodedVideoTimebase: CMTimebase?

    /// The next decoded frame's presentation time.
    private var nextDecodedVideoPresentationTime = CMTime.invalid

    /// The reusable local preview pixel pool.
    private var localPreviewPixelBufferPool: CVPixelBufferPool?

    /// The current local preview frame format.
    private var localPreviewFormat: VideoFormat?

    /// The reusable preview media format description.
    private var localPreviewFormatDescription: CMVideoFormatDescription?

    /// The local image preview.
    private lazy var imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.isHidden = true
        return imageView
    }()

    /// The touch capture and trajectory overlay.
    private lazy var trajectoryOverlayView: TrajectoryOverlayView = {
        let overlayView = TrajectoryOverlayView(
            renderer: DefaultTrajectoryEffectRenderer()
        )
        overlayView.frame = bounds
        overlayView.autoresizingMask = [
            .flexibleWidth,
            .flexibleHeight,
        ]
        overlayView.setRequestedInteractionEnabled(isInteractionEnabled)
        return overlayView
    }()

    /// Creates a video rendering container.
    ///
    /// - Parameters:
    ///   - track: The video track to display, which may be set later.
    ///   - videoContentMode: The video content mode.
    ///   - isInteractionEnabled: Whether remote trajectory interaction is enabled.
    public init(
        track: RealtimeVideoTrack? = nil,
        videoContentMode: VideoContentMode = .fill,
        isInteractionEnabled: Bool = true
    ) {
        self.track = track
        self.videoContentMode = videoContentMode
        self.isInteractionEnabled = isInteractionEnabled
        super.init(frame: .zero)
        configureView()
    }

    /// Creates a video rendering container with a frame.
    ///
    /// - Parameter frame: The initial view frame.
    public override init(
        frame: CGRect
    ) {
        track = nil
        super.init(frame: frame)
        configureView()
    }

    /// Creates a video rendering container from an archive.
    ///
    /// - Parameter coder: The archive decoder.
    public required init?(
        coder: NSCoder
    ) {
        track = nil
        super.init(coder: coder)
        configureView()
    }

    /// Updates track bindings and orientation observation on window attachment.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        displayOrientation = nil
        if window == nil {
            detachCurrentTrack()
        } else {
            attachCurrentTrackIfNeeded()
        }
        updateOrientationObservation()
        updateWindowOrientation()
    }

    /// Updates video and interaction layout for the window.
    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        decodedVideoLayer?.frame = bounds
        CATransaction.commit()
        trajectoryOverlayView.frame = bounds
        bringSubviewToFront(trajectoryOverlayView)
        updateWindowOrientation()
    }
}

extension XmaxRealtimeVideoView {

    /// Updates orientation observation for the track and owning controller.
    private func updateOrientationObservation() {
        var responder: UIResponder? = next
        while responder != nil && !(responder is UIViewController) {
            responder = responder?.next
        }
        let parent =
            window != nil && track?.orientationChangeHandler != nil
            ? responder as? UIViewController : nil
        guard orientationObserver?.parent !== parent else {
            return
        }

        if let observer = orientationObserver {
            observer.willMove(toParent: nil)
            observer.view.removeFromSuperview()
            observer.removeFromParent()
            orientationObserver = nil
        }
        guard let parent else {
            return
        }

        let observer = VideoOrientationObserver(videoView: self)
        orientationObserver = observer
        parent.addChild(observer)
        observer.view.frame = bounds
        observer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(observer.view)
        observer.didMove(toParent: parent)
    }

    /// Synchronizes window orientation outside rotation transitions.
    func updateWindowOrientation() {
        guard orientationObserver?.isTransitioning != true, let scene = window?.windowScene else {
            return
        }
        if #available(iOS 26.0, *) {
            updateInterfaceOrientation(scene.effectiveGeometry.interfaceOrientation)
        } else {
            updateInterfaceOrientation(scene.interfaceOrientation)
        }
    }

    /// Updates track orientation and reports portrait-landscape changes.
    ///
    /// - Parameter orientation: The target interface orientation. Unknown orientations are ignored.
    func updateInterfaceOrientation(
        _ orientation: UIInterfaceOrientation
    ) {
        let next: CameraOrientation
        switch orientation {
        case .portrait:
            next = .portrait
        case .portraitUpsideDown:
            next = .portraitUpsideDown
        case .landscapeLeft:
            next = .landscapeLeft
        case .landscapeRight:
            next = .landscapeRight
        default:
            return
        }

        guard orientation != displayOrientation else {
            return
        }

        let changedAxis =
            displayOrientation.map {
                $0.isLandscape != next.isLandscape
            } ?? false
        displayOrientation = orientation
        track?.displayOrientation = next
        track?.orientationChangeHandler?(changedAxis)
    }

    /// Configures the video and trajectory container.
    func configureView() {
        backgroundColor = .black
        clipsToBounds = true
        addSubview(imageView)
        addSubview(trajectoryOverlayView)
    }

    /// Displays an image frame in static preview.
    ///
    /// - Parameters:
    ///   - frame: The BGRA or NV12 image frame.
    ///   - contentMode: The image content mode.
    ///
    /// - Throws: An error if frame layout is invalid or image creation fails.
    func displayImageFrame(
        _ frame: VideoFrame,
        contentMode: VideoContentMode
    ) throws {
        imageView.image = try Self.makeImage(frame)
        imageView.contentMode = contentMode == .fit ? .scaleAspectFit : .scaleAspectFill
        imageView.isHidden = false
        bringSubviewToFront(imageView)
        bringSubviewToFront(trajectoryOverlayView)
        frameDisplayHandler?()
    }

    /// Clears and hides image preview.
    func clearImageFrame() {
        imageView.image = nil
        imageView.isHidden = true
    }

    /// Prepares the decoded video layer and display clock.
    ///
    /// - Parameter contentMode: The video content mode.
    func prepareDecodedVideoPreview(
        contentMode: VideoContentMode
    ) {
        // Disables implicit transitions for the video layer and its content.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
        }

        let decodedVideoLayer: AVSampleBufferDisplayLayer
        if let currentLayer = self.decodedVideoLayer {
            decodedVideoLayer = currentLayer
        } else {
            decodedVideoLayer = AVSampleBufferDisplayLayer()
            // Apply rotation layout directly without additional layer scaling or flipping animations.
            decodedVideoLayer.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "transform": NSNull(),
                "videoGravity": NSNull()
            ]
            decodedVideoLayer.frame = bounds
            layer.insertSublayer(
                decodedVideoLayer,
                at: 0
            )
            self.decodedVideoLayer = decodedVideoLayer

            var timebase: CMTimebase?
            let status = CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &timebase
            )
            if status == noErr, let timebase {
                CMTimebaseSetTime(
                    timebase,
                    time: .zero
                )
                CMTimebaseSetRate(
                    timebase,
                    rate: 1
                )
                decodedVideoLayer.controlTimebase = timebase
                decodedVideoTimebase = timebase
            }
        }

        decodedVideoLayer.videoGravity = contentMode == .fit ? .resizeAspect : .resizeAspectFill
    }

    /// Sets decoded preview mirroring.
    ///
    /// - Parameter mirrored: Whether to mirror video horizontally.
    func setDecodedVideoPreviewMirrored(
        _ mirrored: Bool
    ) {
        decodedVideoLayer?.setAffineTransform(
            CGAffineTransform(
                scaleX: mirrored ? -1 : 1,
                y: 1
            )
        )
    }

    /// Submits a local NV12 or BGRA frame for immediate preview.
    ///
    /// - Parameters:
    ///   - frame: The local video frame to display.
    ///   - contentMode: The video content mode.
    func displayDecodedVideoFrame(
        _ frame: VideoFrame,
        contentMode: VideoContentMode
    ) {
        // Apply new dimensions and content mode without animating frame position or size.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
        }

        if decodedVideoLayer == nil {
            prepareDecodedVideoPreview(contentMode: contentMode)
        }
        guard let decodedVideoLayer, let decodedVideoTimebase else {
            return
        }
        decodedVideoLayer.videoGravity = contentMode == .fit ? .resizeAspect : .resizeAspectFill
        if decodedVideoLayer.requiresFlushToResumeDecoding {
            decodedVideoLayer.flush()
        }

        do {
            let pixelBuffer = try makeLocalPreviewPixelBuffer(frame)
            let formatDescription = try localPreviewDescription(for: pixelBuffer)
            let presentationTime = CMTimebaseGetTime(decodedVideoTimebase)
            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: presentationTime,
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            guard
                CMSampleBufferCreateReadyWithImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: pixelBuffer,
                    formatDescription: formatDescription,
                    sampleTiming: &timing,
                    sampleBufferOut: &sampleBuffer
                ) == noErr,
                let sampleBuffer
            else {
                throw Self.invalidImageFrameError
            }

            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_DisplayImmediately,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
            decodedVideoLayer.enqueue(sampleBuffer)
            frameDisplayHandler?()
        } catch {
            Self.logRenderingFailure(
                title: "显示本地视频帧失败 (Failed to Display Local Video Frame)",
                error: error
            )
        }
    }

    /// Schedules a remote frame using its duration.
    ///
    /// - Parameters:
    ///   - frame: The processed remote video frame.
    ///   - contentMode: The video content mode.
    func displayRemoteVideoFrame(
        _ frame: RealtimeVideoFrame,
        contentMode: VideoContentMode
    ) {
        if decodedVideoLayer == nil {
            prepareDecodedVideoPreview(contentMode: contentMode)
        }
        guard let decodedVideoLayer, let decodedVideoTimebase else {
            return
        }
        decodedVideoLayer.videoGravity = contentMode == .fit ? .resizeAspect : .resizeAspectFill
        if decodedVideoLayer.requiresFlushToResumeDecoding {
            decodedVideoLayer.flush()
            nextDecodedVideoPresentationTime = .invalid
        }

        var formatDescription: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescriptionOut: &formatDescription
            ) == noErr,
            let formatDescription
        else {
            return
        }

        let currentTime = CMTimebaseGetTime(decodedVideoTimebase)
        let presentationTime: CMTime
        if nextDecodedVideoPresentationTime.isValid, nextDecodedVideoPresentationTime >= currentTime {
            presentationTime = nextDecodedVideoPresentationTime
        } else {
            presentationTime = currentTime
        }

        let duration =
            frame.duration.isValid && frame.duration > .zero
            ? frame.duration
            : CMTime(
                value: 1,
                timescale: 24
            )
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ) == noErr,
            let sampleBuffer
        else {
            return
        }

        decodedVideoLayer.enqueue(sampleBuffer)
        nextDecodedVideoPresentationTime = presentationTime + duration
        frameDisplayHandler?()
    }

    /// Releases the video layer, display clock, and preview buffers.
    func clearDecodedVideoPreview() {
        decodedVideoLayer?.flushAndRemoveImage()
        decodedVideoLayer?.controlTimebase = nil
        decodedVideoLayer?.removeFromSuperlayer()
        decodedVideoLayer = nil
        decodedVideoTimebase = nil
        nextDecodedVideoPresentationTime = .invalid
        localPreviewPixelBufferPool = nil
        localPreviewFormat = nil
        localPreviewFormatDescription = nil
    }

    /// Attaches rendering and interaction when the view has a window.
    func attachCurrentTrackIfNeeded() {
        guard window != nil, let track else {
            return
        }

        if let binding = VideoRenderRegistry.binding(for: track) {
            do {
                try binding.attach(
                    to: self,
                    contentMode: videoContentMode
                )
                attachedTrack = track
            } catch {
                attachedTrack = nil
                Self.logRenderingFailure(
                    title: "绑定视频渲染视图失败 (Failed to Attach Video Render View)",
                    error: error
                )
            }
        }

        if let trajectoryBinding = TrajectoryRegistry.binding(for: track) {
            trajectoryBinding.attach(
                to: trajectoryOverlayView,
                contentMode: videoContentMode
            )
            attachedTrajectoryTrack = track
            attachedTrajectoryBinding = trajectoryBinding
        }
        bringSubviewToFront(trajectoryOverlayView)
    }

    /// Detaches a track's rendering and interaction from this view.
    ///
    /// - Parameter track: The track to detach, or `nil` for no operation.
    func detach(
        track: RealtimeVideoTrack?
    ) {
        guard let track else {
            return
        }

        if attachedTrack === track {
            do {
                try VideoRenderRegistry.binding(for: track)?.detach(from: self)
            } catch {
                Self.logRenderingFailure(
                    title: "解除视频渲染视图失败 (Failed to Detach Video Render View)",
                    error: error
                )
            }
            attachedTrack = nil
        }

        if attachedTrajectoryTrack === track {
            attachedTrajectoryBinding?.detach(
                from: trajectoryOverlayView
            )
            attachedTrajectoryTrack = nil
            attachedTrajectoryBinding = nil
        }
    }

    /// Detaches all video and interaction bindings.
    func detachCurrentTrack() {
        let renderTrack = attachedTrack
        let trajectoryTrack = attachedTrajectoryTrack
        detach(track: renderTrack)
        if trajectoryTrack !== renderTrack {
            detach(track: trajectoryTrack)
        }
    }

    /// Logs a rendering failure.
    ///
    /// - Parameters:
    ///   - title: The bilingual log title.
    ///   - error: The rendering error to log.
    static func logRenderingFailure(
        title: String,
        error: any Error
    ) {
        XmaxLogger.render.error(
            message: "\(title)\n└─ \(XmaxLogger.localized("原因：", "Reason: "))"
                + (error as NSError).localizedDescription
        )
    }

    /// Converts a BGRA or NV12 frame to a UIKit image.
    ///
    /// - Parameter frame: The image frame to convert.
    ///
    /// - Returns: The image containing the frame's pixels.
    ///
    /// - Throws: An error if pixel format or layout is invalid or image creation fails.
    static func makeImage(
        _ frame: VideoFrame
    ) throws -> UIImage {
        if frame.format.pixelFormat == .nv12 {
            return try makeNV12Image(frame)
        }

        let width = frame.format.width
        let height = frame.format.height
        let (minimumBytesPerRow, rowByteCountOverflow) =
            width
            .multipliedReportingOverflow(by: 4)
        guard frame.planes.count == 1 else {
            throw Self.invalidImageFrameError
        }

        let plane = frame.planes[0]
        let (requiredByteCount, byteCountOverflow) = plane.stride
            .multipliedReportingOverflow(by: height)
        guard frame.format.pixelFormat == .bgra,
            width > 0,
            height > 0,
            !rowByteCountOverflow,
            plane.stride >= minimumBytesPerRow,
            plane.byteOffset == 0,
            !byteCountOverflow,
            plane.byteLength >= requiredByteCount,
            plane.data.count >= requiredByteCount,
            let provider = CGDataProvider(
                data: plane.data as CFData
            )
        else {
            throw Self.invalidImageFrameError
        }

        let bitmapInfo =
            CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: plane.stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            throw XmaxError(
                code: .mediaError,
                message: "Failed to create the image preview"
            )
        }

        return UIImage(cgImage: image)
    }

    /// Converts an NV12 frame to a UIKit image.
    ///
    /// - Parameter frame: The biplanar NV12 frame.
    ///
    /// - Returns: The converted image.
    ///
    /// - Throws: An error if buffer conversion or image creation fails.
    static func makeNV12Image(
        _ frame: VideoFrame
    ) throws -> UIImage {
        let width = frame.format.width
        let height = frame.format.height
        let pixelBuffer = try makeNV12PixelBuffer(frame)

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard
            let cgImage = imageContext.createCGImage(
                image,
                from: CGRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: height
                )
            )
        else {
            throw invalidImageFrameError
        }

        return UIImage(cgImage: cgImage)
    }

    /// Creates a preview buffer matching the frame format.
    ///
    /// - Parameter frame: The local NV12 or BGRA frame to copy.
    ///
    /// - Returns: The buffer containing the frame's pixels.
    ///
    /// - Throws: An error if pool creation or pixel copying fails.
    func makeLocalPreviewPixelBuffer(
        _ frame: VideoFrame
    ) throws -> CVPixelBuffer {
        let pixelFormat: OSType
        switch frame.format.pixelFormat {
        case .nv12:
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .bgra:
            pixelFormat = kCVPixelFormatType_32BGRA
        default:
            throw Self.invalidImageFrameError
        }

        if localPreviewFormat != frame.format || localPreviewPixelBufferPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: frame.format.width,
                kCVPixelBufferHeightKey as String: frame.format.height,
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
            ]
            var pool: CVPixelBufferPool?
            guard
                CVPixelBufferPoolCreate(
                    kCFAllocatorDefault,
                    nil,
                    attributes as CFDictionary,
                    &pool
                ) == kCVReturnSuccess,
                let pool
            else {
                throw Self.invalidImageFrameError
            }

            localPreviewPixelBufferPool = pool
            localPreviewFormat = frame.format
            localPreviewFormatDescription = nil
        }

        if frame.format.pixelFormat == .bgra {
            return try Self.makeBGRAPixelBuffer(
                frame,
                pool: localPreviewPixelBufferPool
            )
        }
        return try Self.makeNV12PixelBuffer(
            frame,
            pool: localPreviewPixelBufferPool
        )
    }

    /// Copies BGRA pixels into a displayable buffer.
    ///
    /// - Parameters:
    ///   - frame: The single-plane BGRA frame.
    ///   - pool: A matching buffer pool, or `nil` for standalone allocation.
    ///
    /// - Returns: An IOSurface buffer owning the frame's pixels.
    ///
    /// - Throws: An error if frame layout is invalid or allocation or copying fails.
    static func makeBGRAPixelBuffer(
        _ frame: VideoFrame,
        pool: CVPixelBufferPool? = nil
    ) throws -> CVPixelBuffer {
        let width = frame.format.width
        let height = frame.format.height
        let (rowBytes, overflow) = width.multipliedReportingOverflow(by: 4)
        guard frame.format.pixelFormat == .bgra, width > 0, height > 0,
            !overflow, frame.planes.count == 1
        else {
            throw invalidImageFrameError
        }

        var buffer: CVPixelBuffer?
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &buffer
            )
        } else {
            status = CVPixelBufferCreate(
                nil,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &buffer
            )
        }

        guard status == kCVReturnSuccess, let buffer,
            CVPixelBufferGetWidth(buffer) == width,
            CVPixelBufferGetHeight(buffer) == height,
            CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
            CVPixelBufferLockBaseAddress(
                buffer,
                []
            ) == kCVReturnSuccess
        else {
            throw invalidImageFrameError
        }
        defer {
            CVPixelBufferUnlockBaseAddress(
                buffer,
                []
            )
        }

        try copyPlane(
            frame.planes[0],
            rowByteCount: rowBytes,
            rowCount: height,
            destination: CVPixelBufferGetBaseAddress(buffer),
            destinationStride: CVPixelBufferGetBytesPerRow(buffer)
        )
        return buffer
    }

    /// Returns a media format description matching the pixel buffer.
    ///
    /// - Parameter pixelBuffer: The preview pixel buffer.
    ///
    /// - Returns: The matching dimension and pixel format description.
    ///
    /// - Throws: An error if the format description cannot be created.
    func localPreviewDescription(
        for pixelBuffer: CVPixelBuffer
    ) throws -> CMVideoFormatDescription {
        if let description = localPreviewFormatDescription,
            CMVideoFormatDescriptionMatchesImageBuffer(
                description,
                imageBuffer: pixelBuffer
            )
        {
            return description
        }

        var description: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            ) == noErr, let description
        else {
            throw Self.invalidImageFrameError
        }

        localPreviewFormatDescription = description
        return description
    }

    /// Copies a validated NV12 frame into an IOSurface buffer.
    ///
    /// - Parameters:
    ///   - frame: The NV12 frame to copy.
    ///   - pool: The reusable buffer pool, or `nil` for standalone allocation.
    ///
    /// - Returns: The pixel buffer containing luma and chroma planes.
    ///
    /// - Throws: An error if layout is invalid or allocation, locking, or copying fails.
    static func makeNV12PixelBuffer(
        _ frame: VideoFrame,
        pool: CVPixelBufferPool? = nil
    ) throws -> CVPixelBuffer {
        let width = frame.format.width
        let height = frame.format.height
        guard frame.format.pixelFormat == .nv12,
            width > 0,
            height > 0,
            width.isMultiple(of: 2),
            height.isMultiple(of: 2),
            frame.planes.count == 2
        else {
            throw invalidImageFrameError
        }

        var pixelBuffer: CVPixelBuffer?
        let attributes =
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pool,
                &pixelBuffer
            )
        } else {
            status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes,
                &pixelBuffer
            )
        }

        guard status == kCVReturnSuccess, let pixelBuffer,
            CVPixelBufferGetWidth(pixelBuffer) == width,
            CVPixelBufferGetHeight(pixelBuffer) == height,
            CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else {
            throw invalidImageFrameError
        }

        guard
            CVPixelBufferLockBaseAddress(
                pixelBuffer,
                []
            ) == kCVReturnSuccess
        else {
            throw invalidImageFrameError
        }
        defer {
            CVPixelBufferUnlockBaseAddress(
                pixelBuffer,
                []
            )
        }

        try copyPlane(
            frame.planes[0],
            rowByteCount: width,
            rowCount: height,
            destination: CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                0
            ),
            destinationStride: CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                0
            )
        )

        try copyPlane(
            frame.planes[1],
            rowByteCount: width,
            rowCount: height / 2,
            destination: CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                1
            ),
            destinationStride: CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                1
            )
        )

        return pixelBuffer
    }

    /// Copies the valid rows of a pixel plane.
    ///
    /// - Parameters:
    ///   - plane: The source pixels and row stride.
    ///   - rowByteCount: The bytes to copy per row.
    ///   - rowCount: The row count.
    ///   - destination: The destination plane address.
    ///   - destinationStride: The destination row stride.
    ///
    /// - Throws: An error if source or destination cannot contain the requested region.
    static func copyPlane(
        _ plane: VideoFramePlane,
        rowByteCount: Int,
        rowCount: Int,
        destination: UnsafeMutableRawPointer?,
        destinationStride: Int
    ) throws {
        let (sourceLength, sourceLengthOverflow) = plane.stride
            .multipliedReportingOverflow(by: rowCount)
        guard let destination,
            rowByteCount > 0,
            rowCount > 0,
            plane.stride >= rowByteCount,
            destinationStride >= rowByteCount,
            !sourceLengthOverflow,
            plane.byteLength >= sourceLength,
            plane.byteOffset <= plane.data.count - sourceLength
        else {
            throw invalidImageFrameError
        }

        plane.data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else {
                return
            }

            let sourceStart = source.advanced(by: plane.byteOffset)
            if plane.stride == rowByteCount, destinationStride == rowByteCount {
                memcpy(
                    destination,
                    sourceStart,
                    sourceLength
                )
                return
            }

            for row in 0..<rowCount {
                memcpy(
                    destination.advanced(by: row * destinationStride),
                    sourceStart.advanced(by: row * plane.stride),
                    rowByteCount
                )
            }
        }
    }

    /// The error for an undisplayable image frame.
    static var invalidImageFrameError: XmaxError {
        XmaxError(
            code: .mediaError,
            message: "Image preview frame is invalid"
        )
    }
}
