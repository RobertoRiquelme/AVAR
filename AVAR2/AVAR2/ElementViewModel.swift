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
    /// Starting position for root container when panning begins
    private var panStartPosition: SIMD3<Float>?
    private var selectedEntity: Entity?
    /// Tracks which entity is currently being dragged
    private var draggingEntity: Entity?
    /// The world-space position at the start of the current drag
    private var draggingStartPosition: SIMD3<Float>?

    func loadData(from filename: String) async {
        do {
            let loaded = try ElementService.loadElements(from: filename)
            self.elements = loaded
            logger.log("Loaded \(loaded.count, privacy: .public) elements from \(filename, privacy: .public)")
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
        for element in elements {
            guard let coords = element.position else { continue }
            let entity = createEntity(for: element)
            // Compute world position
            let x = Float(coords[0]) * Constants.worldScale
            let yData = coords.count > 1 ? Float(coords[1]) * Constants.worldScale : 0
            let y = yData + Constants.eyeLevel
            let zData = coords.count > 2 ? Float(coords[2]) * Constants.worldScale : 0
            let z = zData + Constants.frontOffset
            let worldPos = SIMD3<Float>(x, y, z)
            // Position relative to pivot
            entity.position = worldPos - pivot
            logger.debug("Placing entity \(element.id, privacy: .public) at \(worldPos)")
            container.addChild(entity)
            entityMap[element.id] = entity
        }
        // Draw connections and grid under root
        updateConnections(in: content)
        addCoordinateGrid()
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
               let line = createLineBetween(from, and: to) {
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
            container.addChild(axis(from: SIMD3(-0.5, 0, offset), to: SIMD3(0.5, 0, offset), color: .gray))
            container.addChild(axis(from: SIMD3(offset, 0, -0.5), to: SIMD3(offset, 0, 0.5), color: .gray))
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
            let delta = SIMD3<Float>(Float(t3.x), Float(t3.y), Float(t3.z))
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
    
    /// Handle pinch gesture to uniformly scale the entire graph container
    func handleZoomChanged(_ value: EntityTargetValue<MagnificationGesture.Value>) {
        guard let container = rootEntity else { return }
        // Initialize starting scale
        if zoomStartScale == nil {
            zoomStartScale = container.scale.x
        }
        // Compute new scale relative to initial
        let current = Float(value.gestureValue)
        let newScale = zoomStartScale! * current
        container.scale = SIMD3<Float>(repeating: newScale)
    }

    func handleZoomEnded(_ value: EntityTargetValue<MagnificationGesture.Value>) {
        zoomStartScale = nil
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
        let delta = SIMD3<Float>(Float(t3.x), Float(t3.y), Float(t3.z))
        let offset = delta * Constants.dragTranslationScale
        container.position = panStartPosition! + offset
    }

    func handlePanEnded(_ value: EntityTargetValue<DragGesture.Value>) {
        panStartPosition = nil
    }

    private func createEntity(for element: ElementDTO) -> Entity {
        // Create mesh and material via shape factory
        let (mesh, material) = element.meshAndMaterial()
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "element_\(element.id)"

        // Add a label if meaningful: skip if shape.text is "nil" or empty
        let rawText = element.shape?.text
        let labelText: String? = {
            if let t = rawText, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               t.lowercased() != "nil" {
                return t
            }
            // Fallback to id if available
            return element.id.isEmpty ? nil : element.id
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


    private func createLineBetween(_ id1: String, and id2: String) -> ModelEntity? {
        guard let entity1 = entityMap[id1], let entity2 = entityMap[id2] else { return nil }

        let pos1 = entity1.position
        let pos2 = entity2.position
        let lineVector = pos2 - pos1
        let length = simd_length(lineVector)

        let mesh = MeshResource.generateBox(size: SIMD3(length, 0.002, 0.002))
        let material = SimpleMaterial(color: .gray, isMetallic: false)

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

}
