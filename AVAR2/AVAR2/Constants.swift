//
//  Constants.swift
//  AVAR2
//
//  Created automatically to centralize magic numbers.
//

import Foundation

/// Global constants for world scale and placement.
enum Constants {
    /// Scale factor from data units to meters (e.g. 1 data unit = 0.01 m).
    static let worldScale: Float = 0.01
    /// Vertical offset for placing content at eye level (meters).
    static let eyeLevel: Float = 0.0
    /// Forward offset to move content in front of the camera (meters).
    static let frontOffset: Float = -1.0
}