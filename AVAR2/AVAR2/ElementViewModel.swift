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

        // Keep reference for dynamic updates
        self.sceneContent = content

        // Remove previous graph container and background
        if let existing = rootEntity {
            content.remove(existing)
        }
        if let bg = backgroundEntity {
            content.remove(bg)
        }

        // Get dynamic position for this diagram from AppModel - uses persistent surface detection
        let pivot = appModel?.getNextDiagramPosition() ?? SIMD3<Float>(0, 1.0, -2.0)
        print("📍 Loading diagram at position: \(pivot)")
        print("📍 Available surfaces: \(appModel?.surfaceDetector.surfaceAnchors.count ?? 0)")

        guard let normalizationContext = self.normalizationContext else {
            logger.error("Missing normalization context; call loadData(from:) before loadElements(in:)")
            return
        }

        // Compute size of background based on element positions
        let bgWidth = Float(normalizationContext.positionRanges[0] / normalizationContext.globalRange * 2)
        let bgHeight = Float(normalizationContext.positionRanges[1] / normalizationContext.globalRange * 2)

        // Create new root container under pivot (moves and scales all graph content)
        let container = Entity()
        container.name = "graphRoot"
        container.position = pivot
        content.add(container)
        self.rootEntity = container

        // Add invisible background under the same container to capture pan/zoom gestures
        let background = Entity()
        background.name = "graphBackground"
        let bgShape = ShapeResource.generateBox(size: [bgWidth, bgHeight, 0.01])
        background.components.set(CollisionComponent(shapes: [bgShape]))
        // Input is managed by handle and close button; disable background as catch-all target
        background.position = .zero
        container.addChild(background)
        self.backgroundEntity = background

        let hoverEffectComponent = HoverEffectComponent()

        if let onClose = onClose {
            let buttonContainer = Entity()
            buttonContainer.name = "closeButton"

            let buttonRadius: Float = 0.04
            let buttonThickness: Float = 0.005
            let buttonMesh = MeshResource.generateCylinder(height: buttonThickness, radius: buttonRadius)
            let buttonMaterial = SimpleMaterial(color: .white, isMetallic: false)
            let buttonEntity = ModelEntity(mesh: buttonMesh, materials: [buttonMaterial])
            buttonEntity.transform.rotation = simd_quatf(angle: .pi/2, axis: [1, 0, 0])
            buttonContainer.addChild(buttonEntity)

            let textMesh = MeshResource.generateText(
                "×",
                extrusionDepth: 0.001,
                font: .systemFont(ofSize: 0.1),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byWordWrapping
            )
            let textMaterial = SimpleMaterial(color: .gray, isMetallic: false)
            let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
            textEntity.position = [-0.03, -0.05, buttonThickness / 2 + 0.0005]
            buttonContainer.addChild(textEntity)

            let halfW = bgWidth / 2
            let halfH = bgHeight / 2
            let handleWidth: Float = min(bgWidth * 0.5, 0.5)
            let handleHeight: Float = 0.01
            let handleMargin: Float = 0.05
            let handlePosY = -halfH - handleHeight / 2 - handleMargin
            let spacing: Float = 0.02
            let closePosX = -handleWidth / 2 - buttonRadius - spacing
            buttonContainer.position = [closePosX, handlePosY, 0.01]

            buttonContainer.generateCollisionShapes(recursive: true)
            buttonContainer.components.set(InputTargetComponent())
            buttonContainer.components.set(hoverEffectComponent)
            for child in buttonContainer.children {
                child.components.set(InputTargetComponent())
                child.components.set(hoverEffectComponent)
            }
            background.addChild(buttonContainer)
        }

        // Add grab handle for dragging the entire window - full width like native visionOS
        let halfW = bgWidth / 2
        let halfH = bgHeight / 2
        let margin: Float = 0.1
        let handleWidth: Float = bgWidth * 0.45  // 50% smaller grab bar
        let handleHeight: Float = 0.015  // Slightly thinner for more native feel
        let handleThickness: Float = 0.008  // Thinner for more subtle appearance
        let handleMargin: Float = 0.015  // Closer to window
        let handleContainer = Entity()
        handleContainer.name = "grabHandle"
        // Use rounded box for more native visionOS appearance
        let handleMesh = MeshResource.generateBox(size: [handleWidth, handleHeight, handleThickness], cornerRadius: handleHeight * 0.4)
        let handleMaterial = SimpleMaterial(color: .white.withAlphaComponent(0.7), isMetallic: false)  // More transparent like native
        let handleEntity = ModelEntity(mesh: handleMesh, materials: [handleMaterial])
        handleContainer.addChild(handleEntity)
        handleContainer.position = [0, -halfH - handleHeight / 1 - handleMargin, 0.01]
        handleContainer.generateCollisionShapes(recursive: true)
        handleContainer.components.set(InputTargetComponent())
        handleContainer.components.set(hoverEffectComponent)
        for child in handleContainer.children {
            child.components.set(InputTargetComponent())
            child.components.set(hoverEffectComponent)
        }
        background.addChild(handleContainer)
        
        // Store reference for adding snap messages
        self.grabHandleEntity = handleContainer
        print("🎯 Grab handle entity set: \(handleContainer.name)")

        // Add zoom handle at bottom right of diagram
        let zoomHandleContainer = createZoomHandle(bgWidth: bgWidth, bgHeight: bgHeight)
        background.addChild(zoomHandleContainer)
        self.zoomHandleEntity = zoomHandleContainer
        print("🔍 Zoom handle entity set: \(zoomHandleContainer.name)")

        // Clear any existing entities and lines
        entityMap.removeAll()
        lineEntities.removeAll()
        for element in elements {
            guard let coords = element.position else { continue }
            let entity = createEntity(for: element)

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
            let localPos = SIMD3<Float>(Float(normX), yPos, Float(normZ))
            entity.position = localPos
            entity.components.set(hoverEffectComponent)
            container.addChild(entity)
            entityMap[element.id] = entity
        }

        // Draw connections and grid under root
        updateConnections(in: content)
        //addCoordinateGrid()
        
        // Add red sphere at [0,0,0] to show diagram center
        addOriginMarker()
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
            if let from = edge.fromId, let to = edge.toId,
               let line = createLineBetween(from, and: to, colorComponents: edge.color ?? edge.shape?.color) {
                container.addChild(line)
                lineEntities.append(line)
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
            // Apply scale
            let offset = delta * Constants.dragTranslationScale
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

    /// Handle pan gesture to move the entire graph origin like native visionOS windows
    func handlePanChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let container = rootEntity else { return }

        // Get gesture translation in full 3D space
        let translation = value.gestureValue.translation3D
        let gestureOffset = SIMD3<Float>(
            Float(translation.x),
            -Float(translation.y),  // Invert Y axis
            Float(translation.z)    // Include Z movement
        )
        
        // On first pan, just store the starting position
        if panStartPosition == nil {
            panStartPosition = container.position(relativeTo: nil)
            isPanActive = true
            return
        }
        
        // Store initial orientation on first pan
        if panStartOrientation == nil {
            panStartOrientation = container.orientation(relativeTo: nil)
        }
        
        // Native visionOS windows: lateral movement orbits around user, forward/back movement changes distance
        let userPosition = SIMD3<Float>(0, panStartPosition!.y, 0)  // User at same Y level as start
        let startDistanceFromUser = simd_length(panStartPosition! - userPosition)
        
        // Use X movement for orbital rotation (inverted to match natural movement)
        // Add deadzone to prevent unwanted sideways movement during natural forward/back gestures
        let orbitalSensitivity: Float = 0.0008  // Match sensitivity with up/down and forward/back
        let xDeadzone: Float = 0.02  // Ignore small X movements to prevent unnatural sideways drift
        let filteredXMovement = abs(gestureOffset.x) > xDeadzone ? gestureOffset.x : 0
        let orbitalAngle = -filteredXMovement * orbitalSensitivity  // Invert X movement
        
        // Use Z movement for forward/backward distance changes
        let distanceSensitivity: Float = 0.0008  // Match sensitivity with up/down and sideways
        let newDistanceFromUser = startDistanceFromUser - (gestureOffset.z * distanceSensitivity)  // Invert Z movement
        
        // Calculate new position on orbital path around user
        let startDirection = normalize(panStartPosition! - userPosition)
        let startAngle = atan2(startDirection.x, startDirection.z)
        let newAngle = startAngle + orbitalAngle
        
        let newPosition = SIMD3<Float>(
            userPosition.x + sin(newAngle) * newDistanceFromUser,
            panStartPosition!.y + (gestureOffset.y * 0.0008),  // Allow vertical movement
            userPosition.z + cos(newAngle) * newDistanceFromUser
        )
        
        // Set position in 3D space
        container.setPosition(newPosition, relativeTo: nil)
        
        // Rotate to face user like native windows
        let windowToUser = userPosition - newPosition
        let distanceToUser = simd_length(windowToUser)
        
        if distanceToUser > 0.001 {
            // Calculate direction to user, keeping window parallel to ground
            let directionToUser = normalize(SIMD3<Float>(windowToUser.x, 0, windowToUser.z))
            
            // Create rotation to face user - smooth rotation like native windows
            let targetOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: directionToUser)
            container.setOrientation(targetOrientation, relativeTo: nil)
        }
        
        // Surface snapping during pan
        print("🎯 Pan gesture active - checking for surface snapping")
        checkForSurfaceSnapping(container: container, at: newPosition)
    }

    func handlePanEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let container = rootEntity else { return }
        
        // Final snap check when pan ends
        let finalPosition = container.position(relativeTo: nil)
        print("🏁 Pan ended at position: \(finalPosition)")
        if let snapTarget = findNearestWallForSnapping(diagramPosition: finalPosition) {
            print("🎯 Found snap target: \(snapTarget.id)")
            performSnapToSurface(container: container, surface: snapTarget)
        } else {
            print("🚫 No snap target found")
        }
        
        // Native visionOS windows don't have momentum - they stop immediately
        // Just clear the pan state
        panStartPosition = nil
        panStartOrientation = nil
        isPanActive = false

        // Final update of connection lines
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
        
        // Use 2D translation only (completely ignores Z-axis movement)
        let translation2D = value.gestureValue.translation
        let dragX = Float(translation2D.width)
        let dragY = Float(translation2D.height)
        
        // Use only the dominant axis for more predictable scaling
        let dominantDrag = abs(dragX) > abs(dragY) ? dragX : -dragY // Right/up = zoom in, left/down = zoom out
        
        // Much smaller, continuous scale factor for smooth zooming
        let scaleSensitivity: Float = 0.001 // Very gentle scaling for precise control
        let scaleFactor: Float = 1.0 + (dominantDrag * scaleSensitivity)
        let newScale = max(0.3, min(2.0, startScale * scaleFactor)) // Tighter bounds for better UX
        
        // Apply uniform scaling
        container.scale = SIMD3<Float>(repeating: newScale)
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

    // Legacy surface anchor tracking removed - now using PlaneAnchor objects directly from AppModel
    
    // Legacy surface anchor removal removed - now using PlaneAnchor objects directly from AppModel
    
    // Legacy nearestSurfaceAnchor method removed - using PlaneAnchor objects directly
    
    // Legacy calculateDistanceToSurface method removed - using PlaneAnchor objects directly
    
    // Legacy isSurfaceSuitableForSnapping method removed - using PlaneAnchor objects directly
    
    // Legacy calculateOptimalSnapPosition method removed - using PlaneAnchor objects directly
    
    // Legacy snapToSurface method removed - using PlaneAnchor objects directly
    
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
            entity.name = "element_\(element.id)"
            entity.generateCollisionShapes(recursive: true)
            entity.components.set(InputTargetComponent())
            return entity
        }

        let (mesh, material) = element.meshAndMaterial(normalization: normalizationContext)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        if desc.contains("rtellipse") {
            entity.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        }
        entity.name = "element_\(element.id)"

        // Add a label if meaningful for non-RTlabel shapes: skip if shape.text is "nil" or empty
        let rawText = element.shape?.text
        let labelText: String? = {
            if let t = rawText, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               t.lowercased() != "nil" {
                return t
            }
            return element.id.isEmpty ? nil : ""
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
        guard let entity1 = entityMap[id1], let entity2 = entityMap[id2] else { return nil }

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
        print("RTLabel [\(element.id)] transform:\n\(labelEntity.transform.matrix)")
        let bounds = labelEntity.visualBounds(relativeTo: nil)
        print("RTLabel [\(element.id)] bounds center: \(bounds.center), extents: \(bounds.extents)")
        // Debug: add a small red sphere at the label origin
        let debugDot = ModelEntity(
            mesh: MeshResource.generateSphere(radius: 0.01),
            materials: [SimpleMaterial(color: .red, isMetallic: false)]
        )
        labelEntity.addChild(debugDot)
        return labelEntity
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
        
        if let nearestSurface = findNearestWallForSnapping(diagramPosition: position) {
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
    
    /// Find the nearest surface for snapping - diagrams can snap to any PERSISTENT surface
    private func findNearestWallForSnapping(diagramPosition: SIMD3<Float>) -> PlaneAnchor? {
        var closest: (surface: PlaneAnchor, distance: Float)? = nil
        
        let availableSurfaces = getAllSurfaceAnchors()
        print("🔍 Checking \(availableSurfaces.count) PERSISTENT surfaces for snapping at position \(diagramPosition)")
        
        for surface in availableSurfaces {
            // Get surface position in world space using proper transform
            let surfaceWorldTransform = surface.originFromAnchorTransform
            let surfacePosition = SIMD3<Float>(
                surfaceWorldTransform.columns.3.x,
                surfaceWorldTransform.columns.3.y,
                surfaceWorldTransform.columns.3.z
            )
            
            // Calculate 3D distance to surface center
            let distance = simd_distance(diagramPosition, surfacePosition)
            
            // Get surface type for better debug info
            let surfaceType = getSurfaceTypeName(surface)
            print("📍 Surface \(surface.id) (\(surfaceType))")
            print("   📍 Surface world position: \(surfacePosition)")
            print("   📍 Diagram position: \(diagramPosition)")
            print("   📍 Distance: \(distance)m")
            
            // Only snap to walls - detect by orientation (vertical surfaces)
            let isWall = isVerticalSurface(surface) || surfaceType == "Wall"
            if !isWall {
                print("🚫 Skipping non-wall surface: \(surface.id) (\(surfaceType))")
                continue
            }
            
            if distance <= snapDistance {
                if closest == nil || distance < closest!.distance {
                    closest = (surface, distance)
                    print("🎯 New closest wall: \(surface.id) (\(surfaceType)) at \(distance)m")
                }
            } else {
                print("📏 Wall \(surface.id) (\(surfaceType)) too far: \(distance)m > \(snapDistance)m")
            }
        }
        
        if let result = closest?.surface {
            let surfaceType = getSurfaceTypeName(result)
            print("✅ Found snap target: \(result.id) (\(surfaceType)) at \(closest!.distance)m")
        } else {
            print("❌ No surfaces within snap distance (\(snapDistance)m)")
        }
        
        return closest?.surface
    }
    
    /// Perform smooth snap animation to any surface type
    private func performSnapToSurface(container: Entity, surface: PlaneAnchor) {
        // Get surface position and orientation using proper world space transforms
        let surfaceWorldTransform = surface.originFromAnchorTransform
        let surfacePosition = SIMD3<Float>(
            surfaceWorldTransform.columns.3.x,
            surfaceWorldTransform.columns.3.y,
            surfaceWorldTransform.columns.3.z
        )
        let surfaceRotation = simd_quatf(surfaceWorldTransform)
        let surfaceType = getSurfaceTypeName(surface)
        
        var snapPosition: SIMD3<Float>
        var diagramOrientation: simd_quatf
        let offsetDistance: Float = 0.05  // 5cm offset
        
        // Determine snap behavior based on surface type
        if surfaceType.lowercased().contains("wall") {
            // For walls: position diagram vertically, facing out from wall
            // Get the surface normal by transforming the Y axis (surface normal)
            let wallNormal = surfaceRotation.act(SIMD3<Float>(0, 1, 0))
            snapPosition = surfacePosition + (wallNormal * offsetDistance)
            
            // Orient diagram to align with wall surface
            let verticalRotation = simd_quatf(angle: -.pi/2, axis: SIMD3<Float>(1, 0, 0))
            diagramOrientation = surfaceRotation * verticalRotation
            print("📌 Snapping to wall at \(snapPosition)")
        } else if surfaceType.lowercased().contains("table") || surfaceType.lowercased().contains("floor") {
            // For horizontal surfaces: position diagram flat on surface
            let surfaceNormal = surfaceRotation.act(SIMD3<Float>(0, 1, 0))
            snapPosition = surfacePosition + (surfaceNormal * offsetDistance)
            diagramOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))  // Keep upright
            print("📌 Snapping to horizontal surface at \(snapPosition)")
        } else if surfaceType.lowercased().contains("ceiling") {
            // For ceiling: position diagram hanging from ceiling
            let surfaceNormal = surfaceRotation.act(SIMD3<Float>(0, 1, 0))
            snapPosition = surfacePosition - (surfaceNormal * offsetDistance)
            let upsideDownRotation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
            diagramOrientation = upsideDownRotation
            print("📌 Snapping to ceiling at \(snapPosition)")
        } else {
            // For any other surface: use simple position matching with surface normal
            let surfaceNormal = surfaceRotation.act(SIMD3<Float>(0, 1, 0))
            snapPosition = surfacePosition + (surfaceNormal * offsetDistance)
            diagramOrientation = container.orientation(relativeTo: nil)  // Keep current orientation
            print("📌 Snapping to surface at \(snapPosition)")
        }
        
        // Animate to snap position
        container.move(
            to: Transform(
                scale: container.scale,
                rotation: diagramOrientation,
                translation: snapPosition
            ),
            relativeTo: nil,
            duration: 0.4,
            timingFunction: .easeOut
        )
        
        currentSnappedSurface = surface
        let message = "✅ Snapped to \(surfaceType)!"
        print("✅ \(message)")
        // Show message using existing overlay system
        setSnapStatusMessage(message)
        
        // Auto-clear message after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if self.snapStatusMessage.contains("Snapped") {
                self.setSnapStatusMessage("")
            }
        }
    }
    
    // Removed 3D text message functions - using existing overlay system instead
    
    /// Creates an L-shaped zoom handle at the bottom right of the diagram
    private func createZoomHandle(bgWidth: Float, bgHeight: Float) -> Entity {
        let zoomHandleContainer = Entity()
        zoomHandleContainer.name = "zoomHandle"
        
        // L-shape dimensions
        let handleThickness: Float = 0.015
        let handleLength: Float = 0.08
        let handleWidth: Float = 0.015
        
        // Create the horizontal part of the L
        let horizontalMesh = MeshResource.generateBox(size: [handleLength, handleWidth, handleThickness])
        let horizontalMaterial = SimpleMaterial(color: .white, isMetallic: false)
        let horizontalEntity = ModelEntity(mesh: horizontalMesh, materials: [horizontalMaterial])
        horizontalEntity.name = "zoomHandleHorizontal"
        
        // Create the vertical part of the L  
        let verticalMesh = MeshResource.generateBox(size: [handleWidth, handleLength, handleThickness])
        let verticalMaterial = SimpleMaterial(color: .white, isMetallic: false)
        let verticalEntity = ModelEntity(mesh: verticalMesh, materials: [verticalMaterial])
        verticalEntity.name = "zoomHandleVertical"
        
        // Position the parts to form a mirrored L shape (⅃)
        // Vertical part positioned normally
        verticalEntity.position = [0, 0, 0]
        // Horizontal part extends left from the bottom of the vertical part
        horizontalEntity.position = [-handleLength/2 + handleWidth/2, -handleLength/2 + handleWidth/2, 0]
        
        // Add both parts to container
        zoomHandleContainer.addChild(horizontalEntity)
        zoomHandleContainer.addChild(verticalEntity)
        
        // Position at bottom right of diagram
        let halfW = bgWidth / 2
        let halfH = bgHeight / 2
        let margin: Float = 0.05
        zoomHandleContainer.position = [halfW - margin, -halfH + margin, 0.01]
        
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
    
    /// Add a red sphere at [0,0,0] to highlight the diagram's origin point
    private func addOriginMarker() {
        guard let container = rootEntity else { return }
        
        // Create small red sphere
        let sphereRadius: Float = 0.02  // 2cm radius
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
