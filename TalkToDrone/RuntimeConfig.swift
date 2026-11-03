import Foundation
import Observation

/// Application services run on the laptop; the Pi only provides the T2D network.
@Observable
@MainActor
final class RuntimeConfig {
  static let shared = RuntimeConfig()
  static let defaultVideoBaseURL = URL(string: "http://10.42.0.2:8080")!
  static let requestTimeout: TimeInterval = 10

  private(set) var videoBaseURL: URL
  private(set) var speechEndpointURL: URL?

  private let defaults: UserDefaults
  private static let videoKey = "t2d.videoBaseURL"
  private static let speechKey = "t2d.speechEndpointURL"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    videoBaseURL = defaults.string(forKey: Self.videoKey)
      .flatMap { try? Self.validatedURL($0, isBaseURL: true) }
      ?? Self.defaultVideoBaseURL
    speechEndpointURL = defaults.string(forKey: Self.speechKey)
      .flatMap { try? Self.validatedURL($0, isBaseURL: false) }
  }

  /// Validate both values before changing the active, persistent configuration.
  func apply(videoBaseURLText: String, speechEndpointText: String) throws {
    let video = try Self.validatedURL(videoBaseURLText, isBaseURL: true)
    let speechText = speechEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
    let speech = speechText.isEmpty ? nil : try Self.validatedURL(speechText, isBaseURL: false)

    videoBaseURL = video
    speechEndpointURL = speech
    defaults.set(video.absoluteString, forKey: Self.videoKey)
    if let speech {
      defaults.set(speech.absoluteString, forKey: Self.speechKey)
    } else {
      defaults.removeObject(forKey: Self.speechKey)
    }
  }

  private static func validatedURL(_ text: String, isBaseURL: Bool) throws -> URL {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty,
      !value.contains(where: { $0.isWhitespace }),
      var components = URLComponents(string: value),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.port.map({ (1...65535).contains($0) }) ?? true
    else {
      throw ConfigurationError.invalidURL
    }
    guard host != "10.42.0.1" else {
      throw ConfigurationError.hotspotAddress
    }

    components.scheme = scheme
    if isBaseURL {
      while components.path.hasSuffix("/") {
        components.path.removeLast()
      }
    }
    guard let url = components.url else { throw ConfigurationError.invalidURL }
    return url
  }
}

private enum ConfigurationError: LocalizedError {
  case invalidURL
  case hotspotAddress

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Enter a complete HTTP or HTTPS laptop URL with a valid port, without credentials, a query or a fragment."
    case .hotspotAddress:
      return "10.42.0.1 is the T2D hotspot. Enter the laptop service address."
    }
  }
}
