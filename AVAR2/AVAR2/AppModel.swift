//
//  AppModel.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.open
    
    // Simple ARKit surface detector
    let surfaceDetector = ARKitSurfaceDetector()
    private var surfaceDetectionStarted = false
    
    func startSurfaceDetectionIfNeeded() async {
        guard !surfaceDetectionStarted else { return }
        surfaceDetectionStarted = true
        await surfaceDetector.run()
    }
}
