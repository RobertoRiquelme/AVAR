//
//  ContentView.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI
import RealityKit
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "ContentView")

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
            logger.debug("RealityView make block called for: \(filename)")
            viewModel.loadElements(in: content, onClose: onClose)
        } update: { content in
            logger.debug("RealityView update block called for: \(filename)")
            viewModel.updateConnections(in: content)
        }
        .task {
            logger.debug("ContentView task started for: \(filename)")
            viewModel.setAppModel(appModel)
            logger.debug("About to load data for: \(filename)")
            await viewModel.loadData(from: filename)
            logger.debug("Data load completed for: \(filename)")

            // Use shared throttler for collaborative sync
            let throttler = UpdateThrottler()

            // Set up transform change callback for collaborative sync
            viewModel.onTransformChanged = { position, orientation, scale in
                // Throttle updates to avoid lag during drag
                guard throttler.shouldUpdate() else { return }
                guard let session = collaborativeSession else { return }

                // Modern approach: Send device-relative positions
                // SharedCoordinateSpace handles spatial alignment automatically
                session.updateDiagramTransform(
                    filename: filename,
                    worldPosition: position,  // Device-relative, no transform needed!
                    worldOrientation: orientation,
                    worldScale: scale
                )
            }
            
            // Send per-element edits to peers when a node drag ends
            viewModel.onElementMoved = { elementId, localPos in
                guard let session = collaborativeSession else { return }
                session.updateElementPosition(
                    filename: filename,
                    elementId: elementId,
                    localPosition: localPos
                )
            }


            // Share initial position with collaborative session
            if let transform = viewModel.getWorldTransform(),
               collaborativeSession?.isSessionActive == true,
               !collaborativeSession!.sharedDiagrams.contains(where: { $0.filename == filename }) {
                do {
                    let elements = try DiagramDataLoader.loadScriptOutput(from: filename).elements

                    // Modern approach: Send device-relative position
                    // SharedCoordinateSpace handles spatial alignment automatically
                    collaborativeSession?.shareDiagram(
                        filename: filename,
                        elements: elements,
                        worldPosition: transform.position,  // Device-relative!
                        worldOrientation: transform.orientation,
                        worldScale: transform.scale
                    )
                    logger.info("Shared diagram '\(filename)' at device-relative position: \(String(describing: transform.position))")
                } catch {
                    logger.error("Failed to share diagram on initial load: \(error.localizedDescription)")
                }
            }

            logger.debug("ContentView task completed for: \(filename)")
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
