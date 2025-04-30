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
    var translation3D: SIMD3<Float> {
        SIMD3(Float(translation.width) / 500, Float(translation.height) / 500, 0)
    }
}
