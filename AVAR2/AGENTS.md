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
- `SharedDiagram` / `UpdateDiagramTransformMessage` carry `anchorRelativePosition`,
  `anchorRelativeOrientation` and `anchorRelativeScale` — poses in the session-origin frame, never
  world space. **The JSON keys are still `worldPositionX`, `worldOrientationW`, `worldScale` etc.**
  and must stay that way: the iOS lane and any build predating the rename speak those keys.
  `Tests/WireFormatTests.swift` pins the emitted key names.
- Scale is frame-independent (`worldRoot` is rigid, unit-scale); it carries the `anchorRelative`
  prefix only so the three pose fields read as a group.
- A local named `world*` in `ElementViewModel`/`WorldRootTests` genuinely *is* world space (see
  `preservedWorldPosition` in `updateWorldRoot`) — do not blanket-rename those.

### Realignment
When the two headsets end up on anchors that do not agree, **Realign Space** (launcher window →
Collaboration) renegotiates the shared origin. The decision rules live in
`AVAR2/RealignmentProtocol.swift` as a pure function; `CollaborativeSessionManager` performs the
effects (minting anchors, adoption, pose resend, timeouts, status text).

- One participant is the **coordinator**: `SessionOriginElection.owner` over the nearby
  participants plus this device (`realignmentCoordinatorID`), so both devices compute the same
  answer even when they disagree about the current anchor. Either side may *request* it; only the
  coordinator services the request. Both entry points — the local button and an inbound
  `request` — take the probe's anchor from `RealignmentProtocol.probeAnchor`.
- The handshake is `request → probe → report → (commit | prepare → ready → commit) → applied`, with
  `failed` available from the coordinator at any point. If both headsets already hold the same
  tracked anchor, the `report` short-circuits straight to `commit` and **no new anchor is
  created**. *Replace Shared Anchor* sets `replaceAnchor`, which forces a new one regardless.
- Both sides can be waiting on ARKit: a peer that cannot yet see the replacement parks the message
  and answers `ready` from `confirmRealignmentAnchor` once the anchor resolves, and the coordinator
  does the same before `commit`. Adoption **fails closed** — a device that cannot track the anchor
  keeps its previous origin rather than adopting one it cannot resolve.
- Retired anchors go into `retiredOriginIDs`; a `sessionOrigin` announcement or a pose update
  that names one is dropped.
- **Commit is not atomic.** The coordinator adopts the anchor *before* it sends `commit`, and
  `finishRealignment` does not restore the previous `sessionOriginID`. A peer that refuses the
  commit (it lost tracking of the anchor after answering `ready`) sends no `applied`, so the
  coordinator times out after 20 s and reports failure while staying on the new anchor — the two
  headsets are on different origins for at least that long. `testCommitIsNotAtomic` pins this as
  *current* behaviour, not as correct behaviour. By reading, it should then heal without user
  action: the replacement is the coordinator's `ownedAnchorID`, the origin loop re-announces it
  every second once `isRealigning` clears, and the peer's `handleSessionOriginAnnouncement`
  yields to the coordinator (lowest UUID) and adopts it when it can track it. That recovery is
  **untested and unverified on hardware**; if the status says realignment failed, compare the
  origin markers before assuming either outcome.
- Several guards are asymmetric (a phase the coordinator must act on is one the peer must refuse,
  and vice versa). `Tests/RealignmentTests.swift` covers the table, and was checked by deleting or
  loosening each condition in `RealignmentProtocol.swift` in turn and confirming a test fails.
  Keep that property: when adding a guard, delete it again and make sure the suite goes red.
- The tests cover the *decisions*. The manager's `perform(_:message:sender:)`, which turns a
  decision into anchor adoption, sends and timeouts, has no automated coverage.
- None of this has run on two headsets. The tests prove the decision table, not that ARKit
  delivers a shared anchor to both devices.
- It assumes **exactly two participants** (`canRealign` requires a single nearby participant). A
  third headset needs more than loosening that guard.

### Pairing and companion roles
The iPhone companion no longer auto-connects to the first host it finds (`autoConnect` was
removed from `MultipeerConnectivityService`), so the steps are explicit on both devices:
- **visionOS ↔ visionOS**: Collaboration → *Invite Nearby Vision Pro* starts SharePlay.
- **visionOS ↔ iPhone**: on Vision Pro, Collaboration → iPhone Companion → *Allow iPhone to
  Connect*; then on iPhone, Controls → Connect to Vision Pro → *Find Vision Pro* and pick the
  headset. The strings live in `CollaborativeSessionView.swift` and are the user-facing contract —
  keep them in step with any change to the flow.

### Diagram gating on the session origin
`AlignedDiagramView` (in `AVAR2App.swift`) withholds a received diagram until its pose and this
device's origin name the same anchor (`SharedDiagram.hasPose(relativeTo:)` vs
`currentPoseAnchorID`), so it is not drawn at coordinates from a frame this device has not
resolved. `hasDisplayed` latches: once shown, a diagram stays mounted when the anchors stop
matching (during a realignment, say), but `.allowsHitTesting(canDisplay)` makes it
non-interactive until they match again. `requiresSharedOrigin` restricts the gate to diagrams
received over SharePlay while co-located; local and iOS-lane content is never withheld.

`UpdateDiagramTransformMessage` and `RemoveDiagramMessage` carry an optional `diagramID` (the
`SharedDiagram.id` of the instance they refer to) alongside the filename. Receivers match on
filename **and** id when the id is present, and on filename alone when it is absent, so older
senders still work. A remove also records the id in `closedDiagramIDs`, which stops a diagram
snapshot that was already in flight from reopening what the sender just closed.

### Diagnostics
`AVAR2/CollabDiagnosticsView.swift` is the panel to use when debugging a two-device session
(launcher window → Collaboration → Diagnostics). It shows SharePlay state, elected owner vs local
participant, `isSpatial` (co-location), anchor sharing availability, the resolved origin, and
per-envelope traffic counters with the last send error. Note the displayed
`originFromAnchor` translation **must differ** between the two devices — identical values mean a
transform leaked onto the wire. `showSessionOriginMarker` draws an axis triad at the origin on
each device; if the two triads occupy the same physical point, alignment works, independently of
whether diagram rendering works. Loopback buttons inject a local example through the real receive
path, so "does a remote diagram render?" is answerable on one device — they are gated on
`includesTestAffordances`, **not** `#if DEBUG`, so they survive into the TestFlight build.

## Surface detection and snapping
- `AVAR2/ARKitSurfaceDetector.swift` uses `PlaneDetectionProvider` on visionOS.
- Classification uses the visionOS 26 `anchor.surfaceClassification` (`SurfaceClassification`),
  not the deprecated `anchor.classification`. The rename was not cosmetic: ARKit collapsed
  `.unknown` / `.undetermined` / `.notAvailable` into a single `.none` and added six cases
  (stairs, bed, cabinet, homeAppliance, tv, plant).
- **The strings "Floor" and "Table" are load-bearing.** `ElementViewModel.filterValidSurfaces`
  grants a 3D diagram snap validity via `isHorizontalSurface(surface) || surfaceType == "Floor"
  || surfaceType == "Table"`, so mapping any other classification to those names silently turns
  that surface into a snap target. The mapping lives on `SurfaceClassification.surfaceTypeName`
  precisely so it can be tested; `Tests/SurfaceClassificationTests.swift` asserts that exactly
  `.floor` and `.table` produce snap-granting names. The six new classifications return their own
  names and can still qualify *geometrically*, exactly as before.
- `.none` returns `nil` so the caller applies its vertical-surface heuristic. Pre-26 only
  `.unknown` got that heuristic; now all previously-unclassified planes do, so some report "Wall"
  where they used to say "Surface". Status text and logs only — snap validity is unaffected.
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
- `AVAR2/RealignmentProtocol.swift`: pure realignment decision logic (tested)
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

Also build for iOS after touching shared collaboration code — that is what proves the iOS
companion still compiles. `generic/platform=iOS` needs a provisioning profile, so an iOS Simulator
destination is the one that works unattended:

```
xcodebuild -project AVAR2.xcodeproj -scheme AVAR2 \
  -destination 'platform=iOS Simulator,id=<UDID>' -configuration Debug build
```

Take the UDID from `xcrun simctl list devices available | grep iPhone` — simulator names change
with every Xcode release, so a hard-coded name goes stale. Confirm the log mentions
`Debug-iphonesimulator`.

**Hardware testing happens through TestFlight, which ships RELEASE builds.** Two consequences:
- Do not put on-device test affordances behind `#if DEBUG` — that removes them from exactly the
  builds used to do the testing. Use the `includesTestAffordances` flag in `SharedWorldRoot.swift`.
- `assert` is stripped in Release. An invariant that must stay observable on hardware needs a
  `Logger.fault` alongside the `assertionFailure` — see `SharedWorldRoot.assertRigidUnitScale`.
- `AVAR_VERBOSE_LOGS` cannot easily be set for a TestFlight install, so the in-app diagnostics
  panel is the primary observability on hardware, not the console.
Build Release locally before pushing anything meant for a TestFlight run; the gate does this.

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
- `Tests/RealignmentTests.swift` — the realignment handshake: both happy paths (same-anchor
  confirm, replacement), the deferred transitions on each side, and the rejection table. Drives the
  reducer from `RealignmentProtocol.swift` across two simulated devices, applying the state
  changes each decision hands back (anchor adoption is the one piece modelled by hand). Built for
  xrsimulator (it links `CollaborativeSessionManager.swift` for the message types).
  **Any suite that compiles `CollaborativeSessionManager.swift` must now also be given
  `AVAR2/RealignmentProtocol.swift`** — that includes `WireFormatTests` and `DataLoaderTests`.
- `Tests/SurfaceClassificationTests.swift` — the snap-critical classification mapping.
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
- Text meshes go through `cachedTextMesh(_:fontSize:extrusionDepth:alignment:lineBreakMode:)`.
  `generateText` runs CoreText glyph layout plus extrusion and is the most expensive geometry the
  app builds. **Every parameter that affects the mesh is part of the cache key** — add to the key
  if you add a parameter, or callers will silently share a mesh built with different settings.
  Three per-element label paths use it; the remaining `generateText` calls (grab-handle caption,
  status message, plane labels, iOS title) are one-off per diagram or per plane and are left
  uncached deliberately.
- `MeshCache` is bounded at 512 entries with FIFO eviction. Geometry keys are naturally bounded
  (610 across the whole bundled corpus) but **text keys are not** — every distinct label string is
  an entry and diagrams keep arriving over HTTP, so an unbounded cache would leak GPU memory over
  a long session. Eviction is safe: RealityKit retains any mesh still in use by an entity, so
  dropping our reference only costs a regeneration if that mesh recurs. The diagnostics panel
  shows the live count.
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
- **Pose ownership decides what happens when `worldRoot` moves** — the origin first appearing,
  being replaced by a different anchor, or being lost — and the two cases are opposites
  (`ElementViewModel.updateWorldRoot`):
  - *Peer-originated* (`DiagramDataLoader.isReceived(filename)`): the wire pose is authoritative,
    so the container keeps its parent-relative pose and moves with `worldRoot`. That movement is
    what lands it on the same physical spot as the owner's copy.
  - *Locally authored*: the user chose a physical place, so the world pose is preserved across the
    frame change and the recomputed anchor-relative pose is re-broadcast. Without this, local
    content jumped by the whole anchor transform the moment an origin was established.
  Ownership cannot be inferred from "did we receive a transform for it" — `shareDiagram` appends
  our own diagrams to `sharedDiagrams`, so the update handler fires for local ones too.

  The exception is `sameSharedAnchor`: when the update carries the *same* anchor UUID as before
  and only its transform differs, locally authored content takes the peer branch too — it moves
  with the frame and nothing is re-broadcast. Before this, every transform update re-pinned local
  content in world space and sent a correction. That is the behaviour as traced in the code; the
  apparent intent (content should follow an anchor ARKit has re-estimated) has **not** been
  verified on two headsets.
- Pose corrections go through `onAuthoritativeTransform`. The throttled `onTransformChanged`
  drag-stream channel is **gone**: peers now learn a new pose only when a gesture ends or a
  correction fires, so every remaining send must actually arrive. Do not reintroduce throttling on
  this callback — the origin-resolved correction is one-shot and has no follow-up to cover for a
  dropped frame.
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
