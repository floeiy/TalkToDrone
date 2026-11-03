//
//  SpeechRecognition.swift
//  TalkToDrone
//

import AVFoundation
import Foundation
import Observation
import Speech

@Observable
@MainActor
final class SpeechRecognizer {
  static let shared = SpeechRecognizer()

  var transcribedText = ""
  var receivedReply = ""
  var isListening = false
  var errorMessage: String?

  private var isPrimed = false
  private var isStarting = false

  private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?

  private init() {}

  // MARK: - Permissions

  private func primeAudioIfNeeded() async {
    guard !isPrimed else { return }

    let speechStatus = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }

    guard speechStatus == .authorized else {
      errorMessage = "Speech recognition not authorized"
      return
    }

    guard await AVAudioApplication.requestRecordPermission() else {
      errorMessage = "Microphone access not authorized"
      return
    }

    guard speechRecognizer != nil else {
      errorMessage = "Speech recognizer could not be created"
      return
    }

    isPrimed = true
  }

  // MARK: - Audio tap

  /// AVAudioEngine invokes its tap on a real-time audio thread, so the closure
  /// must not inherit MainActor isolation from SpeechRecognizer.
  nonisolated private static func installTap(
    on inputNode: AVAudioInputNode,
    format: AVAudioFormat,
    request: SFSpeechAudioBufferRecognitionRequest
  ) {
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      request.append(buffer)
    }
  }

  // MARK: - Listening

  func startListening() async {
    guard !isListening, !isStarting else { return }

    errorMessage = nil
    receivedReply = ""
    isStarting = true
    defer { isStarting = false }

    if !isPrimed {
      await primeAudioIfNeeded()
    }

    guard isPrimed else { return }
    guard let speechRecognizer, speechRecognizer.isAvailable else {
      errorMessage = "Speech recognizer unavailable"
      return
    }

    recognitionTask?.cancel()
    recognitionTask = nil

    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(.record, mode: .measurement, options: [])
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      errorMessage = "Audio session setup failed: \(error.localizedDescription)"
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if speechRecognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }
    recognitionRequest = request

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    Self.installTap(on: inputNode, format: recordingFormat, request: request)

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
      inputNode.removeTap(onBus: 0)
      recognitionRequest = nil
      return
    }

    transcribedText = ""
    isListening = true

    recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }

      Task { @MainActor in
        let wasListening = self.isListening

        if let result {
          let text = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)

          // Cancellation can yield a final empty callback. Keep the
          // last meaningful transcription visible in the UI.
          if !text.isEmpty {
            self.transcribedText = text
          }
        }

        if wasListening, error != nil || (result?.isFinal ?? false) {
          self.stopListening()
        }
      }
    }
  }

  func stopListening() {
    guard isListening else { return }

    let finalText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
    isListening = false

    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)

    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil

    guard !finalText.isEmpty else { return }
    guard RuntimeConfig.shared.speechEndpointURL != nil else { return }

    Task {
      do {
        let reply = try await NetworkClient.shared.sendTranscript(finalText)
        receivedReply = reply
        SpeechSynthesizer.shared.speak(reply)
      } catch {
        errorMessage = "Network error: \(error.localizedDescription)"
      }
    }
  }
}
