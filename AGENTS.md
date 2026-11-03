# AGENTS.md

## Project: Talk2Drone

### Purpose

Talk2Drone is a small-scale indoor autonomous-drone demonstrator with three primary devices:

1. **Raspberry Pi 5** — provides the dedicated local Wi-Fi hotspot/network used by the system.
2. **Laptop / workstation** — performs the main runtime computation and acts as the central application/control node.
3. **Apple Vision Pro** — provides the user-facing interface: live drone video, speech interaction, and visual feedback.

The drone uses a **Pixhawk Mini / PX4 flight controller**. The final system is intended to allow a user wearing the Vision Pro to speak a spatial command such as "land on the red box", have the command interpreted on the laptop, resolve it to a target location in the local indoor reference frame, and ultimately transmit the resulting command/coordinates to PX4 through the telemetry/control link.

The project should be developed as a robust demo system, not as a collection of one-off scripts.

---

# 1. Current System Architecture

The current intended architecture is:

```text
                           ┌──────────────────────┐
                           │    Apple Vision Pro  │
                           │                      │
                           │  - live video UI     │
                           │  - speech input      │
                           │  - status/feedback   │
                           └──────────┬───────────┘
                                      │
                                      │ T2D Wi-Fi
                                      │
                           ┌──────────▼───────────┐
                           │       Laptop         │
                           │                      │
                           │  CENTRAL RUNTIME     │
                           │                      │
                           │  - receives video    │
                           │  - processes video   │
                           │  - receives speech   │
                           │  - language parsing  │
                           │  - target extraction │
                           │  - coordinate logic  │
                           │  - VP communication  │
                           │  - telemetry output  │
                           └───────┬───────┬──────┘
                                   │       │
                   camera stream   │       │ telemetry / MAVLink
                                   │       │
                         ┌─────────▼──┐   ┌▼─────────────┐
                         │ Drone/Pi   │   │ PX4 / Pixhawk│
                         │ camera src │   │ flight ctrl  │
                         └────────────┘   └──────────────┘

                           ┌──────────────────────┐
                           │   Raspberry Pi 5     │
                           │                      │
                           │  NETWORK ROLE ONLY   │
                           │  - T2D Wi-Fi AP      │
                           │  - 10.42.0.1/24      │
                           │  - headless boot     │
                           └──────────────────────┘
```

## Important architectural change

Older versions of this project used, or experimented with:

- local LLM inference on the Raspberry Pi via Hailo AI HAT,
- Pi-side speech handling,
- Pi-side WebRTC delivery directly to Vision Pro,
- direct Pixhawk↔Pi USB MAVLink routing,
- Pi-side MAVSDK control.

These assumptions are **obsolete unless explicitly reintroduced by the user**.

The current design is:

- **Raspberry Pi = hotspot/network infrastructure only.**
- **Laptop = central compute, video-processing, language, and control node.**
- **Vision Pro = user interface / speech / visualization client.**
- **Pixhawk/PX4 = flight controller.**
- **Telemetry/control from the laptop to PX4 will use a telemetry radio or equivalent flight-control link.**

Do not silently restore the older Pi-centric architecture.

---

# 2. Network Topology

The Raspberry Pi hosts the dedicated Wi-Fi network:

```text
SSID: T2D
Pi IP: 10.42.0.1/24
Subnet: 10.42.0.0/24
```

The hotspot is configured through NetworkManager and starts automatically at boot.

The laptop uses a fixed address on T2D:

```text
Laptop IP: 10.42.0.2/24
```

The laptop may or may not have a second Internet connection during a demo. Therefore:

- the T2D network must function fully without Internet,
- no core runtime functionality may depend on Internet connectivity unless explicitly marked optional,
- cloud/API-dependent features must fail gracefully if no Internet uplink exists.

The Pi is operated headlessly. No GUI login should be required for normal operation.

---

# 3. Raspberry Pi Responsibilities

The Raspberry Pi should remain minimal and robust.

## Required responsibilities

- start the `T2D` hotspot automatically at boot,
- provide the local network for laptop, Vision Pro, and any onboard device that needs access,
- support SSH administration over the T2D network,
- run headlessly.

## Non-responsibilities

Unless requirements change, the Pi should **not**:

- run the language model,
- parse speech commands,
- perform central mission logic,
- perform the primary video-processing pipeline,
- send flight commands directly to PX4,
- run the central MAVSDK/MAVLink control gateway.

If code for these older roles exists in the repository, do not delete it blindly. Instead:

1. determine whether it is still referenced,
2. isolate/deprecate it if appropriate,
3. document why it is no longer part of the active architecture.

---

# 4. Laptop Responsibilities

The laptop is the main runtime host.

It should eventually own the following logical subsystems.

## 4.1 Video ingest

The drone camera stream is sent to the laptop.

The precise camera transport may evolve. Treat the ingest interface as modular.

The laptop should expose a clear internal abstraction such as:

```text
VideoSource
    -> frames / timestamps / metadata
```

Do not tightly couple downstream processing to one specific transport unless required.

## 4.2 Video processing

Video processing occurs on the laptop.

The exact perception algorithm is not the immediate focus of the current implementation unless explicitly requested. Keep interfaces clean enough to support later additions such as:

- ArUco detection,
- object detection / segmentation,
- target localization,
- coordinate estimation,
- visual odometry or pose estimation,
- live overlays.

## 4.3 Vision Pro video forwarding

The processed or selected video stream is sent from the laptop to the Vision Pro.

Prefer a transport suitable for low-latency live video, e.g. WebRTC, unless the repository already defines another working mechanism.

The Vision Pro should not need to know whether the original camera source is the Pi, another onboard computer, or a direct camera transport. The laptop should act as the stable video-service endpoint.

## 4.4 Speech command ingress

Speech originates from the Vision Pro.

The Vision Pro should send either:

- recognized text, or
- audio if the selected architecture requires laptop-side speech recognition.

The laptop owns the command-understanding pipeline.

The speech path should conceptually be:

```text
Vision Pro
    -> speech/text
    -> laptop API
    -> language/intent parser
    -> structured command
```

Do not route speech processing through the Raspberry Pi.

## 4.5 Language / intent extraction

The language layer should transform natural-language instructions into a constrained structured representation.

Example:

```json
{
  "schema_version": 1,
  "command": "land_at",
  "target": "red_box"
}
```

or, after spatial resolution:

```json
{
  "schema_version": 1,
  "command": "land_at",
  "target": "red_box",
  "position_local_m": {
    "x": 1.42,
    "y": -0.65,
    "z": 0.0
  }
}
```

The language model must **not** generate arbitrary raw MAVLink messages or direct motor commands.

The exact LLM backend is expected to move to a GPT/OpenAI API-based solution, but implementation details should remain modular enough that a local or alternative model could be substituted.

Cloud-based language functionality is not guaranteed to have Internet access during every demo. Handle API unavailability explicitly.

## 4.6 Flight-control / telemetry output

The laptop will ultimately send validated target coordinates / commands to PX4 through a telemetry radio or equivalent communication link.

This layer is safety-critical relative to the rest of the demo.

Use a dedicated flight-control gateway abstraction.

Conceptually:

```text
Natural language
    -> structured intent
    -> target resolution
    -> validated local coordinates
    -> flight gateway
    -> telemetry/MAVLink
    -> PX4
```

The language model should never directly own the flight link.

The gateway should eventually validate:

- PX4 connectivity,
- vehicle state,
- localization validity,
- target validity,
- workspace bounds,
- command type,
- command timeout,
- control-mode readiness.

Do not arm or command real motion automatically while developing unrelated components.

---

# 5. PX4 / Flight-Control Context

Flight controller:

```text
Pixhawk Mini
PX4 FMU v5.x
PX4 firmware used during prior integration: 1.16.0
```

The project previously validated external-vision fusion using MAVLink `ODOMETRY` and EKF2.

Known relevant PX4 configuration from prior work:

```text
EKF2_GPS_CTRL = 0
EKF2_HGT_REF = Vision
EKF2_EV_CTRL = horizontal position + vertical position + yaw
```

A synthetic odometry test successfully demonstrated:

```text
external odometry
    -> MAVLink ODOMETRY
    -> PX4 vehicle_visual_odometry
    -> EKF2
    -> cs_ev_pos = True
    -> cs_ev_hgt = True
    -> cs_ev_yaw = True
    -> fused = True
```

This prior result proves that PX4 can accept and fuse external vision correctly.

However, the current architecture may no longer route external odometry through the Pi. When reintroducing real localization, implement it according to the **current laptop-centric architecture**.

Do not rely only on a coarse `local_position_ok` boolean to determine whether external vision is alive. PX4 can maintain a valid local solution temporarily through inertial propagation or stationary/fake-position fallback. A robust control gateway should explicitly monitor the freshness and validity of the active localization source.

---

# 6. Vision Pro Application

The Vision Pro application is the user-facing endpoint.

Expected capabilities:

- connect to the T2D network,
- display the live video stream delivered by the laptop,
- capture speech input,
- send speech/text to the laptop,
- receive command/processing status,
- present useful feedback to the user.

The VP app should use configurable service endpoints. Do not scatter hard-coded IP addresses and ports across Swift files.

Prefer a central configuration object, e.g.:

```swift
struct RuntimeConfig {
    static let laptopHost = "10.42.0.2"
}
```

or a runtime-configurable equivalent.

The Pi address `10.42.0.1` should not be used as the application server endpoint unless the user explicitly asks to restore Pi-hosted services.

---

# 7. Software Design Principles

## 7.1 Preserve working code

Before changing anything:

1. inspect the repository structure,
2. identify existing working components,
3. trace active entry points,
4. identify stale architecture assumptions,
5. avoid broad rewrites unless clearly justified.

Prefer incremental changes.

## 7.2 Clear subsystem boundaries

Keep at least these conceptual boundaries:

```text
network/
video_ingest/
video_processing/
vp_streaming/
speech/
language/
flight/
shared/
```

Do not force this exact folder structure if the repository already has a sensible organization.

## 7.3 Configuration

Move environment-specific values out of implementation code where practical.

Examples:

```text
T2D Pi IP
Laptop T2D IP
HTTP/WebSocket/WebRTC ports
telemetry port/device
OpenAI model
API URL
timeouts
video resolution
frame rate
```

Use config files, environment variables, or one clearly defined runtime configuration layer.

Never commit secrets or API keys.

## 7.4 Logging

Every long-running service should log:

- startup,
- configuration summary,
- connection/disconnection events,
- recoverable failures,
- fatal failures,
- shutdown.

Avoid noisy per-frame logging unless in debug mode.

## 7.5 Recovery

Services should tolerate:

- Vision Pro disconnect/reconnect,
- camera stream interruption,
- network reconnects,
- telemetry reconnects,
- API request failure,
- temporary Internet loss.

Reconnect logic must be bounded and observable.

## 7.6 Safety

Never send real flight commands merely to test unrelated software.

When flight-control code is introduced:

- default to disarmed/read-only behavior,
- make actuation explicit,
- validate coordinates and state,
- maintain timeouts,
- avoid direct LLM-to-MAVLink execution,
- provide a clear abort/failsafe path.

---

# 8. Repository Workflow for Coding Agents

When beginning work:

1. Read this `AGENTS.md`.
2. Inspect the entire repository tree.
3. Read existing README/configuration/docs.
4. Identify current entry points for:
   - Vision Pro app,
   - video server/relay,
   - speech endpoint,
   - telemetry/flight code,
   - Raspberry Pi scripts.
5. Search for stale references to:
   - `10.42.0.1` as the application server,
   - Pi-hosted WebRTC,
   - Hailo,
   - `hailo-ollama`,
   - Pi-side LLM inference,
   - Pi-side MAVSDK,
   - `/dev/ttyACM0`,
   - old HTTP endpoints.
6. Do not delete obsolete code until its usage has been verified.
7. Summarize the current state before making architectural changes.
8. Implement the smallest coherent milestone.
9. Run relevant tests/builds.
10. Update documentation after behavior changes.

---

# 9. Current Priorities

Unless the user gives a different task, prioritize work in this order:

### P0 — establish the laptop as the central runtime
- receive the drone camera stream on laptop,
- expose/forward video to Vision Pro,
- ensure Vision Pro targets laptop rather than Pi.

### P1 — clean speech transport
- Vision Pro sends speech/text to laptop,
- laptop exposes a stable API,
- no Pi-side speech processing.

### P2 — language backend
- introduce GPT/OpenAI API-backed intent extraction,
- use structured schemas,
- keep model/backend replaceable.

### P3 — spatial target resolution
- connect language target to perception output,
- convert selected target to coordinates in the active local frame.

### P4 — telemetry / PX4 command gateway
- connect laptop to telemetry radio,
- expose validated flight-command API,
- keep LLM isolated from raw flight control.

### P5 — autonomous demonstration flow
- user command,
- target recognition,
- coordinate extraction,
- flight-control validation,
- controlled autonomous action,
- UI feedback.

---

# 10. Immediate Non-Goals

Unless explicitly requested, do not spend time on:

- Hailo AI HAT integration,
- local Pi LLM inference,
- Pi-side speech recognition,
- Pi-side WebRTC-to-Vision-Pro serving,
- Pi-side MAVSDK flight control,
- low-level motor control,
- replacing PX4 control loops,
- unnecessary ROS 2 integration.

ROS 2 may become useful later for perception/planning, but it should not be introduced solely for architectural fashion.

---

# 11. Definition of Done for Changes

A change is not complete until:

- it respects the current laptop-centric architecture,
- stale Pi-centric assumptions are not accidentally reintroduced,
- the relevant component builds/runs,
- basic failure handling is present,
- configuration is documented,
- any changed endpoint/IP/port is reflected consistently,
- no secrets are committed,
- existing working functionality is preserved or intentionally migrated.

For Vision Pro changes, build the app if the environment allows it.
For Python services, run them or at minimum execute relevant import/unit tests.
For network services, verify bind address/port and reconnect behavior.
For flight-control changes, prefer simulation/read-only validation before real actuation.

---

# 12. Guiding Principle

The Raspberry Pi is infrastructure.

The laptop is the brain.

The Vision Pro is the interface.

PX4 is the flight controller.

Keep those responsibilities explicit throughout the implementation.
