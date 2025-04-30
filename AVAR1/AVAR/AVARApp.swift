//
//  AVARApp.swift
//  AVAR
//
//  Created by Roberto Riquelme on 22-04-25.
//

import SwiftUI
import RealityKit

@main
struct VisionProShapesApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup {
            FallbackView()
        }
        ImmersiveSpace(id: "MainImmersive") {
            ContentView()
        }
    }
}
