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

@MainActor
class ElementViewModel: ObservableObject {
    private(set) var elements: [ElementDTO] = []
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
            self.elements = try ElementService.loadElements(from: filename)
        } catch {
            print("Error loading data: \(error)")
        }
    }

    func loadElements(in content: RealityViewContent) {
        // Keep a reference for dynamic updates
        self.sceneContent = content
        for element in elements {
            guard let position = element.position else { continue }
            let entity = createEntity(for: element)
            //entity.position = SIMD3(Float(position[0]), Float(position[1]), position.count > 2 ? Float(position[2]) : 0)
            let x = Float(position[0])/100.0
            let y = Float(position[1])/100.0
            let z = Float(position.count > 2 ? position[2] : 0) - 1.0 // 👈 Shift everything 1m forward
            entity.position = SIMD3(x, y, z)
            print("Entity '\(element.id)' placed at \(entity.position)")
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

        let origin = SIMD3<Float>(0, 0, -1)

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
        // Determine mesh based on shapeDescription
        let mesh: MeshResource
        let material = createMaterial(from: element)
        let desc = element.shape?.shapeDescription?.lowercased() ?? ""
        let extent = element.shape?.extent ?? []
        if desc.contains("box") {
            // Box: use 3D extents or default (scaled from data units)
            let size = SIMD3<Float>(
                extent.count > 0 ? Float(extent[0]) / 100.0 : 0.05,
                extent.count > 1 ? Float(extent[1]) / 100.0 : 0.05,
                extent.count > 2 ? Float(extent[2]) / 100.0 : 0.05
            )
            mesh = MeshResource.generateBox(size: size)
        } else if desc.contains("sphere") {
            // Sphere: radius scaled
            let radius = extent.count > 0 ? Float(extent[0]) / 100.0 : 0.05
            mesh = MeshResource.generateSphere(radius: radius)
        } else if desc.contains("cylinder") {
            // Cylinder: radius and height scaled
            let radius = extent.count > 0 ? Float(extent[0]) / 100.0 : 0.05
            let height = extent.count > 1 ? Float(extent[1]) / 100.0 : radius * 2
            mesh = MeshResource.generateCylinder(height: height, radius: radius)
        } else if desc.contains("cone") {
            // Cone: height and base radius scaled
            let radius = extent.count > 0 ? Float(extent[0]) / 100.0 : 0.05
            let height = extent.count > 1 ? Float(extent[1]) / 100.0 : radius * 2
            mesh = MeshResource.generateCone(height: height, radius: radius)
        } else {
            // Default small box
            mesh = MeshResource.generateBox(size: SIMD3<Float>(0.05, 0.05, 0.05))
        }

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

    private func createMaterial(from element: ElementDTO) -> SimpleMaterial {
        let color = element.color ?? element.shape?.color ?? [0.2, 0.4, 1.0, 1.0]
        let uiColor = UIColor(
            red: CGFloat(color[0]),
            green: CGFloat(color[1]),
            blue: CGFloat(color[2]),
            alpha: color.count > 3 ? CGFloat(color[3]) : 1.0
        )
        return SimpleMaterial(color: uiColor, isMetallic: false)
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
