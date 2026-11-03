# Mac continuation — 2026-11-03, Europe/Berlin

The native client integration is implemented and builds for both physical
visionOS and the simulator. Synthetic streaming from the existing Ubuntu
runtime has been verified in the native simulator. **The first milestone is
not yet accepted:** the physical camera is not detected, and physical-headset
installation/streaming has not completed.

## Current machines and responsibilities

| Device | Address / source | Observed state |
| --- | --- | --- |
| Raspberry Pi, SSH `prs` | `10.42.0.1`, `/home/prs/PROJECTS/Talk2Drone` | T2D hotspot; no Pi video server/containers started |
| Ubuntu laptop, user `andrea` | `10.42.0.2:8080`, `/home/andrea/Talk2Drone_proj/t2d` | Existing synthetic video service live; user explicitly wants Ubuntu retained as runtime |
| Mac | DHCP `10.42.0.56`; `/Users/prs/PRS/EICHINGER/TalkToDrone` | Native source/build; backend test copy at `/Users/prs/Projects/Talk2Drone-video` |
| Physical Vision Pro | Paired, visionOS 26.6; user confirms T2D | Development connection intermittent; installation failed with CoreDevice connection errors |
| Camera | User confirms attached to Pi; model/CSI port unknown | No cameras enumerated; IMX708 driver probe fails |

The Mac did not take Linux's `.2` address and did not replace Ubuntu as runtime.
A temporary Mac loopback-only test server on `127.0.0.1:18080` was used solely
to exercise simulator recovery, then stopped. Ubuntu and Pi services were not
restarted or reconfigured.

The user-confirmed physical camera location needs a source-only capture and
transport path from Pi to Ubuntu. Processing, WebRTC-to-headset, speech, and
future control remain on Ubuntu. No Pi WebRTC/Hailo/flight service was restored.

## Native changes

- `RuntimeConfig.swift`: one default laptop URL, persistent in-app overrides,
  URL validation and optional independent speech endpoint (disabled by default).
- `WebRTCClient.swift`: video-only non-trickle ICE, endpoint snapshots,
  cancellation/generation/peer identity guards, health/source reporting,
  actual decoded-frame monitoring and bounded retry.
- `WebRTCVideoView.swift`: explicit track add/remove/dismantle, nonisolated
  decode callback, locked latest-frame buffer, MainActor display delivery and
  stale-renderer identity checks. A slow UI does not queue every decoded frame.
- `ContentView.swift`: server settings, Connect/Retry/Stop and separate source,
  connection and received-frame statuses.
- `NetworkClient.swift` and a guard in `SpeechRecognition.swift`: no obsolete
  Pi speech address; retain transcription locally when forwarding is disabled.
- `Info.plist` and project permission strings: local-network HTTP and clear
  permission explanation, without a global arbitrary-load exemption.
- `DebugVideoSmoke.swift`: opt-in Debug-only native transport checks. Normal
  launch does not run them; Release excludes them.

Existing local uncommitted Swift/Xcode changes were the starting point. No
commit/reset was made, and unrelated speech/synthesis behavior was preserved.

Initial connection plus three automatic retries use delays of 2, 4 and 8 seconds.
Native SDP callbacks and ICE gathering have 10-second limits; HTTP has bounded
timeouts, peer connection and first-frame waits are 15 seconds, and frame stalls
and disconnected states have a 5-second grace period. Source health is polled
every 2 seconds; requests can extend the observed detection time. Retry is
manual after the budget is exhausted. A received track is not labelled live
until the renderer receives decoded frames.

## Validation actually completed

| Check | Result / evidence |
| --- | --- |
| Signed visionOS build, Xcode 27.0 | Passed; `validation/native-device-build.log` |
| visionOS 27 simulator build | Passed; `validation/native-simulator-build.log` |
| Runtime configuration boundary checks | `scripts/test-runtime-config.sh`; `validation/runtime-config-tests.txt` |
| Existing Python backend on Mac, Python 3.12.16 | 16 passed; `validation/mac-pytest.txt` |
| Mac Python receiver → Ubuntu H.264 and VP8 | 60 decoded 640×480 frames each; first frame 0.146/0.291 seconds; `validation/mac-to-linux-*.json` |
| Native simulator → Ubuntu synthetic stream | Decoded/rendered frames, Stop/cleanup, reconnect, bounded failure, queued-connect cancellation, recovery; `validation/native-simulator-smoke.log` |
| Native simulator active-stream backend loss/restart | Loss detected in 4.028 s; new frame 2.020 s after backend readiness; `validation/native-simulator-server-recovery.md` |
| Pi hotspot and camera readback | `validation/mac-pi-readback.txt`, `validation/mac-camera-detection.txt` |

First-frame times measure connection setup, **not** camera-to-display latency.
All successfully tested video was explicitly synthetic. The restart check stops
the entire test backend process; it does not validate camera-only interruption.
Physical-headset playback, real-camera latency/recovery and cold-boot/offline
startup remain unverified. No flight commands or transmitting flight imports
were used.

## Exact native startup and test commands

```bash
cd /Users/prs/PRS/EICHINGER/TalkToDrone
xcodebuild -project TalkToDrone.xcodeproj -scheme TalkToDrone \
  -destination 'generic/platform=visionOS' \
  -derivedDataPath /tmp/t2d-native-build build
scripts/test-runtime-config.sh
```

Use Xcode Run on the paired physical headset, keep it awake/unlocked on T2D,
allow local-network access, and select **Connect Video**. The default endpoint
is `http://10.42.0.2:8080`; `/health` is GET and `/offer` is POST. Active audio
and data channels are not part of this server contract. Media requires dynamic
UDP connectivity on T2D. Optional speech is a separate endpoint, not port 8080.

To run the explicit simulator check after building for its destination:

```bash
xcrun simctl install booted /tmp/t2d-native-build/Build/Products/Debug-xrsimulator/TalkToDrone.app
xcrun simctl launch --terminate-running-process --console-pty booted \
  com.floeiy.TalkToDrone --t2d-video-smoke
```

Use `--console-pty` so progress is not hidden by buffered standard output. The
check leaves video connected after success; Stop in the app or terminate the
simulator app afterward. A Debug physical-device run can use the same launch
argument through Xcode or `devicectl device process launch --console`.

The existing Ubuntu startup/rollback commands remain in the backend `README.md`
on Pi and in the Mac backend copy. Do not start a second service on the occupied
Ubuntu port. The existing service is transient, not a demonstrated boot service.

## Remaining blockers and next actions

1. **Ubuntu administrative access.** TCP 22 refused connections. User reported
   `ssh.service` not found. On Ubuntu, install `openssh-server`, then start SSH:
   `sudo apt update`, `sudo apt install openssh-server`,
   `sudo systemctl enable --now ssh`. This was provided to the user; successful
   installation/access has not yet been observed. Keep Ubuntu as runtime.
2. **Physical camera detection.** Both `rpicam-vid --list-cameras` and `cam -l`
   return no cameras. Kernel probe of IMX708 fails reading chip ID (-5); focus
   motor I2C writes fail (-121). This is below the network/video transport.
   `/boot/firmware/config.txt` forces `camera_auto_detect=0` and
   `dtoverlay=imx708`, which selects CAM/DISP1. CAM/DISP0 requires the `cam0`
   option if the actual sensor is IMX708. Confirm model, connector, cable and
   power before choosing a change; no overlay was guessed or reboot performed.
   See `validation/mac-camera-readiness.md` for evidence and a conditional,
   **untested** source-only UDP sender command for after detection works.
3. **Physical headset.** It was paired/unlocked and briefly reachable, but
   install attempts lost the CoreDevice connection (4016, 3002/IXRemoteError,
   then 4000 timeout). The new app is built, but install/run is not claimed.
   Keep the headset worn, unlocked and reachable, then install and repeat the
   synthetic native checks before selecting the real camera source.
4. **Acceptance.** Once camera enumeration and Ubuntu access work, configure
   capture-only transport to Ubuntu UDP 5600 and select it as backend input.
   Validate real footage through the physical headset, camera-only interruption,
   latency and startup/offline behavior. Only then mark the video milestone done.

After video acceptance: laptop speech API, constrained language/intent backend,
spatial target resolution, and a separate validated flight gateway.
