//
//  ShapeFactory.swift
//  AVAR
//
//  Created by Roberto Riquelme on 22-04-25.
//

// ShapeFactory.swift
import RealityKit
import Foundation

func makeEntity(for shape: Shape) throws -> Entity {
    let entity: ModelEntity
    switch shape.type {
    case .cube:
        guard let size = shape.size else { throw ShapeError.missingSize }
        entity = ModelEntity(mesh: .generateBox(size: [size.width, size.height, size.depth]))
    case .sphere:
        guard let radius = shape.radius else { throw ShapeError.missingRadius }
        entity = ModelEntity(mesh: .generateSphere(radius: radius))
    case .cylinder:
        guard let radius = shape.radius, let height = shape.height else { throw ShapeError.missingCylinderData }
        entity = ModelEntity(mesh: .generateCylinder(height: height, radius: radius))
    }
    
    if let color = shape.color.colorFromHex {
        entity.model?.materials = [SimpleMaterial(color: color, isMetallic: false)]
    }
    
    entity.position = SIMD3(x: shape.position.x, y: shape.position.y, z: shape.position.z)
    if let rotation = shape.rotation {
        entity.orientation = simd_quatf(angle: rotation.y * .pi / 180, axis: [0, 1, 0])
    }
    
    print("Created \(shape.type) with id: \(shape.id)")
    return entity
}

func makeConnection(from connection: Connection, in objects: [Shape]) -> ModelEntity? {
    guard
        let fromShape = objects.first(where: { $0.id == connection.from }),
        let toShape = objects.first(where: { $0.id == connection.to })
    else { return nil }
    
    let start = SIMD3<Float>(x: fromShape.position.x, y: fromShape.position.y, z: fromShape.position.z)
    let end = SIMD3<Float>(x: toShape.position.x, y: toShape.position.y, z: toShape.position.z)
    let direction = normalize(end - start)
    let distance = length(end - start)
    
    let mesh = MeshResource.generateBox(size: [0.005, 0.005, distance])
    let material = SimpleMaterial(color: connection.color.colorFromHex ?? .gray, isMetallic: false)
    let lineEntity = ModelEntity(mesh: mesh, materials: [material])
    lineEntity.position = (start + end) / 2
    lineEntity.look(at: end, from: lineEntity.position, relativeTo: nil)
    print("Connected \(connection.from) to \(connection.to)")
    return lineEntity
}

enum ShapeError: Error {
    case missingSize, missingRadius, missingCylinderData
}
