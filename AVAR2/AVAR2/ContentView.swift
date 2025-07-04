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
    @State private var currentSceneContent: RealityViewContent?
    
    private var surfaceDetector: ARKitSurfaceDetector {
        appModel.surfaceDetector
    }
    
    /// Updates surface anchors in the viewModel when new surfaces are detected
    private func updateSurfaceAnchors() {
        // Convert PlaneAnchors to AnchorEntities for compatibility with existing ViewModel
        let newAnchorEntities = surfaceDetector.surfaceAnchors.compactMap { planeAnchor -> AnchorEntity? in
            let anchorEntity = AnchorEntity()
            anchorEntity.name = "surface_\(planeAnchor.id)"
            anchorEntity.transform = Transform(matrix: planeAnchor.originFromAnchorTransform)
            return anchorEntity
        }
        
        // Update viewModel with detected surfaces
        viewModel.detectedSurfaceAnchors = newAnchorEntities
    }
    
    var body: some View {
        RealityView { content in
            currentSceneContent = content
            // Add surface detector's root entity for surface visualization
            content.add(surfaceDetector.rootEntity)
            // Load and display the diagram elements
            viewModel.loadElements(in: content, onClose: onClose)
        } update: { content in
            currentSceneContent = content
            // Update connections as needed
            viewModel.updateConnections(in: content)
        }
        .task {
            await viewModel.loadData(from: filename)
            // Start ARKit surface detection only once
            await appModel.startSurfaceDetectionIfNeeded()
        }
        .onChange(of: surfaceDetector.surfaceAnchors) { _, newAnchors in
            updateSurfaceAnchors()
        }
        // Combined drag gesture: element drag vs window pan via grab handle
        .gesture(
            DragGesture(minimumDistance: 0).targetedToAnyEntity()
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
        // Pinch gesture (on any entity) to zoom whole diagram, pivoting around touched entity
//        .simultaneousGesture(
//            MagnificationGesture().targetedToAnyEntity()
//                .onChanged { value in
//                    viewModel.handleZoomChanged(value)
//                }
//                .onEnded { value in
//                    viewModel.handleZoomEnded(value)
//                }
//        )
        // Alert on load error
        .alert("Error Loading Data", isPresented: Binding(
            get: { viewModel.loadErrorMessage != nil },
            set: { if !$0 { viewModel.loadErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.loadErrorMessage = nil }
        } message: {
            Text(viewModel.loadErrorMessage ?? "Unknown error.")
        }
        .overlay(alignment: .center) {
            if !viewModel.snapStatusMessage.isEmpty {
                Text(viewModel.snapStatusMessage)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .padding(.top, 20)
                    .transition(.opacity)
                    .zIndex(100)
            }
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
