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
    /// Starting position for root container when panning begins
    private var panStartPosition: SIMD3<Float>?
    private var selectedEntity: Entity?
    /// Tracks which entity is currently being dragged
    private var draggingEntity: Entity?
    /// The world-space position at the start of the current drag
    private var draggingStartPosition: SIMD3<Float>?

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
    func loadElements(in content: RealityViewContent) {
        
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
        
        // Add invisible background to capture pan and zoom
        let background = Entity()
        background.name = "graphBackground"
        let bgShape = ShapeResource.generateBox(size: [10, 10, 0.01])
        background.components.set(CollisionComponent(shapes: [bgShape]))
        background.components.set(InputTargetComponent())
        background.position = pivot
        content.add(background)
        self.backgroundEntity = background
        
        // Create new root container under pivot
        let container = Entity()
        container.name = "graphRoot"
        container.position = pivot
        content.add(container)
        self.rootEntity = container
        
        // Clear any existing entities and lines
        entityMap.removeAll()
        lineEntities.removeAll()
        
        // Instantiate each element and add under root
        guard let normalizationContext = self.normalizationContext else {
            logger.error("Missing normalization context; call loadData(from:) before loadElements(in:)")
            return
        }
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
            let localPos = SIMD3<Float>(Float(normX), -Float(normY), Float(normZ))
            entity.position = localPos
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
    
    /// Handle pan gesture to move the entire graph origin
    func handlePanChanged(_ value: EntityTargetValue<DragGesture.Value>) {
        guard let container = rootEntity else { return }
        // Initialize pan start support
        if panStartPosition == nil {
            panStartPosition = container.position
        }
        // Convert gesture translation3D (Vector3D) to SIMD3<Float>
        let t3 = value.gestureValue.translation3D
        let delta = SIMD3<Float>(Float(t3.x), -Float(t3.y), Float(t3.z))
        let offset = delta * Constants.dragTranslationScale
        container.position = panStartPosition! + offset
    }

    func handlePanEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        panStartPosition = nil
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
        
//        let frame = CGRect(
//            x: CGFloat(w) / 2,
//            y: CGFloat(h) / 2,
//            width: CGFloat(w),
//            height: CGFloat(h)
//        )
//        let mesh = MeshResource.generateText(
//            rawText,
//            extrusionDepth: 1.0, //0.001,
//            font: .systemFont(ofSize: CGFloat(max(h, w))),
//            containerFrame: frame,
//            alignment: .center,
//            lineBreakMode: .byCharWrapping//.byWordWrapping
//        )
        
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
        //labelEntity.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
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
        // Debug: draw a translucent yellow box around the label bounds
//        let boxBounds = labelEntity.visualBounds(relativeTo: labelEntity)
//        let box = ModelEntity(
//            mesh: MeshResource.generateBox(size: boxBounds.extents * 2),
//            materials: [SimpleMaterial(color: .yellow.withAlphaComponent(0.3), isMetallic: false)]
//        )
//        box.position = boxBounds.center
//        labelEntity.addChild(box)
        return labelEntity
    }

}
