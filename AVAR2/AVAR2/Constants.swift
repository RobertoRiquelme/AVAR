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
