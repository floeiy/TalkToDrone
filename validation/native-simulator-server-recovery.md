# Native simulator server-restart recovery — 2026-11-03

Result: **passed** on the visionOS 27.0 simulator with the built native app at
`/tmp/t2d-native-build/Build/Products/Debug-xrsimulator/TalkToDrone.app`.

An isolated Mac backend bound only to `127.0.0.1:18080` served explicitly
synthetic video. The native client decoded a frame, the backend process was
terminated gracefully, and a fresh backend process was started after the
client reported service loss. The same running native app automatically
reconnected and decoded a new frame.

- Client detected service loss 4.028 seconds after backend exit.
- New native decoded frame arrived 2.020 seconds after the restarted backend
  became ready (6.267 seconds after the original backend exit).
- `/health` before loss and after recovery reported one peer and a live
  synthetic source.
- Both backend instances exited with status 0. Simulator app was terminated
  after the test; no process remains listening on TCP 18080.

These timings describe service restart/reconnection, not camera-to-display
latency. This is **not a camera-source-only interruption test**, a physical
Vision Pro test, or a T2D network-disconnection test. Ubuntu/Pi services and
network configuration were untouched.

Commands underlying the test:

```bash
cd /Users/prs/Projects/Talk2Drone-video
T2D_HOST=127.0.0.1 T2D_PORT=18080 T2D_VIDEO_SOURCE=test \
  .venv/bin/python -u webrtc_server.py

xcrun simctl launch --console-pty --terminate-running-process \
  4AFF57C7-B6BD-46C9-81D8-9DEFC6C35E40 com.floeiy.TalkToDrone \
  --t2d-autoconnect -t2d.videoBaseURL http://127.0.0.1:18080
```

The test driver stopped its own backend PID after the first native decoded
frame, waited for `[webrtc] attempt 1 failed`, restarted the same command,
then waited for a second `[webrtc] first decoded video frame`. The URL was
overridden only in the process launch arguments; no persistent UserDefaults
write was made. Simulator app and isolated backend were stopped during cleanup.

Evidence:

- `native-simulator-server-recovery.json`: monotonic event times and health data.
- `native-simulator-server-recovery-app.log`: native connection/frame events.
- `native-simulator-server-recovery-backend.log`: server startup, negotiation,
  cleanup and shutdown for both processes.
