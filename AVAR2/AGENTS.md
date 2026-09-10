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

### THE ALIGNMENT INVARIANT — read this before touching collaboration code

**A `WorldAnchor`'s `originFromAnchorTransform` must never be transmitted between visionOS
devices. Only its UUID crosses the wire.**

Every device has a private, unrelated ARKit world origin. visionOS 26's shared-anchor mechanism
guarantees that the same anchor UUID resolves to the same *physical* point on every nearby
participant, expressed in that participant's own origin. The transform is therefore already
correct locally and **already different** on each device. Transmitting it overwrites a correct
value with a meaningless foreign one — this was the root cause of "diagrams appear everywhere,
nothing aligned", and it is very easy to reintroduce with a well-meaning "send the transform
too" change. `Tests/WireFormatTests.swift` asserts it (JSON key inspection), so a regression
fails the tests rather than only misbehaving on hardware.

### How it works
- `AVAR2/CollaborativeSessionManager.swift`: transports, message types, `SharePlayCoordinator`.
- `AVAR2/SharedWorldAnchorManager.swift`: creates `WorldAnchor(sharedWithNearbyParticipants:)`.
  Shared anchors are **never persisted** — ARKit limits their lifetime to the SharePlay session,
  so re-creating one per session is the normal path, not an error path. Do not add a disk cache.
- `AVAR2/SessionOriginLogic.swift`: pure, tested logic for owner election and the gravity-aligned
  anchor pose. Election is "lowest participant UUID wins" over the *whole* participant list, so
  every device computes the same answer. Never derive an owner from `activeParticipants.first` —
  it is an unordered `Set`.
- `AVAR2/SharedWorldRoot.swift`: the `worldRoot` entity every diagram is parented to, positioned
  at this device's own resolved anchor transform. Diagram poses on the wire are therefore plain
  `position(relativeTo: worldRoot)` values — no matrix math at either end.
- Transports: SharePlay for visionOS↔visionOS; MultipeerConnectivity for the iOS companion.
- iOS is receive-only and cannot resolve a visionOS `WorldAnchor`, so it keeps its own legacy
  `SharedAnchorMessage` handshake (built from an `ARFrame` camera transform). visionOS ignores
  inbound anchor transforms entirely.
- `SharedDiagram.worldPosition` / `.worldOrientation` are **misnamed**: they carry
  anchor-relative values, not world-space ones. Names kept for wire compatibility.

### Diagnostics
`AVAR2/CollabDiagnosticsView.swift` is the panel to use when debugging a two-device session
(launcher window → Collaboration → Diagnostics). It shows SharePlay state, elected owner vs local
participant, `isSpatial` (co-location), anchor sharing availability, the resolved origin, and
per-envelope traffic counters with the last send error. Note the displayed
`originFromAnchor` translation **must differ** between the two devices — identical values mean a
transform leaked onto the wire. `showSessionOriginMarker` draws an axis triad at the origin on
each device; if the two triads occupy the same physical point, alignment works, independently of
whether diagram rendering works. In DEBUG there are loopback buttons that inject a local example
through the real receive path, so "does a remote diagram render?" is answerable on one device.

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
- `AVAR2/DiagramLayoutCoordinator.swift`: grid placement (local diagrams only — a diagram received
  from a peer must NOT get a locally-assigned slot; slots are first-come-first-served per device)
- `AVAR2/HTTPServer.swift`: local HTTP server
- `AVAR2/DiagramStorage.swift`: caches directory for HTTP-uploaded diagrams
- `AVAR2/Constants.swift`: placement and interaction constants
- `AVAR2/SessionOriginLogic.swift`: pure election + anchor-pose logic (tested)
- `AVAR2/SharedWorldRoot.swift`: shared session-origin frame for the scene graph
- `AVAR2/CollabDiagnosticsView.swift`: two-device diagnostics panel
- `Packages/RealityKitContent/`: RealityKit assets and materials
- `Documentation/`: architecture docs + diagrams + API reference

## Building

**`xcodebuild -scheme AVAR2` without an explicit destination silently builds for iOS.** The target
is multi-platform and `SUPPORTED_PLATFORMS` lists `iphoneos` first, so it reports
`** BUILD SUCCEEDED **` having compiled zero `#if os(visionOS)` code. `-sdk xros26.5` and
`SDKROOT=` are both overridden and do not help. Always pass a destination and confirm the log
mentions `Debug-xrsimulator`:

```
xcodebuild -project AVAR2.xcodeproj -scheme AVAR2 \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug build
```

Also build `-destination 'generic/platform=iOS'` after touching shared collaboration code — that
is what proves the iOS companion still compiles.

## Tests
`Tests/` is **not** a member of the Xcode project (the `PBXFileSystemSynchronizedRootGroup` covers
only `AVAR2/`) and there is no test target. The idiom is one `@main struct` per file, compiled
against the app sources:
- `Tests/SessionOriginTests.swift` — owner election (permutation-invariance, tie-break
  antisymmetry) and the gravity-aligned anchor pose. Pure; runs natively on macOS.
- `Tests/WireFormatTests.swift` — the alignment invariant, envelope round-trips, `is2D`
  preservation and back-compat, all four `ScriptOutput` input shapes. Built for xrsimulator and
  run via `xcrun simctl spawn` so the types are exercised as they ship.
- `Tests/WorldRootTests.swift` — the RealityKit `relativeTo:` semantics that keeping locally
  authored content stationary depends on, plus cross-device convergence. Single file, so it needs
  `-parse-as-library` (swiftc otherwise treats one file as script mode, conflicting with `@main`).
- `Tests/ResourceIntegrityTests.swift` — decodes all 37 bundled diagrams and builds a real mesh
  and material for **every** element (~8000), asserting finite geometry. Also reports the slowest
  diagrams, which is the only automated signal on load cost. Needs `AVAR2_RESOURCES` pointing at
  `AVAR2/Resources` (pass it as `SIMCTL_CHILD_AVAR2_RESOURCES` when spawning in the simulator).
- `Tests/LayoutTests.swift`, `Tests/DataLoaderTests.swift` — pre-existing.

Compile a suite with `swiftc` plus the sources it needs, e.g.
`xcrun swiftc -Onone -o /tmp/t Tests/SessionOriginTests.swift AVAR2/SessionOriginLogic.swift && /tmp/t`.
Asserts are the mechanism, so build with `-Onone` (release strips them).

## Environment variables
- `AVAR_VERBOSE_LOGS=1` to enable verbose logging in loaders/view models.
- `AVAR_HTTP_TOKEN=<token>` to enable HTTP auth.

## Performance

- **Every shape builder must go through `MeshCache`** (`cachedBox` / `cachedSphere` /
  `cachedCylinder` / `cachedCone`), never `MeshResource.generate*` directly. Diagrams repeat a
  tiny number of geometries — across all 37 bundled examples, 7928 elements resolve to just 610
  distinct meshes (13x reuse), and `Ejemplo03-1000` uses **2** meshes for 1999 elements. Six RS/RT
  builders previously bypassed the cache and re-tessellated identical cylinders per element, which
  made a 360-circle diagram (`Ejemplo09`) the slowest of all 37 at ~30 ms/element; routing them
  through the cache cut it by roughly 20x. `Tests/ResourceIntegrityTests.swift` prints the slowest
  diagrams so a regression here is visible.
- Text meshes (`generateText`) are *not* cached and CoreText is slow; label-heavy diagrams are the
  remaining cost leaders. Caching by text+size would help where labels repeat (about 2x in
  `Ejemplo11`), but has not been done.
- `MeshCache` never evicts and `clearCache()` is never called. Harmless today (610 keys for the
  whole bundled corpus), but worth revisiting if long sessions load many distinct HTTP diagrams.
- Per-element logging must be gated behind `AVAR_VERBOSE_LOGS` — see `ElementDTO.swift` and
  `ShapeFactory.swift`. Ungated, a 1000-node diagram emits thousands of synchronous stdout writes.

## Known data issues

- **`Resources/Ejemplo03-3000.txt` is byte-identical to `Ejemplo03-1000.txt`** (same MD5; 1000
  nodes + 999 edges, not 3000). The documented "with 3000 elements the app doesn't load the
  visualization" issue therefore cannot be reproduced from the bundled files — regenerate a real
  3000-element export from Pharo before investigating it.

## Gotchas / tips
- HTTP callback must be set in `.onAppear` to avoid missing early POSTs.
- Element positions are normalized by `NormalizationContext.globalRange`; metric scale comes from
  `AppModel.defaultDiagramScale` (`PlatformConfiguration.diagramScale * 0.7`). There are no
  `Constants.worldScale*` values — they existed but were never referenced, and were removed.
- `AppModel` tracks diagram IDs for replace-in-place updates.
- iOS does not support surface detection or immersive space; avoid adding visionOS-only APIs there.
- Diagram containers are parented to `worldRoot`, not to the RealityView content root.
  `relativeTo: nil` still means *scene* space, so `PlaneAnchor` snapping math is unaffected — but
  any value derived from a world-space read must be assigned with `setPosition(_, relativeTo: nil)`
  rather than a bare `.position =`, which would be interpreted in `worldRoot`'s frame.
- `worldRoot` must stay rigid with unit scale; a few call sites pass parent-relative scale into
  `relativeTo: nil` transforms. `SharedWorldRoot.apply` asserts this in DEBUG.
- **Pose ownership decides what happens when the session origin appears or is refined**, and the
  two cases are opposites (`ElementViewModel.updateWorldRoot`):
  - *Peer-originated* (`DiagramDataLoader.isReceived(filename)`): the wire pose is authoritative,
    so the container keeps its parent-relative pose and moves with `worldRoot`. That movement is
    what lands it on the same physical spot as the owner's copy.
  - *Locally authored*: the user chose a physical place, so the world pose is preserved across the
    frame change and the recomputed anchor-relative pose is re-broadcast. Without this, local
    content jumped by the whole anchor transform the moment an origin was established.
  Ownership cannot be inferred from "did we receive a transform for it" — `shareDiagram` appends
  our own diagrams to `sharedDiagrams`, so the update handler fires for local ones too.
- One-shot pose corrections go through `onAuthoritativeTransform`, **not** `onTransformChanged`.
  The latter is throttled for drag streams, where a dropped frame is harmless; a correction with
  no follow-up would be swallowed and peers would keep stale coordinates indefinitely.
- Decoder logging in `ElementDTO.swift` is gated behind `AVAR_VERBOSE_LOGS` because it runs once
  per element (a 1000-node diagram otherwise emits ~5000 synchronous stdout writes per load).
  Keep new per-element logging behind that flag.
- Headless UI automation does not work on the visionOS simulator: coordinate taps do not activate
  SwiftUI controls, because visionOS dispatches gaze-targeted spatial events. Screenshots, launch
  and log inspection work; anything interactive needs a human clicking in the Simulator window.

## Architecture references
- High-level overview: `Documentation/ARCHITECTURE.md`
- Diagrams: `Documentation/ARCHITECTURE_DIAGRAMS.md`
- API model reference: `Documentation/API_MODEL_REFERENCE.md`
