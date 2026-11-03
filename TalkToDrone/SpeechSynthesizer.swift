//
//  SpeechSynthesizer.swift
//  TalkToDrone
//

import AVFoundation

@MainActor
final class SpeechSynthesizer {

  static let shared = SpeechSynthesizer()

  private let synthesizer = AVSpeechSynthesizer()

  private init() {}

  func speak(_ text: String) {
    let cleanedText = text.trimmingCharacters(
      in: .whitespacesAndNewlines
    )

    guard !cleanedText.isEmpty else {
      return
    }

    let utterance = AVSpeechUtterance(
      string: cleanedText
    )

    utterance.voice =
      AVSpeechSynthesisVoice(
        language: "en-US"
      )

    utterance.rate =
      AVSpeechUtteranceDefaultSpeechRate

    synthesizer.speak(utterance)
  }
}
