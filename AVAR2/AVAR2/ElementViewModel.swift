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

    private var selectedEntity: Entity?
    /// Tracks which entity is currently being dragged
    private var draggingEntity: Entity?
    /// The world-space position at the start of the current drag
    private var draggingStartPosition: SIMD3<Float>?
    // In ElementViewModel.swift
    @Published var tableAnchor: AnchorEntity?
    @Published var wallAnchor: AnchorEntity?
    /// Tracks which surface anchor (if any) the graph is currently snapped to
    private var snappedAnchor: AnchorEntity? = nil
    /// List of all detected surface anchors
    @Published var detectedSurfaceAnchors: [AnchorEntity] = []

    // NEW: Snap/unsnap banner
    @Published var snapStatusMessage: String = ""

    // NEW: Set this to false to only show message once, or to true to always show
    private var alwaysShowSnapMessage = true
    
    // Enhanced surface detection constants
    private let snapThreshold: Float = 0.3  // Distance threshold for snapping
    private let releaseThreshold: Float = 0.5  // Distance threshold for releasing snap

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

        // Pivot for graph origin and background plane
        let pivot = SIMD3<Float>(0, Constants.eyeLevel, Constants.frontOffset)

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

        // Add grab handle for dragging the entire window
        let halfW = bgWidth / 2
        let halfH = bgHeight / 2
        let margin: Float = 0.1
        let handleWidth: Float = min(bgWidth * 0.5, 0.5)
        let handleHeight: Float = 0.025
        let handleThickness: Float = 0.01
        let handleMargin: Float = 0.02
        let handleContainer = Entity()
        handleContainer.name = "grabHandle"
        let handleMesh = MeshResource.generateBox(size: [handleWidth, handleHeight, handleThickness])
        let handleMaterial = SimpleMaterial(color: .white, isMetallic: false)
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
        
        // Scale down the movement to match native visionOS sensitivity
        let moveScale: Float = 0.0005  // Reduce sensitivity
        let scaledOffset = gestureOffset * moveScale
        let newPosition = panStartPosition! + scaledOffset
        
        // Set position in 3D space
        container.setPosition(newPosition, relativeTo: nil)
        
        // Auto-rotate to face user but keep parallel to ground like native visionOS windows
        let userPosition = SIMD3<Float>(0, newPosition.y, 0)  // User at same Y level as window
        let windowToUser = userPosition - newPosition
        let distanceToUser = simd_length(windowToUser)
        
        if distanceToUser > 0.001 {
            // Only rotate around Y axis to face user, keeping window parallel to ground
            let directionToUser = normalize(SIMD3<Float>(windowToUser.x, 0, windowToUser.z))  // Zero out Y component
            
            // Create rotation only around Y axis
            if simd_length(scaledOffset) > 0.00001 {  // Only rotate on meaningful movement
                let targetOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: directionToUser)
                container.setOrientation(targetOrientation, relativeTo: nil)
            }
        }
    }

    func handlePanEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        // Native visionOS windows don't have momentum - they stop immediately
        // Just clear the pan state
        panStartPosition = nil
        panStartOrientation = nil
        isPanActive = false
        
        // The orientation will already be correct from handlePanChanged
        // No need to force any specific orientation here

        // Final update of connection lines
        if let content = sceneContent {
            updateConnections(in: content)
        }
    }

    /// Adds a detected surface anchor to the tracking list
    func addDetectedSurfaceAnchor(_ anchor: AnchorEntity) {
        if !detectedSurfaceAnchors.contains(where: { $0 === anchor }) {
            detectedSurfaceAnchors.append(anchor)
            
            // Update primary anchors if needed
            if anchor.name.contains("table") && tableAnchor == nil {
                tableAnchor = anchor
            } else if anchor.name.contains("wall") && wallAnchor == nil {
                wallAnchor = anchor
            }
        }
    }
    
    /// Removes a detected surface anchor from the tracking list
    func removeDetectedSurfaceAnchor(_ anchor: AnchorEntity) {
        detectedSurfaceAnchors.removeAll { $0 === anchor }
        
        if tableAnchor === anchor {
            tableAnchor = detectedSurfaceAnchors.first { $0.name.contains("table") }
        } else if wallAnchor === anchor {
            wallAnchor = detectedSurfaceAnchors.first { $0.name.contains("wall") }
        }
    }
    
    /// Enhanced surface detection with better classification and proximity detection
    private func nearestSurfaceAnchor(to worldPos: SIMD3<Float>, threshold: Float = 0.25) -> AnchorEntity? {
        // Use all detected surface anchors, not just primary ones
        let candidates = detectedSurfaceAnchors.filter { $0.isAnchored }
        var closest: (anchor: AnchorEntity, distance: Float, surfaceDistance: Float)? = nil
        
        for anchor in candidates {
            let anchorPos = anchor.position(relativeTo: nil)
            let dist = simd_distance(anchorPos, worldPos)
            
            // Calculate distance to surface plane, not just anchor center
            let surfaceDistance = calculateDistanceToSurface(worldPos: worldPos, anchor: anchor)
            
            if surfaceDistance < threshold {
                if closest == nil || surfaceDistance < closest!.surfaceDistance {
                    closest = (anchor, dist, surfaceDistance)
                }
            }
        }
        return closest?.anchor
    }
    
    /// Calculates the actual distance from a point to the surface plane
    private func calculateDistanceToSurface(worldPos: SIMD3<Float>, anchor: AnchorEntity) -> Float {
        let anchorPos = anchor.position(relativeTo: nil)
        let anchorRotation = anchor.orientation(relativeTo: nil)
        
        // Get the normal vector of the surface plane
        let surfaceNormal = anchorRotation.act(SIMD3<Float>(0, 1, 0))
        
        // Calculate distance to plane
        let toPoint = worldPos - anchorPos
        let distanceToPlane = abs(simd_dot(toPoint, surfaceNormal))
        
        return distanceToPlane
    }
    
    /// Checks if a surface is suitable for snapping based on orientation and size
    private func isSurfaceSuitableForSnapping(_ anchor: AnchorEntity) -> Bool {
        // Check if anchor has sufficient size (you might need to access the underlying ARPlaneAnchor)
        // For now, we'll assume all detected anchors are suitable
        return anchor.isAnchored
    }
    
    /// Calculates the optimal snap position for a container on a surface
    private func calculateOptimalSnapPosition(for container: Entity, on anchor: AnchorEntity) -> SIMD3<Float> {
        let worldPos = container.position(relativeTo: nil)
        let anchorPos = anchor.position(relativeTo: nil)
        let anchorRotation = anchor.orientation(relativeTo: nil)
        
        // Get the surface normal
        let surfaceNormal = anchorRotation.act(SIMD3<Float>(0, 1, 0))
        
        // Project the container position onto the surface plane
        let toContainer = worldPos - anchorPos
        let distanceToPlane = simd_dot(toContainer, surfaceNormal)
        let projectedWorldPos = worldPos - (surfaceNormal * distanceToPlane)
        
        // Convert to anchor local space and add small offset above surface
        let localPos = anchor.convert(position: projectedWorldPos, from: nil)
        
        // Add small offset to prevent z-fighting
        let offsetAmount: Float = 0.05
        return localPos + SIMD3<Float>(0, offsetAmount, 0)
    }
    
    /// Performs the snap animation to a surface
    private func snapToSurface(container: Entity, anchor: AnchorEntity, localPos: SIMD3<Float>) {
        // Animate the snap
        container.move(
            to: Transform(scale: container.scale, rotation: container.orientation, translation: localPos),
            relativeTo: anchor,
            duration: 0.25,
            timingFunction: .easeOut
        )
        
        // After animation, reparent to the anchor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            container.removeFromParent()
            anchor.addChild(container)
            container.position = localPos
        }
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
    private func getSurfaceTypeName(_ anchor: AnchorEntity) -> String {
        if anchor.name.contains("table") || anchor === tableAnchor {
            return "Table"
        } else if anchor.name.contains("wall") || anchor === wallAnchor {
            return "Wall"
        } else if anchor.name.contains("floor") {
            return "Floor"
        } else if anchor.name.contains("ceiling") {
            return "Ceiling"
        } else {
            return "Surface"
        }
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
        snapStatusMessage = message
        // Optionally auto-clear after a second
        if alwaysShowSnapMessage == false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if self.snapStatusMessage == message {
                    self.snapStatusMessage = ""
                }
            }
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
}

// MARK: - Camera Transform Helpers
extension simd_float4x4 {
    /// Extracts the translation (position) from a 4x4 transform matrix
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}
