//
//  ImageControllerTests.swift
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
import XCTest
@testable import XmaxSDK

final class ImageControllerTests: XCTestCase {
    func testLargeImageProducesCappedPreviewAndRtcFrames() async throws {
        let image = DecodedImageStub(width: 3840, height: 2160)
        let recorder = ImageFrameRecorder()
        let controller = ImageController(
            rtcManager: RtcManagingStub(),
            imageManager: ImageManagingStub(decodedImage: image),
            mediaService: MediaService(),
            frameListener: { recorder.append($0) }
        )
        let stream = try await controller.createLocalImageStream(imageData: Data("image".utf8))
        await controller.stopLocalImageStream()

        XCTAssertEqual(stream.videoTrack?.videoFormat?.size, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(image.frameSizes, [CGSize(width: 1920, height: 1080)])
        XCTAssertEqual(recorder.frames.first?.format.width, 1920)
        XCTAssertEqual(recorder.frames.first?.format.height, 1080)
    }

    func testImageUsesModelDefaultFrameRate() async throws {
        let controller = ImageController(
            rtcManager: RtcManagingStub(),
            imageManager: ImageManagingStub(decodedImage: DecodedImageStub(width: 400, height: 1600)),
            mediaService: MediaServicingStub(
                resolvedSize: CGSize(width: 832, height: 1_472), model: .x2_1
            ),
            frameListener: { _ in }
        )
        let prepared = try await controller.createLocalImageStream(
            imageData: Data("encoded-image".utf8)
        )
        XCTAssertEqual(prepared.videoTrack?.videoFormat?.fps, RealtimeModel.x2_1.defaultFrameRate)
        await controller.stopLocalImageStream()
    }

    func testCreateAcceptsEncodedImageDataDirectly() async throws {
        let imageData = Data("encoded-image".utf8)
        let decodedImage = DecodedImageStub(width: 400, height: 1600)
        let controller = ImageController(
            rtcManager: RtcManagingStub(),
            imageManager: ImageManagingStub(decodedImage: decodedImage),
            mediaService: MediaServicingStub(
                resolvedSize: CGSize(width: 832, height: 1_472)
            ),
            frameListener: { _ in }
        )

        let prepared = try await controller.createLocalImageStream(
            imageData: imageData
        )
        await controller.stopLocalImageStream()

        XCTAssertEqual(
            prepared.videoTrack?.videoFormat,
            RealtimeVideoFormat(width: 400, height: 1600, fps: 30)
        )
        XCTAssertEqual(
            decodedImage.frameSizes,
            [CGSize(width: 400, height: 1600)]
        )
    }

    func testCreateResolvesDefaultFormatAndEmitsFrame() async throws {
        let fileURL = try makeTemporaryImageDataFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let decodedImage = DecodedImageStub(
            width: 1024,
            height: 768
        )
        let recorder = ImageFrameRecorder()
        let controller = ImageController(
            rtcManager: RtcManagingStub(),
            imageManager: ImageManagingStub(decodedImage: decodedImage),
            mediaService: MediaServicingStub(
                resolvedSize: CGSize(width: 896, height: 672)
            ),
            frameListener: { frame in
                recorder.append(frame)
            }
        )

        let prepared = try await controller.createLocalImageStream(
            fileURL: fileURL
        )
        await controller.stopLocalImageStream()

        XCTAssertEqual(
            prepared.videoTrack?.videoFormat,
            RealtimeVideoFormat(width: 1024, height: 768, fps: 30)
        )
        XCTAssertEqual(
            decodedImage.frameSizes,
            [CGSize(width: 1024, height: 768)]
        )
        let frame = try XCTUnwrap(recorder.frames.first)
        XCTAssertEqual(
            frame.format,
            try VideoFormat(width: 1024, height: 768, pixelFormat: .bgra)
        )
        XCTAssertEqual(frame.planes.first?.stride, 1024 * 4)
        XCTAssertNotNil(frame.bufferReuseID)
        XCTAssertGreaterThan(frame.timestampUs, 0)
    }

    func testCreatePreservesSourceInsteadOfApplyingModelBuckets() async throws {
        let fileURL = try makeTemporaryImageDataFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let mediaService = MediaServicingStub(
            resolvedSize: CGSize(width: 832, height: 1_472)
        )
        let controller = ImageController(
            rtcManager: RtcManagingStub(),
            imageManager: ImageManagingStub(
                decodedImage: DecodedImageStub(width: 400, height: 1600)
            ),
            mediaService: mediaService,
            frameListener: { _ in }
        )

        let prepared = try await controller.createLocalImageStream(
            fileURL: fileURL
        )
        await controller.stopLocalImageStream()

        XCTAssertEqual(
            mediaService.requestedSizes,
            [CGSize(width: 400, height: 1600)]
        )
        XCTAssertEqual(
            prepared.videoTrack?.videoFormat,
            RealtimeVideoFormat(
                width: 400, height: 1600, fps: 30
            )
        )
    }

    func testCreateRejectsEmptyImageData() async {
        let controller = ImageController(
            rtcManager: RtcManagingStub(),
            imageManager: ImageManagingStub(
                decodedImage: DecodedImageStub(width: 1, height: 1)
            ),
            mediaService: MediaServicingStub(
                resolvedSize: CGSize(width: 832, height: 1_472)
            ),
            frameListener: { _ in }
        )

        do {
            _ = try await controller.createLocalImageStream(
                imageData: Data()
            )
            XCTFail("Expected empty image data to be rejected")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Image source data must not be empty"
                )
            )
        }
    }
    func testCreateConfiguresExternalSourceAndRegistersTrack() async throws {
        let rtcManager = RtcManagingStub()
        let controller = makeController(rtcManager: rtcManager)
        let stream = try await controller.createLocalImageStream(
            imageData: Data("image".utf8)
        )
        let track = try XCTUnwrap(stream.videoTrack)

        XCTAssertEqual(stream.id, StreamID.local.rawValue)
        XCTAssertEqual(track.id, "video0")
        XCTAssertNil(track.position)
        XCTAssertTrue(track === controller.currentTrack)
        XCTAssertEqual(rtcManager.calls, [.useExternalVideoSource])

        let hasBinding = await MainActor.run {
            VideoRenderRegistry.binding(for: track) != nil
        }
        XCTAssertTrue(hasBinding)
        await controller.stopLocalImageStream()
    }

    func testStopClearsTrackAndPreviewBinding() async throws {
        let controller = makeController()
        let stream = try await controller.createLocalImageStream(
            imageData: Data("image".utf8)
        )
        let track = try XCTUnwrap(stream.videoTrack)

        try await MainActor.run {
            let binding = try XCTUnwrap(VideoRenderRegistry.binding(for: track))
            try binding.attach(to: XmaxRealtimeVideoView(), contentMode: .fill)
        }

        await controller.stopLocalImageStream()
        await controller.stopLocalImageStream()

        XCTAssertNil(controller.currentTrack)
        let hasBinding = await MainActor.run {
            VideoRenderRegistry.binding(for: track) != nil
        }
        XCTAssertFalse(hasBinding)
    }

    func testFirstFrameFailureRollsBackAndAllowsRetry() async throws {
        let expectedError = XmaxError(code: .mediaError, message: "Failed to push image frame")
        let recorder = ImageFrameRecorder()
        let controller = makeController(frameListener: { frame in
            recorder.append(frame)
            if recorder.frames.count == 1 {
                throw expectedError
            }
        })

        do {
            _ = try await controller.createLocalImageStream(
                imageData: Data("image".utf8)
            )
            XCTFail("Expected initial frame output to fail")
        } catch {
            XCTAssertEqual(error as? XmaxError, expectedError)
        }
        XCTAssertNil(controller.currentTrack)

        let stream = try await controller.createLocalImageStream(
            imageData: Data("image".utf8)
        )
        XCTAssertTrue(controller.currentTrack === stream.videoTrack)
        await controller.stopLocalImageStream()
    }

    func testCreateRejectsDuplicateWithoutStoppingExistingStream() async throws {
        let controller = makeController()
        let stream = try await controller.createLocalImageStream(
            imageData: Data("image".utf8)
        )

        do {
            _ = try await controller.createLocalImageStream(
                imageData: Data("another-image".utf8)
            )
            XCTFail("Expected duplicate image stream to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }

        XCTAssertTrue(controller.currentTrack === stream.videoTrack)
        await controller.stopLocalImageStream()
    }

    func testDecodedInputBypassesDecoder() async throws {
        let decodedImage = DecodedImageStub(width: 400, height: 1600)
        let controller = ImageController(
            rtcManager: RtcManagingStub(),
            imageManager: FailingImageManager(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 832, height: 1472)),
            frameListener: { _ in }
        )

        let stream = try await controller.createLocalImageStream(
            decodedImage: decodedImage
        )

        XCTAssertEqual(stream.videoTrack?.videoFormat?.width, 400)
        XCTAssertEqual(decodedImage.frameSizes, [CGSize(width: 400, height: 1600)])
        await controller.stopLocalImageStream()
    }

    func testDecodeFailureDoesNotConfigureRTCOrCreateTrack() async {
        let rtc = RtcManagingStub()
        let controller = ImageController(
            rtcManager: rtc,
            imageManager: FailingImageManager(),
            frameListener: { _ in }
        )

        do {
            _ = try await controller.createLocalImageStream(
                imageData: Data("invalid".utf8)
            )
            XCTFail("Expected decode failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }

        XCTAssertNil(controller.currentTrack)
        XCTAssertTrue(rtc.calls.isEmpty)
    }

    func testCreateRejectsRemoteFileURL() async throws {
        let controller = makeController()
        let url = try XCTUnwrap(URL(string: "https://example.com/image.png"))

        do {
            _ = try await controller.createLocalImageStream(fileURL: url)
            XCTFail("Expected remote file URL to be rejected")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }

        XCTAssertNil(controller.currentTrack)
    }

    func testRepeatedFramesReusePixelsAndStopAfterCleanup() async throws {
        let decodedImage = DecodedImageStub(width: 400, height: 1600)
        let recorder = ImageFrameRecorder()
        let receivedFrames = expectation(description: "Received three frames")
        receivedFrames.expectedFulfillmentCount = 3
        let controller = ImageController(
            rtcManager: RtcManagingStub(),
            imageManager: ImageManagingStub(decodedImage: decodedImage),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 832, height: 1472)),
            frameListener: { frame in
                recorder.append(frame)
                if recorder.frames.count <= 3 {
                    receivedFrames.fulfill()
                }
            }
        )

        _ = try await controller.createLocalImageStream(
            imageData: Data("image".utf8)
        )
        await fulfillment(of: [receivedFrames], timeout: 2)
        await controller.stopLocalImageStream()

        let frames = recorder.frames
        XCTAssertGreaterThanOrEqual(frames.count, 3)
        XCTAssertEqual(decodedImage.frameSizes.count, 1)
        for (previous, next) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(previous.bufferReuseID, next.bufferReuseID)
            XCTAssertGreaterThan(next.timestampUs, previous.timestampUs)
        }

        try await Task.sleep(nanoseconds: 100000000)
        XCTAssertEqual(recorder.frames.count, frames.count)
    }

    func testLaterFrameFailureDoesNotStopFollowingFrames() async throws {
        let recorder = ImageFrameRecorder()
        let continued = expectation(description: "Frame after failed frame")
        let controller = makeController(frameListener: { frame in
            recorder.append(frame)
            if recorder.frames.count == 2 {
                throw XmaxError(code: .mediaError, message: "One frame failed")
            }
            if recorder.frames.count == 3 { continued.fulfill() }
        })
        let stream = try await controller.createLocalImageStream(
            imageData: Data("image".utf8)
        )
        await fulfillment(of: [continued], timeout: 2)
        XCTAssertTrue(controller.currentTrack === stream.videoTrack)
        await controller.stopLocalImageStream()
    }

}

private extension ImageControllerTests {
    func makeController(
        rtcManager: RtcManagingStub = RtcManagingStub(),
        frameListener: @escaping MediaVideoFrameListener = { _ in }
    ) -> ImageController {
        ImageController(
            rtcManager: rtcManager,
            imageManager: ImageManagingStub(decodedImage: DecodedImageStub(width: 400, height: 1600)),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 832, height: 1472)),
            frameListener: frameListener
        )
    }

    func makeTemporaryImageDataFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try Data("image".utf8).write(to: url)
        return url
    }
}

private final class ImageFrameRecorder: @unchecked Sendable {

    // 并发状态
    private let lock = NSLock()
    private var storedFrames: [VideoFrame] = []

    var frames: [VideoFrame] {
        lock.withLock { storedFrames }
    }

    func append(_ frame: VideoFrame) {
        lock.withLock {
            storedFrames.append(frame)
        }
    }
}

private final class DecodedImageStub:
    DecodedImage,
    @unchecked Sendable {

    // 图片信息
    let size: CGSize

    // 并发状态
    private let lock = NSLock()
    private var storedFrameSizes: [CGSize] = []

    init(width: Int, height: Int) {
        size = CGSize(width: width, height: height)
    }

    var frameSizes: [CGSize] {
        lock.withLock { storedFrameSizes }
    }

    func makeVideoFrame(
        width: Int,
        height: Int
    ) throws -> VideoFrame {
        lock.withLock {
            storedFrameSizes.append(CGSize(width: width, height: height))
        }
        return try VideoFrame(
            format: VideoFormat(
                width: width,
                height: height,
                pixelFormat: .bgra
            ),
            timestampUs: 0,
            planes: [
                VideoFramePlane(
                    data: Data(repeating: 0, count: width * height * 4),
                    stride: width * 4
                )
            ],
            bufferReuseID: UUID()
        )
    }
}

private final class ImageManagingStub: ImageManaging, Sendable {

    // 图片资源
    private let decodedImage: any DecodedImage

    init(decodedImage: any DecodedImage) {
        self.decodedImage = decodedImage
    }

    func decode(_ data: Data) throws -> any DecodedImage {
        decodedImage
    }
}

private struct FailingImageManager: ImageManaging {
    func decode(_ data: Data) throws -> any DecodedImage {
        throw XmaxError(code: .mediaError, message: "Failed to decode image")
    }
}
