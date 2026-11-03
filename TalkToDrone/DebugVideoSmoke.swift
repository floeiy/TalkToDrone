#if DEBUG
import Foundation

/// Explicitly invoked development check; never runs on a normal app launch.
@MainActor
enum DebugVideoSmoke {
  static func run(client: WebRTCClient, baseURL: URL) async {
    do {
      print("[native-smoke] START \(baseURL.absoluteString)")
      await client.connect(baseURL: baseURL)
      try await wait(seconds: 35) { client.renderedFrameCount >= 30 }
      print("[native-smoke] PASS first connection: \(client.renderedFrameCount) rendered frames; \(client.sourceStatus)")

      client.disconnect()
      try await Task.sleep(for: .seconds(2))
      guard !client.isRunning, client.remoteVideoTrack == nil else {
        throw SmokeFailure.failed("Stop did not release the video connection")
      }
      print("[native-smoke] PASS stop and cleanup")

      await client.connect(baseURL: baseURL)
      try await wait(seconds: 35) { client.renderedFrameCount >= 30 }
      print("[native-smoke] PASS reconnect: \(client.renderedFrameCount) rendered frames")

      // Port 9 is intentionally unavailable, exercising the same HTTP failure
      // and bounded retry path used when the configured service is stopped.
      var unavailable = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
      unavailable.port = 9
      await client.connect(baseURL: unavailable.url!)
      try await wait(seconds: 90) { !client.isRunning }
      guard client.remoteVideoTrack == nil else {
        throw SmokeFailure.failed("Unavailable server retained a video track")
      }
      print("[native-smoke] PASS unavailable server stops retrying: \(client.connectionStatus)")

      // connect schedules its owned negotiation task and returns. Cancel before
      // yielding so that queued work cannot resurrect a peer after Stop.
      await client.connect(baseURL: baseURL)
      client.disconnect()
      try await Task.sleep(for: .seconds(2))
      guard !client.isRunning, client.remoteVideoTrack == nil else {
        throw SmokeFailure.failed("Cancelled connection became active again")
      }
      print("[native-smoke] PASS cancellation of queued connection")

      await client.connect(baseURL: baseURL)
      try await wait(seconds: 35) { client.renderedFrameCount >= 30 }
      print("[native-smoke] PASS recovery: \(client.renderedFrameCount) rendered frames")
      print("[native-smoke] COMPLETE — video remains connected")
    } catch {
      print("[native-smoke] FAIL \(error.localizedDescription); \(client.connectionStatus); \(client.frameStatus)")
      client.disconnect()
    }
  }

  private static func wait(seconds: TimeInterval, until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
      guard Date() < deadline else { throw SmokeFailure.failed("Timed out waiting for video state") }
      try await Task.sleep(for: .milliseconds(200))
    }
  }

  private enum SmokeFailure: LocalizedError {
    case failed(String)
    var errorDescription: String? {
      switch self { case .failed(let reason): return reason }
    }
  }
}
#endif
