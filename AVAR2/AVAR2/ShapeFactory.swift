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
        let material = createMaterial()
        let mesh = createMesh(normalization: normalization)
        return (mesh, material)
    }
    
    private func createMaterial() -> SimpleMaterial {
        let rgba = self.color ?? self.shape?.color ?? [0.2, 0.4, 1.0, 1.0]
        let uiColor = UIColor(
            red: CGFloat(rgba[0]),
            green: CGFloat(rgba[1]),
            blue: CGFloat(rgba[2]),
            alpha: rgba.count > 3 ? CGFloat(rgba[3]) : 1.0
        )
        return SimpleMaterial(color: uiColor, roughness: 0.5, isMetallic: false)
    }
    
    private func createMesh(normalization: NormalizationContext) -> MeshResource {
        let desc = shape?.shapeDescription?.lowercased() ?? ""
        let extent = shape?.extent ?? []
        let normalized = createNormalizationFunction(extent: extent, normalization: normalization)

        if desc.contains("rt") {
            return createRTMesh(desc: desc, normalized: normalized)
        } else {
            return create3DMesh(desc: desc, normalized: normalized)
        }
    }
    
    private func createNormalizationFunction(extent: [Double], normalization: NormalizationContext) -> (Int, Double) -> Float {
        return { index, defaultValue in
            guard index < extent.count else {
                return Float(defaultValue)
            }
            return Float(extent[index] / normalization.globalRange * 2)
        }
    }
    
    private func createRTMesh(desc: String, normalized: (Int, Double) -> Float) -> MeshResource {
        if desc.contains("label") {
            // Labels should render as 3D text, not boxes
            return createRTLabel(normalized: normalized)
        } else if desc.contains("box") {
            return createRTBox(normalized: normalized)
        } else if desc.contains("ellipse") {
            return createRTEllipse(normalized: normalized)
        } else {
            print("⚠️ Unknown RT shape: '\(desc)' - using fallback")
            return createEmptyMesh()
        }
    }
    
    private func create3DMesh(desc: String, normalized: (Int, Double) -> Float) -> MeshResource {
        if desc.contains("cube") || desc.contains("box") {
            return createCube(normalized: normalized)
        } else if desc.contains("sphere") {
            return createSphere(normalized: normalized)
        } else if desc.contains("cylinder") {
            return createCylinder(normalized: normalized)
        } else if desc.contains("cone") {
            return createCone(normalized: normalized)
        } else {
            print("⚠️ Unknown 3D shape: '\(desc)'")
            return createEmptyMesh()
        }
    }
    
    private func createRTBox(normalized: (Int, Double) -> Float) -> MeshResource {
        let w = normalized(0, 0.1)
        let h = normalized(1, 0.1)
        let d = normalized(2, 0.01)
        return MeshResource.generateBox(size: SIMD3(w, h, d))
    }
    
    private func createRTEllipse(normalized: (Int, Double) -> Float) -> MeshResource {
        let h = normalized(0, 0.01)
        let r = normalized(1, Double(h * 2))
        return MeshResource.generateCylinder(height: h, radius: r)
    }

    private func createRTLabel(normalized: (Int, Double) -> Float) -> MeshResource {
        // For labels, use the text if available
        let text = shape?.text ?? id ?? "?"
        let w = normalized(0, 0.1)
        let h = normalized(1, 0.05)

        // Try to create 3D text mesh
        do {
            let textMesh = MeshResource.generateText(
                text,
                extrusionDepth: 0.01,
                font: .systemFont(ofSize: 0.08),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byTruncatingTail
            )
            return textMesh
        } catch {
            // Fallback to a small box if text generation fails
            return MeshResource.generateBox(size: SIMD3(w, h, 0.01))
        }
    }

    private func createCube(normalized: (Int, Double) -> Float) -> MeshResource {
        let w = max(0.01, normalized(0, 0.1))
        let h = max(0.01, normalized(1, 0.1))
        let d = max(0.01, normalized(2, 0.1))
        return MeshResource.generateBox(size: SIMD3(w, h, d))
    }

    private func createSphere(normalized: (Int, Double) -> Float) -> MeshResource {
        let r = max(0.01, normalized(0, 0.05))
        return MeshResource.generateSphere(radius: r)
    }

    private func createCylinder(normalized: (Int, Double) -> Float) -> MeshResource {
        let r = max(0.01, normalized(0, 0.05))
        let h = max(0.01, normalized(1, Double(r * 2)))
        return MeshResource.generateCylinder(height: h, radius: r)
    }

    private func createCone(normalized: (Int, Double) -> Float) -> MeshResource {
        let r = max(0.01, normalized(0, 0.05))
        let h = max(0.01, normalized(1, Double(r * 2)))
        return MeshResource.generateCone(height: h, radius: r)
    }
    
    private func createEmptyMesh() -> MeshResource {
        // Fallback cube for unrecognized shapes
        return MeshResource.generateBox(size: SIMD3<Float>(0.1, 0.1, 0.1))
    }
}
