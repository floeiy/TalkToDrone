//
//  NetworkClient.swift
//  TalkToDrone
//

import Foundation

@MainActor
final class NetworkClient {
  static let shared = NetworkClient()

  private let session: URLSession

  private init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = RuntimeConfig.requestTimeout
    configuration.timeoutIntervalForResource = 15
    session = URLSession(configuration: configuration)
  }

  func sendTranscript(_ transcript: String) async throws -> String {
    guard let receiverURL = RuntimeConfig.shared.speechEndpointURL else {
      throw NetworkError.speechDisabled
    }
    let payload = TranscriptRequest(transcript: transcript)
    let body = try JSONEncoder().encode(payload)

    var request = URLRequest(url: receiverURL)
    request.httpMethod = "POST"
    request.timeoutInterval = RuntimeConfig.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw NetworkError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      throw NetworkError.httpError(statusCode: httpResponse.statusCode)
    }

    let decodedResponse = try JSONDecoder().decode(ServerResponse.self, from: data)
    return decodedResponse.reply
  }
}

private struct TranscriptRequest: Encodable {
  let transcript: String
}

private struct ServerResponse: Decodable {
  let reply: String
}

private enum NetworkError: LocalizedError {
  case speechDisabled
  case invalidResponse
  case httpError(statusCode: Int)

  var errorDescription: String? {
    switch self {
    case .speechDisabled:
      return "Speech forwarding is disabled. Configure a laptop speech service to forward transcripts."
    case .invalidResponse:
      return "The server returned an invalid response."
    case .httpError(let statusCode):
      return "The server returned HTTP status \(statusCode)."
    }
  }
}
