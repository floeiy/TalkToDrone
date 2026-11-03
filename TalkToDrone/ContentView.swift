import SwiftUI

struct ContentView: View {
  private let speechRecognizer = SpeechRecognizer.shared
  private let webRTCClient = WebRTCClient.shared
  private let runtimeConfig = RuntimeConfig.shared

  @State private var videoAddress = RuntimeConfig.shared.videoBaseURL.absoluteString
  @State private var speechAddress = RuntimeConfig.shared.speechEndpointURL?.absoluteString ?? ""
  @State private var configurationError: String?
  @State private var configurationMessage = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        Text("Talk to Drone")
          .font(.largeTitle)
          .fontWeight(.semibold)

        serverSection
        cameraSection

        Divider()

        speechSection
      }
      .padding(40)
    }
    .onDisappear { webRTCClient.disconnect() }
    .task {
      #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--t2d-video-smoke") {
        await DebugVideoSmoke.run(client: webRTCClient, baseURL: runtimeConfig.videoBaseURL)
      } else if ProcessInfo.processInfo.arguments.contains("--t2d-autoconnect") {
        await webRTCClient.connect(baseURL: runtimeConfig.videoBaseURL)
      }
      #endif
    }
  }

  private var serverSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Laptop video server")
        .font(.headline)
      TextField(RuntimeConfig.defaultVideoBaseURL.absoluteString, text: $videoAddress)
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .accessibilityIdentifier("videoServerURL")

      DisclosureGroup("Optional speech service") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Leave empty to keep speech on this device. Configure a laptop speech service to forward transcripts.")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField("Full speech endpoint URL (optional)", text: $speechAddress)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .accessibilityIdentifier("speechEndpointURL")
        }
        .padding(.top, 8)
      }

      Button("Apply Server Settings") {
        do {
          try runtimeConfig.apply(videoBaseURLText: videoAddress, speechEndpointText: speechAddress)
          webRTCClient.disconnect()
          videoAddress = runtimeConfig.videoBaseURL.absoluteString
          speechAddress = runtimeConfig.speechEndpointURL?.absoluteString ?? ""
          configurationError = nil
          configurationMessage = "Settings saved. Connect video to use this server."
        } catch {
          configurationError = error.localizedDescription
          configurationMessage = ""
        }
      }
      .accessibilityIdentifier("applyServerSettings")

      if let configurationError {
        Text(configurationError)
          .font(.caption)
          .foregroundStyle(.red)
      } else if !configurationMessage.isEmpty {
        Text(configurationMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text("Current server: \(runtimeConfig.videoBaseURL.absoluteString)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: 640)
  }

  // MARK: - Camera

  @ViewBuilder
  private var cameraSection: some View {
    VStack(spacing: 12) {
      Text("Laptop Video")
        .font(.headline)
        .foregroundStyle(.secondary)

      Text(webRTCClient.connectionStatus)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("videoConnectionStatus")

      Text(webRTCClient.sourceStatus)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 640)
        .accessibilityIdentifier("videoSourceStatus")

      if let videoTrack = webRTCClient.remoteVideoTrack {
        WebRTCVideoView(videoTrack: videoTrack, onFrameReceived: {
          webRTCClient.didReceiveVideoFrame(from: videoTrack)
        })
          .frame(width: 640, height: 480)
          .clipShape(RoundedRectangle(cornerRadius: 16))

        Text(webRTCClient.frameStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("videoFrameStatus")
      } else {
        Rectangle()
          .fill(.black)
          .frame(width: 640, height: 480)
          .clipShape(RoundedRectangle(cornerRadius: 16))

        Text("No video track connected")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Button(webRTCClient.isRunning ? "Retry Video" : "Connect Video") {
          Task {
            await webRTCClient.connect(baseURL: runtimeConfig.videoBaseURL)
          }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("connectOrRetryVideo")

        Button("Stop Video") {
          webRTCClient.disconnect()
        }
        .disabled(!webRTCClient.isRunning)
        .accessibilityIdentifier("stopVideo")
      }
    }
  }

  // MARK: - Speech

  @ViewBuilder
  private var speechSection: some View {
    if runtimeConfig.speechEndpointURL == nil {
      Text("Speech forwarding is disabled. You can still transcribe speech here.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    if let error = speechRecognizer.errorMessage {
      Text(error)
        .foregroundStyle(.red)
    } else if speechRecognizer.isListening {
      Text("Listening...")
        .font(.title3)
        .foregroundStyle(.green)
    } else {
      Text("Ready")
        .font(.title3)
        .foregroundStyle(.secondary)
    }

    Text(
      speechRecognizer.transcribedText.isEmpty
        ? "Your speech will appear here."
        : speechRecognizer.transcribedText
    )
    .font(.title2)
    .multilineTextAlignment(.center)
    .frame(maxWidth: 500)
    .padding()

    if speechRecognizer.isListening {
      Button("Stop Listening") {
        speechRecognizer.stopListening()
      }
      .buttonStyle(.borderedProminent)
    } else {
      Button("Start Listening") {
        Task {
          await speechRecognizer.startListening()
        }
      }
      .buttonStyle(.borderedProminent)
    }

    if !speechRecognizer.receivedReply.isEmpty {
      VStack(spacing: 8) {
        Text("Drone response")
          .font(.headline)
          .foregroundStyle(.secondary)

        Text(speechRecognizer.receivedReply)
          .font(.title2)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 500)
      }
      .padding()
    }
  }
}

#Preview {
  ContentView()
}
