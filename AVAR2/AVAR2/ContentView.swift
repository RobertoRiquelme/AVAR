//
//  ContentView.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI
import RealityKit
import RealityKitContent
import ARKit

/// Displays an immersive graph based on a selected example file.
struct ContentView: View {
    /// The resource filename (without extension) to load.
    var filename: String = "2D Tree Layout"
    var onClose: (() -> Void)? = nil
    @StateObject private var viewModel = ElementViewModel()
    @Environment(AppModel.self) private var appModel
    @Environment(\.collaborativeSessionManager) private var collaborativeManager

    var body: some View {
        RealityView { content in
            viewModel.loadElements(in: content, onClose: onClose)
        } update: { content in
            viewModel.updateConnections(in: content)
        }
        .enableCollaborativeSession { isActive in
            print("📡 Collaborative session state changed for \(filename): \(isActive)")
        }
        .task {
            print("📋 ContentView task started for: \(filename)")
            viewModel.setAppModel(appModel)
            viewModel.setCollaborativeManager(collaborativeManager)
            await viewModel.loadData(from: filename)
            print("📋 ContentView task completed for: \(filename)")
        }
        .gesture(
            DragGesture(minimumDistance: 5).targetedToAnyEntity()  // Small threshold like native visionOS
                .onChanged { value in
                    var entity: Entity? = value.entity
                    while let current = entity {
                        let name = current.name
                        if name.starts(with: "element_") && !viewModel.isGraph2D {
                            viewModel.handleDragChanged(value)
                            return
                        } else if name == "grabHandle" {
                            viewModel.handlePanChanged(value)
                            return
                        } else if name == "zoomHandle" {
                            viewModel.handleZoomHandleDragChanged(value)
                            return
                        } else if name == "rotationButton" {
                            viewModel.handleRotationButtonDragChanged(value)
                            return
                        }
                        entity = current.parent
                    }
                }
                .onEnded { value in
                    var entity: Entity? = value.entity
                    while let current = entity {
                        let name = current.name
                        if name.starts(with: "element_") && !viewModel.isGraph2D {
                            viewModel.handleDragEnded(value)
                            return
                        } else if name == "grabHandle" {
                            viewModel.handlePanEnded(value)
                            return
                        } else if name == "zoomHandle" {
                            viewModel.handleZoomHandleDragEnded(value)
                            return
                        } else if name == "rotationButton" {
                            viewModel.handleRotationButtonDragEnded(value)
                            return
                        }
                        entity = current.parent
                    }
                }
        )
        .simultaneousGesture(
            TapGesture().targetedToAnyEntity()
                .onEnded { value in
                    var entity: Entity? = value.entity
                    while let current = entity {
                        if current.name == "closeButton" {
                            onClose?()
                            break
                        }
                        entity = current.parent
                    }
                }
        )
        .alert("Error Loading Data", isPresented: Binding(
            get: { viewModel.loadErrorMessage != nil },
            set: { if !$0 { viewModel.loadErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.loadErrorMessage = nil }
        } message: {
            Text(viewModel.loadErrorMessage ?? "Unknown error.")
        }
    }
}

// MARK: - Previews
#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(filename: "Simple Tree")
            //.environment(AppModel())
    }
}
#endif