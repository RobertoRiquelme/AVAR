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

/// Context for normalizing positions and extents based on the overall data range.
struct NormalizationContext {
    /// True if the source JSON was 2D ("RTelements") rather than full 3D.
    let is2D: Bool
    /// Center of the data positions in each dimension.
    let positionCenters: [Double]
    /// Range (max - min) of the data positions in each dimension (non-zero).
    let positionRanges: [Double]

    /// Maximum range (span) across all dimensions; used to preserve aspect ratio.
    var globalRange: Double { positionRanges.max() ?? 1 }

    /// Build a normalization context from raw element positions.
    init(elements: [ElementDTO], is2D: Bool) {
        let dims = is2D ? 2 : 3
        var mins = [Double](repeating: .greatestFiniteMagnitude, count: dims)
        var maxs = [Double](repeating: -.greatestFiniteMagnitude, count: dims)
        for element in elements {
            if let coords = element.position {
                for i in 0..<dims {
                    let v = coords.count > i ? coords[i] : 0
                    mins[i] = min(mins[i], v)
                    maxs[i] = max(maxs[i], v)
                }
            }
        }
        var centers = [Double]()
        var ranges = [Double]()
        for i in 0..<dims {
            let minv = mins[i]
            let maxv = maxs[i]
            let range = maxv - minv
            centers.append((maxv + minv) / 2)
            ranges.append(range != 0 ? range : 1)
        }
        self.is2D = is2D
        self.positionCenters = centers
        self.positionRanges = ranges
    }
}

/// Extension on ElementDTO to produce a MeshResource and Material based on shapeDescription.
extension ElementDTO {
    /// Builds the mesh and material for this element, using the given normalization context.
    func meshAndMaterial(normalization: NormalizationContext) -> (mesh: MeshResource, material: SimpleMaterial) {
        // Determine base color
        let rgba = self.color ?? self.shape?.color ?? [0.2, 0.4, 1.0, 1.0]
        let uiColor = UIColor(
            red: CGFloat(rgba[0]),
            green: CGFloat(rgba[1]),
            blue: CGFloat(rgba[2]),
            alpha: rgba.count > 3 ? CGFloat(rgba[3]) : 1.0
        )
        let material = SimpleMaterial(color: uiColor, roughness: 0.5, isMetallic: false)

        let desc = shape?.shapeDescription?.lowercased() ?? ""
        let extent = shape?.extent ?? []

        func normalized(_ index: Int, defaultValue: Double) -> Float {
            guard index < extent.count else { return Float(defaultValue) }
            return Float(extent[index] / normalization.globalRange * 2)
        }

        let mesh: MeshResource
        if desc.contains("rt") {
            if desc.contains("box") {
                let w = normalized(0, defaultValue: 0.1)
                let h = normalized(1, defaultValue: 0.1)
                let d = normalized(2, defaultValue: 0.01)
                mesh = MeshResource.generateBox(size: SIMD3(w, h, d))
            } else if desc.contains("ellipse") {
                let h = normalized(0, defaultValue: 0.01)
                let r = normalized(1, defaultValue: Double(h * 2))
                mesh = MeshResource.generateCylinder(height: h, radius: r)
            } else {
                mesh = MeshResource.generateBox(size: SIMD3<Float>(0, 0, 0))
            }
        } else {
            if desc.contains("cube") {
                let w = normalized(0, defaultValue: 0.1)
                let h = normalized(1, defaultValue: 0.1)
                let d = normalized(2, defaultValue: 0.1)
                mesh = MeshResource.generateBox(size: SIMD3(w, h, d))
            } else if desc.contains("sphere") {
                let r = normalized(0, defaultValue: 0.05)
                mesh = MeshResource.generateSphere(radius: r)
            } else if desc.contains("cylinder") {
                let r = normalized(0, defaultValue: 0.05)
                let h = normalized(1, defaultValue: Double(r * 2))
                mesh = MeshResource.generateCylinder(height: h, radius: r)
            } else if desc.contains("cone") {
                let r = normalized(0, defaultValue: 0.05)
                let h = normalized(1, defaultValue: Double(r * 2))
                mesh = MeshResource.generateCone(height: h, radius: r)
            } else {
                mesh = MeshResource.generateBox(size: SIMD3<Float>(0, 0, 0))
            }
        }

        return (mesh, material)
    }
}
