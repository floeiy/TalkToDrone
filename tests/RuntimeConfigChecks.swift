import Foundation

/// Standalone checks: use a disposable preferences suite, never the app's settings.
@main
struct RuntimeConfigChecks {
  @MainActor
  static func main() throws {
    let suite = "t2d.config.checks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      throw CheckFailure.failed("Could not create temporary preferences")
    }
    defer { defaults.removePersistentDomain(forName: suite) }

    let config = RuntimeConfig(defaults: defaults)
    try check(config.videoBaseURL.absoluteString == "http://10.42.0.2:8080", "Laptop default URL")
    try check(config.speechEndpointURL == nil, "Speech forwarding disabled by default")
    print("PASS defaults: laptop video endpoint, speech disabled")

    try config.apply(
      videoBaseURLText: " https://laptop.local:8443/video/// ",
      speechEndpointText: "http://10.42.0.77:8000/speech"
    )
    try check(config.videoBaseURL.absoluteString == "https://laptop.local:8443/video", "Base URL normalization")
    try check(config.speechEndpointURL?.absoluteString == "http://10.42.0.77:8000/speech", "Independent speech endpoint")
    print("PASS valid configuration: HTTPS, normalized base path, independent speech URL")

    let restored = RuntimeConfig(defaults: defaults)
    try check(restored.videoBaseURL == config.videoBaseURL, "Video persistence")
    try check(restored.speechEndpointURL == config.speechEndpointURL, "Speech persistence")
    print("PASS settings restored from preferences")

    let invalidURLs = [
      "", "laptop.local", "ftp://laptop.local", "http://laptop:0",
      "http://laptop:65536", "http://user:password@laptop", "http://laptop?x=1",
      "http://laptop#fragment", "http://laptop with spaces", "http://10.42.0.1:8080",
    ]
    for url in invalidURLs {
      try reject("invalid video URL: \(url)") {
        try config.apply(videoBaseURLText: url, speechEndpointText: "")
      }
      try check(config.videoBaseURL == restored.videoBaseURL, "Rejected video must preserve active URL")
      try check(config.speechEndpointURL == restored.speechEndpointURL, "Rejected video must preserve speech")
    }
    print("PASS invalid video URLs rejected without changing active settings (\(invalidURLs.count) cases)")

    for url in invalidURLs where !url.isEmpty {
      try reject("invalid speech URL: \(url)") {
        try config.apply(videoBaseURLText: "http://10.42.0.2:8080", speechEndpointText: url)
      }
      try check(config.videoBaseURL == restored.videoBaseURL, "Rejected speech must preserve active video URL")
      try check(config.speechEndpointURL == restored.speechEndpointURL, "Rejected speech must preserve active speech URL")
    }
    let afterRejections = RuntimeConfig(defaults: defaults)
    try check(afterRejections.videoBaseURL == restored.videoBaseURL, "Rejected update must preserve persisted video URL")
    try check(afterRejections.speechEndpointURL == restored.speechEndpointURL, "Rejected update must preserve persisted speech URL")
    print("PASS invalid speech URLs rejected atomically; persisted settings unchanged (\(invalidURLs.count - 1) cases)")

    try config.apply(videoBaseURLText: "http://10.42.0.2:8080/", speechEndpointText: "  \n")
    try check(config.videoBaseURL == RuntimeConfig.defaultVideoBaseURL, "Trailing slash normalized")
    try check(config.speechEndpointURL == nil, "Clearing speech disables forwarding")
    try check(RuntimeConfig(defaults: defaults).speechEndpointURL == nil, "Cleared speech remains disabled after restart")
    print("PASS clearing speech disables forwarding persistently")
    print("RuntimeConfig checks passed.")
  }

  @MainActor
  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
  }

  @MainActor
  private static func reject(_ label: String, operation: () throws -> Void) throws {
    do {
      try operation()
    } catch {
      return
    }
    throw CheckFailure.failed("Unexpectedly accepted \(label)")
  }

  private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
      switch self { case .failed(let message): return "RuntimeConfig check failed: \(message)" }
    }
  }
}
