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
        if let session = collaborativeSession {
            mainContent
                .onReceive(session.$sharedDiagrams) { diagrams in
                    guard let shared = diagrams.first(where: { $0.filename == filename }) else { return }
                    // Poses are already in the shared session-origin frame — applied directly
                    // against worldRoot, no anchor matrix math.
                    viewModel.applySharedDiagramTransform(
                        position: shared.anchorRelativePosition,
                        orientation: shared.anchorRelativeOrientation,
                        scale: shared.anchorRelativeScale
                    )
                }
                .onReceive(session.$sessionOriginTransform) { originTransform in
                    // One assignment moves every diagram coherently when ARKit refines or
                    // re-acquires the anchor.
                    viewModel.updateWorldRoot(originFromAnchor: originTransform)
                }
                #if DEBUG
                .onChange(of: appModel.debugWorldRootOffset, initial: true) { _, enabled in
                    viewModel.debugWorldRootOffsetEnabled = enabled
                }
                #endif
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
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

                session.updateDiagramTransform(
                    filename: filename,
                    anchorRelativePosition: position,
                    anchorRelativeOrientation: orientation,
                    anchorRelativeScale: scale
                )
            }

            // Authoritative, one-shot pose pushes (e.g. the correction issued when the session
            // origin resolves). Deliberately NOT throttled — there is no follow-up update to
            // cover for a dropped one.
            viewModel.onAuthoritativeTransform = { position, orientation, scale in
                guard let session = collaborativeSession else { return }
                session.updateDiagramTransform(
                    filename: filename,
                    anchorRelativePosition: position,
                    anchorRelativeOrientation: orientation,
                    anchorRelativeScale: scale
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

            // Cache and share the pose in the SHARED frame (relative to worldRoot), not world
            // space. Being anchor-relative by construction is what removed the conversion math.
            if let transform = viewModel.getSharedTransform() {
                collaborativeSession?.cacheLocalDiagramTransform(
                    filename: filename,
                    position: transform.position,
                    orientation: transform.orientation,
                    scale: transform.scale
                )

                if collaborativeSession?.isSessionActive == true,
                   !collaborativeSession!.sharedDiagrams.contains(where: { $0.filename == filename }) {
                    do {
                        let output = try DiagramDataLoader.loadScriptOutput(from: filename)

                        collaborativeSession?.shareDiagram(
                            filename: filename,
                            elements: output.elements,
                            is2D: output.is2D,
                            anchorRelativePosition: transform.position,
                            anchorRelativeOrientation: transform.orientation,
                            anchorRelativeScale: transform.scale
                        )
                        logger.info("Shared diagram '\(filename)' at device-relative position: \(String(describing: transform.position))")
                    } catch {
                        logger.error("Failed to share diagram on initial load: \(error.localizedDescription)")
                    }
                }
            }

            // NOTE: the duplicate "apply shared transform after initial load" block that used to
            // live here is gone. It existed only to paper over `applySharedDiagramTransform`
            // silently dropping updates that arrived before `rootEntity` existed. That is now
            // handled properly by `pendingSharedTransform`, which the scene builder consumes at
            // construction time — so either arrival order converges without a second apply.

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
