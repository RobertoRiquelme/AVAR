//
//  ContentView.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ContentView: View {
    @StateObject private var viewModel = ElementViewModel()

    var body: some View {
        RealityView { content in
            
            let testBox = ModelEntity(mesh: .generateBox(size: 0.2), materials: [SimpleMaterial(color: .red, isMetallic: true)])
            testBox.position = SIMD3(1, 1, -1) // 1 meter in front of user
            content.add(testBox)
            
            viewModel.loadElements(in: content)
        } update: { content in
            viewModel.updateConnections(in: content)
        }
        .task {
            await viewModel.loadData(from: "2D Tree Layout") // confirm this file exists
            print("Loaded \(viewModel.elements.count) elements")
        }
        .onAppear { print("Visible") }
        .gesture(
            DragGesture(minimumDistance: 0).targetedToAnyEntity()
                .onChanged { value in
                    viewModel.handleDragChanged(value)
                }
                .onEnded { value in
                    viewModel.handleDragEnded(value)
                }
        )
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
