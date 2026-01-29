# AVAR2 – Files Overview

This document explains **what each major file does**, which *types/functions* are inside, and why it matters.

If you only want the fastest way to understand the codebase, read in this order:

1. `PlatformApp.swift` (scenes + main UI + entry points)
2. `ContentView.swift` → `ElementViewModel.swift` (diagram rendering + gestures)
3. `DiagramSceneBuilder.swift` + `ShapeFactory.swift` (entity construction)
4. `DiagramDataLoader.swift` + `ElementDTO.swift` (decoding + input formats)
5. `HTTPServer.swift` (remote input)
6. `CollaborativeSessionManager.swift` + `MultipeerConnectivityService.swift` (collaboration)

---

## 0. Documentation files

- `README.md`
  - High-level overview: what AVAR2 is, supported platforms, how to run, inputs, HTTP API, collaboration and JSON formats.

- `FILES_OVERVIEW.md` (this file)
  - File-by-file description and code navigation map.

- `USER_INTERACTION.md`
  - A file explaining how to use the app on visionOS and iOS.

---

## 1. App entry points and scenes

### `PlatformApp.swift`
**Why it matters:** this is the **real entry point** (`@main`). It defines the scenes for visionOS and iOS and contains the launcher UI.

Key types:

- `PlatformApp: App`
  - Creates a shared `CollaborativeSessionManager`.
  - On **visionOS**: declares
    - `WindowGroup` → `VisionOSMainView`
    - `ImmersiveSpace(id: "MainImmersive")` → `VisionOSImmersiveView`
  - On **iOS**: declares `WindowGroup` → `iOS_ContentView`.

- `VisionOSAppState: ObservableObject`
  - Holds `activeFiles: [String]` (the list of diagrams currently open in immersive).
  - Holds the `AppModel` instance (shared state and utilities).

- `VisionOSMainView`
  - The *launcher window* on Vision Pro.
  - Provides an **Input Source** picker:
    - `From File` (bundled `.txt` examples)
    - `From JSON` (paste JSON → temp file)
    - `HTTP Server` (start server + view logs)
  - Hosts a **CollaborationCard** at the top (host/join session, broadcast anchor, open details, start Shared Space on visionOS 26).
  - Wires `HTTPServer.onJSONReceived` to:
    - ensure immersive space is open
    - save payload to `DiagramStorage` and update `activeFiles`
    - update existing diagrams if `ScriptOutput.id` matches a known diagram

- `VisionOSImmersiveView`
  - Renders **multiple diagrams** at once (driven by `sharedState.activeFiles`).
  - Places diagrams using `AppModel` (and `DiagramLayoutCoordinator`) so new diagrams don’t overlap.
  - Applies collaboration updates (diagram transforms + per-node moves) when received.

- `CollaborationCard` + helper UI types
  - Expandable card showing session state / code / buttons.
  - “Start Share Space” is gated behind `#available(visionOS 26.0, *)`.

Notable behavior:

- The app opens the immersive space **automatically** on first launch (`hasLaunched` → `ensureImmersiveSpaceActive()`).
- Leaving immersive space resets layout state (`AppModel.resetDiagramPositioning()`) and can stop SharePlay.

---

### `AVAR2App.swift`
**Why it matters:** contains many **shared views and immersive helpers** used by the visionOS experience.

Key components include:

- `ImmersiveSpaceWrapper`
  - Wraps immersive content, adds a background, handles keyboard-based debug toggles.

- `StaticSurfaceView`
  - Displays the plane visualization entity (driven by `ARKitSurfaceDetector`/`ARKitVisualizationManager`).

- `FPSMonitor` and related UI
  - Tracks frame timing / FPS for debugging.


This file is the “UI toolbox” that keeps `PlatformApp.swift` from becoming even larger.

---

## 2. Core rendering pipeline

### `ContentView.swift`
**Why it matters:** the per-diagram **RealityKit view**. Each open diagram file corresponds to a `ContentView(filename:)` instance.

- On **visionOS**:
  - Uses `RealityView { content in ... } update: { ... }`.
  - Creates and configures `ElementViewModel`.
  - Installs gestures:
    - Targeted `DragGesture` (nodes vs grab/zoom/rotation handle)
    - Targeted `TapGesture` (close button)
  - Hooks collaboration callbacks:
    - `viewModel.onTransformChanged` → send throttled diagram transform updates
    - `viewModel.onElementMoved` → send per-element move updates

- On **iOS**:
  - Contains a stub `ContentView` definition, but the iOS experience is implemented in `iOS_ContentView.swift`.

---

### `ElementViewModel.swift`
**Why it matters:** this is the heart of the **visionOS diagram renderer**.

Main responsibilities:

- Loads diagram data (`DiagramDataLoader` → `ScriptOutput`) and stores decoded `ElementDTO`s.
- Builds RealityKit entities via:
  - `ShapeFactory` (geometry + material)
  - `DiagramSceneBuilder` (background panel + handles + title + container)
- Maintains per-diagram “world transform” (position, rotation, scale).
- Implements node dragging and updates line connections.
- Exposes callbacks used for collaboration:
  - `onTransformChanged(position, orientation, scale)`
  - `onElementMoved(elementId, localPosition)`

Important implementation details:

- Distinguishes **2D vs 3D** graphs (`isGraph2D`) to disable node dragging for 2D.
- Names entities so gestures can detect intent:
  - nodes: `element_<id>`
  - handles: `grabHandle`, `zoomHandle`, `rotationButton`, `closeButton`

---

### `DiagramSceneBuilder.swift`
**Why it matters:** builds the reusable **diagram “window” scaffolding** around nodes.

Creates:

- Background panel (with a subtle material)
- A container entity for nodes and edges
- UI handles:
  - grab handle (pan)
  - zoom handle
  - rotation control
  - close button
- Optional title label

Also encodes conventions used by gestures (`name` values for entities).

---

### `ShapeFactory.swift`
**Why it matters:** maps `ElementDTO.shape.shapeDescription` values to RealityKit meshes/materials.

Key types:

- `NormalizationContext`
  - Computes normalization scale based on element bounding boxes and whether the diagram is 2D.

- `ShapeFactory`
  - `entity(for:normalization:)` builds a `ModelEntity` for an `ElementDTO`.
  - Supports multiple families (RW/RT/RS) plus a fallback.

This is where you extend the system if you introduce new shapes.

---

### `DiagramLayoutCoordinator.swift`
**Why it matters:** places diagrams so multiple open diagrams form a clean layout.

- Computes an approximate bounding box for a diagram and chooses a non-overlapping position.
- Supports different layout patterns (`horizontal`, `vertical`, `grid`).

Used by:

- `AppModel` when determining the initial position for new diagrams.

---

## 3. Global state and configuration

### `AppModel.swift`
**Why it matters:** shared app state for visionOS.

Responsibilities:

- Manages diagram positioning:
  - `registerDiagram(...)` and `getDiagramInfo(...)` for ID-based updates (e.g., HTTP update by `id`).
  - `resetDiagramPositioning()` clears layout tracking.
- Holds surface detection subsystem:
  - `surfaceDetector: ARKitSurfaceDetector`
  - `togglePlaneVisualization()`
  - `startSurfaceDetectionIfNeeded()`
- Stores global settings:
  - `spacingBetweenDiagrams`, `diagramScale`, etc.

---

### `PlatformConfiguration.swift`
**Why it matters:** centralized platform toggles and constants.

Examples:

- `isVisionOS` / `isIOS`
- Default diagram scale for the current platform

---

### `Constants.swift`
**Why it matters:** central constants used across the app.

Contains `AVARConstants`, including:

- `defaultHTTPPort`
- `updateInterval` (throttling)
- `spacingBetweenDiagrams`

---

### `Extensions.swift`
**Why it matters:** utility extensions for math/transform conversions.

Includes helpers like:

- `simd_float4x4.position` getter/setter
- `simd_quatf` conversion utilities

These are used throughout RealityKit + collaboration code.

---

## 4. Data decoding and loading

### `ElementDTO.swift`
**Why it matters:** defines the **JSON contract** (as code).

Key types:

- `ElementDTO`
  - Node/edge model: `id`, `type`, `position`, optional `extent`, optional `shape`, etc.
  - Edges support both `from`/`to` and `from_id`/`to_id`.

- `ScriptOutput`
  - The flexible top-level decoder that supports:
    - a direct array of elements
    - `{ "elements": [...] }`
    - `{ "RTelements": [...] }`
    - `{ "nodes": [...], "edges": [...] }` (RS format)
  - Optional `id` field is used for HTTP updates.

If you’re unsure what JSON formats are accepted, this file is the ground truth.

---

### `ElementService.swift`
**Why it matters:** loads diagram files from different places.

Capabilities:

- Load from app bundle by name (`.txt` or `.json`).
- Load from shared disk location (`DiagramStorage`) for HTTP-generated diagrams.
- Fallback to temporary directory.

---

### `DiagramDataLoader.swift`
**Why it matters:** centralized loader that produces a `ScriptOutput` and normalizes errors.

- Reads bytes via `ElementService`.
- Decodes using `JSONDecoder()`.
- Returns `ScriptOutput`, which provides `.elements`.

---

### `DiagramStorage.swift`
**Why it matters:** defines where HTTP diagrams are persisted.

- Uses a subfolder (`HTTPDiagrams`) inside the app’s caches directory.
- Provides helpers to create the folder and build file URLs.

---

## 5. HTTP / networking

### `HTTPServer.swift`
**Why it matters:** local HTTP server (NWListener) that receives diagrams.

Key behavior:

- Listens on `Constants.defaultHTTPPort`.
- `POST /avar` accepts JSON, performs cleanup for common escaping issues, then decodes into `ScriptOutput`.
- Exposes:
  - `onJSONReceived: (ScriptOutput, rawJSONString) -> Void`
  - `lastReceivedJSON`
  - `logs`

Authentication:

- Optional token via environment variable `AVAR_HTTP_TOKEN`.
- Header `Authorization: Bearer ...` or `X-AVAR-Token: ...`.

Actual “diagram update” behavior is implemented in the callback wiring in `PlatformApp.swift`.

---

## 6. Collaboration and synchronization

### `CollaborativeSessionManager.swift`
**Why it matters:** orchestrates multi-user diagram sharing.

Key responsibilities:

- Host/join session flow
- Tracks connected peers
- Publishes shared state:
  - `sharedDiagrams: [SharedDiagram]`
  - `sharedAnchor: SharedWorldAnchor?`
- Sends and receives message envelopes (`SharedSpaceEnvelope`), including:
  - `.diagram(SharedDiagram)`
  - `.transform(UpdateDiagramTransformMessage)`
  - `.elementMoved(ElementPositionMessage)`
  - `.anchor(SharedAnchorMessage)`

Platform-specific alignment:

- On iOS, anchor messages can include `ARWorldMap` data for improved alignment.
- On visionOS 26, works with `VisionOSSharedSpaceCoordinator` to leverage Shared Space coordinate data.

---

### `MultipeerConnectivityService.swift`
**Why it matters:** the P2P transport.

- Wraps `MCNearbyServiceAdvertiser` / `MCNearbyServiceBrowser`.
- Broadcasts and receives `Data` payloads.
- Provides callbacks used by `CollaborativeSessionManager`.

---

### `VisionOSSharedSpaceCoordinator.swift`
**Why it matters:** visionOS 26 Shared Space integration.

- Hosts or joins a `SharedCoordinateSpaceProvider`.
- Receives coordinate space “participant mapping” data and forwards it into the collaboration pipeline.

This file is only meaningful on visionOS 26+.

---

### `CollaborativeSessionView.swift`
**Why it matters:** UI for managing a session.

- Shows participants, status, and controls.
- Presented as a sheet from `VisionOSMainView`.

---

## 7. Plane detection and visualization (visionOS)

### `ARKitSurfaceDetector.swift`
**Why it matters:** runs plane detection on visionOS.

- Uses `ARKitSession` + `PlaneDetectionProvider`.
- Tracks detected planes and provides them to visualization.
- Exposes a `planeEntities` dictionary and status.

---

### `ARKitVisualizations.swift`
**Why it matters:** renders the detected planes.

- `ARKitVisualizationManager` builds a `ModelEntity` per plane and updates/cleans them.
- Also builds a “scan area” visualization.

---

## 8. iOS companion app

### `iOS_ContentView.swift`
**Why it matters:** iOS AR viewer and alignment tools.

What’s inside:

- `iOS_ContentView`: SwiftUI wrapper that hosts an ARView and basic controls.
- `ARViewContainer`: integrates RealityKit `ARView` into SwiftUI.
- `ARViewModel`: owns the `ARView`, builds diagram anchors and entities.

Capabilities:

- Renders `SharedDiagram` elements into AR.
- Supports alignment modes (local preview vs shared-anchor alignment).
- Handles receiving a shared anchor, optionally applying an `ARWorldMap`.
- Provides user tools like “Recenter / Reset Mapping”.

---

## Appendix: Where to add new features

- New **shape types**: `ShapeFactory.swift` (and the iOS creation helpers in `iOS_ContentView.swift`).
- New **diagram input sources**: `VisionOSMainView` (UI) + `ElementService` / `DiagramStorage` (data).
- New **collaboration message**: add a case in `SharedSpaceEnvelope`, then handle encode/decode + dispatch in `CollaborativeSessionManager`.
- New **placement strategy**: `DiagramLayoutCoordinator` + callers in `AppModel`.

