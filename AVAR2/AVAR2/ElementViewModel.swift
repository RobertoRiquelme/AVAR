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
    
    /// Get the current world transform of the diagram
    func getWorldTransform() -> (position: SIMD3<Float>, orientation: simd_quatf, scale: Float)? {
        guard let root = rootEntity else { return nil }
        let worldPos = root.position(relativeTo: nil)
        let worldOrient = root.orientation(relativeTo: nil)
        let worldScale = root.scale.x // Uniform scale
        return (worldPos, worldOrient, worldScale)
    }
    /// Background entity to capture pan/zoom gestures
    private var backgroundEntity: Entity?
    /// Starting uniform scale for the container when zoom begins
    private var zoomStartScale: Float?
    
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
    private let snapDistance: Float = 1.0  // 1 meter - focused on nearby surfaces

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
    private let snapThreshold: Float = 1.0  // Distance threshold for snapping
    private let releaseThreshold: Float = 1.0  // Distance threshold for releasing snap
    
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
        print("🔍 ElementViewModel.loadData called for: \(filename)")
        self.filename = filename  // Store filename for position tracking
        rebuildPending = true
        print("🔍 rebuildPending set to true, sceneContent is: \(sceneContent == nil ? "nil" : "set")")
        do {
            print("🔍 About to call DiagramDataLoader for: \(filename)")
            let output = try DiagramDataLoader.loadScriptOutput(from: filename)
            self.elements = output.elements
            self.isGraph2D = output.is2D
            self.normalizationContext = NormalizationContext(elements: output.elements, is2D: output.is2D)
            logger.log("Loaded \(output.elements.count, privacy: .public) elements (2D: \(output.is2D, privacy: .public)) from \(filename, privacy: .public)")
            print("✅ Successfully loaded \(output.elements.count) elements")
            print("🔍 About to call rebuildSceneIfNeeded")
            rebuildSceneIfNeeded()
            print("🔍 rebuildSceneIfNeeded completed")
        } catch let error as DiagramLoadingError {
            let message = error.errorDescription ?? "Failed to load diagram"
            logger.error("\(message, privacy: .public)")
            print("❌ DiagramLoadingError: \(message)")
            self.loadErrorMessage = message
        } catch {
            let msg = "Failed to load \(filename): \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            print("❌ General error: \(msg)")
            self.loadErrorMessage = msg
        }
    }

#if os(visionOS)
    /// Creates and positions all element entities in the scene.
    /// - Parameter onClose: Optional callback to invoke when the close button is tapped.
    func loadElements(in content: RealityViewContent, onClose: (() -> Void)? = nil) {
        print("🎯 loadElements called")
        pendingOnClose = onClose
        setupSceneContent(content)
        rebuildPending = true
        print("🎯 rebuildPending set to true in loadElements")
        rebuildSceneIfNeeded()
    }
#endif

    private func rebuildSceneIfNeeded() {
        print("🏗️ rebuildSceneIfNeeded called")
        print("🏗️ rebuildPending: \(rebuildPending)")
        print("🏗️ normalizationContext: \(normalizationContext == nil ? "nil" : "set")")
        print("🏗️ sceneContent: \(sceneContent == nil ? "nil" : "set")")
        #if os(visionOS)
        guard rebuildPending,
              let normalizationContext = self.normalizationContext,
              let content = self.sceneContent else {
            print("🏗️ Guard failed - scene rebuild skipped")
            return
        }
        print("🏗️ All conditions met - proceeding with scene rebuild")
        rebuildPending = false

        if let existing = rootEntity {
            content.remove(existing)
        }
        if let background = backgroundEntity {
            content.remove(background)
        }

        let sceneBuilder = DiagramSceneBuilder(
            filename: filename,
            isGraph2D: isGraph2D,
            spawnScale: spawnScale,
            appModel: appModel,
            logger: logger
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

        updateBackgroundEntityCollisionShapes(scale: buildResult.container.scale.x)
        createAndPositionElements(container: buildResult.container, normalizationContext: normalizationContext)
        updateConnections(in: content)
        addOriginMarker()
        #else
        // No immersive scene on iOS.
        #endif
    }
    
    private func setupSceneContent(_ content: RealityViewContent) {
        print("🎬 setupSceneContent called")
        print("🎬 rebuildPending: \(rebuildPending)")
        self.sceneContent = content

        if let existing = rootEntity {
            content.remove(existing)
        }
        if let bg = backgroundEntity {
            content.remove(bg)
        }

        // If data was already loaded but scene wasn't ready, rebuild now
        if rebuildPending {
            print("🎬 Data was already loaded, triggering rebuildSceneIfNeeded")
            rebuildSceneIfNeeded()
        } else {
            print("🎬 No rebuild pending")
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
            let localPos = calculateElementPosition(coords: coords, normalizationContext: normalizationContext)
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
            if let from = edge.fromId, let to = edge.toId {
                if let line = self.createLineBetween(from, and: to, colorComponents: edge.color ?? edge.shape?.color) {
                    container.addChild(line)
                    self.lineEntities.append(line)
                    self.debugLog("📍 Created line between elements \(from) and \(to)")
                } else {
                    logger.warning("⚠️ Failed to create line between \(from) and \(to) - entities not found in entityMap")
                }
            }
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
            entity.look(at: to, from: entity.position, relativeTo: nil)
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
        if let transform = getWorldTransform() {
            onTransformChanged?(transform.position, transform.orientation, transform.scale)
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
            // set new container position so pivotWorld = container.position + scaledLocal
            container.position = pivotWorld - scaledLocal
        }
    }

    func handleZoomEnded(_ value: EntityTargetValue<MagnificationGesture.Value>) {
        // clear zoom state
        zoomStartScale = nil
        zoomPivotWorld = nil
        zoomPivotLocal = nil
        // Notify transform change
        if let transform = getWorldTransform() {
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
        let sensitivity: Float = 0.0008
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
        if let transform = getWorldTransform() {
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
        let scaleSensitivity: Float = 0.001
        let scaleFactor: Float = 1.0 + (diagonalMovement * scaleSensitivity)
        let newScale = max(0.3, min(2.0, startScale * scaleFactor)) // Tighter bounds for better UX
        
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
        if let transform = getWorldTransform() {
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
        let rotationSensitivity: Float = 0.001  // Reduced sensitivity for more precise control
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
        if let transform = getWorldTransform() {
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
        guard let sceneContent = sceneContent else { return }
        
        let worldPos = container.position(relativeTo: nil)
        
        // Animate back to world space
        container.move(
            to: Transform(scale: container.scale, rotation: container.orientation, translation: worldPos),
            relativeTo: nil,
            duration: 0.25,
            timingFunction: .easeOut
        )
        
        // After animation, reparent to scene root
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            container.removeFromParent()
            sceneContent.add(container)
            container.position = worldPos
        }
    }
    
    /// Gets a human-readable surface type name
    private func getSurfaceTypeName(_ anchor: PlaneAnchor) -> String {
        switch anchor.classification {
        case .table:
            return "Table"
        case .wall:
            return "Wall"
        case .floor:
            return "Floor"
        case .ceiling:
            return "Ceiling"
        case .seat:
            return "Seat"
        case .door:
            return "Door"
        case .window:
            return "Window"
        case .unknown:
            // For unknown surfaces, try to detect if it's vertical (wall-like)
            if isVerticalSurface(anchor) {
                return "Wall"
            } else {
                return "Surface"
            }
        case .notAvailable:
            return "Surface"
        case .undetermined:
            return "Surface"
        @unknown default:
            return "Surface"
        }
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

        let desc = element.shape?.shapeDescription?.lowercased() ?? ""
        // Special case: render RTlabel shapes as text-only entities using specified extents
        logger.log("Create Entity - \(desc)")
        if desc.contains("rtlabel") {
            let entity = createRTLabelEntity(for: element, normalization: normalizationContext)
            entity.name = element.id != nil ? "element_\(element.id!)" : "element_\(UUID().uuidString.prefix(8))"
            entity.generateCollisionShapes(recursive: true)
            entity.components.set(InputTargetComponent())
            return entity
        }

        let (mesh, material) = element.meshAndMaterial(normalization: normalizationContext)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        if desc.contains("rtellipse") {
            entity.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        }
        entity.name = element.id != nil ? "element_\(element.id!)" : "element_\(UUID().uuidString.prefix(8))"

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

        entity.generateCollisionShapes(recursive: true)
        entity.components.set(InputTargetComponent())
        return entity
    }

    private func createLineBetween(_ id1: String, and id2: String, colorComponents: [Double]?) -> ModelEntity? {
        self.debugLog("🔍 Looking for entities with keys: '\(id1)' and '\(id2)'")
        self.debugLog("🗂️ Available entity keys: \(Array(self.entityMap.keys).sorted())")
        guard let entity1 = self.entityMap[id1], let entity2 = self.entityMap[id2] else { 
            logger.error("❌ Could not find entities for keys '\(id1)' and/or '\(id2)'")
            return nil 
        }

        let pos1 = entity1.position
        let pos2 = entity2.position
        let lineVector = pos2 - pos1
        let length = simd_length(lineVector)

        let mesh = MeshResource.generateBox(size: SIMD3(length, 0.002, 0.002))
        let materialColor: UIColor = {
            if let rgba = colorComponents {
                return UIColor(
                    red: CGFloat(rgba[0]),
                    green: CGFloat(rgba[1]),
                    blue: CGFloat(rgba[2]),
                    alpha: rgba.count > 3 ? CGFloat(rgba[3]) : 1.0
                )
            }
            return .gray
        }()
        let material = SimpleMaterial(color: materialColor, isMetallic: false)

        let lineEntity = ModelEntity(mesh: mesh, materials: [material])
        lineEntity.position = pos1 + (lineVector / 2)
        // Orient the line along the vector: rotate +X axis to match the direction
        if length > 0 {
            let direction = lineVector / length
            let quat = simd_quatf(from: SIMD3<Float>(1, 0, 0), to: direction)
            lineEntity.orientation = quat
        }

        return lineEntity
    }

    private func createLabelEntity(text: String) -> Entity {
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.05), containerFrame: .zero, alignment: .center, lineBreakMode: .byWordWrapping)
        let material = SimpleMaterial(color: .white, isMetallic: false)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// Creates a 2D RTlabel entity using the shape.text and shape.extent to size the text container.
    private func createRTLabelEntity(for element: ElementDTO, normalization: NormalizationContext) -> Entity {
        guard let rawText = element.shape?.text,
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rawText.lowercased() != "nil" else {
            return ModelEntity()
        }
        logger.log("RTlabel - rawText: \(rawText)")
        // Build text mesh sized to shape.extent, thin and unlit for visibility
        let extent = element.shape?.extent ?? []
        // Normalize extents into [-1…+1], interpreting extent[0]=width, extent[1]=height
        let w = extent.count > 0
            ? Float(extent[0] / normalization.globalRange)
            : 0.1
        let h = extent.count > 1
            ? Float(extent[1] / normalization.globalRange)
            : 0.05

        let minframe = CGFloat(min(h, w))
        logger.log("rawText: \(rawText) | w: \(w) | h: \(h) | minframe: \(minframe)")
        let mesh = MeshResource.generateText(
            rawText,
            extrusionDepth: 0.005,
            font: .systemFont(ofSize: minframe),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )

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
        // Orient label into XZ-plane so it faces camera in 2D mode, lift slightly to avoid z-fighting
        labelEntity.position.y += 0.001
        // Debug: print world transform and bounds
        debugLog("RTLabel [\(String(describing: element.id))] transform:\n\(labelEntity.transform.matrix)")
        let bounds = labelEntity.visualBounds(relativeTo: nil)
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
