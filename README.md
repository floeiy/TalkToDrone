# TalkToDrone — native Vision Pro client

Read [AGENTS.md](AGENTS.md) for the laptop-centric architecture and
[the hardware handover](docs/hardware-validation-2026-11-03.md) for the current
setup, startup commands, verified results and remaining checks. The earlier
[Mac continuation record](docs/mac-continuation-2026-11-03.md) preserves the
implementation and simulator validation history.

The Raspberry Pi provides the `T2D` network at `10.42.0.1`. The existing Linux
video runtime is `http://10.42.0.2:8080`. The Mac currently has DHCP address
`10.42.0.56`; do not assign it `.2` while Linux owns that address.

## Run the native app

Open `TalkToDrone.xcodeproj`, choose scheme `TalkToDrone`, select the paired
Vision Pro, and Run. Both headset and runtime must be connected to T2D. Allow
local-network access when asked. In the app, enter the laptop video server URL,
apply it, then select **Connect Video**. **Retry Video** starts a fresh session;
**Stop Video** cancels connection/retry work and releases the track.

The default server URL is defined once in `TalkToDrone/RuntimeConfig.swift` and
can be changed in the app without rebuilding. Settings persist on that device.
The client posts a video-only, fully gathered ICE offer to `/offer` and reads
`/health`. No external STUN/TURN service or Internet connection is needed for
LAN video. HTTP signaling uses port 8080; media uses negotiated UDP ports.

Real-camera playback on the physical Vision Pro was confirmed by the wearer on
2026-11-03. The IMX708 camera on the Pi sends H.264/MPEG-TS over UDP 5600 to
Ubuntu, which forwards video over WebRTC. Both source and runtime currently use
transient user services; see the hardware handover to recreate them after a
restart. Source status and received-frame status are shown separately.

Speech transcription remains available. Forwarding is disabled by default;
an optional, separate laptop speech endpoint can be configured. The video
runtime does not implement speech, intent extraction, or flight commands.

## Build and validation commands

```bash
cd /Users/prs/PRS/EICHINGER/TalkToDrone
xcodebuild -project TalkToDrone.xcodeproj -scheme TalkToDrone \
  -destination 'generic/platform=visionOS' \
  -derivedDataPath /tmp/t2d-native-build build
```

The project uses LiveKitWebRTC via Swift Package Manager; dependency resolution
requires Internet on a first build. Subsequent operation on T2D is local.
The local-network declaration uses `NSAllowsLocalNetworking` and
`NSLocalNetworkUsageDescription`; no global arbitrary HTTP exception is needed.
See [Apple's local-network ATS documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

The backend source/context has been copied from the Pi to
`/Users/prs/Projects/Talk2Drone-video`, with its own Python 3.12 environment:

```bash
cd /Users/prs/Projects/Talk2Drone-video
.venv/bin/python -m pytest -q tests
.venv/bin/python scripts/smoke_video.py --url http://10.42.0.2:8080 --frames 60
curl --max-time 5 http://10.42.0.2:8080/health
```

For developer validation only, Debug builds recognize `--t2d-autoconnect` and
`--t2d-video-smoke`. The latter checks decoded frames, Stop, reconnect, bounded
failure on an unavailable server, cancellation, and recovery; it leaves the
valid video stream connected after success. It never starts speech or flight
commands. Neither option runs during a normal launch or in a Release build.

The Raspberry source and handover remain at
`/home/prs/PROJECTS/Talk2Drone` (case-sensitive), accessed with
`ssh prs@10.42.0.1`. Runtime startup instructions are in its `README.md` and in
the Mac backend copy. Do not run the old Pi WebRTC/Hailo/MAVSDK services.
