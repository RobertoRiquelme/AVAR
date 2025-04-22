//
//  Model.swift
//  AVAR
//
//  Created by Roberto Riquelme on 22-04-25.
//

import Foundation
import simd

struct SceneWrapper: Codable {
    let scene: Scene
}

struct Scene: Codable {
    let objects: [Shape]
    let connections: [Connection]

    enum CodingKeys: String, CodingKey {
        case objects = "objects"
        case connections = "connections"
    }
}

struct Shape: Codable {
    let id: String
    let type: ShapeType
    let position: Vector3
    let rotation: Vector3?
    let size: Size3D?
    let radius: Float?
    let height: Float?
    let color: String
    let metadata: Metadata?

    enum CodingKeys: String, CodingKey {
        case id, type, position, rotation, size, radius, height, color, metadata
    }
}

struct Connection: Codable {
    let id: String
    let type: ConnectionType
    let from: String
    let to: String
    let color: String
    let thickness: Float?
    let metadata: Metadata?

    enum CodingKeys: String, CodingKey {
        case id, type, from, to, color, thickness, metadata
    }
}

enum ShapeType: String, Codable {
    case cube, sphere, cylinder
}

enum ConnectionType: String, Codable {
    case line, arrow
}

struct Vector3: Codable {
    let x: Float
    let y: Float
    let z: Float

    enum CodingKeys: String, CodingKey {
        case x, y, z
    }
}

struct Size3D: Codable {
    let width: Float
    let height: Float
    let depth: Float

    enum CodingKeys: String, CodingKey {
        case width, height, depth
    }
}

struct Metadata: Codable {
    let label: String?

    enum CodingKeys: String, CodingKey {
        case label
    }
}
