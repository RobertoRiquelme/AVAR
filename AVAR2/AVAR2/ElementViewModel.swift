//
//  ElementViewModel.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import Foundation
import RealityKit
import SwiftUI
import simd
import OSLog

#if os(visionOS)
import RealityKitContent

#if canImport(ARKit)
import ARKit
#endif

// Logger for ViewModel
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "ElementViewModel")
private let isVerboseLoggingEnabled = ProcessInfo.processInfo.environment["AVAR_VERBOSE_LOGS"] != nil

/// Throttler for rate-limiting updates (e.g., collaborative sync)
final class UpdateThrottler: @unchecked Sendable {
    private var lastUpdateTime = ContinuousClock.now
    private let updateInterval: Duration
    private let lock = NSLock()

    init(intervalMs: Int = Constants.collaborativeSyncIntervalMs) {
        self.updateInterval = .milliseconds(intervalMs)
    }

    func shouldUpdate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        if lastUpdateTime.advanced(by: updateInterval) <= now {
            lastUpdateTime = now
            return true
        }
        return false
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastUpdateTime = ContinuousClock.now
    }
}

@MainActor
class ElementViewModel: ObservableObject {
    @Published private(set) var elements: [ElementDTO] = []
    /// A user-facing error message when loading fails
    @Published var loadErrorMessage: String? = nil
    /// True when the loaded graph came from RTelements (2D) rather than elements (3D)
    @Published private(set) var isGraph2D: Bool = false
    /// The filename this view model is displaying
    private var filename: String?
    private var normalizationContext: NormalizationContext?
    private var entityMap: [String: Entity] = [:]
    private var lineEntities: [Entity] = []
    /// Holds the current RealityViewContent so we can update connections on the fly
    #if os(visionOS)
    private var sceneContent: RealityViewContent?
    #else
    private var sceneContent: Any? // iOS fallback
    #endif
    /// Root container for all graph entities (so we can scale/transform as a group)
    private var rootEntity: Entity?
    /// Stores the close callback so we can rebuild after async loads.
    private var pendingOnClose: (() -> Void)?
    /// Marks whether a scene rebuild should occur when data/content become available.
    private var rebuildPending = false
    /// Default scale applied when spawning a diagram (30% smaller)
    private var spawnScale: Float {
        appModel?.defaultDiagramScale ?? PlatformConfiguration.diagramScale * 0.7
    }
    
    /// A pose that arrived before the entities existed, applied once they do.
    ///
    /// The old code did `guard let root = rootEntity else { return }` and silently discarded the
    /// update — which meant the peer's *first* placement message, the one that matters most, was
    /// almost always thrown away (it races `rebuildSceneIfNeeded`, which needs both a
    /// normalization context and scene content).
    private var pendingSharedTransform: (position: SIMD3<Float>?, orientation: simd_quatf?, scale: Float?)?

    /// This device's resolved transform for the session-origin anchor, mirrored from the
    /// collaboration session so `worldRoot` can be positioned at build time.
    private var sessionOriginTransform: simd_float4x4?

    /// Pushes a pose that must reach peers exactly once and must NOT be throttled.
    ///
    /// `onTransformChanged` is rate-limited for drag streams, where dropping a frame is harmless
    /// because another follows immediately. A pose correction after the session origin resolves
    /// has no follow-up: if the throttle swallows it, peers keep the stale pre-origin coordinates
    /// indefinitely. Hence a separate channel.
    var onAuthoritativeTransform: ((SIMD3<Float>, simd_quatf, Float) -> Void)?

    /// Forces a non-identity `worldRoot` so the reparenting can be validated on a single device.
    /// See `SharedWorldRoot.debugOffsetPose`. Always compiled — see `includesTestAffordances`.
    var debugWorldRootOffsetEnabled = false {
        didSet {
            guard debugWorldRootOffsetEnabled != oldValue else { return }
            updateWorldRoot(originFromAnchor: sessionOriginTransform)
        }
    }

    /// Whether this diagram arrived from a peer rather than being authored on this device.
    ///
    /// Decides who owns the pose when the session origin appears or is refined — see
    /// `updateWorldRoot(originFromAnchor:)`.
    private var isPeerOriginated = false

    /// The diagram's pose **in the shared session-origin frame**.
    ///
    /// This is the value that goes on the wire. Because the container is parented to `worldRoot`,
    /// asking for it relative to the parent *is* the conversion — which is why both duplicated
    /// `anchor.transform.inverse` blocks in `CollaborativeSessionManager` could be deleted, along
    /// with their inconsistency (position used `matrix.inverse` while orientation used
    /// `simd_quatf(matrix).inverse`).
    func getSharedTransform() -> (position: SIMD3<Float>, orientation: simd_quatf, scale: Float)? {
        guard let root = rootEntity else { return nil }
        let parent = root.parent   // worldRoot, or nil before it exists
        return (root.position(relativeTo: parent),
                root.orientation(relativeTo: parent),
                root.scale.x)
    }

    // NOTE: `getWorldTransform()` was removed. Every caller now uses `getSharedTransform()`,
    // which reports the pose in the shared session-origin frame — the value that actually goes on
    // the wire. Reporting world space was the old, unconvertible representation.

    /// Apply a peer's pose, which is expressed in the shared session-origin frame.
    ///
    /// No matrices, no inverses, no `useFullAnchorTransform` flag — and in particular none of the
    /// old branch that deliberately zeroed the anchor translation (`columns.3 = (0,0,0,1)`),
    /// which placed remote diagrams around the *receiver's* origin rotated by the sender's yaw.
    func applySharedDiagramTransform(position: SIMD3<Float>?,
                                     orientation: simd_quatf?,
                                     scale: Float?) {
        guard let root = rootEntity else {
            pendingSharedTransform = (position, orientation, scale)
            return
        }
        let parent = root.parent
        if let position { root.setPosition(position, relativeTo: parent) }
        if let orientation { root.setOrientation(orientation, relativeTo: parent) }
        if let scale {
            root.scale = SIMD3<Float>(repeating: scale)
            updateBackgroundEntityCollisionShapes(scale: scale)
        }
    }

    /// Points this diagram's `worldRoot` at the session origin.
    ///
    /// Called whenever the resolved anchor transform appears or is refined by ARKit. What should
    /// happen to the diagram depends on **who owns its pose**, and the two cases are opposites:
    ///
    /// - **Peer-originated**: the anchor-relative pose from the wire is authoritative. The
    ///   container must therefore keep its parent-relative pose and *move with* `worldRoot` —
    ///   that movement is precisely what brings it onto the same physical spot as the owner's.
    ///
    /// - **Locally authored**: the user put this diagram at a physical place, and it must stay
    ///   there. Its parent-relative pose is only a derived value, so we preserve the world pose
    ///   across the frame change and re-broadcast the recomputed anchor-relative pose to peers.
    ///
    /// Without the second branch, local content visibly jumped by the whole anchor transform the
    /// moment a session origin was established (or slightly, on every ARKit refinement) — the
    /// diagram would leave the table the user had just placed it on.
    func updateWorldRoot(originFromAnchor: simd_float4x4?) {
        sessionOriginTransform = originFromAnchor

        // A real origin always wins; the debug pose only stands in when there is none.
        var originFromAnchor = originFromAnchor
        if originFromAnchor == nil, debugWorldRootOffsetEnabled {
            originFromAnchor = SharedWorldRoot.debugOffsetPose
        }

        guard let root = rootEntity,
              let worldRoot = root.parent,
              worldRoot.name == SharedWorldRoot.name else { return }

        guard !isPeerOriginated else {
            SharedWorldRoot.apply(originFromAnchor: originFromAnchor, to: worldRoot)
            return
        }

        // Capture in WORLD space, move the frame, then restore the world pose. Scale is
        // parent-relative but `worldRoot` is always rigid and unit-scale, so it is unaffected.
        let preservedWorldPosition = root.position(relativeTo: nil)
        let preservedWorldOrientation = root.orientation(relativeTo: nil)

        SharedWorldRoot.apply(originFromAnchor: originFromAnchor, to: worldRoot)

        root.setPosition(preservedWorldPosition, relativeTo: nil)
        root.setOrientation(preservedWorldOrientation, relativeTo: nil)

        // Physically unchanged, but its pose *in the shared frame* is now different — so peers
        // need the new value or they would keep placing it at the pre-origin coordinates.
        // Deliberately on the unthrottled channel: this correction is one-shot.
        if let transform = getSharedTransform() {
            onAuthoritativeTransform?(transform.position, transform.orientation, transform.scale)
        }
    }
    /// Background entity to capture pan/zoom gestures
    private var backgroundEntity: Entity?
    /// Starting uniform scale for the container when zoom begins
    private var zoomStartScale: Float?
    
    /// Called when an individual element has been repositioned in container-local space
    var onElementMoved: ((String, SIMD3<Float>) -> Void)?
    /// Callback for when diagram transform changes (for syncing)
    var onTransformChanged: ((SIMD3<Float>, simd_quatf, Float) -> Void)?
    /// Pivot point in world space at zoom start
    private var zoomPivotWorld: SIMD3<Float>?
    /// Pivot point in container-local space (normalized, unscaled) at zoom start
    private var zoomPivotLocal: SIMD3<Float>?
    /// Starting container position when panning begins
    private var panStartPosition: SIMD3<Float>?
    /// Container orientation at the start of a pan
    private var panStartOrientation: simd_quatf?
    /// Flag to prevent surface snapping during active pan
    private var isPanActive: Bool = false
    /// Current surface the diagram is snapped to (if any)
    private var currentSnappedSurface: PlaneAnchor? = nil
    /// Snapping distance threshold
    private let snapDistance: Float = Constants.snapDistance

    private var selectedEntity: Entity?
    /// Tracks which entity is currently being dragged
    private var draggingEntity: Entity?
    /// The world-space position at the start of the current drag
    private var draggingStartPosition: SIMD3<Float>?
    // In ElementViewModel.swift
    // Legacy AnchorEntity properties removed - now working directly with PlaneAnchor objects from AppModel
    
    /// Reference to AppModel (simplified)
    private var appModel: AppModel?
    
    /// Reference to the grab handle for adding snap messages
    private var grabHandleEntity: Entity?
    /// Reference to the zoom handle for scaling gestures
    private var zoomHandleEntity: Entity?
    /// Starting scale when zoom handle drag begins
    private var zoomHandleStartScale: Float?
    /// Starting drag position for zoom handle
    private var zoomHandleStartDragPosition: SIMD3<Float>?
    /// Reference to the rotation button for Y-axis rotation (3D diagrams only)
    private var rotationButtonEntity: Entity?
    /// Starting rotation when rotation drag begins
    private var rotationStartAngle: Float?
    /// Starting drag position for rotation
    private var rotationStartDragPosition: SIMD3<Float>?

    private func debugLog(_ message: @autoclosure @escaping () -> String) {
        guard isVerboseLoggingEnabled else { return }
        logger.debug("\(message(), privacy: .public)")
    }

    // NEW: Snap/unsnap banner
    @Published var snapStatusMessage: String = ""

    // NEW: Set this to false to only show message once, or to true to always show
    private var alwaysShowSnapMessage = true
    
    // Enhanced surface detection constants
    private let snapThreshold: Float = Constants.snapThreshold
    private let releaseThreshold: Float = Constants.releaseThreshold
    
    /// Set the AppModel reference for accessing shared surface anchors
    func setAppModel(_ appModel: AppModel) {
        self.appModel = appModel
        debugLog("🔧 ElementViewModel: AppModel set, using PERSISTENT surface detection")
        debugLog("🔧 Surface detection running: \(appModel.surfaceDetector.isRunning), anchors: \(appModel.surfaceDetector.surfaceAnchors.count)")
    }
    
    /// Get all available surface anchors with proper coordinate system handling
    private func getAllSurfaceAnchors() -> [PlaneAnchor] {
        guard let appModel = appModel else { 
            logger.warning("⚠️ getAllSurfaceAnchors: No AppModel available")
            return [] 
        }
        let anchors = appModel.surfaceDetector.surfaceAnchors
        debugLog("🔍 getAllSurfaceAnchors: Found \(anchors.count) PERSISTENT surface anchors")
        
        // Log each surface for debugging
        for anchor in anchors {
            let surfaceType = getSurfaceTypeName(anchor)
            debugLog("   📍 Surface \(anchor.id): \(surfaceType)")
        }
        
        return anchors
    }
    
    /// Update the 3D snap message above the grab handle
    private func update3DSnapMessage(_ message: String) {
        guard let grabHandle = grabHandleEntity else { 
            logger.warning("⚠️ Cannot update 3D snap message - no grab handle entity")
            return 
        }
        debugLog("🎯 Updating 3D snap message: '\(message)'")
        
        // Remove existing snap message
        if let existingMessage = grabHandle.children.first(where: { $0.name == "snapMessage" }) {
            existingMessage.removeFromParent()
        }
        
        // Don't add anything if message is empty
        guard !message.isEmpty else { return }
        
        // Create 3D text entity
        let textMesh = MeshResource.generateText(
            message,
            extrusionDepth: 0.002,
            font: .systemFont(ofSize: 0.03),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        
        // Create text material with bright color
        let textMaterial = SimpleMaterial(color: .systemBlue, isMetallic: false)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        textEntity.name = "snapMessage"
        
        // Position above the grab handle
        textEntity.position = [0, 0.08, 0] // 8cm above the handle
        
        // Add to grab handle
        grabHandle.addChild(textEntity)
        
        debugLog("🎯 Added 3D snap message: '\(message)' above grab handle")
    }

    func loadData(from filename: String) async {
        debugLog("ElementViewModel.loadData called for: \(filename)")
        self.filename = filename  // Store filename for position tracking
        rebuildPending = true
        debugLog("rebuildPending set to true, sceneContent is: \(self.sceneContent == nil ? "nil" : "set")")
        do {
            debugLog("About to call DiagramDataLoader for: \(filename)")
            let output = try DiagramDataLoader.loadScriptOutput(from: filename)
            self.isPeerOriginated = DiagramDataLoader.isReceived(filename)
            self.elements = output.elements
            self.isGraph2D = output.is2D
            self.normalizationContext = NormalizationContext(elements: output.elements, is2D: output.is2D)
            logger.info("Loaded \(output.elements.count) elements (2D: \(output.is2D)) from \(filename)")
            debugLog("About to call rebuildSceneIfNeeded")
            rebuildSceneIfNeeded()
            debugLog("rebuildSceneIfNeeded completed")
        } catch let error as DiagramLoadingError {
            let message = error.errorDescription ?? "Failed to load diagram"
            logger.error("\(message, privacy: .public)")
            self.loadErrorMessage = message
        } catch {
            let msg = "Failed to load \(filename): \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            self.loadErrorMessage = msg
        }
    }

#if os(visionOS)
    /// Creates and positions all element entities in the scene.
    /// - Parameter onClose: Optional callback to invoke when the close button is tapped.
    func loadElements(in content: RealityViewContent, onClose: (() -> Void)? = nil) {
        debugLog("loadElements called")
        pendingOnClose = onClose
        setupSceneContent(content)
        rebuildPending = true
        debugLog("rebuildPending set to true in loadElements")
        rebuildSceneIfNeeded()
    }
#endif

    private func rebuildSceneIfNeeded() {
        debugLog("rebuildSceneIfNeeded called")
        debugLog("rebuildPending: \(self.rebuildPending)")
        debugLog("normalizationContext: \(self.normalizationContext == nil ? "nil" : "set")")
        debugLog("sceneContent: \(self.sceneContent == nil ? "nil" : "set")")
        #if os(visionOS)
        guard rebuildPending,
              let normalizationContext = self.normalizationContext,
              let content = self.sceneContent else {
            debugLog("Guard failed - scene rebuild skipped")
            return
        }
        debugLog("All conditions met - proceeding with scene rebuild")
        rebuildPending = false

        if let existing = rootEntity {
            existing.removeFromParent()
        }
        if let background = backgroundEntity {
            background.removeFromParent()
        }

        // A pose that arrived before entities existed is consumed at construction time so the
        // diagram is correct on its first frame rather than snapping into place afterwards.
        let initialPose = pendingSharedTransform.flatMap { pending -> (SIMD3<Float>, simd_quatf?, Float?)? in
            guard let position = pending.position else { return nil }
            return (position, pending.orientation, pending.scale)
        }

        let sceneBuilder = DiagramSceneBuilder(
            filename: filename,
            isGraph2D: isGraph2D,
            spawnScale: spawnScale,
            appModel: appModel,
            logger: logger,
            initialAnchorRelativePose: initialPose
        )

        let buildResult = sceneBuilder.buildScene(
            in: content,
            normalizationContext: normalizationContext,
            onClose: pendingOnClose
        )

        self.rootEntity = buildResult.container
        self.backgroundEntity = buildResult.background
        self.grabHandleEntity = buildResult.grabHandle
        self.zoomHandleEntity = buildResult.zoomHandle
        self.rotationButtonEntity = buildResult.rotationButton

        // Point worldRoot at the session origin before anything reads world coordinates.
        SharedWorldRoot.apply(originFromAnchor: sessionOriginTransform,
                              to: SharedWorldRoot.findOrCreate(in: content))

        updateBackgroundEntityCollisionShapes(scale: buildResult.container.scale.x)
        createAndPositionElements(container: buildResult.container, normalizationContext: normalizationContext)
        updateConnections(in: content)
        addOriginMarker()

        if initialPose != nil { pendingSharedTransform = nil }
        #else
        // No immersive scene on iOS.
        #endif
    }
    
    private func setupSceneContent(_ content: RealityViewContent) {
        debugLog("setupSceneContent called")
        debugLog("rebuildPending: \(self.rebuildPending)")
        self.sceneContent = content

        // removeFromParent rather than content.remove: the container now hangs off worldRoot, so
        // content.remove would not detach it.
        if let existing = rootEntity {
            existing.removeFromParent()
        }
        if let bg = backgroundEntity {
            bg.removeFromParent()
        }

        // If data was already loaded but scene wasn't ready, rebuild now
        if rebuildPending {
            debugLog("Data was already loaded, triggering rebuildSceneIfNeeded")
            rebuildSceneIfNeeded()
        } else {
            debugLog("No rebuild pending")
        }
    }
    
    /// Update the background entity's collision shapes to match the current scale
    /// This ensures snapping calculations use the correct scaled dimensions
    private func updateBackgroundEntityCollisionShapes(scale: Float) {
        guard let background = backgroundEntity,
              let normalizationContext = self.normalizationContext else { 
            logger.warning("⚠️ Cannot update background collision shapes - missing background entity or normalization context")
            return 
        }
        
        // Calculate scaled dimensions
        let baseWidth = Float(normalizationContext.positionRanges[0] / normalizationContext.globalRange * 2)
        let baseHeight = Float(normalizationContext.positionRanges[1] / normalizationContext.globalRange * 2)
        let baseDepth = normalizationContext.positionCenters.count > 2 ? 
            Float(normalizationContext.positionRanges[2] / normalizationContext.globalRange * 2) : 0.01
        
        // Apply scale to dimensions
        let scaledWidth = baseWidth * scale
        let scaledHeight = baseHeight * scale
        let scaledDepth = baseDepth * scale
        
        // Create new collision shape with scaled dimensions
        let scaledShape = ShapeResource.generateBox(size: [scaledWidth, scaledHeight, scaledDepth])
        background.components.set(CollisionComponent(shapes: [scaledShape]))
        
        debugLog("📦 Updated background collision shapes: \(scaledWidth) x \(scaledHeight) x \(scaledDepth) (scale: \(scale))")
    }
    
    private func createAndPositionElements(container: Entity, normalizationContext: NormalizationContext) {
        entityMap.removeAll()
        lineEntities.removeAll()
        let hoverEffectComponent = HoverEffectComponent()

        debugLog("🔄 Creating and positioning \(self.elements.count) elements")
        var validElements = 0

        for element in self.elements {
            // Skip edge/line elements - they don't need visual representation, only connection info
            if element.type.lowercased() == "edge" || element.shape?.shapeDescription?.lowercased() == "line" {
                debugLog("🔗 Skipping edge/line element \(element.id ?? "unknown") - used for connections only")
                continue
            }

            guard let coords = element.position else {
                logger.warning("⚠️ Element \(element.id ?? "unknown") has no position - skipping")
                continue
            }

            // Skip camera elements - they don't need visual representation
            if element.type.lowercased() == "camera" {
                debugLog("📷 Skipping camera element \(element.id ?? "unknown")")
                continue
            }

            let entity = createEntity(for: element)
            var localPos = calculateElementPosition(coords: coords, normalizationContext: normalizationContext)

            // Push back elements that have borderColor but no fill color (noPaint/hollow)
            // to avoid z-fighting with other elements
            let hasNoPaint = element.color == nil && element.borderColor != nil
            if hasNoPaint {
                localPos.z -= 0.003
            }

            debugLog("📍 Element \(element.id ?? "unknown") positioned at \(localPos)")

            entity.position = localPos
            entity.components.set(hoverEffectComponent)
            container.addChild(entity)
            let elementIdKey = element.id ?? "element_\(UUID().uuidString.prefix(8))"
            entityMap[elementIdKey] = entity
            debugLog("🗝️ Stored entity with key: '\(elementIdKey)' for element ID: \(element.id ?? "nil")")
            validElements += 1
        }

        logger.info("✅ Successfully created \(validElements) out of \(self.elements.count) elements")
    }
    
    private func calculateElementPosition(coords: [Double], normalizationContext: NormalizationContext) -> SIMD3<Float> {
        let dims = normalizationContext.positionCenters.count
        let rawX = coords.count > 0 ? coords[0] : 0
        let rawY = coords.count > 1 ? coords[1] : 0
        let rawZ = dims > 2 && coords.count > 2 ? coords[2] : 0
        let globalRange = normalizationContext.globalRange
        let normX = (rawX - normalizationContext.positionCenters[0]) / globalRange * 2
        let normY = (rawY - normalizationContext.positionCenters[1]) / globalRange * 2
        let normZ = dims > 2
            ? (rawZ - normalizationContext.positionCenters[2]) / globalRange * 2
            : 0
        let yPos = normalizationContext.is2D ? -Float(normY) : Float(normY)
        return SIMD3<Float>(Float(normX), yPos, Float(normZ))
    }

    /// Draws lines for each edge specified by fromId/toId on edge elements.
    /// Rebuilds all connection lines under the root container
    func updateConnections(in content: RealityViewContent) {
        guard let container = rootEntity else { return }
        // Remove existing lines
        lineEntities.forEach { $0.removeFromParent() }
        lineEntities.removeAll()
        // For each element that defines an edge, connect fromId -> toId
        for edge in self.elements {
            guard let connection = self.createConnectionEntity(for: edge) else { continue }
            container.addChild(connection)
            self.lineEntities.append(connection)
        }
    }

    /// Adds XYZ axes and optional grid lines under the root container
    private func addCoordinateGrid() {
        guard let container = rootEntity else { return }
        let axisLength: Float = 1.0
        let lineThickness: Float = 0.002
        func axis(from: SIMD3<Float>, to: SIMD3<Float>, color: UIColor) -> ModelEntity {
            let vector = to - from
            let length = simd_length(vector)
            let mesh = MeshResource.generateBox(size: [length, lineThickness, lineThickness])
            let material = SimpleMaterial(color: color, isMetallic: false)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = from + vector / 2
            // `to` and `entity.position` are CONTAINER-LOCAL, so the reference frame must be the
            // container, not the scene root. With `relativeTo: nil` these local coordinates were
            // interpreted as world space — already wrong before reparenting (the debug axes were
            // misoriented whenever the diagram wasn't at the origin with identity rotation), and
            // wrong differently once the container hangs off worldRoot.
            entity.look(at: to, from: entity.position, relativeTo: container)
            return entity
        }
        // Local origin for axes and grid
        let originLocal = SIMD3<Float>(0, 0, 0)
        // Axes at container origin
        container.addChild(axis(from: originLocal, to: originLocal + SIMD3(axisLength, 0, 0), color: .red))
        container.addChild(axis(from: originLocal, to: originLocal + SIMD3(0, axisLength, 0), color: .green))
        container.addChild(axis(from: originLocal, to: originLocal + SIMD3(0, 0, axisLength), color: .blue))
        // Grid lines in XZ plane around origin
        let gridSize = 2
        for i in -gridSize...gridSize {
            let offset = Float(i) * 0.1
            container.addChild(axis(from: SIMD3(-1.0, 0, offset), to: SIMD3(1.0, 0, offset), color: .gray))
            container.addChild(axis(from: SIMD3(offset, 0, -1.0), to: SIMD3(offset, 0, 1.0), color: .gray))
        }
    }

    func handleDragChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        // Only allow dragging of our element entities
        guard value.entity.name.hasPrefix("element_") else { return }
        // Initialize drag state if needed
        if draggingEntity !== value.entity {
            draggingEntity = value.entity
            draggingStartPosition = value.entity.position
        }
        // Compute new position based on start + gesture's 3D translation
        if let start = draggingStartPosition {
            // Get 3D gesture translation (Vector3D) and convert to SIMD3<Float>
            let t3 = value.gestureValue.translation3D
            let delta = SIMD3<Float>(Float(t3.x), -Float(t3.y), Float(t3.z))
            
            // Transform gesture by inverse of container rotation for coherent movement
            let containerOrientation = rootEntity?.orientation(relativeTo: nil) ?? simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            let inverseRotation = containerOrientation.inverse
            let rotatedDelta = inverseRotation.act(delta)
            
            // Apply scale and account for current diagram scale to maintain consistent gesture feel
            let currentScale = rootEntity?.scale.x ?? 1.0
            let adjustedScale = Constants.dragTranslationScale / currentScale
            let offset = rotatedDelta * adjustedScale
            value.entity.position = start + offset
            selectedEntity = value.entity
            // Update connection lines immediately
            if let content = sceneContent {
                updateConnections(in: content)
            }
        }
    }

    func handleDragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        // Clear drag state
        draggingEntity = nil
        draggingStartPosition = nil
        selectedEntity = nil
        // Final update of connection lines
        if let content = sceneContent {
            updateConnections(in: content)
        }
        // Notify transform change
        if let transform = getSharedTransform() {
            onTransformChanged?(transform.position, transform.orientation, transform.scale)
        }
        // If the gesture ended on an element_*, report its new local position
        if value.entity.name.hasPrefix("element_") {
            let raw = value.entity.name
            let elementId = String(raw.dropFirst("element_".count))
            let localPos = value.entity.position                   // local to the diagram container
            onElementMoved?(elementId, localPos)
        }
    }

    /// Handle pinch gesture to uniformly scale the entire graph container, pivoting around the touched entity
    func handleZoomChanged(_ value: EntityTargetValue<MagnificationGesture.Value>) {
        guard let container = rootEntity else { return }
        // Magnification amount (1.0 = no change)
        let current = Float(value.gestureValue)
        // On first change, record initial scale and pivot
        if zoomStartScale == nil {
            // record starting uniform scale
            zoomStartScale = container.scale.x
            // compute pivot in world space: the touched entity's origin
            let pivotWorld = value.entity.convert(position: SIMD3<Float>(0, 0, 0), to: nil)
            zoomPivotWorld = pivotWorld
            // compute pivot in container-local space (accounting for initial scale)
            let localWithScale = container.convert(position: pivotWorld, from: nil)
            // normalize by initial scale to get unscaled local coordinates
            zoomPivotLocal = localWithScale / zoomStartScale!
        }
        // compute new uniform scale
        let newScale = zoomStartScale! * current
        container.scale = SIMD3<Float>(repeating: newScale)
        
        // Update background entity's collision shapes to match new scale
        updateBackgroundEntityCollisionShapes(scale: newScale)
        
        // reposition container so that pivotWorld remains fixed under the pinch
        if let pivotWorld = zoomPivotWorld, let pivotLocal = zoomPivotLocal {
            // compute local pivot after scaling
            let scaledLocal = pivotLocal * newScale
            // set new container position so pivotWorld = container.position + scaledLocal.
            // `pivotWorld` came from `convert(position:to: nil)`, i.e. WORLD space, so it must be
            // assigned with relativeTo: nil — a bare `.position =` would be interpreted in the
            // parent's (worldRoot's) frame and offset the pinch by the whole anchor transform.
            container.setPosition(pivotWorld - scaledLocal, relativeTo: nil)
        }
    }

    func handleZoomEnded(_ value: EntityTargetValue<MagnificationGesture.Value>) {
        // clear zoom state
        zoomStartScale = nil
        zoomPivotWorld = nil
        zoomPivotLocal = nil
        // Notify transform change
        if let transform = getSharedTransform() {
            onTransformChanged?(transform.position, transform.orientation, transform.scale)
        }
    }

    /// Handle pan gesture with native visionOS WindowGroup-like behavior
    func handlePanChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let container = rootEntity else { return }
        
        let gestureOffset = extractGestureOffset(from: value)
        
        if !initializePanStateIfNeeded(container: container) {
            return
        }
        
        let newPosition = calculateNewPanPosition(gestureOffset: gestureOffset)
        updateContainerPosition(container: container, position: newPosition)
        updateContainerOrientation(container: container, position: newPosition)
        checkForSurfaceSnapping(container: container, at: newPosition)
    }
    
    private func extractGestureOffset(from value: EntityTargetValue<DragGesture.Value>) -> SIMD3<Float> {
        let translation = value.gestureValue.translation3D
        return SIMD3<Float>(
            Float(translation.x),
            -Float(translation.y),  // Invert Y axis for visionOS coordinate system
            Float(translation.z)
        )
    }
    
    private func initializePanStateIfNeeded(container: Entity) -> Bool {
        if panStartPosition == nil {
            panStartPosition = container.position(relativeTo: nil)
            isPanActive = true
            return false
        }
        return true
    }
    
    private func calculateNewPanPosition(gestureOffset: SIMD3<Float>) -> SIMD3<Float> {
        let sensitivity: Float = Constants.panSensitivity
        let scaledGesture = gestureOffset * sensitivity
        return panStartPosition! + scaledGesture
    }
    
    private func updateContainerPosition(container: Entity, position: SIMD3<Float>) {
        container.setPosition(position, relativeTo: nil)
    }
    
    private func updateContainerOrientation(container: Entity, position: SIMD3<Float>) {
        let userPosition = SIMD3<Float>(0, position.y, 0)
        let windowToUser = userPosition - position
        let distanceToUser = simd_length(windowToUser)
        
        if distanceToUser > 0.001 {
            let directionToUser = normalize(SIMD3<Float>(windowToUser.x, 0, windowToUser.z))
            let angle = atan2(directionToUser.x, directionToUser.z)
            let targetOrientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            container.setOrientation(targetOrientation, relativeTo: nil)
        }
    }

    func handlePanEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let container = rootEntity else { return }
        
        let finalPosition = container.position(relativeTo: nil)
        let smoothedPosition = calculateFinalPanPosition(finalPosition)
        
        animateToFinalPosition(container: container, position: smoothedPosition)
        handleSurfaceSnappingOnPanEnd(container: container, position: smoothedPosition)
        resetPanState()
        updateConnectionsAfterPan()
        
        // Notify transform change
        if let transform = getSharedTransform() {
            onTransformChanged?(transform.position, transform.orientation, transform.scale)
        }
    }
    
    private func calculateFinalPanPosition(_ finalPosition: SIMD3<Float>) -> SIMD3<Float> {
        let comfortPosition = applyComfortZoneSnapping(finalPosition)
        let dampingFactor: Float = 0.85
        return mix(finalPosition, comfortPosition, t: dampingFactor)
    }
    
    private func animateToFinalPosition(container: Entity, position: SIMD3<Float>) {
        container.move(
            to: Transform(
                scale: container.scale,
                rotation: container.orientation(relativeTo: nil),
                translation: position
            ),
            relativeTo: nil,
            duration: 0.3,
            timingFunction: .easeOut
        )
    }
    
    private func handleSurfaceSnappingOnPanEnd(container: Entity, position: SIMD3<Float>) {
        if let snapTarget = findNearestSurfaceForSnapping(diagramPosition: position) {
            performSnapToSurface(container: container, surface: snapTarget)
        }
    }
    
    private func resetPanState() {
        panStartPosition = nil
        panStartOrientation = nil
        isPanActive = false
    }
    
    private func updateConnectionsAfterPan() {
        if let content = sceneContent {
            updateConnections(in: content)
        }
    }
    
    /// Handle zoom handle drag to scale the diagram
    func handleZoomHandleDragChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let container = rootEntity else { return }
        
        // Initialize zoom handle drag state
        if zoomHandleStartScale == nil {
            zoomHandleStartScale = container.scale.x
        }
        
        guard let startScale = zoomHandleStartScale else { return }
        
        // Native visionOS WindowGroup zoom behavior: diagonal movement from corner
        let translation2D = value.gestureValue.translation
        let dragX = Float(translation2D.width)   // Right = positive
        let dragY = Float(translation2D.height)  // Down = positive
        
        // Use distance-based calculation for consistent diagonal behavior
        // Determine zoom direction based on the dominant movement away from/toward origin
        let distance = sqrt(dragX * dragX + dragY * dragY)
        let direction: Float = (dragX + dragY) >= 0 ? 1.0 : -1.0  // Down-right = zoom in, up-left = zoom out
        let diagonalMovement = distance * direction
        
        // Simple, direct scaling like native visionOS
        let scaleSensitivity: Float = Constants.zoomScaleSensitivity
        let scaleFactor: Float = 1.0 + (diagonalMovement * scaleSensitivity)
        let newScale = max(Constants.minZoomScale, min(Constants.maxZoomScale, startScale * scaleFactor))
        
        // Apply uniform scaling
        container.scale = SIMD3<Float>(repeating: newScale)
        
        // Update background entity's collision shapes to match new scale
        updateBackgroundEntityCollisionShapes(scale: newScale)
    }
    
    /// Handle zoom handle drag end
    func handleZoomHandleDragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        // Clear zoom handle drag state
        zoomHandleStartScale = nil
        zoomHandleStartDragPosition = nil
        
        // Final update of connection lines
        if let content = sceneContent {
            updateConnections(in: content)
        }
        
        // Notify transform change
        if let transform = getSharedTransform() {
            onTransformChanged?(transform.position, transform.orientation, transform.scale)
        }
    }
    
    /// Handle rotation button drag to rotate 3D diagrams on Y-axis
    func handleRotationButtonDragChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let container = rootEntity, !isGraph2D else { 
            logger.warning("⚠️ Rotation only available for 3D diagrams")
            return 
        }
        
        // Initialize rotation drag state
        if rotationStartAngle == nil {
            let currentRotation = container.orientation(relativeTo: nil)
            // Extract Y-axis rotation angle from quaternion
            rotationStartAngle = extractYAxisRotation(from: currentRotation)
            rotationStartDragPosition = SIMD3<Float>(
                Float(value.gestureValue.startLocation3D.x),
                Float(value.gestureValue.startLocation3D.y),
                Float(value.gestureValue.startLocation3D.z)
            )
        }
        
        guard let startAngle = rotationStartAngle,
              let startPos = rotationStartDragPosition else { return }
        
        // Calculate rotation based on horizontal drag movement
        let currentPos = SIMD3<Float>(
            Float(value.gestureValue.location3D.x),
            Float(value.gestureValue.location3D.y),
            Float(value.gestureValue.location3D.z)
        )
        
        // Use horizontal movement for rotation
        let deltaX = currentPos.x - startPos.x
        let rotationSensitivity: Float = Constants.rotationSensitivity
        let rotationDelta = deltaX * rotationSensitivity
        
        let newAngle = startAngle + rotationDelta
        let newRotation = simd_quatf(angle: newAngle, axis: SIMD3<Float>(0, 1, 0))
        
        // Apply rotation to container
        container.setOrientation(newRotation, relativeTo: nil)
        
        debugLog("🔄 Rotating 3D diagram: angle=\(newAngle) radians (\(newAngle * 180 / .pi) degrees)")
    }
    
    /// Handle rotation button drag end
    func handleRotationButtonDragEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        // Clear rotation drag state
        rotationStartAngle = nil
        rotationStartDragPosition = nil
        
        // Final update of connection lines
        if let content = sceneContent {
            updateConnections(in: content)
        }
        
        debugLog("🔄 Rotation gesture ended")
        
        // Notify transform change
        if let transform = getSharedTransform() {
            onTransformChanged?(transform.position, transform.orientation, transform.scale)
        }
    }
    
    /// Extract Y-axis rotation angle from a quaternion
    private func extractYAxisRotation(from quaternion: simd_quatf) -> Float {
        // Convert quaternion to Euler angles and extract Y rotation
        let yRotation = atan2(2.0 * (quaternion.vector.w * quaternion.vector.y + quaternion.vector.x * quaternion.vector.z),
                             1.0 - 2.0 * (quaternion.vector.y * quaternion.vector.y + quaternion.vector.z * quaternion.vector.z))
        return yRotation
    }
    
    /// Performs the unsnap animation from a surface
    private func unsnapFromSurface(container: Entity) {
        let worldPos = container.position(relativeTo: nil)

        // Animate back to world space.
        // `rotation:` must be the WORLD orientation to match `relativeTo: nil` and `worldPos`.
        // A bare `container.orientation` is parent-relative, which would rotate the diagram by
        // the session-origin yaw on every unsnap.
        container.move(
            to: Transform(scale: container.scale,
                          rotation: container.orientation(relativeTo: nil),
                          translation: worldPos),
            relativeTo: nil,
            duration: 0.25,
            timingFunction: .easeOut
        )

        // Re-assert the world pose after the animation.
        //
        // This deliberately does NOT reparent. The old code did
        // `removeFromParent(); sceneContent.add(container)`, which moved the diagram out of
        // `worldRoot` and back to the scene root — permanently un-sharing it, since its pose was
        // then no longer expressed in the shared frame. Nothing reparents the container during
        // snapping in the first place, so there was never anything to undo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            container.setPosition(worldPos, relativeTo: nil)
        }
    }
    
    /// Gets a human-readable surface type name.
    ///
    /// The classification-to-name mapping lives on `SurfaceClassification` so it can be tested
    /// exhaustively — "Floor" and "Table" grant 3D snap validity in `filterValidSurfaces`, so a
    /// stray mapping there would silently change which surfaces diagrams snap to.
    ///
    /// Only the unclassified case needs the anchor itself: ARKit's `.none` (which replaces the
    /// pre-26 `.unknown` / `.undetermined` / `.notAvailable`) falls back to geometry. Previously
    /// only `.unknown` got this heuristic and the other two returned "Surface"; now all three do,
    /// so some unclassified vertical surfaces report "Wall" where they used to say "Surface".
    /// That affects the status message and logs only — neither string is "Floor" or "Table", and
    /// the 2D path filters purely on geometry.
    private func getSurfaceTypeName(_ anchor: PlaneAnchor) -> String {
        if let name = anchor.surfaceClassification.surfaceTypeName { return name }
        return isVerticalSurface(anchor) ? "Wall" : "Surface"
    }
    
    /// Detect if a surface is vertical (likely a wall) based on its orientation
    private func isVerticalSurface(_ anchor: PlaneAnchor) -> Bool {
        let rotation = simd_quatf(anchor.originFromAnchorTransform)
        let normal = rotation.act(SIMD3<Float>(0, 1, 0)) // Surface normal
        
        // Check if the surface normal is mostly horizontal (pointing sideways)
        // For vertical surfaces, the Y component should be close to 0
        let verticalThreshold: Float = 0.7 // Adjust this value as needed
        let isVertical = abs(normal.y) < verticalThreshold
        
        if isVertical {
            debugLog("🧱 Detected vertical surface (wall): \(anchor.id) with normal \(normal)")
        }
        
        return isVertical
    }
    
    /// Find the lowest Y position of all entities in the 3D diagram, accounting for entity size
    private func findLowestEntityPosition() -> Float {
        guard let container = rootEntity else { return 0 }
        
        var lowestY: Float = Float.greatestFiniteMagnitude
        
        // Iterate through all entities in the container to find the lowest Y position
        for entity in container.children {
            if entity.name.starts(with: "element_") {
                // Get the entity's bounds to account for its actual size
                let bounds = entity.visualBounds(relativeTo: container)
                let entityBottomY = bounds.center.y - bounds.extents.y / 2
                if entityBottomY < lowestY {
                    lowestY = entityBottomY
                }
            }
        }
        
        // If no entities found, return 0
        if lowestY == Float.greatestFiniteMagnitude {
            lowestY = 0
        }
        
        debugLog("📐 Lowest entity bottom Y position: \(lowestY)")
        return lowestY
    }
    
    /// Find the highest Y position of all entities in the 3D diagram, accounting for entity size
    private func findHighestEntityPosition() -> Float {
        guard let container = rootEntity else { return 0 }
        
        var highestY: Float = -Float.greatestFiniteMagnitude
        
        // Iterate through all entities in the container to find the highest Y position
        for entity in container.children {
            if entity.name.starts(with: "element_") {
                // Get the entity's bounds to account for its actual size
                let bounds = entity.visualBounds(relativeTo: container)
                let entityTopY = bounds.center.y + bounds.extents.y / 2
                if entityTopY > highestY {
                    highestY = entityTopY
                }
            }
        }
        
        // If no entities found, return 0
        if highestY == -Float.greatestFiniteMagnitude {
            highestY = 0
        }
        
        debugLog("📐 Highest entity top Y position: \(highestY)")
        return highestY
    }
    
    /// Detect if a surface is horizontal (likely a floor, table, or ceiling) based on its orientation
    private func isHorizontalSurface(_ anchor: PlaneAnchor) -> Bool {
        let rotation = simd_quatf(anchor.originFromAnchorTransform)
        let normal = rotation.act(SIMD3<Float>(0, 1, 0)) // Surface normal
        
        // Check if the surface normal is mostly vertical (pointing up or down)
        // For horizontal surfaces, the Y component should be close to 1 or -1
        let horizontalThreshold: Float = 0.7 // Adjust this value as needed
        let isHorizontal = abs(normal.y) > horizontalThreshold
        
        if isHorizontal {
            debugLog("🏢 Detected horizontal surface (floor/table/ceiling): \(anchor.id) with normal \(normal)")
        }
        
        return isHorizontal
    }
    
    /// Provides haptic feedback for snapping actions
    private func provideFeedback(for action: FeedbackAction) {
        #if os(visionOS)
        // visionOS doesn't have traditional haptic feedback, but we could use audio cues
        // For now, we'll just log the action
        switch action {
        case .snap:
            logger.log("Snap feedback triggered")
        case .release:
            logger.log("Release feedback triggered")
        }
        #endif
    }
    
    enum FeedbackAction {
        case snap
        case release
    }

    private func setSnapStatusMessage(_ message: String) {
        self.debugLog("🔔 Setting snap status message: '\(message)'")
        self.debugLog("🔔 Previous message was: '\(self.snapStatusMessage)'")
        self.snapStatusMessage = message
        self.debugLog("🔔 Message set successfully. Current value: '\(self.snapStatusMessage)'")
        
        // Update the 3D message above grab handle
        self.update3DSnapMessage(message)
        
        // Optionally auto-clear after a second
        if self.alwaysShowSnapMessage == false {
            self.debugLog("🔔 Auto-clear enabled - will clear in 1.5 seconds")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                if self.snapStatusMessage == message {
                    self.debugLog("🔔 Auto-clearing message: '\(message)'")
                    self.snapStatusMessage = ""
                    self.update3DSnapMessage("") // Clear 3D message too
                } else {
                    self.debugLog("🔔 Message changed, not clearing: '\(message)' vs '\(self.snapStatusMessage)'")
                }
            }
        } else {
            self.debugLog("🔔 Auto-clear disabled (alwaysShowSnapMessage = true)")
        }
    }

    private func createEntity(for element: ElementDTO) -> Entity {
        guard let normalizationContext = self.normalizationContext else {
            preconditionFailure("Normalization context must be set before creating entities")
        }

        // RS shapes store type directly in element.type, not in shape.shapeDescription
        let elementType = element.type.lowercased()
        let shapeDesc = (element.shape?.shapeDescription ?? "").lowercased()
        let desc = shapeDesc.isEmpty ? elementType : shapeDesc

        // Check if this is an RS or RT shape
        let isRSShape = elementType.hasPrefix("rs")
        let isRTShape = elementType.hasPrefix("rt")
        let isCircle = elementType.contains("circle") || desc.contains("circle")
        let isEllipse = elementType.contains("ellipse") || desc.contains("ellipse")
        let isLabel = elementType.contains("label") || desc.contains("label")

        // Performance optimization: skip per-element collision shapes for large datasets
        let skipDetailedCollision = elements.count > 500

        // Special case: render RTlabel and RSLabel shapes as text-only entities using specified extents
        logger.log("Create Entity - type: \(elementType), desc: \(desc)")
        if isLabel && (isRTShape || isRSShape) {
            let entity = createRTLabelEntity(for: element, normalization: normalizationContext)
            entity.name = element.id != nil ? "element_\(element.id!)" : "element_\(UUID().uuidString.prefix(8))"

            // Only add interaction components for 3D diagrams (skip for large datasets)
            if !isGraph2D && !skipDetailedCollision {
                entity.generateCollisionShapes(recursive: true)
                entity.components.set(InputTargetComponent())
            }
            return entity
        }

        // Special case: RSCircle/RSEllipse with borderColor/borderWidth (hollow donut)
        if (isCircle || isEllipse) && isRSShape && element.borderColor != nil {
            let entity = createHollowCircleEntity(for: element, normalization: normalizationContext)
            entity.name = element.id != nil ? "element_\(element.id!)" : "element_\(UUID().uuidString.prefix(8))"

            // Only add interaction components for 3D diagrams (skip for large datasets)
            if !isGraph2D && !skipDetailedCollision {
                entity.generateCollisionShapes(recursive: true)
                entity.components.set(InputTargetComponent())
            }
            return entity
        }

        let (mesh, material) = element.meshAndMaterial(normalization: normalizationContext)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        // Rotate cylinders (ellipses/circles) to be flat in XY plane
        if isCircle || isEllipse {
            entity.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        }
        entity.name = element.id != nil ? "element_\(element.id!)" : "element_\(UUID().uuidString.prefix(8))"

        // Add border ring for RSBox/RSCircle/RSEllipse with borderColor
        if isRSShape && element.borderColor != nil && element.borderWidth != nil {
            let borderEntity = createBorderEntity(for: element, normalization: normalizationContext)
            if let border = borderEntity {
                entity.addChild(border)
            }
        }

        // Add a label if meaningful for non-RTlabel shapes: skip if shape.text is "nil" or empty
        let rawText = element.shape?.text
        let labelText: String? = {
            if let t = rawText, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               t.lowercased() != "nil" {
                return t
            }
            return nil  // Don't show element IDs as labels
        }()
        if let text = labelText {
            let labelEntity = createLabelEntity(text: text)
            labelEntity.position.y += 0.1
            entity.addChild(labelEntity)
        }

        // Only add interaction components for 3D diagrams (skip for performance on large datasets)
        if !isGraph2D && !skipDetailedCollision {
            entity.generateCollisionShapes(recursive: true)
            entity.components.set(InputTargetComponent())
        }
        return entity
    }

    private func createConnectionEntity(for edge: ElementDTO) -> ModelEntity? {
        // Check if this is an RSPolyline with points array
        if let points = edge.points, points.count >= 2 {
            return createPolylineEntity(for: edge, points: points)
        }

        // Standard direct connection between two entities
        guard let fromId = edge.fromId, let toId = edge.toId else { return nil }
        self.debugLog("🔍 Looking for entities with keys: '\(fromId)' and '\(toId)'")
        self.debugLog("🗂️ Available entity keys: \(Array(self.entityMap.keys).sorted())")
        guard let fromEntity = self.entityMap[fromId], let toEntity = self.entityMap[toId] else {
            logger.error("❌ Could not find entities for keys '\(fromId)' and/or '\(toId)'")
            return nil
        }

        let pos1 = fromEntity.position
        let pos2 = toEntity.position
        let lineVector = pos2 - pos1
        let length = simd_length(lineVector)
        guard length > 0 else { return nil }

        let radius = max(Float(edge.shape?.radius ?? 0.005), 0.0005)
        let mesh = MeshResource.generateCylinder(height: length, radius: radius)
        let materialColor: UIColor = {
            let rgba = edge.color ?? edge.shape?.color
            if let components = rgba, components.count >= 3 {
                return UIColor(
                    red: CGFloat(components[0]),
                    green: CGFloat(components[1]),
                    blue: CGFloat(components[2]),
                    alpha: components.count > 3 ? CGFloat(components[3]) : 1.0
                )
            }
            return .gray
        }()
        let material = SimpleMaterial(color: materialColor, isMetallic: false)

        let connectionEntity = ModelEntity(mesh: mesh, materials: [material])
        connectionEntity.position = pos1 + (lineVector / 2)
        if length > 0 {
            let direction = lineVector / length
            let quat = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
            connectionEntity.orientation = quat
        }

        // Add arrow marker if markerEnd is present
        if let markerEnd = edge.markerEnd, let markerShape = markerEnd.shape {
            let arrowEntity = createArrowMarkerEntity(
                markerShape: markerShape,
                at: pos2,
                direction: lineVector,
                color: materialColor
            )
            connectionEntity.addChild(arrowEntity)
        }

        return connectionEntity
    }

    /// Creates a polyline entity from multiple waypoints (for RSPolyline)
    private func createPolylineEntity(for edge: ElementDTO, points: [[Double]]) -> ModelEntity? {
        guard let normContext = normalizationContext else { return nil }

        let containerEntity = ModelEntity()

        // Convert points to SIMD3 positions using normalization
        var positions: [SIMD3<Float>] = []
        for point in points {
            let coords = point + [0.0] // Add Z coordinate if missing
            let pos = calculateElementPosition(coords: coords, normalizationContext: normContext)
            positions.append(pos)
        }

        guard positions.count >= 2 else { return nil }

        // Get line color and radius
        let materialColor: UIColor = {
            let rgba = edge.color ?? edge.borderColor ?? edge.shape?.color
            if let components = rgba, components.count >= 3 {
                return UIColor(
                    red: CGFloat(components[0]),
                    green: CGFloat(components[1]),
                    blue: CGFloat(components[2]),
                    alpha: components.count > 3 ? CGFloat(components[3]) : 1.0
                )
            }
            return .gray
        }()
        let material = SimpleMaterial(color: materialColor, isMetallic: false)
        let radius = max(Float(edge.shape?.radius ?? 0.005), 0.0005)

        // Create a line segment for each pair of consecutive points
        for i in 0..<(positions.count - 1) {
            let pos1 = positions[i]
            let pos2 = positions[i + 1]
            let lineVector = pos2 - pos1
            let length = simd_length(lineVector)
            guard length > 0 else { continue }

            let mesh = MeshResource.generateCylinder(height: length, radius: radius)
            let segmentEntity = ModelEntity(mesh: mesh, materials: [material])
            segmentEntity.position = pos1 + (lineVector / 2)

            if length > 0 {
                let direction = lineVector / length
                let quat = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
                segmentEntity.orientation = quat
            }

            containerEntity.addChild(segmentEntity)
        }

        // Add arrow marker at the end if this is an RSArrowedLine
        if edge.type.lowercased().contains("arrowed"), positions.count >= 2 {
            let lastPos = positions[positions.count - 1]
            let prevPos = positions[positions.count - 2]
            let direction = lastPos - prevPos
            let arrowEntity = createArrowHead(
                at: lastPos,
                direction: direction,
                color: materialColor,
                markerEnd: edge.markerEnd
            )
            containerEntity.addChild(arrowEntity)
        }

        return containerEntity
    }

    /// Creates an arrow head entity at the end of a line as a small triangle
    private func createArrowHead(
        at position: SIMD3<Float>,
        direction: SIMD3<Float>,
        color: UIColor,
        markerEnd: MarkerDTO?
    ) -> ModelEntity {
        // Determine arrow size from markerEnd or use default (smaller size)
        let arrowSize: Float
        if let extent = markerEnd?.shape?.extent, extent.count >= 2 {
            // Use extent from marker shape, normalized, scaled down
            let normContext = normalizationContext!
            arrowSize = Float(extent[0] / normContext.globalRange * 2) * 0.15
        } else {
            arrowSize = 0.004  // Much smaller default size
        }

        // Create a triangle mesh for the arrow head (pointing in +Y direction initially)
        // Triangle is flat in XY plane with small Z offset to appear in front
        var descriptor = MeshDescriptor()
        let arrowLength = arrowSize * 1.5
        let trianglePositions: [SIMD3<Float>] = [
            SIMD3(-arrowSize, 0, 0.002),           // Left base (slight Z offset to appear in front)
            SIMD3(arrowSize, 0, 0.002),            // Right base
            SIMD3(0, arrowLength, 0.002)           // Tip (pointing up in +Y)
        ]
        descriptor.positions = .init(trianglePositions)
        descriptor.primitives = .triangles([0, 1, 2])

        let mesh: MeshResource
        do {
            mesh = try MeshResource.generate(from: [descriptor])
        } catch {
            // Fallback to a small box if triangle generation fails
            mesh = MeshResource.generateBox(size: SIMD3<Float>(arrowSize, arrowSize, 0.001))
        }

        let material = SimpleMaterial(color: color, isMetallic: false)
        let arrowEntity = ModelEntity(mesh: mesh, materials: [material])

        // Position at the endpoint, slightly offset forward along Z to appear in front
        var adjustedPosition = position
        adjustedPosition.z += 0.003  // Small Z offset to render in front of other elements
        arrowEntity.position = adjustedPosition

        // Orient arrow to point along the line direction
        let length = simd_length(direction)
        if length > 0 {
            let normalizedDir = direction / length
            // Triangle points up by default (Y axis), rotate to point along direction
            let quat = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normalizedDir)
            arrowEntity.orientation = quat
        }

        return arrowEntity
    }

    /// Creates an arrow marker entity for edge endpoints
    private func createArrowMarkerEntity(
        markerShape: ShapeDTO,
        at position: SIMD3<Float>,
        direction: SIMD3<Float>,
        color: UIColor
    ) -> ModelEntity {
        // Create a small triangle for the arrow head
        let arrowSize: Float = 0.02
        var descriptor = MeshDescriptor()

        // Triangle vertices (pointing in +X direction initially)
        let positions: [SIMD3<Float>] = [
            SIMD3(0, arrowSize/2, 0),      // Top
            SIMD3(0, -arrowSize/2, 0),     // Bottom
            SIMD3(arrowSize, 0, 0)         // Tip
        ]

        descriptor.positions = .init(positions)
        descriptor.primitives = .triangles([0, 1, 2])

        let mesh = try! MeshResource.generate(from: [descriptor])
        let material = SimpleMaterial(color: color, isMetallic: false)
        let arrowEntity = ModelEntity(mesh: mesh, materials: [material])

        // Position at the end of the line (relative to connection entity center)
        let lineLength = simd_length(direction)
        arrowEntity.position = SIMD3<Float>(0, lineLength/2, 0)

        // Local rotation only. The parent connection entity is already oriented along the edge
        // (`simd_quatf(from: (0,1,0), to: direction)`), so the arrow just needs to turn from its
        // own X axis onto the parent's Y. The edge direction is deliberately not used here.
        if lineLength > 0 {
            arrowEntity.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        }

        return arrowEntity
    }

    private func createLabelEntity(text: String) -> Entity {
        let mesh = cachedTextMesh(text, fontSize: 0.05, lineBreakMode: .byWordWrapping)
        let material = SimpleMaterial(color: .white, isMetallic: false)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// Creates a border entity for RS shapes (RSBox, RSCircle, RSEllipse) with borderColor
    private func createBorderEntity(for element: ElementDTO, normalization: NormalizationContext) -> ModelEntity? {
        let elementType = element.type.lowercased()
        let extent = element.extent ?? element.shape?.extent ?? []

        guard extent.count >= 2,
              let borderRGBA = element.borderColor,
              let borderWidth = element.borderWidth else {
            return nil
        }

        let w = Float(extent[0] / normalization.globalRange * 2)
        let h = Float(extent[1] / normalization.globalRange * 2)
        let normalizedBorderWidth = Float(borderWidth / normalization.globalRange * 2)

        let borderColor = UIColor(
            red: CGFloat(borderRGBA[0]),
            green: CGFloat(borderRGBA[1]),
            blue: CGFloat(borderRGBA[2]),
            alpha: borderRGBA.count > 3 ? CGFloat(borderRGBA[3]) : 1.0
        )
        let borderMaterial = SimpleMaterial(color: borderColor, roughness: 0.5, isMetallic: false)

        if elementType.contains("box") {
            // Create a wireframe border for boxes using 4 thin lines
            let container = ModelEntity()
            let halfW = w / 2.0
            let halfH = h / 2.0
            let depth: Float = 0.002

            // Top edge
            let topMesh = MeshResource.generateBox(size: SIMD3(w + normalizedBorderWidth, normalizedBorderWidth, depth))
            let topEntity = ModelEntity(mesh: topMesh, materials: [borderMaterial])
            topEntity.position = SIMD3(0, halfH, 0)
            container.addChild(topEntity)

            // Bottom edge
            let bottomEntity = ModelEntity(mesh: topMesh, materials: [borderMaterial])
            bottomEntity.position = SIMD3(0, -halfH, 0)
            container.addChild(bottomEntity)

            // Left edge
            let sideMesh = MeshResource.generateBox(size: SIMD3(normalizedBorderWidth, h + normalizedBorderWidth, depth))
            let leftEntity = ModelEntity(mesh: sideMesh, materials: [borderMaterial])
            leftEntity.position = SIMD3(-halfW, 0, 0)
            container.addChild(leftEntity)

            // Right edge
            let rightEntity = ModelEntity(mesh: sideMesh, materials: [borderMaterial])
            rightEntity.position = SIMD3(halfW, 0, 0)
            container.addChild(rightEntity)

            return container
        }

        return nil
    }

    /// Creates a 2D RTlabel/RSLabel entity using the shape.text or element.text and shape.extent or element.extent to size the text container.
    /// Creates a hollow circle (donut) entity for RSCircle with borderColor
    private func createHollowCircleEntity(for element: ElementDTO, normalization: NormalizationContext) -> Entity {
        let extent = element.extent ?? element.shape?.extent ?? []

        // Get diameter from extent
        let diameter = extent.count > 0 ? Float(extent[0] / normalization.globalRange * 2) : 0.1
        let outerRadius = diameter / 2.0

        // Calculate border width as thickness of the ring
        let borderWidth = element.borderWidth ?? element.shape?.borderWidth ?? 1.0
        let normalizedBorderWidth = Float(borderWidth / normalization.globalRange * 2)

        // Get border color
        let borderRGBA = element.borderColor ?? [0.5, 0.5, 0.5, 1.0]
        let borderColor = UIColor(
            red: CGFloat(borderRGBA[0]),
            green: CGFloat(borderRGBA[1]),
            blue: CGFloat(borderRGBA[2]),
            alpha: borderRGBA.count > 3 ? CGFloat(borderRGBA[3]) : 1.0
        )
        let borderMaterial = SimpleMaterial(color: borderColor, roughness: 0.5, isMetallic: false)

        // Create a donut ring using custom mesh
        let height: Float = 0.001 // Minimal depth for 2D
        let ringMesh = createDonutMesh(outerRadius: outerRadius, borderWidth: normalizedBorderWidth, height: height)

        let ringEntity = ModelEntity(mesh: ringMesh, materials: [borderMaterial])
        ringEntity.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))

        return ringEntity
    }

    /// Creates a custom donut (ring) mesh
    private func createDonutMesh(outerRadius: Float, borderWidth: Float, height: Float) -> MeshResource {
        let innerRadius = max(outerRadius - borderWidth, 0.001)
        let segments = 32 // Number of segments for smooth circle

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        // Create vertices for outer and inner circles at top and bottom
        for i in 0...segments {
            let angle = Float(i) * (2 * .pi / Float(segments))
            let cos = cosf(angle)
            let sin = sinf(angle)

            // Outer circle - top
            positions.append(SIMD3<Float>(outerRadius * cos, height / 2, outerRadius * sin))
            // Inner circle - top
            positions.append(SIMD3<Float>(innerRadius * cos, height / 2, innerRadius * sin))
            // Outer circle - bottom
            positions.append(SIMD3<Float>(outerRadius * cos, -height / 2, outerRadius * sin))
            // Inner circle - bottom
            positions.append(SIMD3<Float>(innerRadius * cos, -height / 2, innerRadius * sin))
        }

        // Create triangles for the ring (top, bottom, outer edge, inner edge)
        for i in 0..<segments {
            let base = UInt32(i * 4)
            let nextBase = UInt32((i + 1) * 4)

            // Top face
            indices.append(contentsOf: [base, nextBase, nextBase + 1])
            indices.append(contentsOf: [base, nextBase + 1, base + 1])

            // Bottom face
            indices.append(contentsOf: [base + 2, nextBase + 3, nextBase + 2])
            indices.append(contentsOf: [base + 2, base + 3, nextBase + 3])

            // Outer edge
            indices.append(contentsOf: [base, nextBase + 2, nextBase])
            indices.append(contentsOf: [base, base + 2, nextBase + 2])

            // Inner edge
            indices.append(contentsOf: [base + 1, nextBase + 1, nextBase + 3])
            indices.append(contentsOf: [base + 1, nextBase + 3, base + 3])
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = .init(positions)
        descriptor.primitives = .triangles(indices)

        return try! MeshResource.generate(from: [descriptor])
    }

    private func createRTLabelEntity(for element: ElementDTO, normalization: NormalizationContext) -> Entity {
        // For RSLabel, text is at element level; for RTLabel, text is in shape
        let rawText = element.text ?? element.shape?.text
        guard let text = rawText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.lowercased() != "nil" else {
            return ModelEntity()
        }
        logger.log("Label - rawText: \(text)")
        // Build text mesh sized to shape.extent or element.extent, thin and unlit for visibility
        let extent = element.extent ?? element.shape?.extent ?? []
        // Normalize extents into [-1…+1], interpreting extent[0]=width, extent[1]=height
        let w = extent.count > 0
            ? Float(extent[0] / normalization.globalRange)
            : 0.1
        let h = extent.count > 1
            ? Float(extent[1] / normalization.globalRange)
            : 0.05

        // Use constant font size so all labels appear the same visual size
        // The extent values represent bounding box, not desired visual size
        let fontSize: CGFloat = 0.04  // Fixed size for uniform label appearance
        debugLog("text: \(text) | w: \(w) | h: \(h) | fontSize: \(fontSize)")
        let mesh = cachedTextMesh(text, fontSize: fontSize, lineBreakMode: .byWordWrapping)

        let materialColor: UIColor = {
            let rgba = element.shape?.color ?? element.color
            if let components = rgba, components.count >= 3 {
                return UIColor(
                    red:   CGFloat(components[0]),
                    green: CGFloat(components[1]),
                    blue:  CGFloat(components[2]),
                    alpha: components.count > 3 ? CGFloat(components[3]) : 1.0
                )
            }
            return .white
        }()
        // Use unlit material so the text remains visible regardless of scene lighting
        let material = UnlitMaterial(color: materialColor)
        let labelEntity = ModelEntity(mesh: mesh, materials: [material])

        // Center the text mesh properly
        // Text meshes are positioned at their baseline, so we need to offset to center them
        let bounds = labelEntity.visualBounds(relativeTo: nil)
        // Move the label so its visual center aligns with position (0, 0, 0)
        // This ensures labels appear centered above their corresponding cylinders
        labelEntity.position = SIMD3<Float>(
            -bounds.center.x,  // Center horizontally
            -bounds.center.y,  // Center vertically
            0.001              // Slight Z offset to avoid z-fighting
        )
        // Debug: print world transform and bounds
        debugLog("RTLabel [\(String(describing: element.id))] transform:\n\(labelEntity.transform.matrix)")
        debugLog("RTLabel [\(String(describing: element.id))] bounds center: \(bounds.center), extents: \(bounds.extents)")
        return labelEntity
    }
    
    /// Apply spatial constraints to keep windows within user's comfortable field of view
    private func applySpatialConstraints(_ position: SIMD3<Float>) -> SIMD3<Float> {
        let boundaries = (
            x: (-2.0 as Float, 2.0 as Float),
            y: (-1.0 as Float, 1.5 as Float),
            z: (0.5 as Float, 3.0 as Float)
        )
        
        // Apply soft boundary resistance
        var constrainedPosition = position
        let resistanceThreshold: Float = 0.2  // Start applying resistance 20cm before boundary
        let maxResistance: Float = 0.8  // Maximum 80% resistance
        
        // X-axis constraints
        if position.x < boundaries.x.0 + resistanceThreshold {
            let overshoot = (boundaries.x.0 + resistanceThreshold) - position.x
            let resistance = min(maxResistance, overshoot / resistanceThreshold)
            constrainedPosition.x = boundaries.x.0 + (position.x - boundaries.x.0) * (1.0 - resistance)
        } else if position.x > boundaries.x.1 - resistanceThreshold {
            let overshoot = position.x - (boundaries.x.1 - resistanceThreshold)
            let resistance = min(maxResistance, overshoot / resistanceThreshold)
            constrainedPosition.x = boundaries.x.1 - (boundaries.x.1 - position.x) * (1.0 - resistance)
        }
        
        // Y-axis constraints
        if position.y < boundaries.y.0 + resistanceThreshold {
            let overshoot = (boundaries.y.0 + resistanceThreshold) - position.y
            let resistance = min(maxResistance, overshoot / resistanceThreshold)
            constrainedPosition.y = boundaries.y.0 + (position.y - boundaries.y.0) * (1.0 - resistance)
        } else if position.y > boundaries.y.1 - resistanceThreshold {
            let overshoot = position.y - (boundaries.y.1 - resistanceThreshold)
            let resistance = min(maxResistance, overshoot / resistanceThreshold)
            constrainedPosition.y = boundaries.y.1 - (boundaries.y.1 - position.y) * (1.0 - resistance)
        }
        
        // Z-axis constraints
        if position.z < boundaries.z.0 + resistanceThreshold {
            let overshoot = (boundaries.z.0 + resistanceThreshold) - position.z
            let resistance = min(maxResistance, overshoot / resistanceThreshold)
            constrainedPosition.z = boundaries.z.0 + (position.z - boundaries.z.0) * (1.0 - resistance)
        } else if position.z > boundaries.z.1 - resistanceThreshold {
            let overshoot = position.z - (boundaries.z.1 - resistanceThreshold)
            let resistance = min(maxResistance, overshoot / resistanceThreshold)
            constrainedPosition.z = boundaries.z.1 - (boundaries.z.1 - position.z) * (1.0 - resistance)
        }
        
        return constrainedPosition
    }
    
    /// Apply comfort zone snapping that pulls windows to optimal viewing distance
    private func applyComfortZoneSnapping(_ position: SIMD3<Float>) -> SIMD3<Float> {
        let comfortDistance: Float = 1.2  // Optimal viewing distance
        let snapThreshold: Float = 0.1    // 10cm snap threshold
        let snapStrength: Float = 0.3     // Interpolation factor
        
        let userPosition = SIMD3<Float>(0, position.y, 0)  // User at same Y level
        let distanceFromUser = simd_distance(position, userPosition)
        
        // Apply magnetic attraction to comfort zone
        if abs(distanceFromUser - comfortDistance) < snapThreshold {
            let direction = normalize(position - userPosition)
            let comfortPosition = userPosition + direction * comfortDistance
            return mix(position, comfortPosition, t: snapStrength)
        }
        
        return position
    }
    
    /// Update window orientation to face user while maintaining natural behavior
    private func updateWindowOrientation(container: Entity, position: SIMD3<Float>) {
        let userPosition = SIMD3<Float>(0, position.y, 0)
        let windowToUser = userPosition - position
        let distanceToUser = simd_length(windowToUser)
        
        if distanceToUser > 0.001 {
            // Calculate direction to user, keeping window parallel to ground
            let directionToUser = normalize(SIMD3<Float>(windowToUser.x, 0, windowToUser.z))
            
            // Create stable rotation using atan2
            let angle = atan2(directionToUser.x, directionToUser.z)
            let targetOrientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
            
            // Apply lighter smoothing to orientation changes to prevent losing orientation
            let currentOrientation = container.orientation(relativeTo: nil)
            let smoothedOrientation = simd_slerp(currentOrientation, targetOrientation, 0.03)
            container.setOrientation(smoothedOrientation, relativeTo: nil)
        }
    }
    
    /// Find the nearest point on a surface to the given diagram position
    /// This allows diagrams to snap anywhere on the surface, not just the center
    private func findNearestPointOnSurface(diagramPosition: SIMD3<Float>, surface: PlaneAnchor) -> SIMD3<Float> {
        // Get plane's transform and position
        let planeTransform = surface.originFromAnchorTransform
        let planePosition = SIMD3<Float>(
            planeTransform.columns.3.x,
            planeTransform.columns.3.y,
            planeTransform.columns.3.z
        )
        let planeRotation = simd_quatf(planeTransform)
        
        // Get plane dimensions (convert Float16 to Float)
        let planeExtent = surface.geometry.extent
        let planeWidth = Float(planeExtent.width)  // Width along X axis
        let planeHeight = Float(planeExtent.height)  // Height along Z axis
        
        debugLog("📐 Surface dimensions: \(planeWidth)m x \(planeHeight)m")
        debugLog("📐 Surface center: \(planePosition)")
        debugLog("📐 Diagram position: \(diagramPosition)")
        
        // Transform point to plane's local space
        let toPlane = diagramPosition - planePosition
        let localPoint = simd_inverse(planeRotation).act(toPlane)
        
        debugLog("📐 Local point on surface: \(localPoint)")
        
        // Clamp the point to the plane bounds - this enables snapping anywhere on surface
        let clampedX = Swift.max(-planeWidth/2, Swift.min(planeWidth/2, localPoint.x))
        let clampedZ = Swift.max(-planeHeight/2, Swift.min(planeHeight/2, localPoint.z))
        
        debugLog("📐 Clamped local point: x=\(clampedX), z=\(clampedZ)")
        
        // Find nearest point on the plane within bounds
        let nearestOnPlane = planeRotation.act(SIMD3<Float>(clampedX, 0, clampedZ)) + planePosition
        
        debugLog("📐 Final snap point: \(nearestOnPlane)")
        
        return nearestOnPlane
    }
    
    /// Calculate the distance from a point to the nearest point on a plane surface
    /// Takes into account the plane's bounds, enabling snapping anywhere on the surface, not just the center
    private func distanceToPlane(point: SIMD3<Float>, planeAnchor: PlaneAnchor) -> Float {
        // Get plane's transform and position
        let planeTransform = planeAnchor.originFromAnchorTransform
        let planePosition = SIMD3<Float>(
            planeTransform.columns.3.x,
            planeTransform.columns.3.y,
            planeTransform.columns.3.z
        )
        let planeRotation = simd_quatf(planeTransform)
        
        // Get plane normal (Y axis in plane's local space) - used for distance calculations
        _ = planeRotation.act(SIMD3<Float>(0, 1, 0))
        
        // Get plane dimensions (convert Float16 to Float)
        let planeExtent = planeAnchor.geometry.extent
        let planeWidth = Float(planeExtent.width)  // Width along X axis
        let planeHeight = Float(planeExtent.height)  // Height along Z axis
        
        // Transform point to plane's local space
        let toPlane = planePosition - point
        let localPoint = simd_inverse(planeRotation).act(toPlane)
        
        // Clamp the point to the plane bounds
        let clampedX = Swift.max(-planeWidth/2, Swift.min(planeWidth/2, localPoint.x))
        let clampedZ = Swift.max(-planeHeight/2, Swift.min(planeHeight/2, localPoint.z))
        
        // Find nearest point on the plane within bounds
        let nearestOnPlane = planeRotation.act(SIMD3<Float>(clampedX, 0, clampedZ)) + planePosition
        
        // Calculate distance to the nearest point on the plane
        return simd_distance(point, nearestOnPlane)
    }
    
    /// Check for surface snapping during pan gestures
    private func checkForSurfaceSnapping(container: Entity, at position: SIMD3<Float>) {
        let availableSurfaces = getAllSurfaceAnchors()
        debugLog("🔍 checkForSurfaceSnapping called with PERSISTENT surfaces")
        debugLog("🔍 Diagram position: \(position)")
        debugLog("🔍 Available PERSISTENT surfaces: \(availableSurfaces.count)")
        
        guard !availableSurfaces.isEmpty else { 
            debugLog("🚫 No PERSISTENT surfaces available for snapping")
            return 
        }
        
        if let nearestSurface = findNearestSurfaceForSnapping(diagramPosition: position) {
            // Show visual feedback that snapping is available
            let surfaceType = getSurfaceTypeName(nearestSurface)
            let message = "📍 Near \(surfaceType) - Release to Snap!"
            debugLog("✨ \(message)")
            setSnapStatusMessage(message)
        } else {
            // Clear snap message if not near any surface
            if !snapStatusMessage.isEmpty && snapStatusMessage.contains("Near") {
                setSnapStatusMessage("")
            }
        }
    }
    
    /// Find the nearest surface for snapping based on diagram type
    /// 2D diagrams snap to vertical surfaces (walls), 3D diagrams snap to horizontal surfaces (floors/tables)
    /// Both support snapping anywhere on the detected surface, not just the center
    private func findNearestSurfaceForSnapping(diagramPosition: SIMD3<Float>) -> PlaneAnchor? {
        let availableSurfaces = getAllSurfaceAnchors()
        let diagramType = isGraph2D ? "2D" : "3D"
        let targetSurfaceType = isGraph2D ? "vertical (walls)" : "horizontal (floors/tables)"
        
        debugLog("🔍 Checking \(availableSurfaces.count) PERSISTENT surfaces for \(diagramType) diagram snapping to \(targetSurfaceType) at position \(diagramPosition)")
        debugLog("🔍 3D diagrams can snap anywhere on horizontal surfaces, not just the center")
        
        let validSurfaces = filterValidSurfaces(availableSurfaces)
        let closest = findClosestSurface(validSurfaces, diagramPosition: diagramPosition)
        
        logSnapResult(closest: closest, diagramType: diagramType, targetSurfaceType: targetSurfaceType)
        return closest?.surface
    }
    
    private func filterValidSurfaces(_ surfaces: [PlaneAnchor]) -> [PlaneAnchor] {
        return surfaces.filter { surface in
            let surfaceType = self.getSurfaceTypeName(surface)
            let isValidSurface: Bool
            
            if isGraph2D {
                isValidSurface = isVerticalSurface(surface)
                if !isValidSurface {
                    self.debugLog("🚫 Skipping non-vertical surface for 2D diagram: \(surface.id) (\(surfaceType))")
                }
            } else {
                isValidSurface = isHorizontalSurface(surface) || surfaceType == "Floor" || surfaceType == "Table"
                if !isValidSurface {
                    self.debugLog("🚫 Skipping non-horizontal surface for 3D diagram: \(surface.id) (\(surfaceType))")
                }
            }
            
            return isValidSurface
        }
    }
    
    private func findClosestSurface(_ surfaces: [PlaneAnchor], diagramPosition: SIMD3<Float>) -> (surface: PlaneAnchor, distance: Float)? {
        var closest: (surface: PlaneAnchor, distance: Float)? = nil
        
        for surface in surfaces {
            let surfacePosition = extractSurfacePosition(surface)
            let distance = distanceToPlane(point: diagramPosition, planeAnchor: surface)
            let surfaceType = self.getSurfaceTypeName(surface)
            
            self.logSurfaceInfo(surface: surface, surfaceType: surfaceType, surfacePosition: surfacePosition, diagramPosition: diagramPosition, distance: distance)

            if distance <= self.snapDistance {
                if closest == nil || distance < closest!.distance {
                    closest = (surface, distance)
                    self.debugLog("🎯 New closest \(self.isGraph2D ? "wall" : "horizontal surface"): \(surface.id) (\(surfaceType)) at \(distance)m")
                }
            } else {
                self.debugLog("📏 Surface \(surface.id) (\(surfaceType)) too far: \(distance)m > \(self.snapDistance)m")
            }
        }
        
        return closest
    }
    
    private func extractSurfacePosition(_ surface: PlaneAnchor) -> SIMD3<Float> {
        let surfaceWorldTransform = surface.originFromAnchorTransform
        return SIMD3<Float>(
            surfaceWorldTransform.columns.3.x,
            surfaceWorldTransform.columns.3.y,
            surfaceWorldTransform.columns.3.z
        )
    }
    
    private func logSurfaceInfo(surface: PlaneAnchor, surfaceType: String, surfacePosition: SIMD3<Float>, diagramPosition: SIMD3<Float>, distance: Float) {
        debugLog("📍 Surface \(surface.id) (\(surfaceType))")
        debugLog("   📍 Surface world position: \(surfacePosition)")
        debugLog("   📍 Diagram position: \(diagramPosition)")
        debugLog("   📍 Distance: \(distance)m")
    }
    
    private func logSnapResult(closest: (surface: PlaneAnchor, distance: Float)?, diagramType: String, targetSurfaceType: String) {
        if let result = closest?.surface {
            let surfaceType = getSurfaceTypeName(result)
            logger.info("✅ Found snap target for \(diagramType) diagram: \(result.id) (\(surfaceType)) at \(closest!.distance)m")
        } else {
            logger.error("❌ No \(targetSurfaceType) surfaces within snap distance (\(self.snapDistance)m) for \(diagramType) diagram")
        }
    }
    
    /// Perform smooth snap animation to any surface type
    private func performSnapToSurface(container: Entity, surface: PlaneAnchor) {
        let diagramPosition = container.position(relativeTo: nil)
        let nearestPointOnSurface = self.findNearestPointOnSurface(diagramPosition: diagramPosition, surface: surface)
        let surfaceWorldTransform = surface.originFromAnchorTransform
        let surfaceRotation = simd_quatf(surfaceWorldTransform)
        let surfaceType = self.getSurfaceTypeName(surface)
        
        let (snapPosition, diagramOrientation) = self.calculateSnapPositionAndOrientation(
            nearestPointOnSurface: nearestPointOnSurface,
            surfaceRotation: surfaceRotation,
            surfaceType: surfaceType,
            container: container,
            isGraph2D: isGraph2D
        )
        
        self.animateToSnapPosition(container: container, position: snapPosition, orientation: diagramOrientation)
        self.finalizeSnap(surface: surface, surfaceType: surfaceType)
    }
    
    private func calculateSnapPositionAndOrientation(
        nearestPointOnSurface: SIMD3<Float>,
        surfaceRotation: simd_quatf,
        surfaceType: String,
        container: Entity,
        isGraph2D: Bool
    ) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let offsetDistance: Float = 0.05
        
        if surfaceType.lowercased().contains("wall") {
            return calculateWallSnapPosition(nearestPointOnSurface: nearestPointOnSurface, surfaceRotation: surfaceRotation, offsetDistance: offsetDistance, isGraph2D: isGraph2D, container: container)
        } else if surfaceType.lowercased().contains("table") || surfaceType.lowercased().contains("floor") {
            return calculateHorizontalSnapPosition(nearestPointOnSurface: nearestPointOnSurface, surfaceRotation: surfaceRotation, offsetDistance: offsetDistance, isGraph2D: isGraph2D, container: container)
        } else if surfaceType.lowercased().contains("ceiling") {
            return calculateCeilingSnapPosition(nearestPointOnSurface: nearestPointOnSurface, surfaceRotation: surfaceRotation, offsetDistance: offsetDistance, isGraph2D: isGraph2D, container: container)
        } else {
            return calculateGenericSnapPosition(nearestPointOnSurface: nearestPointOnSurface, surfaceRotation: surfaceRotation, offsetDistance: offsetDistance, container: container)
        }
    }
    
    private func calculateWallSnapPosition(nearestPointOnSurface: SIMD3<Float>, surfaceRotation: simd_quatf, offsetDistance: Float, isGraph2D: Bool, container: Entity) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let wallNormal = surfaceRotation.act(SIMD3<Float>(0, 1, 0))
        let snapPosition = nearestPointOnSurface + (wallNormal * offsetDistance)
        
        // Only rotate 2D diagrams to align with walls, 3D diagrams keep their orientation
        let diagramOrientation: simd_quatf
        if isGraph2D {
            let verticalRotation = simd_quatf(angle: -.pi/2, axis: SIMD3<Float>(1, 0, 0))
            diagramOrientation = surfaceRotation * verticalRotation
            debugLog("📌 Snapping 2D diagram to wall at \(snapPosition) with rotation")
        } else {
            diagramOrientation = container.orientation(relativeTo: nil)
            debugLog("📌 Snapping 3D diagram to wall at \(snapPosition) preserving orientation")
        }
        
        return (snapPosition, diagramOrientation)
    }
    
    private func calculateHorizontalSnapPosition(nearestPointOnSurface: SIMD3<Float>, surfaceRotation: simd_quatf, offsetDistance: Float, isGraph2D: Bool, container: Entity) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let surfaceNormal = surfaceRotation.act(SIMD3<Float>(0, 1, 0))
        let bottomOffset = calculateBottomOffset(offsetDistance: offsetDistance)
        // Use nearestPointOnSurface which allows snapping anywhere on the surface, not just center
        let snapPosition = nearestPointOnSurface + (surfaceNormal * bottomOffset)
        
        // 3D diagrams preserve their orientation, 2D diagrams use default upright orientation
        let diagramOrientation: simd_quatf
        if isGraph2D {
            diagramOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)) // Default upright for 2D
            debugLog("📌 Snapping 2D diagram to horizontal surface at \(snapPosition) with default orientation")
        } else {
            diagramOrientation = container.orientation(relativeTo: nil) // Preserve current orientation for 3D
            debugLog("📌 Snapping 3D diagram to horizontal surface at \(snapPosition) preserving orientation")
        }
        
        return (snapPosition, diagramOrientation)
    }
    
    private func calculateCeilingSnapPosition(nearestPointOnSurface: SIMD3<Float>, surfaceRotation: simd_quatf, offsetDistance: Float, isGraph2D: Bool, container: Entity) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let surfaceNormal = surfaceRotation.act(SIMD3<Float>(0, 1, 0))
        let topOffset = calculateTopOffset(offsetDistance: offsetDistance)
        let snapPosition = nearestPointOnSurface - (surfaceNormal * topOffset)
        
        // 2D diagrams flip upside down for ceiling mounting, 3D diagrams preserve orientation
        let diagramOrientation: simd_quatf
        if isGraph2D {
            let upsideDownRotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
            diagramOrientation = upsideDownRotation
            debugLog("📌 Snapping 2D diagram to ceiling at \(snapPosition) with upside-down rotation")
        } else {
            diagramOrientation = container.orientation(relativeTo: nil)
            debugLog("📌 Snapping 3D diagram to ceiling at \(snapPosition) preserving orientation")
        }
        
        return (snapPosition, diagramOrientation)
    }
    
    private func calculateGenericSnapPosition(nearestPointOnSurface: SIMD3<Float>, surfaceRotation: simd_quatf, offsetDistance: Float, container: Entity) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let surfaceNormal = surfaceRotation.act(SIMD3<Float>(0, 1, 0))
        let snapPosition = nearestPointOnSurface + (surfaceNormal * offsetDistance)
        let diagramOrientation = container.orientation(relativeTo: nil)
        debugLog("📌 Snapping to surface at \(snapPosition)")
        return (snapPosition, diagramOrientation)
    }
    
    private func calculateBottomOffset(offsetDistance: Float) -> Float {
        if !isGraph2D {
            let lowestEntityY = findLowestEntityPosition()
            let currentScale = rootEntity?.scale.x ?? 1.0
            let scaledLowestY = lowestEntityY * currentScale
            let bottomOffset = offsetDistance - scaledLowestY
            debugLog("📌 3D diagram bottom offset: \(bottomOffset), lowest entity Y: \(lowestEntityY), scale: \(currentScale), scaled lowest Y: \(scaledLowestY)")
            return bottomOffset
        } else {
            return offsetDistance
        }
    }
    
    private func calculateTopOffset(offsetDistance: Float) -> Float {
        if !isGraph2D {
            let highestEntityY = findHighestEntityPosition()
            let currentScale = rootEntity?.scale.x ?? 1.0
            let scaledHighestY = highestEntityY * currentScale
            let topOffset = offsetDistance + scaledHighestY
            debugLog("📌 3D diagram top offset: \(topOffset), highest entity Y: \(highestEntityY), scale: \(currentScale), scaled highest Y: \(scaledHighestY)")
            return topOffset
        } else {
            return offsetDistance
        }
    }
    
    private func animateToSnapPosition(container: Entity, position: SIMD3<Float>, orientation: simd_quatf) {
        container.move(
            to: Transform(
                scale: container.scale,
                rotation: orientation,
                translation: position
            ),
            relativeTo: nil,
            duration: 0.4,
            timingFunction: .easeOut
        )
    }
    
    private func finalizeSnap(surface: PlaneAnchor, surfaceType: String) {
        currentSnappedSurface = surface
        let message = "✅ Snapped to \(surfaceType)!"
        logger.info("✅ \(message)")
        setSnapStatusMessage(message)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if self.snapStatusMessage.contains("Snapped") {
                self.setSnapStatusMessage("")
            }
        }
    }
    
    // Removed 3D text message functions - using existing overlay system instead
    
    /// Add a red sphere at [0,0,0] to highlight the diagram's origin point
    private func addOriginMarker() {
        guard let container = rootEntity else { return }
        
        // Create small red sphere
        let sphereRadius: Float = 0.005  // 2cm radius
        let sphereMesh = MeshResource.generateSphere(radius: sphereRadius)
        let sphereMaterial = SimpleMaterial(color: .red, isMetallic: false)
        let sphereEntity = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        sphereEntity.name = "originMarker"
        
        // Position at exact [0,0,0] in container space
        sphereEntity.position = SIMD3<Float>(0, 0, 0)
        
        // Add to container
        container.addChild(sphereEntity)
        
        debugLog("🔴 Added red origin marker at [0,0,0]")
    }
    
}

// MARK: - Camera Transform Helpers
extension simd_float4x4 {
    /// Extracts the translation (position) from a 4x4 transform matrix
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

#else
// iOS ElementViewModel stub for compatibility
@MainActor
class ElementViewModel: ObservableObject {
    @Published private(set) var elements: [ElementDTO] = []
    @Published var errorMessage: String?
    @Published var loadErrorMessage: String?
    @Published var isVisible = true
    @Published var containerPosition: SIMD3<Float> = SIMD3<Float>(0, 0, -1.5)
    @Published var containerScale: Float = 1.0
    @Published var isViewMode: Bool = false
    @Published var isGraph2D: Bool = false
    @Published var selectedAnchor: Any? = nil

    private var appModel: AppModel?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "ElementViewModel.iOS")
    private let isVerboseLoggingEnabled = ProcessInfo.processInfo.environment["AVAR_VERBOSE_LOGS"] != nil

    private func debugLog(_ message: String) {
        guard isVerboseLoggingEnabled else { return }
        logger.debug("\(message, privacy: .public)")
    }

    func setAppModel(_ appModel: AppModel) {
        self.appModel = appModel
        debugLog("📱 iOS: AppModel set")
    }
    
    func loadData(from filename: String) async {
        do {
            // iOS stub - basic data loading without 3D rendering
            let scriptOutput = try DiagramDataLoader.loadScriptOutput(from: filename)
            self.elements = scriptOutput.elements
            self.loadErrorMessage = nil
            debugLog("📱 iOS: Loaded \(elements.count) elements from \(filename)")
            
            // Determine if it's a 2D graph based on elements
            self.isGraph2D = elements.allSatisfy { element in
                guard let position = element.position, position.count >= 3 else { return true }
                return position[2] == 0 // z-coordinate is at index 2
            }
        } catch {
            self.loadErrorMessage = "Failed to load \(filename): \(error.localizedDescription)"
            debugLog("📱 iOS: Failed to load \(filename): \(error)")
        }
    }
    
    // Stub methods for iOS compatibility
    func loadElements(in content: Any, onClose: (() -> Void)? = nil) {
        debugLog("📱 iOS: 3D element rendering not available")
    }
    
    func updateConnections(in content: Any) {
        debugLog("📱 iOS: 3D connection updates not available")
    }
    
    func snapToSurface(_ anchor: Any) {
        debugLog("📱 iOS: Surface snapping not available")
    }
    
    func resetToFrontPosition() {
        containerPosition = SIMD3<Float>(0, 0, -1.5)
        containerScale = 1.0
        debugLog("📱 iOS: Reset to default position")
    }
    
    // Drag handling methods for iOS compatibility
    func handleDragChanged(_ value: Any) {
        debugLog("📱 iOS: Drag changed - 3D manipulation not available")
    }
    
    func handleDragEnded(_ value: Any) {
        debugLog("📱 iOS: Drag ended - 3D manipulation not available")
    }
    
    func handlePanChanged(_ value: Any) {
        debugLog("📱 iOS: Pan changed - 3D manipulation not available")
    }
    
    func handlePanEnded(_ value: Any) {
        debugLog("📱 iOS: Pan ended - 3D manipulation not available")
    }
}
#endif
