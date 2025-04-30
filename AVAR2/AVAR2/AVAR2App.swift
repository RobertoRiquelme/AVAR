//
//  AVAR2App.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI

@main
struct AVAR2: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some Scene {
        
        // 1. 2D launcher
        WindowGroup {
            VStack {
                Text("Launch Immersive Experience")
                    .font(.title)
                    .padding()

                Button("Enter Immersive Space") {
                    Task {
                        await openImmersiveSpace(id: "MainImmersive")
                    }
                }
                .font(.title2)
            }
        }

        // 2. Full immersive spatial scene
        ImmersiveSpace(id: "MainImmersive") {
            ContentView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
