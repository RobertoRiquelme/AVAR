//
//  ElementViewModel.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import Foundation
import RealityKit
import RealityKitContent
import SwiftUI
import simd
import OSLog
import ARKit

// Logger for ViewModel
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "ElementViewModel")

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
    private var sceneContent: RealityViewContent?
    /// Root container for all graph entities (so we can scale/transform as a group)
    private var rootEntity: Entity?
    /// Background entity to capture pan/zoom gestures
    private var backgroundEntity: Entity?
    /// Starting uniform scale for the container when zoom begins
    private var zoomStartScale: Float?
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
        print("🔧 ElementViewModel: AppModel set, using PERSISTENT surface detection")
        print("🔧 Surface detection running: \(appModel.surfaceDetector.isRunning), anchors: \(appModel.surfaceDetector.surfaceAnchors.count)")
    }
    
    /// Get all available surface anchors with proper coordinate system handling
    private func getAllSurfaceAnchors() -> [PlaneAnchor] {
        guard let appModel = appModel else { 
            print("⚠️ getAllSurfaceAnchors: No AppModel available")
            return [] 
        }
        let anchors = appModel.surfaceDetector.surfaceAnchors
        print("🔍 getAllSurfaceAnchors: Found \(anchors.count) PERSISTENT surface anchors")
        
        // Log each surface for debugging
        for anchor in anchors {
            let surfaceType = getSurfaceTypeName(anchor)
            print("   📍 Surface \(anchor.id): \(surfaceType)")
        }
        
        return anchors
    }
    
    /// Update the 3D snap message above the grab handle
    private func update3DSnapMessage(_ message: String) {
        guard let grabHandle = grabHandleEntity else { 
            print("⚠️ Cannot update 3D snap message - no grab handle entity")
            return 
        }
        print("🎯 Updating 3D snap message: '\(message)'")
        
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
        
        print("🎯 Added 3D snap message: '\(message)' above grab handle")
    }

    func loadData(from filename: String) async {
        self.filename = filename  // Store filename for position tracking
        do {
            let output = try ElementService.loadScriptOutput(from: filename)
            self.elements = output.elements
            self.isGraph2D = output.is2D
            self.normalizationContext = NormalizationContext(elements: output.elements, is2D: output.is2D)
            logger.log("Loaded \(output.elements.count, privacy: .public) elements (2D: \(output.is2D, privacy: .public)) from \(filename, privacy: .public)")
        } catch {
            let msg = "Failed to load \(filename): \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            self.loadErrorMessage = msg
        }
    }

    /// Creates and positions all element entities in the scene.
    /// - Parameter onClose: Optional callback to invoke when the close button is tapped.
    func loadElements(in content: RealityViewContent, onClose: (() -> Void)? = nil) {
        setupSceneContent(content)
        
        guard let normalizationContext = self.normalizationContext else {
            logger.error("Missing normalization context; call loadData(from:) before loadElements(in:)")
            return
        }
        
        let container = createRootContainer(content: content, normalizationContext: normalizationContext)
        let background = createBackgroundEntity(container: container, normalizationContext: normalizationContext)
        
        setupUIControls(background: background, normalizationContext: normalizationContext, onClose: onClose)
        createAndPositionElements(container: container, normalizationContext: normalizationContext)
        
        updateConnections(in: content)
        addOriginMarker()
    }
    
    private func setupSceneContent(_ content: RealityViewContent) {
        self.sceneContent = content
        
        if let existing = rootEntity {
            content.remove(existing)
        }
        if let bg = backgroundEntity {
            content.remove(bg)
        }
    }
    
    private func createRootContainer(content: RealityViewContent, normalizationContext: NormalizationContext) -> Entity {
        let pivot = appModel?.getNextDiagramPosition(for: filename ?? "unknown") ?? SIMD3<Float>(0, 1.0, -2.0)
        print("📍 Loading diagram at position: \(pivot)")
        print("📍 Available surfaces: \(appModel?.surfaceDetector.surfaceAnchors.count ?? 0)")
        
        let container = Entity()
        container.name = "graphRoot"
        container.position = pivot
        content.add(container)
        self.rootEntity = container
        
        return container
    }
    
    private func createBackgroundEntity(container: Entity, normalizationContext: NormalizationContext) -> Entity {
        let bgWidth = Float(normalizationContext.positionRanges[0] / normalizationContext.globalRange * 2)
        let bgHeight = Float(normalizationContext.positionRanges[1] / normalizationContext.globalRange * 2)
        let bgDepth = normalizationContext.positionCenters.count > 2 ? 
            Float(normalizationContext.positionRanges[2] / normalizationContext.globalRange * 2) : 0.01
        
        let background = Entity()
        background.name = "graphBackground"
        let bgShape = ShapeResource.generateBox(size: [bgWidth, bgHeight, bgDepth])
        background.components.set(CollisionComponent(shapes: [bgShape]))
        background.position = .zero
        container.addChild(background)
        self.backgroundEntity = background
        
        return background
    }
    
    /// Update the background entity's collision shapes to match the current scale
    /// This ensures snapping calculations use the correct scaled dimensions
    private func updateBackgroundEntityCollisionShapes(scale: Float) {
        guard let background = backgroundEntity,
              let normalizationContext = self.normalizationContext else { 
            print("⚠️ Cannot update background collision shapes - missing background entity or normalization context")
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
        
        print("📦 Updated background collision shapes: \(scaledWidth) x \(scaledHeight) x \(scaledDepth) (scale: \(scale))")
    }
    
    private func setupUIControls(background: Entity, normalizationContext: NormalizationContext, onClose: (() -> Void)?) {
        let bgWidth = Float(normalizationContext.positionRanges[0] / normalizationContext.globalRange * 2)
        let bgHeight = Float(normalizationContext.positionRanges[1] / normalizationContext.globalRange * 2)
        let bgDepth = normalizationContext.positionCenters.count > 2 ? 
            Float(normalizationContext.positionRanges[2] / normalizationContext.globalRange * 2) : 0.01
        
        if let onClose = onClose {
            let closeButton = createCloseButton(bgWidth: bgWidth, bgHeight: bgHeight, bgDepth: bgDepth, onClose: onClose)
            background.addChild(closeButton)
        }
        
        let grabHandle = createGrabHandle(bgWidth: bgWidth, bgHeight: bgHeight, bgDepth: bgDepth)
        background.addChild(grabHandle)
        self.grabHandleEntity = grabHandle
        print("🎯 Grab handle entity set: \(grabHandle.name)")
        
        let zoomHandle = createZoomHandle(bgWidth: bgWidth, bgHeight: bgHeight, bgDepth: bgDepth)
        background.addChild(zoomHandle)
        self.zoomHandleEntity = zoomHandle
        print("🔍 Zoom handle entity set: \(zoomHandle.name)")
    }
    
    private func createCloseButton(bgWidth: Float, bgHeight: Float, bgDepth: Float, onClose: @escaping () -> Void) -> Entity {
        let buttonContainer = Entity()
        buttonContainer.name = "closeButton"
        
        let buttonRadius: Float = 0.02
        let buttonThickness: Float = 0.008
        let buttonMesh = MeshResource.generateCylinder(height: buttonThickness, radius: buttonRadius)
        let buttonMaterial = SimpleMaterial(color: .white.withAlphaComponent(0.8), isMetallic: false)
        let buttonEntity = ModelEntity(mesh: buttonMesh, materials: [buttonMaterial])
        buttonEntity.transform.rotation = simd_quatf(angle: .pi/2, axis: [1, 0, 0])
        buttonContainer.addChild(buttonEntity)
        
        let textMesh = MeshResource.generateText(
            "×",
            extrusionDepth: 0.002,
            font: .systemFont(ofSize: 0.06),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        let textMaterial = SimpleMaterial(color: .black.withAlphaComponent(0.7), isMetallic: false)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        
        let textBounds = textMesh.bounds
        let textOffset = SIMD3<Float>(-textBounds.center.x, -textBounds.center.y, buttonThickness / 2 + 0.001)
        textEntity.position = textOffset
        buttonContainer.addChild(textEntity)
        
        positionCloseButton(buttonContainer, bgWidth: bgWidth, bgHeight: bgHeight, bgDepth: bgDepth, buttonRadius: buttonRadius)
        setupButtonInteraction(buttonContainer)
        
        return buttonContainer
    }
    
    private func positionCloseButton(_ buttonContainer: Entity, bgWidth: Float, bgHeight: Float, bgDepth: Float, buttonRadius: Float) {
        let halfH = bgHeight / 2
        let handleWidth: Float = bgWidth * 0.65
        let handleHeight: Float = 0.018
        let handleMargin: Float = 0.015
        let handlePosY = -halfH - handleHeight / 2 - handleMargin
        let spacing: Float = 0.015
        let closePosX = -handleWidth / 2 - buttonRadius - spacing
        let closePosZ = isGraph2D ? Float(0.01) : (bgDepth / 2 + 0.01)
        buttonContainer.position = [closePosX, handlePosY, closePosZ]
    }
    
    private func createGrabHandle(bgWidth: Float, bgHeight: Float, bgDepth: Float) -> Entity {
        let halfH = bgHeight / 2
        let handleWidth: Float = bgWidth * 0.65
        let handleHeight: Float = 0.018
        let handleThickness: Float = 0.008
        let handleMargin: Float = 0.015
        let handleContainer = Entity()
        handleContainer.name = "grabHandle"
        
        let handleMesh = MeshResource.generateBox(size: [handleWidth, handleHeight, handleThickness], cornerRadius: handleHeight * 0.4)
        let handleMaterial = SimpleMaterial(color: .white.withAlphaComponent(0.7), isMetallic: false)
        let handleEntity = ModelEntity(mesh: handleMesh, materials: [handleMaterial])
        handleContainer.addChild(handleEntity)
        
        let handlePosZ = isGraph2D ? Float(0.01) : (bgDepth / 2 + 0.01)
        handleContainer.position = [0, -halfH - handleHeight / 1 - handleMargin, handlePosZ]
        
        setupButtonInteraction(handleContainer)
        
        return handleContainer
    }
    
    private func setupButtonInteraction(_ buttonContainer: Entity) {
        let hoverEffectComponent = HoverEffectComponent()
        buttonContainer.generateCollisionShapes(recursive: true)
        buttonContainer.components.set(InputTargetComponent())
        buttonContainer.components.set(hoverEffectComponent)
        for child in buttonContainer.children {
            child.components.set(InputTargetComponent())
            child.components.set(hoverEffectComponent)
        }
    }
    
    private func createAndPositionElements(container: Entity, normalizationContext: NormalizationContext) {
        entityMap.removeAll()
        lineEntities.removeAll()
        let hoverEffectComponent = HoverEffectComponent()
        
        print("🔄 Creating and positioning \(elements.count) elements")
        var validElements = 0
        
        for element in elements {
            // Skip edge/line elements - they don't need visual representation, only connection info
            if element.type.lowercased() == "edge" || element.shape?.shapeDescription?.lowercased() == "line" {
                print("🔗 Skipping edge/line element \(element.id ?? "unknown") - used for connections only")
                continue
            }
            
            guard let coords = element.position else { 
                print("⚠️ Element \(element.id ?? "unknown") has no position - skipping")
                continue 
            }
            
            // Skip camera elements - they don't need visual representation
            if element.type.lowercased() == "camera" {
                print("📷 Skipping camera element \(element.id ?? "unknown")")
                continue
            }
            
            let entity = createEntity(for: element)
            let localPos = calculateElementPosition(coords: coords, normalizationContext: normalizationContext)
            print("📍 Element \(element.id ?? "unknown") positioned at \(localPos)")
            
            entity.position = localPos
            entity.components.set(hoverEffectComponent)
            container.addChild(entity)
            let elementIdKey = element.id ?? "element_\(UUID().uuidString.prefix(8))"
            entityMap[elementIdKey] = entity
            print("🗝️ Stored entity with key: '\(elementIdKey)' for element ID: \(element.id ?? "nil")")
            validElements += 1
        }
        
        print("✅ Successfully created \(validElements) out of \(elements.count) elements")
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
        for edge in elements {
            if let from = edge.fromId, let to = edge.toId {
                if let line = createLineBetween(from, and: to, colorComponents: edge.color ?? edge.shape?.color) {
                    container.addChild(line)
                    lineEntities.append(line)
                    print("📍 Created line between elements \(from) and \(to)")
                } else {
                    print("⚠️ Failed to create line between \(from) and \(to) - entities not found in entityMap")
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
    }
    
    /// Handle rotation button drag to rotate 3D diagrams on Y-axis
    func handleRotationButtonDragChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let container = rootEntity, !isGraph2D else { 
            print("⚠️ Rotation only available for 3D diagrams")
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
        
        print("🔄 Rotating 3D diagram: angle=\(newAngle) radians (\(newAngle * 180 / .pi) degrees)")
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
        
        print("🔄 Rotation gesture ended")
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
            print("🧱 Detected vertical surface (wall): \(anchor.id) with normal \(normal)")
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
        
        print("📐 Lowest entity bottom Y position: \(lowestY)")
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
        
        print("📐 Highest entity top Y position: \(highestY)")
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
            print("🏢 Detected horizontal surface (floor/table/ceiling): \(anchor.id) with normal \(normal)")
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
        print("🔔 Setting snap status message: '\(message)'")
        print("🔔 Previous message was: '\(snapStatusMessage)'")
        snapStatusMessage = message
        print("🔔 Message set successfully. Current value: '\(snapStatusMessage)'")
        
        // Update the 3D message above grab handle
        update3DSnapMessage(message)
        
        // Optionally auto-clear after a second
        if alwaysShowSnapMessage == false {
            print("🔔 Auto-clear enabled - will clear in 1.5 seconds")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if self.snapStatusMessage == message {
                    print("🔔 Auto-clearing message: '\(message)'")
                    self.snapStatusMessage = ""
                    self.update3DSnapMessage("") // Clear 3D message too
                } else {
                    print("🔔 Message changed, not clearing: '\(message)' vs '\(self.snapStatusMessage)'")
                }
            }
        } else {
            print("🔔 Auto-clear disabled (alwaysShowSnapMessage = true)")
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
        print("🔍 Looking for entities with keys: '\(id1)' and '\(id2)'")
        print("🗂️ Available entity keys: \(Array(entityMap.keys).sorted())")
        guard let entity1 = entityMap[id1], let entity2 = entityMap[id2] else { 
            print("❌ Could not find entities for keys '\(id1)' and/or '\(id2)'")
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
        print("RTLabel [\(String(describing: element.id))] transform:\n\(labelEntity.transform.matrix)")
        let bounds = labelEntity.visualBounds(relativeTo: nil)
        print("RTLabel [\(String(describing: element.id))] bounds center: \(bounds.center), extents: \(bounds.extents)")
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
        
        print("📐 Surface dimensions: \(planeWidth)m x \(planeHeight)m")
        print("📐 Surface center: \(planePosition)")
        print("📐 Diagram position: \(diagramPosition)")
        
        // Transform point to plane's local space
        let toPlane = diagramPosition - planePosition
        let localPoint = simd_inverse(planeRotation).act(toPlane)
        
        print("📐 Local point on surface: \(localPoint)")
        
        // Clamp the point to the plane bounds - this enables snapping anywhere on surface
        let clampedX = Swift.max(-planeWidth/2, Swift.min(planeWidth/2, localPoint.x))
        let clampedZ = Swift.max(-planeHeight/2, Swift.min(planeHeight/2, localPoint.z))
        
        print("📐 Clamped local point: x=\(clampedX), z=\(clampedZ)")
        
        // Find nearest point on the plane within bounds
        let nearestOnPlane = planeRotation.act(SIMD3<Float>(clampedX, 0, clampedZ)) + planePosition
        
        print("📐 Final snap point: \(nearestOnPlane)")
        
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
        print("🔍 checkForSurfaceSnapping called with PERSISTENT surfaces")
        print("🔍 Diagram position: \(position)")
        print("🔍 Available PERSISTENT surfaces: \(availableSurfaces.count)")
        
        guard !availableSurfaces.isEmpty else { 
            print("🚫 No PERSISTENT surfaces available for snapping")
            return 
        }
        
        if let nearestSurface = findNearestSurfaceForSnapping(diagramPosition: position) {
            // Show visual feedback that snapping is available
            let surfaceType = getSurfaceTypeName(nearestSurface)
            let message = "📍 Near \(surfaceType) - Release to Snap!"
            print("✨ \(message)")
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
        
        print("🔍 Checking \(availableSurfaces.count) PERSISTENT surfaces for \(diagramType) diagram snapping to \(targetSurfaceType) at position \(diagramPosition)")
        print("🔍 3D diagrams can snap anywhere on horizontal surfaces, not just the center")
        
        let validSurfaces = filterValidSurfaces(availableSurfaces)
        let closest = findClosestSurface(validSurfaces, diagramPosition: diagramPosition)
        
        logSnapResult(closest: closest, diagramType: diagramType, targetSurfaceType: targetSurfaceType)
        return closest?.surface
    }
    
    private func filterValidSurfaces(_ surfaces: [PlaneAnchor]) -> [PlaneAnchor] {
        return surfaces.filter { surface in
            let surfaceType = getSurfaceTypeName(surface)
            let isValidSurface: Bool
            
            if isGraph2D {
                isValidSurface = isVerticalSurface(surface)
                if !isValidSurface {
                    print("🚫 Skipping non-vertical surface for 2D diagram: \(surface.id) (\(surfaceType))")
                }
            } else {
                isValidSurface = isHorizontalSurface(surface) || surfaceType == "Floor" || surfaceType == "Table"
                if !isValidSurface {
                    print("🚫 Skipping non-horizontal surface for 3D diagram: \(surface.id) (\(surfaceType))")
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
            let surfaceType = getSurfaceTypeName(surface)
            
            logSurfaceInfo(surface: surface, surfaceType: surfaceType, surfacePosition: surfacePosition, diagramPosition: diagramPosition, distance: distance)
            
            if distance <= snapDistance {
                if closest == nil || distance < closest!.distance {
                    closest = (surface, distance)
                    print("🎯 New closest \(isGraph2D ? "wall" : "horizontal surface"): \(surface.id) (\(surfaceType)) at \(distance)m")
                }
            } else {
                print("📏 Surface \(surface.id) (\(surfaceType)) too far: \(distance)m > \(snapDistance)m")
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
        print("📍 Surface \(surface.id) (\(surfaceType))")
        print("   📍 Surface world position: \(surfacePosition)")
        print("   📍 Diagram position: \(diagramPosition)")
        print("   📍 Distance: \(distance)m")
    }
    
    private func logSnapResult(closest: (surface: PlaneAnchor, distance: Float)?, diagramType: String, targetSurfaceType: String) {
        if let result = closest?.surface {
            let surfaceType = getSurfaceTypeName(result)
            print("✅ Found snap target for \(diagramType) diagram: \(result.id) (\(surfaceType)) at \(closest!.distance)m")
        } else {
            print("❌ No \(targetSurfaceType) surfaces within snap distance (\(snapDistance)m) for \(diagramType) diagram")
        }
    }
    
    /// Perform smooth snap animation to any surface type
    private func performSnapToSurface(container: Entity, surface: PlaneAnchor) {
        let diagramPosition = container.position(relativeTo: nil)
        let nearestPointOnSurface = findNearestPointOnSurface(diagramPosition: diagramPosition, surface: surface)
        let surfaceWorldTransform = surface.originFromAnchorTransform
        let surfaceRotation = simd_quatf(surfaceWorldTransform)
        let surfaceType = getSurfaceTypeName(surface)
        
        let (snapPosition, diagramOrientation) = calculateSnapPositionAndOrientation(
            nearestPointOnSurface: nearestPointOnSurface,
            surfaceRotation: surfaceRotation,
            surfaceType: surfaceType,
            container: container,
            isGraph2D: isGraph2D
        )
        
        animateToSnapPosition(container: container, position: snapPosition, orientation: diagramOrientation)
        finalizeSnap(surface: surface, surfaceType: surfaceType)
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
            print("📌 Snapping 2D diagram to wall at \(snapPosition) with rotation")
        } else {
            diagramOrientation = container.orientation(relativeTo: nil)
            print("📌 Snapping 3D diagram to wall at \(snapPosition) preserving orientation")
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
            print("📌 Snapping 2D diagram to horizontal surface at \(snapPosition) with default orientation")
        } else {
            diagramOrientation = container.orientation(relativeTo: nil) // Preserve current orientation for 3D
            print("📌 Snapping 3D diagram to horizontal surface at \(snapPosition) preserving orientation")
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
            print("📌 Snapping 2D diagram to ceiling at \(snapPosition) with upside-down rotation")
        } else {
            diagramOrientation = container.orientation(relativeTo: nil)
            print("📌 Snapping 3D diagram to ceiling at \(snapPosition) preserving orientation")
        }
        
        return (snapPosition, diagramOrientation)
    }
    
    private func calculateGenericSnapPosition(nearestPointOnSurface: SIMD3<Float>, surfaceRotation: simd_quatf, offsetDistance: Float, container: Entity) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let surfaceNormal = surfaceRotation.act(SIMD3<Float>(0, 1, 0))
        let snapPosition = nearestPointOnSurface + (surfaceNormal * offsetDistance)
        let diagramOrientation = container.orientation(relativeTo: nil)
        print("📌 Snapping to surface at \(snapPosition)")
        return (snapPosition, diagramOrientation)
    }
    
    private func calculateBottomOffset(offsetDistance: Float) -> Float {
        if !isGraph2D {
            let lowestEntityY = findLowestEntityPosition()
            let currentScale = rootEntity?.scale.x ?? 1.0
            let scaledLowestY = lowestEntityY * currentScale
            let bottomOffset = offsetDistance - scaledLowestY
            print("📌 3D diagram bottom offset: \(bottomOffset), lowest entity Y: \(lowestEntityY), scale: \(currentScale), scaled lowest Y: \(scaledLowestY)")
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
            print("📌 3D diagram top offset: \(topOffset), highest entity Y: \(highestEntityY), scale: \(currentScale), scaled highest Y: \(scaledHighestY)")
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
        print("✅ \(message)")
        setSnapStatusMessage(message)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if self.snapStatusMessage.contains("Snapped") {
                self.setSnapStatusMessage("")
            }
        }
    }
    
    // Removed 3D text message functions - using existing overlay system instead
    
    /// Creates an L-shaped zoom handle at the bottom right of the diagram
    private func createZoomHandle(bgWidth: Float, bgHeight: Float, bgDepth: Float) -> Entity {
        let zoomHandleContainer = Entity()
        zoomHandleContainer.name = "zoomHandle"
        
        // Native visionOS zoom handle dimensions - wider for better usability
        let handleThickness: Float = 0.008  // Thinner for more native feel
        let handleLength: Float = 0.08  // Even longer for easier grabbing
        let handleWidth: Float = 0.02   // Even wider for better touch target
        let cornerRadius: Float = handleWidth * 0.3  // Rounded corners like native
        
        // Create the horizontal part of the L with rounded corners
        let horizontalMesh = MeshResource.generateBox(size: [handleLength, handleWidth, handleThickness], cornerRadius: cornerRadius)
        let horizontalMaterial = SimpleMaterial(color: .white.withAlphaComponent(0.7), isMetallic: false)  // Semi-transparent like native
        let horizontalEntity = ModelEntity(mesh: horizontalMesh, materials: [horizontalMaterial])
        horizontalEntity.name = "zoomHandleHorizontal"
        
        // Create the vertical part of the L with rounded corners
        let verticalMesh = MeshResource.generateBox(size: [handleWidth, handleLength, handleThickness], cornerRadius: cornerRadius)
        let verticalMaterial = SimpleMaterial(color: .white.withAlphaComponent(0.7), isMetallic: false)  // Semi-transparent like native
        let verticalEntity = ModelEntity(mesh: verticalMesh, materials: [verticalMaterial])
        verticalEntity.name = "zoomHandleVertical"
        
        // Position the parts to form a native-style L shape (⅃) - positioned in the actual corner
        // Vertical part positioned at the right edge
        verticalEntity.position = [handleLength/2 - handleWidth/2, 0, 0]
        // Horizontal part extends from the bottom of the vertical part
        horizontalEntity.position = [0, -handleLength/2 + handleWidth/2, 0]
        
        // Add both parts to container
        zoomHandleContainer.addChild(horizontalEntity)
        zoomHandleContainer.addChild(verticalEntity)
        
        // Add rotation button for 3D diagrams only
        if !isGraph2D {
            let rotationButton = createRotationButton(handleWidth: handleWidth, handleLength: handleLength, handleThickness: handleThickness)
            zoomHandleContainer.addChild(rotationButton)
            // Store reference for gesture handling
            self.rotationButtonEntity = rotationButton
        }
        
        // Position exactly at the bottom right corner like native visionOS
        let halfW = bgWidth / 2
        let halfH = bgHeight / 2
        let margin: Float = 0.02  // Smaller margin for tighter corner placement
        // Position on front face for 3D diagrams, slightly in front for 2D diagrams
        let zoomPosZ = isGraph2D ? Float(0.01) : (bgDepth / 2 + 0.01)
        zoomHandleContainer.position = [halfW - margin, -halfH + margin, zoomPosZ]
        
        // Enable interaction
        zoomHandleContainer.generateCollisionShapes(recursive: true)
        zoomHandleContainer.components.set(InputTargetComponent())
        let hoverEffectComponent = HoverEffectComponent()
        zoomHandleContainer.components.set(hoverEffectComponent)
        
        // Enable interaction on child entities too
        for child in zoomHandleContainer.children {
            child.components.set(InputTargetComponent())
            child.components.set(hoverEffectComponent)
        }
        
        return zoomHandleContainer
    }
    
    /// Creates a circular rotation button for 3D diagrams
    /// Positioned on top of the bottom of the L and to the left of the upper part
    private func createRotationButton(handleWidth: Float, handleLength: Float, handleThickness: Float) -> Entity {
        let rotationButtonContainer = Entity()
        rotationButtonContainer.name = "rotationButton"
        
        // Create circular button (cylinder)
        let buttonRadius: Float = handleWidth * 0.8  // Slightly smaller than handle width
        let buttonThickness: Float = handleThickness * 1.5  // Slightly thicker than handle
        let buttonMesh = MeshResource.generateCylinder(height: buttonThickness, radius: buttonRadius)
        
        // Use a different color to distinguish from zoom handle
        let buttonMaterial = SimpleMaterial(color: .systemBlue.withAlphaComponent(0.8), isMetallic: false)
        let buttonEntity = ModelEntity(mesh: buttonMesh, materials: [buttonMaterial])
        buttonEntity.name = "rotationButtonCylinder"
        
        // Rotate the cylinder to lie flat (perpendicular to Z axis)
        buttonEntity.transform.rotation = simd_quatf(angle: .pi/2, axis: [1, 0, 0])
        
        rotationButtonContainer.addChild(buttonEntity)
        
        // Position: "on top of the bottom of the scale L, and to the left of the upper part of the L"
        // Bottom of L (horizontal part) is at [0, -handleLength/2 + handleWidth/2, 0]
        // Upper part of L (vertical part) is at [handleLength/2 - handleWidth/2, 0, 0]
        // So position should be to the left of vertical part and on top of horizontal part
        let buttonX = handleLength/2 - handleWidth/2 - buttonRadius * 2 - 0.025  // To the left of vertical part
        let buttonY = -handleLength/2 + handleWidth/2 + buttonRadius + 0.03 // On top of horizontal part
        let buttonZ = buttonThickness/2 + handleThickness/2 - 0.01 // + 0.002  // Slightly in front
        
        rotationButtonContainer.position = [buttonX, buttonY, buttonZ]
        
        // Enable interaction
        rotationButtonContainer.generateCollisionShapes(recursive: true)
        rotationButtonContainer.components.set(InputTargetComponent())
        let hoverEffectComponent = HoverEffectComponent()
        rotationButtonContainer.components.set(hoverEffectComponent)
        
        // Enable interaction on child entities too
        for child in rotationButtonContainer.children {
            child.components.set(InputTargetComponent())
            child.components.set(hoverEffectComponent)
        }
        
        return rotationButtonContainer
    }
    
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
        
        print("🔴 Added red origin marker at [0,0,0]")
    }
    
}

// MARK: - Camera Transform Helpers
extension simd_float4x4 {
    /// Extracts the translation (position) from a 4x4 transform matrix
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}
