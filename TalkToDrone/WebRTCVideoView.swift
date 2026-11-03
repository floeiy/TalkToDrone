// Native WebRTC rendering, with one pending frame and explicit track cleanup.
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import SwiftUI
import UIKit

@MainActor
final class WebRTCVideoRendererView: UIView {
  private let displayLayer = AVSampleBufferDisplayLayer()
  private var renderer: VideoFrameRenderer?
  private var track: LKRTCVideoTrack?
  var onFrameReceived: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = UIColor.black.cgColor
    layer.addSublayer(displayLayer)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    displayLayer.frame = bounds
  }

  func attach(_ newTrack: LKRTCVideoTrack) {
    guard track !== newTrack else { return }
    detach()
    let newRenderer = VideoFrameRenderer { [weak self] renderer in
      // The callback is scheduled on MainActor; identity excludes stale frames.
      guard let self, self.renderer === renderer,
        let sampleBuffer = renderer.takeLatestFrame() else { return }
      let output = self.displayLayer.sampleBufferRenderer
      if output.status == .failed { output.flush() }
      guard output.isReadyForMoreMediaData else { return }
      output.enqueue(sampleBuffer)
      guard output.status != .failed else { return }
      self.onFrameReceived?()
    }
    renderer = newRenderer
    track = newTrack
    newTrack.add(newRenderer)
  }

  func detach() {
    renderer?.deactivate()
    if let renderer { track?.remove(renderer) }
    renderer = nil
    track = nil
    displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
  }
}

// libwebrtc calls this adapter on its decode thread, never on MainActor.
// The lock protects active/latestFrame/drainScheduled. A slow UI drops old
// frames rather than accumulating a Task and pixel buffer for every frame.
nonisolated private final class VideoFrameRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
  private let lock = NSLock()
  private let converter = WebRTCFrameConverter()
  private var latestFrame: CMSampleBuffer?
  private var drainScheduled = false
  private var active = true
  private let deliver: @MainActor @Sendable (VideoFrameRenderer) -> Void

  nonisolated init(deliver: @escaping @MainActor @Sendable (VideoFrameRenderer) -> Void) {
    self.deliver = deliver
  }

  nonisolated func setSize(_ size: CGSize) {}

  nonisolated func renderFrame(_ frame: LKRTCVideoFrame?) {
    guard let frame, let pixels = converter.makePixelBuffer(from: frame.buffer),
      let sample = Self.makeSampleBuffer(from: pixels) else { return }
    lock.lock()
    guard active else { lock.unlock(); return }
    latestFrame = sample
    let schedule = !drainScheduled
    drainScheduled = true
    lock.unlock()
    if schedule {
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.deliver(self)
      }
    }
  }

  nonisolated func takeLatestFrame() -> CMSampleBuffer? {
    lock.lock()
    defer { lock.unlock() }
    drainScheduled = false
    defer { latestFrame = nil }
    return active ? latestFrame : nil
  }

  nonisolated func deactivate() {
    lock.lock()
    defer { lock.unlock() }
    active = false
    latestFrame = nil
  }

  nonisolated private static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    var description: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
      formatDescriptionOut: &description
    ) == noErr, let description else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid,
      presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
      formatDescription: description, sampleTiming: &timing,
      sampleBufferOut: &sample
    ) == noErr, let sample else { return nil }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }
}

nonisolated private final class WebRTCFrameConverter: @unchecked Sendable {
  nonisolated func makePixelBuffer(from buffer: LKRTCVideoFrameBuffer) -> CVPixelBuffer? {
    if let cvBuffer = buffer as? LKRTCCVPixelBuffer {
      return makePixelBuffer(from: cvBuffer)
    }
    if let i420Buffer = buffer as? LKRTCI420Buffer {
      return makePixelBuffer(from: i420Buffer)
    }

    print("[video] unsupported buffer type: \(type(of: buffer))")
    return nil
  }

  nonisolated private func makePixelBuffer(from buffer: LKRTCCVPixelBuffer) -> CVPixelBuffer? {
    if !buffer.requiresCropping(),
      !buffer.requiresScaling(toWidth: buffer.width, height: buffer.height)
    {
      return buffer.pixelBuffer
    }

    let width = Int(buffer.width)
    let height = Int(buffer.height)
    let pixelFormat = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer)
    let attributes: [String: Any] = [
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]

    var outputBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      pixelFormat,
      attributes as CFDictionary,
      &outputBuffer
    )

    guard status == kCVReturnSuccess, let outputBuffer else { return nil }

    let temporaryBufferSize = Int(
      buffer.bufferSizeForCroppingAndScaling(
        toWidth: buffer.width,
        height: buffer.height
      )
    )

    if temporaryBufferSize > 0 {
      var temporaryBuffer = [UInt8](repeating: 0, count: temporaryBufferSize)
      let success = temporaryBuffer.withUnsafeMutableBufferPointer { pointer in
        buffer.cropAndScale(to: outputBuffer, withTempBuffer: pointer.baseAddress)
      }
      return success ? outputBuffer : nil
    }

    return buffer.cropAndScale(to: outputBuffer, withTempBuffer: nil)
      ? outputBuffer
      : nil
  }

  nonisolated private func makePixelBuffer(from buffer: LKRTCI420Buffer) -> CVPixelBuffer? {
    let width = Int(buffer.width)
    let height = Int(buffer.height)
    let attributes: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]

    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &pixelBuffer
    )

    guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)

    LKRTCYUVHelper.i420(
      toARGB: buffer.dataY,
      srcStrideY: buffer.strideY,
      srcU: buffer.dataU,
      srcStrideU: buffer.strideU,
      srcV: buffer.dataV,
      srcStrideV: buffer.strideV,
      dstARGB: destination,
      dstStrideARGB: Int32(destinationStride),
      width: buffer.width,
      height: buffer.height
    )

    return pixelBuffer
  }
}

struct WebRTCVideoView: UIViewRepresentable {
  let videoTrack: LKRTCVideoTrack
  let onFrameReceived: () -> Void

  func makeUIView(context: Context) -> WebRTCVideoRendererView {
    let view = WebRTCVideoRendererView()
    view.onFrameReceived = onFrameReceived
    view.attach(videoTrack)
    return view
  }

  func updateUIView(_ view: WebRTCVideoRendererView, context: Context) {
    view.onFrameReceived = onFrameReceived
    view.attach(videoTrack)
  }

  static func dismantleUIView(_ view: WebRTCVideoRendererView, coordinator: ()) {
    view.onFrameReceived = nil
    view.detach()
  }
}
