//
//  ContentView.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI
import RealityKit

#if os(visionOS)
import RealityKitContent

#if canImport(ARKit)
import ARKit
#endif

/// Displays an immersive graph based on a selected example file.
struct ContentView: View {
    /// The resource filename (without extension) to load.
    var filename: String = "2D Tree Layout"
    var onClose: (() -> Void)? = nil
    @StateObject private var viewModel = ElementViewModel()
    @Environment(AppModel.self) private var appModel
    var collaborativeSession: CollaborativeSessionManager? = nil

    var body: some View {
        RealityView { content in
            viewModel.loadElements(in: content, onClose: onClose)
        } update: { content in
            viewModel.updateConnections(in: content)
        }
        .task {
            print("📋 ContentView task started for: \(filename)")
            viewModel.setAppModel(appModel)
            await viewModel.loadData(from: filename)

            // Throttler for collaborative sync (class to allow mutation in closure)
            class UpdateThrottler {
                var lastUpdateTime = ContinuousClock.now
                let updateInterval: Duration = .milliseconds(100) // Max 10 updates/second

                func shouldUpdate() -> Bool {
                    let now = ContinuousClock.now
                    if lastUpdateTime.advanced(by: updateInterval) <= now {
                        lastUpdateTime = now
                        return true
                    }
                    return false
                }
            }
            let throttler = UpdateThrottler()

            // Set up transform change callback for collaborative sync
            viewModel.onTransformChanged = { position, orientation, scale in
                // Throttle updates to avoid lag during drag
                guard throttler.shouldUpdate() else { return }
                guard let session = collaborativeSession else { return }

                let worldPosition: SIMD3<Float>
                if let sharedAnchor = session.sharedAnchor {
                    // Transform to anchor-local coordinates (fast operation)
                    worldPosition = simd_float4x4.toAnchorSpace(worldPosition: position, anchorTransform: sharedAnchor.transform)
                } else {
                    worldPosition = position
                }

                // Update collaborative session (network call - expensive)
                session.updateDiagramTransform(
                    filename: filename,
                    worldPosition: worldPosition,
                    worldOrientation: orientation,
                    worldScale: scale
                )
            }

            // Share initial position with collaborative session
            if let transform = viewModel.getWorldTransform(),
               collaborativeSession?.isSessionActive == true,
               !collaborativeSession!.sharedDiagrams.contains(where: { $0.filename == filename }) {
                do {
                    let elements = try DiagramDataLoader.loadScriptOutput(from: filename).elements

                    // Transform to anchor-local coordinates before sharing
                    let worldPosition: SIMD3<Float>
                    if let sharedAnchor = collaborativeSession?.sharedAnchor {
                        // Transform to anchor's local coordinate system
                        worldPosition = simd_float4x4.toAnchorSpace(worldPosition: transform.position, anchorTransform: sharedAnchor.transform)
                        print("📍 Initial share for '\(filename)': world \(transform.position) → anchor-local \(worldPosition)")
                    } else {
                        worldPosition = transform.position
                        print("⚠️ Initial share for '\(filename)' without shared anchor")
                    }

                    collaborativeSession?.shareDiagram(
                        filename: filename,
                        elements: elements,
                        worldPosition: worldPosition,
                        worldOrientation: transform.orientation,
                        worldScale: transform.scale
                    )
                } catch {
                    print("❌ Failed to share diagram on initial load: \(error)")
                }
            }
            
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

#else
/// iOS ContentView stub - 3D rendering not available
struct ContentView: View {
    var filename: String = "2D Tree Layout"
    var onClose: (() -> Void)? = nil
    @StateObject private var viewModel = ElementViewModel()
    @Environment(AppModel.self) private var appModel
    
    var body: some View {
        VStack {
            Text("📱 iOS View")
                .font(.title)
                .padding()
            
            Text("Loading: \(filename)")
                .font(.headline)
            
            Text("3D rendering available on visionOS")
                .foregroundColor(.secondary)
                .padding()
            
            if let errorMessage = viewModel.loadErrorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .padding()
            }
            
            Button("Close") {
                onClose?()
            }
            .buttonStyle(.bordered)
            .padding()
            
            Spacer()
        }
        .task {
            viewModel.setAppModel(appModel)
            await viewModel.loadData(from: filename)
        }
    }
}
#endif

// MARK: - Previews
#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(filename: "Simple Tree")
            //.environment(AppModel())
    }
}
#endif
