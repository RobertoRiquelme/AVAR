//
//  Constants.swift
//  AVAR2
//
//  Created automatically to centralize magic numbers.
//

import Foundation

/// Global constants for world scale and placement.
enum Constants {
    /// World Scale factor from data units to meters (e.g. 1 data unit = 0.01 m).
    static let worldScale: Float = 0.005
    /// 2D Scale factor from data units to meters (e.g. 1 data unit = 0.01 m).
    static let worldScale2D: Float = 0.005
    /// 3D Scale factor from data units to meters (e.g. 1 data unit = 0.01 m).
    static let worldScale3D: Float = 0.1
    /// Vertical offset for placing content at eye level (meters).
    /// Typical eye height is ~1.6 meters.
    static let eyeLevel: Float = 1.0
    /// Forward offset to move
    ///  content in front of the camera (meters).
    static let frontOffset: Float = -2.0
    /// Scale factor for 3D drag translation: smaller values reduce sensitivity.
    static let dragTranslationScale: Float = 0.001

    // MARK: - Surface Snapping Constants
    /// Distance threshold for snapping to surfaces (meters)
    static let snapDistance: Float = 1.0
    /// Distance threshold for releasing snap (meters)
    static let snapThreshold: Float = 1.0
    /// Distance threshold for releasing from snapped surface (meters)
    static let releaseThreshold: Float = 1.0
    /// Offset distance from surface when snapped (meters)
    static let surfaceSnapOffset: Float = 0.05

    // MARK: - Gesture Constants
    /// Minimum drag distance to recognize gesture
    static let minimumDragDistance: CGFloat = 5
    /// Pan sensitivity multiplier
    static let panSensitivity: Float = 0.0008
    /// Rotation sensitivity multiplier
    static let rotationSensitivity: Float = 0.001
    /// Zoom scale sensitivity multiplier
    static let zoomScaleSensitivity: Float = 0.001
    /// Minimum allowed zoom scale
    static let minZoomScale: Float = 0.3
    /// Maximum allowed zoom scale
    static let maxZoomScale: Float = 2.0

    // MARK: - Spatial Boundaries
    /// Comfortable viewing boundaries for spatial content
    enum SpatialBoundaries {
        static let minX: Float = -2.0
        static let maxX: Float = 2.0
        static let minY: Float = -1.0
        static let maxY: Float = 1.5
        static let minZ: Float = 0.5
        static let maxZ: Float = 3.0
        /// Optimal viewing distance from user (meters)
        static let comfortDistance: Float = 1.2
        /// Threshold for comfort zone snapping (meters)
        static let snapThreshold: Float = 0.1
        /// Interpolation factor for comfort snapping
        static let snapStrength: Float = 0.3
        /// Resistance threshold near boundaries (meters)
        static let resistanceThreshold: Float = 0.2
        /// Maximum resistance factor
        static let maxResistance: Float = 0.8
    }

    // MARK: - UI Element Sizes
    /// Grab handle dimensions
    enum GrabHandle {
        static let widthMultiplier: Float = 0.65
        static let height: Float = 0.018
        static let thickness: Float = 0.008
        static let margin: Float = 0.015
        static let cornerRadiusMultiplier: Float = 0.4
    }

    /// Close button dimensions
    enum CloseButton {
        static let radius: Float = 0.02
        static let thickness: Float = 0.008
        static let spacing: Float = 0.015
    }

    /// Zoom handle dimensions
    enum ZoomHandle {
        static let thickness: Float = 0.008
        static let length: Float = 0.08
        static let width: Float = 0.02
        static let cornerRadiusMultiplier: Float = 0.3
        static let margin: Float = 0.02
    }

    // MARK: - Throttling
    /// Update interval for collaborative sync (milliseconds)
    static let collaborativeSyncIntervalMs: Int = 16  // ~60 updates/sec

    // MARK: - HTTP Server
    /// Default HTTP server port
    static let httpServerPort: UInt16 = 8081
    /// Maximum request size (bytes)
    static let maxHttpRequestSize: Int = 5 * 1024 * 1024
    /// Maximum log entries to keep
    static let maxHttpLogEntries: Int = 50

    // MARK: - Layout Coordinator
    /// Default grid spacing for diagram placement (meters)
    static let defaultGridSpacing: Float = 0.9
    /// Maximum search radius for diagram placement
    static let maxLayoutSearchRadius: Int = 20
}

/// Runtime-configurable placement settings for diagrams in world space.
struct WorldPlacementConfiguration {
    var eyeLevel: Float
    var frontOffset: Float
    var gridSpacing: Float

    static var `default`: WorldPlacementConfiguration {
        WorldPlacementConfiguration(
            eyeLevel: Constants.eyeLevel,
            frontOffset: Constants.frontOffset,
            gridSpacing: 0.9
        )
    }
}
