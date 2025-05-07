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
        // Keep a reference for dynamic updates
        self.sceneContent = content
        // Remove any existing nodes & lines
        entityMap.values.forEach { content.remove($0) }
        entityMap.removeAll()
        lineEntities.forEach { content.remove($0) }
        lineEntities.removeAll()

        // Instantiate each element on a vertical plane at eye level, using data's second coordinate for height
        for element in elements {
            guard let coords = element.position else { continue }
            let entity = createEntity(for: element)
            // X axis: first coordinate
            let x = Float(coords[0]) * Constants.worldScale
            // Y axis (vertical): second coordinate + eye level offset
            let yData = coords.count > 1 ? Float(coords[1]) * Constants.worldScale : 0
            let y = yData + Constants.eyeLevel
            // Z axis (depth): third coordinate if present, else constant offset
            let zData = coords.count > 2 ? Float(coords[2]) * Constants.worldScale : 0
            let z = zData + Constants.frontOffset
            entity.position = SIMD3(x, y, z)
            logger.debug("Placing entity \(element.id, privacy: .public) at \(entity.position)")
            content.add(entity)
            entityMap[element.id] = entity
        }
        updateConnections(in: content)
        addCoordinateGrid(to: content)
    }
    
    /// Draws lines for each edge specified by fromId/toId on edge elements.
    func updateConnections(in content: RealityViewContent) {
        // Remove existing lines
        lineEntities.forEach { content.remove($0) }
        lineEntities.removeAll()

        // For each element that defines an edge, connect fromId -> toId
        for edge in elements {
            if let from = edge.fromId, let to = edge.toId,
               let line = createLineBetween(from, and: to) {
                content.add(line)
                lineEntities.append(line)
            }
        }
    }

    func addCoordinateGrid(to content: RealityViewContent) {
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

        // Place grid and axes at eye level and forward offset
        let origin = SIMD3<Float>(0, Constants.eyeLevel, Constants.frontOffset)

        // X Axis (Red)
        content.add(axis(from: origin, to: origin + SIMD3(axisLength, 0, 0), color: .red))
        // Y Axis (Green)
        content.add(axis(from: origin, to: origin + SIMD3(0, axisLength, 0), color: .green))
        // Z Axis (Blue)
        content.add(axis(from: origin, to: origin + SIMD3(0, 0, axisLength), color: .blue))

        // Optional: Ground grid or XY plane
        let gridSize = 2
        for i in -gridSize...gridSize {
            let offset = Float(i) * 0.1
            // X grid lines
            content.add(axis(from: origin + SIMD3(-0.5, 0, offset), to: origin + SIMD3(0.5, 0, offset), color: .gray))
            // Z grid lines
            content.add(axis(from: origin + SIMD3(offset, 0, -0.5), to: origin + SIMD3(offset, 0, 0.5), color: .gray))
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
        // Compute new position based on start + translation
        if let start = draggingStartPosition {
            // translation3D already yields SIMD3<Float>
            let translation3D = value.gestureValue.translation3D
            value.entity.position = start + translation3D
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
