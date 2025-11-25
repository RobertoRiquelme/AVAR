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

private let shapeFactoryLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "ShapeFactory")

/// Thread-safe cache for reusable mesh resources
final class MeshCache: @unchecked Sendable {
    static let shared = MeshCache()

    private var cache: [String: MeshResource] = [:]
    private let lock = NSLock()

    private init() {}

    func mesh(for key: String, generator: () -> MeshResource?) -> MeshResource? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[key] {
            return cached
        }

        guard let newMesh = generator() else { return nil }
        cache[key] = newMesh
        return newMesh
    }

    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}

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
        // RS shapes store type directly in element.type, not in shape.shapeDescription
        let desc = (shape?.shapeDescription ?? type).lowercased()
        // For RS shapes, extent is at element level, not in shape
        let extent = shape?.extent ?? self.extent ?? []
        let normalized = createNormalizationFunction(extent: extent, normalization: normalization)

        if desc.contains("rt") {
            return createRTMesh(desc: desc, normalized: normalized)
        } else if desc.contains("rs") {
            return createRSMesh(desc: desc, normalized: normalized)
        } else if desc.contains("rw") {
            return create3DMesh(desc: desc, normalized: normalized)
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

    private func createRSMesh(desc: String, normalized: (Int, Double) -> Float) -> MeshResource {
        // RS shapes (Roassal) - similar to RT but with slight differences
        if desc.contains("label") {
            return createRTLabel(normalized: normalized) // Reuse RT label
        } else if desc.contains("box") {
            return createRTBox(normalized: normalized) // Reuse RT box
        } else if desc.contains("circle") {
            return createRSCircle(normalized: normalized) // Use specialized RSCircle handler
        } else if desc.contains("polygon") {
            return createRSPolygon(normalized: normalized)
        } else if desc.contains("composite") {
            // Composite nodes are handled at the decoder level, shouldn't reach here
            return createEmptyMesh()
        } else {
            print("⚠️ Unknown RS shape: '\(desc)' - using fallback")
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
        let d = normalized(2, 0.001)  // Minimal depth for 2D diagrams
        return MeshResource.generateBox(size: SIMD3(w, h, d))
    }
    
    private func createRTEllipse(normalized: (Int, Double) -> Float) -> MeshResource {
        let h = normalized(0, 0.001)  // Minimal depth for 2D diagrams
        let r = normalized(1, Double(h * 2))
        return MeshResource.generateCylinder(height: h, radius: r)
    }

    private func createRSCircle(normalized: (Int, Double) -> Float) -> MeshResource {
        // RSCircle extent is [diameter, diameter], not [height, radius]
        // Use extent[0] as diameter to calculate radius
        let diameter = normalized(0, 0.05)  // Default to 0.05 if no extent
        let radius = diameter / 2.0
        let height: Float = 0.001  // Minimal depth for 2D diagrams
        return MeshResource.generateCylinder(height: height, radius: radius)
    }

    private func createRTLabel(normalized: (Int, Double) -> Float) -> MeshResource {
        // For labels, use the text if available
        let text = shape?.text ?? id ?? "?"
        let w = normalized(0, 0.1)
        let h = normalized(1, 0.05)

        // Try to create 3D text mesh with minimal extrusion depth for 2D
        do {
            let textMesh = MeshResource.generateText(
                text,
                extrusionDepth: 0.001,  // Minimal depth for 2D diagrams
                font: .systemFont(ofSize: 0.08),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byTruncatingTail
            )
            return textMesh
        } catch {
            // Fallback to a small box if text generation fails
            return MeshResource.generateBox(size: SIMD3(w, h, 0.001))
        }
    }

    private func createCube(normalized: (Int, Double) -> Float) -> MeshResource {
        let w = max(0.01, normalized(0, 0.1))
        let h = max(0.01, normalized(1, 0.1))
        let d = max(0.01, normalized(2, 0.1))
        return cachedBox(size: SIMD3(w, h, d))
    }

    private func createSphere(normalized: (Int, Double) -> Float) -> MeshResource {
        let r = max(0.01, normalized(0, 0.05))
        return cachedSphere(radius: r)
    }

    private func createCylinder(normalized: (Int, Double) -> Float) -> MeshResource {
        let r = max(0.01, normalized(0, 0.05))
        let h = max(0.01, normalized(1, Double(r * 2)))
        return cachedCylinder(height: h, radius: r)
    }

    private func createCone(normalized: (Int, Double) -> Float) -> MeshResource {
        let r = max(0.01, normalized(0, 0.05))
        let h = max(0.01, normalized(1, Double(r * 2)))
        return cachedCone(height: h, radius: r)
    }
    
    private func createRSPolygon(normalized: (Int, Double) -> Float) -> MeshResource {
        // RSPolygon is used for arrow markers - create a simple triangle
        guard let points = shape?.points, points.count >= 3 else {
            // Fallback to a small triangle if no points specified
            return createTriangleMesh(size: 0.02)
        }

        // For now, create a simple triangle mesh
        // In a full implementation, you would use the points array to create a custom polygon
        return createTriangleMesh(size: 0.02)
    }

    private func createTriangleMesh(size: Float) -> MeshResource {
        let cacheKey = "triangle_\(size)"
        if let cached = MeshCache.shared.mesh(for: cacheKey, generator: {
            // Create a simple triangle for arrow heads
            var descriptor = MeshDescriptor()

            // Triangle vertices (pointing right)
            let positions: [SIMD3<Float>] = [
                SIMD3(0, size/2, 0),      // Top
                SIMD3(0, -size/2, 0),     // Bottom
                SIMD3(size, 0, 0)         // Tip (right)
            ]

            descriptor.positions = .init(positions)

            // Triangle indices
            descriptor.primitives = .triangles([0, 1, 2])

            do {
                return try MeshResource.generate(from: [descriptor])
            } catch {
                shapeFactoryLogger.error("Failed to generate triangle mesh: \(error.localizedDescription)")
                return nil
            }
        }) {
            return cached
        }
        // Fallback if cache generation failed
        return createEmptyMesh()
    }

    private func createEmptyMesh() -> MeshResource {
        let cacheKey = "fallback_box_0.1"
        return MeshCache.shared.mesh(for: cacheKey, generator: {
            MeshResource.generateBox(size: SIMD3<Float>(0.1, 0.1, 0.1))
        }) ?? MeshResource.generateBox(size: SIMD3<Float>(0.1, 0.1, 0.1))
    }

    // MARK: - Cached Mesh Generation Helpers

    private func cachedBox(size: SIMD3<Float>) -> MeshResource {
        let cacheKey = "box_\(size.x)_\(size.y)_\(size.z)"
        return MeshCache.shared.mesh(for: cacheKey, generator: {
            MeshResource.generateBox(size: size)
        }) ?? MeshResource.generateBox(size: size)
    }

    private func cachedSphere(radius: Float) -> MeshResource {
        let cacheKey = "sphere_\(radius)"
        return MeshCache.shared.mesh(for: cacheKey, generator: {
            MeshResource.generateSphere(radius: radius)
        }) ?? MeshResource.generateSphere(radius: radius)
    }

    private func cachedCylinder(height: Float, radius: Float) -> MeshResource {
        let cacheKey = "cylinder_\(height)_\(radius)"
        return MeshCache.shared.mesh(for: cacheKey, generator: {
            MeshResource.generateCylinder(height: height, radius: radius)
        }) ?? MeshResource.generateCylinder(height: height, radius: radius)
    }

    private func cachedCone(height: Float, radius: Float) -> MeshResource {
        let cacheKey = "cone_\(height)_\(radius)"
        return MeshCache.shared.mesh(for: cacheKey, generator: {
            MeshResource.generateCone(height: height, radius: radius)
        }) ?? MeshResource.generateCone(height: height, radius: radius)
    }
}
