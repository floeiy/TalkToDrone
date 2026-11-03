# Pi camera readiness — 2026-11-03

Read-only observations in `mac-camera-detection.txt` are from the Pi's current
boot. The Pi kernel journal has an incorrect historical clock; timestamps in
that raw output are not the date of this validation.

`rpicam-vid --list-cameras` reports `No cameras available!`; `cam -l` also lists
none. The kernel attempted an IMX708 at I2C 11-001a but failed to read its chip
ID (error -5) and failed driver probe. The focus motor also reports I2C write
failures (-121). The IMX708 driver directory has no bound camera device.
Available video devices are codec/ISP nodes, and the current user's ACL permits
media-device access, so this is not just a missing application stream or a
simple user-permission failure.

`/boot/firmware/config.txt` sets `camera_auto_detect=0` and
`dtoverlay=imx708`. The installed overlay documentation is actually under
`/boot/firmware/current/overlays/README` (`os_prefix=current/`). It describes
IMX708 as using Unicam 1 by default and offers the `cam0` override. Inspection
of the installed DTBO confirms default `csi1`, `cam1_clk`, `cam1_reg`; `cam0`
switches to `csi0`, `cam0_clk`, `cam0_reg` and `i2c_csi_dsi0`.

Thus the configured camera port is CAM/DISP1. If the actual supported IMX708 is
connected to CAM/DISP0, the corresponding configuration is
`dtoverlay=imx708,cam0`. No configuration was changed; confirm actual camera
model, connector and ribbon seating before choosing a fix. The evidence cannot
distinguish wrong port, cable/power problem, or a different sensor model by itself.

After camera enumeration is restored, the smallest existing-runtime transport
is rpicam/libav H.264 in MPEG-TS over UDP. Installed rpicam has libav support;
installed FFmpeg lists libx264. This source-only command is a proposed
**untested** command, not a running service:

```bash
# On the Pi, only after `rpicam-vid --list-cameras` names the intended camera.
# Replace RUNTIME_IP with the chosen central runtime address.
rpicam-vid --nopreview --timeout 0 --width 640 --height 480 --framerate 15 \
  --codec libav --libav-video-codec libx264 --libav-format mpegts \
  --low-latency --intra 15 --bitrate 1500000 \
  --output 'udp://RUNTIME_IP:5600?pkt_size=1316'

# On the central runtime host, with the sender running:
T2D_HOST=RUNTIME_IP \
  T2D_VIDEO_SOURCE='udp://0.0.0.0:5600?fifo_size=65536&overrun_nonfatal=1' \
  T2D_VIDEO_FORMAT=mpegts .venv/bin/python webrtc_server.py
```

This keeps capture/transport on the camera source and WebRTC/processing on the
central runtime. No ROS adapter is required for this candidate path. Do not
overwrite Linux's currently running synthetic service blindly; coordinate its
stop/start or use the separately selected Mac endpoint. Runtime source port
5600 is UDP; the client continues to use the chosen host's HTTP 8080 endpoint.
