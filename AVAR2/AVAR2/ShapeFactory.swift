//
//  ShapeFactory.swift
//  AVAR2
//
//  Created automatically to isolate mesh/material generation.
//

import RealityKit
import SwiftUI
import simd
import OSLog

/// Extension on ElementDTO to produce a MeshResource and Material based on shapeDescription.
extension ElementDTO {
    /// Builds the mesh and material for this element.
    func meshAndMaterial() -> (mesh: MeshResource, material: SimpleMaterial) {
        // Determine base color
        let rgba = self.color ?? self.shape?.color ?? [0.2, 0.4, 1.0, 1.0]
        let uiColor = UIColor(
            red: CGFloat(rgba[0]),
            green: CGFloat(rgba[1]),
            blue: CGFloat(rgba[2]),
            alpha: rgba.count > 3 ? CGFloat(rgba[3]) : 1.0
        )
        let material = SimpleMaterial(color: uiColor, roughness: 0.5, isMetallic: false)

        // Shape descriptor and dimension array
        let desc = shape?.shapeDescription?.lowercased() ?? ""
        let extent = shape?.extent ?? []

        // Select mesh primitive
        let mesh: MeshResource
        
        // Generate 2D
        // Box, Ellipse, label, edge, element
        if desc.contains("rt") {
            if desc.contains("box") {
                let width  = extent.count > 0 ? Float(extent[0]) * Constants.worldScale2D : 0.1
                let height = extent.count > 1 ? Float(extent[1]) * Constants.worldScale2D : 0.1
                let depth  = extent.count > 2 ? Float(extent[2]) * Constants.worldScale2D : 0.1
                mesh = MeshResource.generateBox(size: SIMD3(width, height, depth))
            } else if desc.contains("ellipse") {
                let height = extent.count > 0 ? Float(extent[0]) * Constants.worldScale2D : 0.05
                let radius = extent.count > 1 ? Float(extent[1]) * Constants.worldScale2D : height * 2
                mesh = MeshResource.generateCylinder(height: height, radius: radius)
            } else {
                // Default mesh: small box
                mesh = MeshResource.generateBox(size: SIMD3<Float>(0.0, 0.0, 0.0))
            }
        }
        // Generate 3D
        else {
            if desc.contains("cube") {
                let width  = extent.count > 0 ? Float(extent[0]) * Constants.worldScale3D : 0.1
                let height = extent.count > 1 ? Float(extent[1]) * Constants.worldScale3D : 0.1
                let depth  = extent.count > 2 ? Float(extent[2]) * Constants.worldScale3D : 0.1
                mesh = MeshResource.generateBox(size: SIMD3(width, height, depth))
            } else if desc.contains("sphere") {
                let radius = extent.count > 0 ? Float(extent[0]) * Constants.worldScale3D : 0.05
                mesh = MeshResource.generateSphere(radius: radius)
            } else if desc.contains("cylinder") {
                let radius = extent.count > 0 ? Float(extent[0]) * Constants.worldScale3D : 0.05
                let height = extent.count > 1 ? Float(extent[1]) * Constants.worldScale3D : radius * 2
                mesh = MeshResource.generateCylinder(height: height, radius: radius)
            } else if desc.contains("cone") {
                let radius = extent.count > 0 ? Float(extent[0]) * Constants.worldScale3D : 0.05
                let height = extent.count > 1 ? Float(extent[1]) * Constants.worldScale3D : radius * 2
                mesh = MeshResource.generateCone(height: height, radius: radius)
            } else {
                // Default mesh: small box
                mesh = MeshResource.generateBox(size: SIMD3<Float>(0.0, 0.0, 0.0))
            }
        }

        return (mesh, material)
    }
}
