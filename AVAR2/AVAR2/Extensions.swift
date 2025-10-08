//
//  Extensions.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

// No custom 2D->3D translation override: relying on VisionOS built-in translation3D on DragGesture.Value

import simd

// MARK: - Matrix Transformation Helpers for Collaborative Sessions

extension simd_float4x4 {
    /// Creates a translation matrix from a SIMD3 position
    init(translationVector: SIMD3<Float>) {
        self.init(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(translationVector.x, translationVector.y, translationVector.z, 1)
        )
    }

    /// Extracts the translation component from a matrix
    var translationVector: SIMD3<Float> {
        return SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    /// Transforms a position vector by this matrix
    func transformPosition(_ position: SIMD3<Float>) -> SIMD3<Float> {
        let point = SIMD4<Float>(position.x, position.y, position.z, 1.0)
        let transformed = self * point
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    // Note: Manual anchor transformation methods removed
    // Modern approach (visionOS 2+): Use device-relative positions
    // SharedCoordinateSpaceProvider handles spatial alignment automatically
}

extension SIMD4 where Scalar == Float {
    /// Convenient access to xyz components
    var xyz: SIMD3<Float> {
        return SIMD3<Float>(x, y, z)
    }
}
