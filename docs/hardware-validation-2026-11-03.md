# Real-camera hardware validation — 2026-11-03

This record updates the hardware status in
[the earlier Mac continuation](mac-continuation-2026-11-03.md). The real Pi
camera now sends video to the Ubuntu runtime, and the user confirms seeing
the real camera image in the physical Vision Pro app. Mac receivers also
decoded the forwarded footage using H.264 and VP8. Basic live playback works;
the complete automated physical-device smoke check did not pass.

## Active video path

```text
Pi IMX708 camera
    → H.264 / MPEG-TS / UDP 5600
Ubuntu 10.42.0.2
    → input decoding → WebRTC encoding / forwarding
Vision Pro, app endpoint http://10.42.0.2:8080
```

The user confirmed that the camera is physically attached to the Pi. Its
additional role for this test is capture, source encoding and transport only.
The Pi continues to host T2D at `10.42.0.1`; it does not host the application
endpoint, speech processing, perception, or flight control. Ubuntu remains
the central runtime at `/home/andrea/Talk2Drone_proj/t2d`. The Mac is used for
development and diagnostic receiving.

## Evidence and acceptance status

| Check | Observed result |
| --- | --- |
| Pi camera → Mac diagnostic UDP decoder | Passed: 45 decoded 640×480 frames, 2.933 s of media, first frame after 2.585 s; source `network/live`, sender exit code 0. [Evidence](../validation/pi-camera-udp-to-mac-check.json) |
| Pi camera → Ubuntu → Mac H.264 WebRTC receiver | Passed: 60 decoded 640×480 frames, 3.933 s of media, first frame after 1.603 s; WebRTC connected, Ubuntu source `network/live` with 61 frames received and 0.008 s frame age. [Evidence](../validation/real-camera-ubuntu-webrtc-h264.json) |
| Pi camera → Ubuntu → Mac VP8 WebRTC receiver | Passed: 60 decoded 640×480 frames, 3.933 s of media, first frame after 0.177 s; WebRTC connected, Ubuntu source `network/live` with 0.009 s frame age. [Evidence](../validation/real-camera-ubuntu-webrtc-vp8.json) |
| Physical Vision Pro app installation / launch | Installed and launched after the developer verification step. The launched Debug smoke check targets `http://10.42.0.2:8080`. |
| Physical Vision Pro rendered frames / Stop / reconnect / bounded failure | Passed within the partial smoke run: 31 rendered frames on first connection, Stop/cleanup, 31 frames after reconnect, and stopped after three retries against unavailable port 9. |
| Complete automated physical Vision Pro smoke check | Did not pass: the queued-connection cancellation assertion failed. A later unattended reconnect attempt timed out. No cause is established by these observations. |
| Wearer confirms visible real-camera image | Passed: user reported “funziona l app riesco a vedermi”. Focus quality and latency were not explicitly assessed. |
| Speech capture / local transcription on the physical headset | Pending; not exercised by the video smoke check. |
| Speech forwarding / intent interpretation / flight control | Outside this video test; not implemented by the video server and not validated. |
| Camera-to-display latency | Not measured. |
| Real-camera interruption and recovery | Pending. |
| Full cold boot and unattended offline startup | Pending; the two video services below are transient user services. |

First-frame times measure connection setup until the diagnostic receiver
decodes a frame. They are not camera-to-display latency measurements. Source
frame age measures the time since Ubuntu last decoded input, not the age of
the scene displayed by a viewer. The Mac WebRTC check does not validate the
physical headset renderer.

The retained [physical-device application log excerpt](../validation/native-device-real-camera-smoke.log)
records the successful assertions above and then
`FAIL Cancelled connection became active again`. The
[repeat-run excerpt](../validation/native-device-real-camera-smoke-repeat.log)
records the later reconnect timeout. Both excerpts retain only application
`[native-smoke]` and `[webrtc]` lines; neither contains a smoke `COMPLETE` result.
User confirmation establishes successful visible playback separately from
these incomplete automation results. Source `idle` with no active receiver
is normal because the backend opens input on demand.

## Start the real-camera test

These commands recreate the current transient configuration. Run each block
on the named machine as its normal user. Stop any existing instance first;
do not start a second runtime on port 8080. No dependency installation or
Internet connection is needed once the installed environments are present.

On **Pi**, as `prs`, start the camera source before connecting a viewer:

```bash
systemctl --user stop t2d-camera-source.service
systemd-run --user --unit=t2d-camera-source \
  --description='Talk2Drone camera source to Ubuntu' \
  --property=Restart=on-failure --property=RestartSec=2 \
  --property=TimeoutStopSec=10 \
  /usr/bin/rpicam-vid --nopreview --timeout 0 \
  --width 640 --height 480 --framerate 15 \
  --codec libav --libav-video-codec libx264 --libav-format mpegts \
  --low-latency --intra 15 --bitrate 1500000 \
  --autofocus-mode continuous \
  --output 'udp://10.42.0.2:5600?pkt_size=1316'
systemctl --user status t2d-camera-source.service --no-pager
```

On **Ubuntu**, as `andrea`:

```bash
systemctl --user stop t2d-video.service
systemd-run --user --unit=t2d-video \
  --description='Talk2Drone laptop real camera video test' \
  --working-directory=/home/andrea/Talk2Drone_proj/t2d \
  --setenv=T2D_HOST=10.42.0.2 \
  --setenv='T2D_VIDEO_SOURCE=udp://0.0.0.0:5600?fifo_size=65536&overrun_nonfatal=1' \
  --setenv=T2D_VIDEO_FORMAT=mpegts --setenv=T2D_VIDEO_FPS=15 \
  --property=Restart=on-failure --property=RestartSec=3 \
  --property=TimeoutStopSec=15 \
  /home/andrea/Talk2Drone_proj/t2d/.venv/bin/python \
  /home/andrea/Talk2Drone_proj/t2d/webrtc_server.py
systemctl --user status t2d-video.service --no-pager
curl --max-time 5 http://10.42.0.2:8080/health
```

If the initial stop reports that a unit is not loaded, proceed to its startup
command. If a previous failed transient unit remains loaded, inspect its
journal and use `systemctl --user reset-failed UNIT.service` before recreating
that unit. Neither service is enabled at boot by these commands. Process
restart supervision does not by itself prove recovery from camera or Wi-Fi
interruption.

On **Vision Pro**, connect to T2D, keep the device awake and unlocked, open
TalkToDrone, allow local-network access, set the video server to
`http://10.42.0.2:8080`, and select **Connect Video**. The camera sender's UDP
URL is internal to Ubuntu ingest and must not be entered in the headset app.
Signaling uses HTTP 8080; WebRTC media uses negotiated UDP ports. Both need
local connectivity. Internet may be required separately to establish or renew
Apple's developer trust for the installed development build.

## Inspect and stop

On **Pi**:

```bash
journalctl --user-unit=t2d-camera-source.service -n 40 --no-pager
systemctl --user stop t2d-camera-source.service
```

On **Ubuntu**:

```bash
journalctl --user-unit=t2d-video.service -n 40 --no-pager
systemctl --user stop t2d-video.service
```

Use **Stop Video** in the headset before stopping the services for a clean
manual shutdown. Stopping these units does not stop the Pi hotspot or SSH.
Do not run a second camera capture command while the source service owns the
camera.

## Restore the previous synthetic backend

The previous Ubuntu unit was saved before changing the source at
`/home/andrea/Talk2Drone_proj/t2d/validation/t2d-video-before-real-camera.service`.
The following recreates its synthetic runtime settings as a transient user
unit; it does not install that backup as a persistent boot service.

Stop `t2d-camera-source.service` on **Pi** with the command above. Then run on
**Ubuntu**, as `andrea`:

```bash
systemctl --user stop t2d-video.service
systemd-run --user --unit=t2d-video \
  --description='Talk2Drone laptop video test' \
  --working-directory=/home/andrea/Talk2Drone_proj/t2d \
  --setenv=T2D_HOST=10.42.0.2 --setenv=T2D_VIDEO_SOURCE=test \
  --property=Restart=on-failure --property=RestartSec=3 \
  --property=TimeoutStopSec=15 \
  /home/andrea/Talk2Drone_proj/t2d/.venv/bin/python \
  /home/andrea/Talk2Drone_proj/t2d/webrtc_server.py
curl --max-time 5 http://10.42.0.2:8080/health
```

Reconnect the viewer and verify that the source is explicitly reported as
synthetic. This rollback keeps the same Ubuntu application endpoint and does
not change Wi-Fi configuration or headset settings.

## Remaining limits

The source uses 640×480 at 15 fps and software H.264 encoding on the Pi.
Continuous autofocus is requested; focus quality has not been confirmed.
The cancellation failure and later unattended reconnect timeout remain
unresolved. Camera interruption/recovery, measured latency, sustained playback,
cold boot and physical speech remain unvalidated. These transient services
are a supervised test setup. No flight command was part of these tests.
