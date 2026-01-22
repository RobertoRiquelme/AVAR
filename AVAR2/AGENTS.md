# AGENTS.md - AVAR2 (visionOS + iOS)

## Project overview
AVAR2 is a SwiftUI + RealityKit app that loads diagram JSON (2D/3D layouts) and renders them as interactive spatial scenes. It supports:
- visionOS immersive space (primary experience)
- iOS AR companion view (receive-only for collaboration)
- diagram input from bundled files, pasted JSON, or a local HTTP server
- SharePlay / GroupActivities collaboration with spatial anchor alignment

Primary goal: visualize nodes (boxes/spheres/cylinders/cones/RS/RT shapes) and edges in 3D, allow dragging/positioning, and sync across devices.

## Platforms / requirements
- macOS 15+ with Xcode 16+
- visionOS 2.0+ for immersive experience
- iOS 18+ for companion AR view

## Entry points and major flows
- App entry: `AVAR2/PlatformApp.swift` (@main)
  - visionOS: `VisionOSMainView` + `ImmersiveSpace(id: "MainImmersive")`
  - iOS: `iOS_ContentView`
- Shared UI components: `AVAR2/AVAR2App.swift`
- Per-diagram RealityView + gestures: `AVAR2/ContentView.swift`
- Diagram rendering logic: `AVAR2/ElementViewModel.swift`
- App-wide state and layout: `AVAR2/AppModel.swift`

### Diagram loading flow (high level)
1. User chooses file/JSON/HTTP input.
2. JSON is saved (bundle file or `DiagramStorage` cache directory).
3. `ContentView` creates `ElementViewModel` and triggers `DiagramDataLoader`.
4. `ElementDTO` decoding -> `NormalizationContext` -> `ShapeFactory` builds meshes.
5. `DiagramSceneBuilder` assembles scene (root, background, handles, shapes, edges).
6. AppModel positions diagrams using `DiagramLayoutCoordinator`.

## Data formats (JSON)
Decoder is tolerant and supports multiple formats via `ScriptOutput` in `AVAR2/ElementDTO.swift`:
- Direct array: `[{...}, {...}]` (treated as 3D)
- Object form: `{ "elements": [...] }` (3D)
- RT form: `{ "RTelements": [...] }` (2D)
- RS form: `{ "nodes": [...], "edges": [...] }` (2D)
- Optional root `id` (Int/Double/String) for diagram updates

Element fields (subset):
- `position`: [x,y,z] or [x,y]
- `extent`: [w,h,d] (or [w,h] for 2D)
- `shape.shapeDescription`: RWBox/RWCylinder/RWSphere/RWCone, RT/RS labels, etc.
- `from_id` / `to_id` (or `from` / `to`) for edges
- RS composites: `nodes` nested inside a composite get flattened during decode

## HTTP server
- Code: `AVAR2/HTTPServer.swift`
- Port: 8081 (`Constants.httpServerPort`)
- Endpoints:
  - `GET /` basic landing
  - `GET /avar` status/help page
  - `POST /avar` submit diagram JSON
- Auth: optional via `AVAR_HTTP_TOKEN` env var.
  - If set, requests must send `Authorization: Bearer <token>` or `X-AVAR-Token: <token>`
- Callback wiring: `VisionOSMainView.onAppear` sets `httpServer.onJSONReceived` early to avoid missing the first POST.
- HTTP uploads are stored under caches via `DiagramStorage` and referenced by filename.
- Diagram updates: if JSON root has `id`, incoming POST replaces existing diagram with the same id.

## Collaboration
- `AVAR2/CollaborativeSessionManager.swift` handles SharePlay (GroupActivities) + Multipeer fallback.
- visionOS 26+ uses SharedWorldAnchorManager for spatial alignment.
- iOS is receive-only; visionOS can broadcast and share anchors.

## Surface detection and snapping
- `AVAR2/ARKitSurfaceDetector.swift` uses `PlaneDetectionProvider` on visionOS.
- `AppModel` runs surface detection once per app session.
- `ElementViewModel` uses surface anchors to snap diagrams to walls/floors/ceilings.

## Key files and directories
- `AVAR2/PlatformApp.swift`: app entry, visionOS launcher, HTTP callback wiring
- `AVAR2/AVAR2App.swift`: shared UI components + immersive wrapper
- `AVAR2/ContentView.swift`: RealityView host + gestures
- `AVAR2/ElementViewModel.swift`: core rendering/interaction logic
- `AVAR2/ShapeFactory.swift`: mesh/material creation for RT/RS/RW shapes
- `AVAR2/ElementDTO.swift`: JSON decoding and format tolerance
- `AVAR2/DiagramSceneBuilder.swift`: scene graph assembly (handles, background, close button)
- `AVAR2/DiagramLayoutCoordinator.swift`: grid placement
- `AVAR2/HTTPServer.swift`: local HTTP server
- `AVAR2/DiagramStorage.swift`: caches directory for dynamic diagrams
- `AVAR2/Constants.swift`: scaling and interaction constants
- `Packages/RealityKitContent/`: RealityKit assets and materials
- `Documentation/`: architecture docs + diagrams + API reference

## Tests
Lightweight, ad-hoc test entry points (not XCTest):
- `Tests/DataLoaderTests.swift`
- `Tests/LayoutTests.swift`
Run in Xcode as standalone executables or compile manually with the app sources if needed.

## Environment variables
- `AVAR_VERBOSE_LOGS=1` to enable verbose logging in loaders/view models.
- `AVAR_HTTP_TOKEN=<token>` to enable HTTP auth.

## Gotchas / tips
- HTTP callback must be set in `.onAppear` to avoid missing early POSTs.
- Element positions are normalized and scaled using `NormalizationContext` and `Constants.worldScale*`.
- `AppModel` tracks diagram IDs for replace-in-place updates.
- iOS does not support surface detection or immersive space; avoid adding visionOS-only APIs there.

## Architecture references
- High-level overview: `Documentation/ARCHITECTURE.md`
- Diagrams: `Documentation/ARCHITECTURE_DIAGRAMS.md`
- API model reference: `Documentation/API_MODEL_REFERENCE.md`
