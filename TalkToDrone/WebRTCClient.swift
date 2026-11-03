//
//  WebRTCClient.swift
//  TalkToDrone
//

import Foundation
@preconcurrency import LiveKitWebRTC
import Observation

@Observable
@MainActor
final class WebRTCClient: NSObject {
  static let shared = WebRTCClient()

  private(set) var connectionStatus = "Disconnected"
  private(set) var sourceStatus = "Source not checked"
  private(set) var frameStatus = "No video frames yet"
  private(set) var isRunning = false
  private(set) var renderedFrameCount = 0
  private(set) var remoteVideoTrack: LKRTCVideoTrack?

  private let factory: LKRTCPeerConnectionFactory
  private let session: URLSession
  private var peerConnection: LKRTCPeerConnection?
  private var sessionTask: Task<Void, Never>?
  private var generation = 0
  private var lastFrameReceived: Date?
  private var isSynthetic = false
  private let maximumRetries = 3

  private override init() {
    LKRTCInitializeSSL()
    factory = LKRTCPeerConnectionFactory(
      encoderFactory: LKRTCDefaultVideoEncoderFactory(),
      decoderFactory: LKRTCDefaultVideoDecoderFactory()
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    configuration.waitsForConnectivity = false
    session = URLSession(configuration: configuration)
    super.init()
  }

  // A manual Connect/Retry starts a new bounded recovery cycle. Each cycle
  // snapshots its endpoint, so edits never redirect an in-flight negotiation.
  func connect(baseURL: URL) async {
    disconnect()
    isRunning = true
    sourceStatus = "Checking laptop video source..."
    let currentGeneration = generation
    print("[webrtc] starting video session at \(baseURL.absoluteString)")
    sessionTask = Task { [weak self] in
      await self?.runSession(baseURL: baseURL, generation: currentGeneration)
    }
  }

  func connect() async {
    await connect(baseURL: RuntimeConfig.shared.videoBaseURL)
  }

  func disconnect() {
    generation += 1
    sessionTask?.cancel()
    sessionTask = nil
    closePeer()
    isRunning = false
    connectionStatus = "Disconnected"
    sourceStatus = "Source not checked"
    isSynthetic = false
    print("[webrtc] video session stopped")
  }

  func stop() { disconnect() }

  /// Called by the renderer after receiving a decoded frame. SDP/track events
  /// alone do not establish that video is flowing. Ignore old renderer callbacks.
  func didReceiveVideoFrame(from track: LKRTCVideoTrack) {
    guard isRunning, remoteVideoTrack === track else { return }
    if lastFrameReceived == nil {
      print("[webrtc] first decoded video frame")
    }
    lastFrameReceived = Date()
    renderedFrameCount += 1
    frameStatus = isSynthetic ? "Receiving synthetic test video" : "Receiving video"
  }

  private func runSession(baseURL: URL, generation currentGeneration: Int) async {
    for attempt in 0...maximumRetries {
      do {
        try ensureCurrent(currentGeneration)
        if attempt > 0 {
          let delay = 1 << attempt // 2, 4, 8 seconds; manual Retry resets the budget.
          connectionStatus = "Reconnecting in \(delay)s (\(attempt)/\(maximumRetries))..."
          try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
          try ensureCurrent(currentGeneration)
        }
        connectionStatus = "Checking video service..."
        let health = try await fetchHealth(baseURL: baseURL)
        try ensureCurrent(currentGeneration)
        updateSourceStatus(health)
        let pc = try await connectPeer(baseURL: baseURL, generation: currentGeneration)
        try await monitor(pc, baseURL: baseURL, generation: currentGeneration)
      } catch {
        guard currentGeneration == generation, !Task.isCancelled else { return }
        print("[webrtc] attempt \(attempt + 1) failed: \(error.localizedDescription)")
        closePeer()
        frameStatus = "Video unavailable: \(error.localizedDescription)"
        if attempt == maximumRetries {
          isRunning = false
          connectionStatus = "Stopped after \(maximumRetries) retries. \(error.localizedDescription) Tap Retry."
          sessionTask = nil
          return
        }
        connectionStatus = error.localizedDescription
      }
    }
  }

  private func connectPeer(baseURL: URL, generation currentGeneration: Int) async throws -> LKRTCPeerConnection {
    let configuration = LKRTCConfiguration()
    configuration.iceServers = []
    configuration.sdpSemantics = .unifiedPlan
    let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    guard let pc = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
      throw WebRTCClientError.failure("Could not create a video connection.")
    }
    peerConnection = pc
    let transceiver = LKRTCRtpTransceiverInit()
    transceiver.direction = .recvOnly
    guard pc.addTransceiver(of: .video, init: transceiver) != nil else {
      throw WebRTCClientError.failure("Could not create a receiving video track.")
    }

    connectionStatus = "Creating video offer..."
    let offer = try await createOffer(pc)
    try ensureCurrent(currentGeneration, peer: pc)
    try await setDescription(offer, on: pc, local: true)
    try ensureCurrent(currentGeneration, peer: pc)
    connectionStatus = "Gathering local network candidates..."
    let iceDeadline = Date().addingTimeInterval(10)
    while pc.iceGatheringState != .complete {
      try ensureCurrent(currentGeneration, peer: pc)
      guard Date() < iceDeadline else {
        throw WebRTCClientError.failure("Local network discovery timed out. Check T2D and Local Network permission.")
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard let localDescription = pc.localDescription else {
      throw WebRTCClientError.failure("WebRTC local description is missing.")
    }

    connectionStatus = "Connecting to laptop..."
    let answer = try await sendOffer(localDescription, baseURL: baseURL)
    try ensureCurrent(currentGeneration, peer: pc)
    try await setDescription(LKRTCSessionDescription(type: .answer, sdp: answer.sdp), on: pc, local: false)
    try ensureCurrent(currentGeneration, peer: pc)
    connectionStatus = "Waiting for video connection..."
    let connectionDeadline = Date().addingTimeInterval(15)
    while pc.connectionState != .connected {
      try ensureCurrent(currentGeneration, peer: pc)
      if pc.connectionState == .failed || pc.connectionState == .closed {
        throw WebRTCClientError.failure("Video connection failed. Check T2D and the laptop firewall.")
      }
      guard Date() < connectionDeadline else {
        throw WebRTCClientError.failure("Video connection timed out. Check T2D and the laptop firewall.")
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    connectionStatus = "Connected to laptop"
    return pc
  }

  private func monitor(_ pc: LKRTCPeerConnection, baseURL: URL, generation currentGeneration: Int) async throws {
    let connectedAt = Date()
    var disconnectedAt: Date?
    var nextHealthCheck = Date.distantPast
    var healthFailures = 0
    while true {
      try ensureCurrent(currentGeneration, peer: pc)
      let now = Date()
      switch pc.connectionState {
      case .failed, .closed:
        throw WebRTCClientError.failure("The laptop video connection was lost.")
      case .disconnected:
        if disconnectedAt == nil { disconnectedAt = now }
        connectionStatus = "Network interrupted..."
        if now.timeIntervalSince(disconnectedAt!) > 5 {
          throw WebRTCClientError.failure("The T2D connection was interrupted.")
        }
      default:
        disconnectedAt = nil
        connectionStatus = "Connected to laptop"
      }
      if let lastFrameReceived {
        if now.timeIntervalSince(lastFrameReceived) > 5 {
          throw WebRTCClientError.failure("Video frames stopped arriving.")
        }
      } else if now.timeIntervalSince(connectedAt) > 15 {
        throw WebRTCClientError.failure("Connected, but no video frames arrived.")
      }
      if now >= nextHealthCheck {
        do {
          let health = try await fetchHealth(baseURL: baseURL)
          try ensureCurrent(currentGeneration, peer: pc)
          updateSourceStatus(health)
          healthFailures = 0
          if health.source.state == "unavailable" || health.source.state == "closed" {
            throw WebRTCClientError.sourceUnavailable
          }
        } catch WebRTCClientError.sourceUnavailable {
          throw WebRTCClientError.failure("The laptop camera source is unavailable.")
        } catch {
          try ensureCurrent(currentGeneration, peer: pc)
          healthFailures += 1
          sourceStatus = "Cannot check laptop source: \(error.localizedDescription)"
          if healthFailures >= 2 { throw error }
        }
        nextHealthCheck = Date().addingTimeInterval(2)
      }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
  }

  private func ensureCurrent(_ currentGeneration: Int, peer: LKRTCPeerConnection? = nil) throws {
    try Task.checkCancellation()
    guard currentGeneration == generation, isRunning,
      peer == nil || peerConnection === peer else { throw CancellationError() }
  }

  private func closePeer() {
    let oldPeer = peerConnection
    peerConnection = nil // Invalidate delegate callbacks before close() invokes them.
    remoteVideoTrack = nil
    lastFrameReceived = nil
    renderedFrameCount = 0
    frameStatus = "No video frames yet"
    oldPeer?.close()
  }

  // MARK: - SDP

  private func createOffer(_ pc: LKRTCPeerConnection) async throws -> LKRTCSessionDescription {
    try await boundedSDPOperation("Creating the video offer") { completion in
      let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
      let callback: @Sendable (LKRTCSessionDescription?, Error?) -> Void = { description, error in
        if let error { completion(.failure(error)) }
        else if let description { completion(.success(description)) }
        else { completion(.failure(WebRTCClientError.failure("WebRTC did not create an SDP offer."))) }
      }
      pc.offer(for: constraints, completionHandler: callback)
    }
  }

  private func setDescription(_ description: LKRTCSessionDescription, on pc: LKRTCPeerConnection, local: Bool) async throws {
    let _: Void = try await boundedSDPOperation("Applying the video description") { completion in
      let callback: @Sendable (Error?) -> Void = { error in
        if let error { completion(.failure(error)) }
        else { completion(.success(())) }
      }
      if local { pc.setLocalDescription(description, completionHandler: callback) }
      else { pc.setRemoteDescription(description, completionHandler: callback) }
    }
  }

  // Native SDP callbacks are not Swift tasks. A one-shot continuation explicitly
  // handles timeout/cancellation, including a callback arriving after either.
  private func boundedSDPOperation<Value>(
    _ label: String,
    operation: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
  ) async throws -> Value {
    let completion = SDPCompletion<Value>()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        completion.continuation = continuation
        completion.timeout = Task {
          do { try await Task.sleep(nanoseconds: 10_000_000_000) }
          catch { return }
          completion.finish(.failure(WebRTCClientError.failure("\(label) timed out.")))
        }
        operation { result in
          Task { @MainActor in completion.finish(result) }
        }
      }
    } onCancel: {
      Task { @MainActor in completion.finish(.failure(CancellationError())) }
    }
  }

  // MARK: - HTTP signaling and source health

  private func sendOffer(_ offer: LKRTCSessionDescription, baseURL: URL) async throws -> SDPAnswer {
    var request = URLRequest(url: baseURL.appendingPathComponent("offer"), timeoutInterval: 10)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(SDPOffer(sdp: offer.sdp, type: "offer"))
    let (data, response) = try await session.data(for: request)
    try validateResponse(response)
    let answer = try JSONDecoder().decode(SDPAnswer.self, from: data)
    guard answer.type == "answer", !answer.sdp.isEmpty else {
      throw WebRTCClientError.failure("The laptop returned an invalid video answer.")
    }
    return answer
  }

  private func fetchHealth(baseURL: URL) async throws -> VideoHealth {
    var request = URLRequest(url: baseURL.appendingPathComponent("health"), timeoutInterval: 3)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await session.data(for: request)
    try validateResponse(response)
    let health = try JSONDecoder().decode(VideoHealth.self, from: data)
    guard health.role == "laptop" else {
      throw WebRTCClientError.failure("This address is not the laptop video service.")
    }
    return health
  }

  private func validateResponse(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw WebRTCClientError.failure("The laptop returned an invalid HTTP response.")
    }
    switch http.statusCode {
    case 200...299: return
    case 400: throw WebRTCClientError.failure("The laptop rejected this video offer (HTTP 400).")
    case 429: throw WebRTCClientError.failure("The laptop has reached its viewer limit (HTTP 429).")
    case 503: throw WebRTCClientError.failure("The laptop video source is unavailable (HTTP 503).")
    default: throw WebRTCClientError.failure("The laptop returned HTTP \(http.statusCode).")
    }
  }

  private func updateSourceStatus(_ health: VideoHealth) {
    let previousStatus = sourceStatus
    isSynthetic = health.source.kind == "synthetic"
    let label = isSynthetic ? "Synthetic test source" : "Camera source (\(health.source.kind))"
    if let error = health.source.error, !error.isEmpty {
      sourceStatus = "\(label): \(health.source.state) — \(error)"
    } else if health.source.state == "live", let age = health.source.frame_age_s, age > 5 {
      sourceStatus = "\(label): stale input (\(Int(age))s since laptop decode)"
    } else {
      sourceStatus = "\(label): \(health.source.state)"
    }
    if lastFrameReceived != nil {
      frameStatus = isSynthetic ? "Receiving synthetic test video" : "Receiving video"
    }
    if sourceStatus != previousStatus { print("[webrtc] source: \(sourceStatus)") }
  }
}

@MainActor
private final class SDPCompletion<Value> {
  var continuation: CheckedContinuation<Value, Error>?
  var timeout: Task<Void, Never>?

  func finish(_ result: Result<Value, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timeout?.cancel()
    timeout = nil
    continuation.resume(with: result)
  }
}

private struct SDPOffer: Encodable {
  let sdp: String
  let type: String
}

private struct SDPAnswer: Decodable {
  let sdp: String
  let type: String
}

private struct VideoHealth: Decodable {
  let role: String
  let source: Source

  struct Source: Decodable {
    let kind: String
    let state: String
    let frame_age_s: Double?
    let error: String?
  }
}

private enum WebRTCClientError: LocalizedError {
  case failure(String)
  case sourceUnavailable

  var errorDescription: String? {
    switch self {
    case .failure(let message): return message
    case .sourceUnavailable: return "The laptop camera source is unavailable."
    }
  }
}

// MARK: - LKRTCPeerConnectionDelegate

extension WebRTCClient: LKRTCPeerConnectionDelegate {
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
  nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}

  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
    Task { @MainActor [weak self] in
      guard let self, self.isRunning, self.peerConnection === peerConnection else { return }
      print("[webrtc] connection state: \(newState.rawValue)")
      // The session loop owns status, deadlines and recovery. Late callbacks
      // cannot clear a newer peer or start a second recovery loop.
    }
  }

  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
    guard let track = rtpReceiver.track as? LKRTCVideoTrack else { return }
    Task { @MainActor [weak self] in
      guard let self, self.isRunning, self.peerConnection === peerConnection else { return }
      self.remoteVideoTrack = track
      self.frameStatus = "Video track ready — waiting for frames"
    }
  }

  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove rtpReceiver: LKRTCRtpReceiver) {
    Task { @MainActor [weak self] in
      guard let self, self.peerConnection === peerConnection,
        self.remoteVideoTrack === rtpReceiver.track else { return }
      self.remoteVideoTrack = nil
      self.frameStatus = "Video track removed"
    }
  }
}
