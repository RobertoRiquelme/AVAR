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
                // Poses on the wire are plain scene coordinates: the group immersive space is the
                // shared frame, so a received pose is applied as-is. The shared room anchor is
                // deliberately not involved — see `FrameDiagnostics`.
                .onReceive(session.receivedDiagramTransform) { diagram in
                    guard diagram.filename == filename else { return }
                    viewModel.applySharedDiagramTransform(
                        position: diagram.anchorRelativePosition,
                        orientation: diagram.anchorRelativeOrientation,
                        scale: diagram.anchorRelativeScale
                    )
                }
                // A node dragged on another device: move the live node here too. Applies whether
                // this device owns the diagram or received it.
                .onReceive(session.receivedElementMove) { move in
                    guard move.filename == filename else { return }
                    viewModel.applyRemoteElementMove(elementId: move.elementId,
                                                     localPosition: move.localPosition,
                                                     dataPosition: move.dataPosition)
                }
                // The forced offset puts this device in a private frame, so it must never be on
                // while anything is shared: poses would be sent and applied in the wrong frame.
                .onChange(of: appModel.debugWorldRootOffset && !session.isSessionActive, initial: true) { _, enabled in
                    viewModel.debugWorldRootOffsetEnabled = enabled
                }
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        RealityView { content in
            logger.debug("RealityView make block called for: \(filename)")
            if let session = collaborativeSession {
                if let shared = session.sharedDiagrams.first(where: { $0.filename == filename }),
                   !session.isLocallyShared(shared) {
                    viewModel.applySharedDiagramTransform(position: shared.anchorRelativePosition,
                                                          orientation: shared.anchorRelativeOrientation,
                                                          scale: shared.anchorRelativeScale)
                }
            }
            viewModel.loadElements(in: content, onClose: onClose)
        }
        .onChange(of: appModel.optimizeDiagramEdges) { _, _ in
            viewModel.updateConnections()
        }
        .task {
            logger.debug("ContentView task started for: \(filename)")
            viewModel.setAppModel(appModel)
            logger.debug("About to load data for: \(filename)")
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
            viewModel.onElementMoved = { elementId, localPos, dataPosition in
                guard let session = collaborativeSession else { return }
                session.updateElementPosition(
                    filename: filename,
                    elementId: elementId,
                    localPosition: localPos,
                    dataPosition: dataPosition
                )
            }

            // RealityView and the data task can start in either order. Share only once the
            // scene builder has produced the actual pose in this device's current frame.
            viewModel.onSceneReady = { position, orientation, scale in
                guard let session = collaborativeSession,
                      !DiagramDataLoader.isReceived(filename) else { return }
                session.cacheLocalDiagramTransform(filename: filename, position: position,
                                                   orientation: orientation, scale: scale)
                guard session.isSessionActive else { return }
                do {
                    let output = try DiagramDataLoader.loadScriptOutput(from: filename)
                    session.shareDiagram(filename: filename, elements: output.elements, is2D: output.is2D,
                                         anchorRelativePosition: position,
                                         anchorRelativeOrientation: orientation, anchorRelativeScale: scale,
                                         poseAnchorID: session.currentPoseAnchorID)
                } catch {
                    logger.error("Failed to share diagram on initial load: \(error.localizedDescription)")
                }
            }
            await viewModel.loadData(from: filename)

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
