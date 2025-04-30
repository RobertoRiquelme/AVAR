//
//  ContentView.swift
//  AVAR
//
//  Created by Roberto Riquelme on 22-04-25.
//

import SwiftUI
import RealityKit

struct ContentView: View {
    var body: some View {
        RealityView { content in
            let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, -0.5))
            do {
                let wrapper = try JSONDecoder().decode(SceneWrapper.self, from: sampleJSON.data(using: .utf8)!)
                let sceneData = wrapper.scene
                for object in sceneData.objects {
                    let entity = try makeEntity(for: object)
                    anchor.addChild(entity)
                }
                for connection in sceneData.connections {
                    if let line = makeConnection(from: connection, in: sceneData.objects) {
                        anchor.addChild(line)
                    }
                }

                // Add a debug box for visibility check
                let debugBox = ModelEntity(mesh: .generateBox(size: 0.1))
                debugBox.model?.materials = [SimpleMaterial(color: .white, isMetallic: false)]
                debugBox.position = [0, 0.1, 0]
                anchor.addChild(debugBox)

                content.add(anchor)
            } catch {
                print("Failed to load scene: \(error)")
            }
        }
    }
}
