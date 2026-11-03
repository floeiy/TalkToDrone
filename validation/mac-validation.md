# Mac backend validation — 2026-11-03

Run from `/Users/prs/Projects/Talk2Drone-video` on the Mac, over T2D to the
existing Linux runtime at `http://10.42.0.2:8080`. No Pi application service,
camera publisher, flight code, or Linux service restart was performed.

The Mac initially had only Apple Python 3.9.6. An isolated `.bootstrap` venv
contains uv 0.13.7; uv downloaded CPython 3.12.16 into `.python/` and created
`.venv/`. No Linux virtual environment was copied. The three runtime pins are
unchanged: aiohttp 3.14.5, aiortc 1.15.0 and av 17.1.0. Dependency installation
needed Internet; the tested WebRTC path uses the local T2D network.

Commands executed successfully:

```bash
.venv/bin/python -m pytest -q tests
.bootstrap/bin/uv pip check --python .venv/bin/python
.venv/bin/python scripts/smoke_video.py --url http://10.42.0.2:8080 --frames 60 --codec H264
.venv/bin/python scripts/smoke_video.py --url http://10.42.0.2:8080 --frames 60 --codec VP8
curl --max-time 5 -sS http://10.42.0.2:8080/health
```

- `mac-pytest.txt`: 16 passed in 11.10 seconds. pytest-asyncio emitted a warning
  that `asyncio_default_fixture_loop_scope` is unset; no test failed.
- `mac-pip-check.txt`: all 28 installed packages compatible.
- `mac-python-packages.txt`: complete resolved package versions.
- `mac-to-linux-h264.json`: 60 actual decoded 640×480 frames; first decoded frame
  0.146 s after starting negotiation; media duration 1.967 s.
- `mac-to-linux-vp8.json`: a subsequent independent session decoded 60 640×480
  frames; first frame 0.291 s; media duration 1.967 s.
- `mac-linux-health-after.json`: zero peers, source idle after client shutdown.

Both sessions explicitly received **synthetic** footage. First-frame time is
connection setup time, not camera-to-display latency. These checks establish
the Mac-to-Linux Python WebRTC path and normal close/reconnect; they do not
validate the native Vision Pro app, actual drone camera, loss/restart recovery,
or offline cold boot.

Read-only Pi evidence is in `mac-pi-readback.txt`: `T2DHotspot` active on wlan0
at 10.42.0.1/24, autoconnect enabled, shared IPv4, NetworkManager and SSH enabled,
system default still `graphical.target`, no Docker containers listed, and no
TCP video service on 8080. `/dev/video19` through `/dev/video35` name codec/ISP
devices; that device inventory alone does not establish a usable camera source.

Backend source files were unchanged. Local environment directories and these
validation reports are the only additions from backend validation.
