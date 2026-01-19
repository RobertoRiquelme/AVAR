# AVAR2

AVAR2 is a **SwiftUI + RealityKit** project for visualizing **2D/3D diagram layouts** as interactive spatial content.

- **visionOS (Apple Vision Pro)**: diagrams render inside an **ImmersiveSpace** using `RealityView`. Users can move entire diagrams in space, drag nodes (for 3D diagrams), and use on-diagram handles for pan/zoom/rotation.
- **iOS (companion)**: diagrams render in an **ARKit / RealityKit `ARView`**, primarily as a viewer for shared diagrams, with optional alignment using a shared anchor.

AVAR2 supports multiple diagram inputs:

- **Bundled examples** ("From File")
- **Paste JSON** ("From JSON")
- **HTTP POST** to a local on-device server ("HTTP Server")

It also supports multi-user sessions:

- **Local peer-to-peer** sync via **MultipeerConnectivity**
- **Shared anchor** alignment to keep diagrams in roughly the same place for everyone
- On **visionOS 26**, optional Shared Space alignment via `SharedCoordinateSpaceProvider`

---

## Contents

- [Platforms and versions](#platforms-and-versions)
- [Requirements](#requirements)
- [Build and run](#build-and-run)
- [Using the app (visionOS)](#using-the-app-visionos)
  - [Input sources](#input-sources)
  - [Immersive controls and interactions](#immersive-controls-and-interactions)
- [HTTP server API](#http-server-api)
- [Collaboration](#collaboration)
- [Diagram JSON format](#diagram-json-format)
- [Adding new bundled examples](#adding-new-bundled-examples)
- [Development notes](#development-notes)
- [Troubleshooting](#troubleshooting)

---

## Platforms and versions

- **visionOS**: The project is actively developed and tested on **visionOS 26**.
  - The codebase contains feature gates such as `#available(visionOS 26.0, *)` (e.g., Shared Space / coordinate space sync).
- **iOS**: Companion AR viewer and collaborative participant.

---

## Requirements

- macOS 15+ (Sequoia) for development
- Xcode 16+
- visionOS 26+ for full immersive experience
- iOS 18+ for companion AR view
- Target device or simulator with RealityKit support

**Permissions / entitlements you will typically need:**

- **Local Network** (required for HTTP server and Multipeer discovery)
- **SharePlay / GroupActivities** (only if you use SharePlay features)

---

## Build and run

1. Clone the repo.
    ```bash
    git clone https://github.com/RobertoRiquelme/AVAR.git
    cd AVAR2
    ```
2. Open the Xcode project.
    ```bash
    open AVAR2.xcodeproj
    ```
3. Select a target:
   - `PlatformApp` builds for visionOS and iOS.
4. Configure signing, and ensure Local Network privacy strings are present in `Info.plist`.
5. Run on device or simulator.

---

## Using the app (visionOS)

On visionOS the app launches into a **launcher window** (`VisionOSMainView`) and can open an **immersive space** (`ImmersiveSpace(id: "MainImmersive")`).

### Input sources

AVAR2 provides a segmented picker:

1. **From File**
   - Lists bundled example files.
   - **Note:** the current example discovery code enumerates **`.txt` resources** in the main bundle (see `PlatformApp.swift`).
   - `ElementService` can load `.txt` or `.json`, but if you want your file to appear in the picker without changing code, add it as `.txt`.

2. **From JSON**
   - Paste JSON into the text editor.
   - The UI validates by attempting to decode a `ScriptOutput` model.
   - When loading, the JSON is written to a temporary `.txt` file and then loaded through the same code path as bundled examples.

3. **HTTP Server**
   - Starts a local on-device server (port and endpoint defined in `Constants.swift` and `HTTPServer.swift`).
   - POST JSON to `/avar` to create or update diagrams.
   - The launcher window shows server logs and the last received JSON.

### Immersive controls and interactions

Once a diagram is loaded, it renders in immersive space using `ContentView` + `ElementViewModel`.

**Diagram-level controls (visionOS):**

- **Grab handle** (`"grabHandle"`): move the entire diagram window in space.
- **Zoom handle** (`"zoomHandle"`): scale the diagram.
- **Rotation button** (`"rotationButton"`): rotate the diagram.
- **Close button** (`"closeButton"`): remove a diagram from the scene.

**Node-level controls (visionOS):**

- Nodes are typically named `"element_<id>"`.
- For **3D** diagrams, you can drag nodes; connections update live.
- For **2D** diagrams (`isGraph2D == true`), node dragging is disabled (by design).

**Immersion and debug controls (visionOS):**

- The immersive environment supports `.mixed` and `.full` immersion styles.
- Keyboard shortcuts (when a keyboard is connected) are wired in `ImmersiveSpaceWrapper`:
  - `Space`: toggle debug overlay
  - `r`: reset immersion toward mixed
  - `f`: go to full immersion
- The launcher includes buttons such as **Exit Immersive Space** and **Show/Hide Plane Visualization**.

**Surface detection / plane visualization:**

- Plane detection and visualization are provided by `ARKitSurfaceDetector` + `ARKitVisualizationManager`.
- `AppModel.togglePlaneVisualization()` toggles visual plane rendering.

---

## HTTP server API

### Endpoints

- `GET /` – simple HTML page
- `GET /avar` – HTML helper page (includes an example `curl`)
- `POST /avar` – submit a diagram JSON payload
- `OPTIONS *` – permissive CORS handling (basic)

### Port

- Default port is defined in `Constants.swift` (`AVARConstants.defaultHTTPPort`).

### Authentication

Authentication is **optional**.

- If `AVAR_HTTP_TOKEN` is set in the environment, auth is enabled.
- When enabled, POST requests require either:
  - `Authorization: Bearer <token>`
  - or `X-AVAR-Token: <token>`

### Updating diagrams

If your JSON includes a root-level `id`, AVAR2 will treat it as an **update key**:

- First `POST` with a given `id` → creates a diagram
- Next `POST` with the same `id` → replaces the prior diagram instance (see `AppModel.registerDiagram` / `getDiagramInfo`)

### Example curl

```bash
curl -X POST http://<device-ip>:8081/avar \
  -H "Content-Type: application/json" \
  -d @diagram.json
```

If auth is enabled:

```bash
curl -X POST http://<device-ip>:8081/avar \
  -H "Content-Type: application/json" \
  -H "X-AVAR-Token: <token>" \
  -d @diagram.json
```

---

## Collaboration

Collaboration is coordinated by `CollaborativeSessionManager`.

### Transport

- **MultipeerConnectivity** is used for discovery and data exchange (`MultipeerConnectivityService`).
- If `GroupActivities` is available, AVAR2 can also integrate with **SharePlay**.

### Roles

- **Host**: starts a session, can broadcast a shared anchor, shares diagrams.
- **Participant**: joins a session, receives shared diagrams and anchor messages.

### Shared anchor alignment 
*On construction*

To reduce "everyone sees the diagram in a different place":

- Hosts can **broadcast a shared anchor** (`broadcastCurrentSharedAnchor()` on visionOS; `broadcastSharedAnchor()` on iOS).
- iOS can optionally embed an **ARWorldMap** to improve alignment.

### visionOS 26 Shared Space alignment
*On construction*

On **visionOS 26**, AVAR2 can use `SharedCoordinateSpaceProvider` via `VisionOSSharedSpaceCoordinator`:

- The host starts Share Space (if available)
- The coordinator exchanges coordinate data with participants
- Diagram transforms are treated as **device-relative** and mapped via the shared coordinate space

This path is guarded by availability checks (so you can keep older build targets if needed, but the feature itself requires visionOS 26).

---

## Diagram JSON format

The decoder model is `ScriptOutput` / `ElementDTO` (see `ElementDTO.swift`). The app is flexible and accepts multiple shapes of JSON.

### 1) Direct array of elements

You can POST or paste a raw array:

```json
[
  {"id":"A","type":"node","position":[0,0,0],"shape":{"shapeDescription":"RWBox","extent":[1,1,1],"color":[0.2,0.6,1.0,1.0]}},
  {"id":"B","type":"node","position":[2,0,0],"shape":{"shapeDescription":"RWSphere","extent":[1,1,1],"color":[1.0,0.3,0.3,1.0]}},
  {"id":"E1","type":"edge","from_id":"A","to_id":"B"}
]
```

### 2) ScriptOutput object (preferred)

```json
{
  "id": "demo",
  "elements": [
    {"id":"A","type":"node","position":[0,0,0]},
    {"id":"B","type":"node","position":[2,0,0]},
    {"id":"E1","type":"edge","from":"A","to":"B"}
  ]
}
```

Notes:

- The root keys can be `elements` **or** `RTelements` (both are supported).
- For edges, both `from`/`to` **and** `from_id`/`to_id` are accepted.
- The app will infer 2D vs 3D based on `position[2]` across nodes.

### 3) RS-style node/edge graph

A graph can also be expressed as:

```json
{
  "nodes": [
    {"id":"A","type":"node","position":[0,0,0]},
    {"id":"B","type":"node","position":[1,0,0]}
  ],
  "edges": [
    {"id":"E1","type":"edge","from":"A","to":"B"}
  ]
}
```

### Supported shapes

`ShapeFactory` (visionOS) and the iOS renderer handle several shape descriptions. Common ones:

- `RWBox`
- `RWSphere`
- `RWCylinder`
- `RWCone`
- `RT*` and `RS*` variants are also supported (see `ShapeFactory.swift`).

If shape data is missing, a reasonable default is used.

---

## Adding new bundled examples

1. Add your diagram file to the Xcode project resources.
2. Use a **`.txt`** extension if you want it to show up in the "From File" picker without code changes.
3. Ensure the file is included in the correct target membership.
4. Rebuild; it should appear in the picker.

---

## Development notes

If you want to understand the app quickly:

1. Start at **`PlatformApp.swift`** to see scenes, launcher UI, and the immersive entry.
2. Look at **`ContentView.swift`** and **`ElementViewModel.swift`** for diagram rendering + gestures.
3. Check **`DiagramSceneBuilder.swift`** and **`ShapeFactory.swift`** for how diagram entities are built.
4. For collaboration, read **`CollaborativeSessionManager.swift`** and **`MultipeerConnectivityService.swift`**.
5. For HTTP input, read **`HTTPServer.swift`**, `DiagramStorage.swift`, and the callback wiring in `PlatformApp.swift`.

---

## Troubleshooting

### "HTTP server works on simulator but not on device"

- Confirm **Local Network** permission is enabled:
  - Settings → Privacy & Security → Local Network → enable AVAR2
- Confirm device and sender are on the same LAN/Wi‑Fi.

### "POST /avar returns 401"

- Auth is enabled when `AVAR_HTTP_TOKEN` exists.
- Add `Authorization: Bearer <token>` or `X-AVAR-Token: <token>`.

### "Diagram doesn't render"

- Paste your JSON into the "From JSON" editor first to validate.
- Check server logs in the UI (last JSON + decode errors).
- Ensure your elements have `position` arrays.

### "Collaboration connected but content is misaligned"

- Have the **host broadcast an anchor** after opening diagrams.
- On iOS, try resetting/recentering mapping.
- On visionOS 26, prefer the Shared Space flow (if enabled) to reduce drift.

## License
This project is provided as-is. Modify and distribute freely.