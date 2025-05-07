//
//  Extensions.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import Foundation
import SwiftUI
import simd

extension DragGesture.Value {
    /// Convert 2D drag translation to a 3D offset in world space.
    /// X tracks horizontal finger movement, Y tracks vertical (inverted so dragging up moves up).
    var translation3D: SIMD3<Float> {
        SIMD3(
            Float(translation.width)  / 500,
            -Float(translation.height) / 500,
            0
        )
    }
}
