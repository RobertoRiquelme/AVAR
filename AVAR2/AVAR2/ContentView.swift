//
//  ContentView.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 30-04-25.
//

import SwiftUI
import RealityKit
import RealityKitContent


/// Displays an immersive graph based on a selected example file.
struct ContentView: View {
    /// The resource filename (without extension) to load.
    var filename: String = "2D Tree Layout"
    var onClose: (() -> Void)? = nil
    @StateObject private var viewModel = ElementViewModel()
    @State private var isTableDetected: Bool = false
    @State private var isWallDetected: Bool = false
    
    var body: some View {
        RealityView { content in
            // Insert invisible anchors for table & wall detection
            let tableAnchor = AnchorEntity(
                plane: .horizontal,
                classification: .table,
                minimumBounds: [0.3, 0.3]
            )
            tableAnchor.name = "tableAnchor"
            content.add(tableAnchor)
            
            let wallAnchor = AnchorEntity(
                plane: .vertical,
                classification: .wall,
                minimumBounds: [0.3, 0.3]
            )
            wallAnchor.name = "wallAnchor"
            content.add(wallAnchor)
            
            // Save to ViewModel or local state if needed
            viewModel.tableAnchor = tableAnchor
            viewModel.wallAnchor = wallAnchor

            viewModel.loadElements(in: content, onClose: onClose)
        } update: { content in
            // Check detection state
            if let tableAnchor = content.entities.first(where: { $0.name == "tableAnchor" }) as? AnchorEntity {
                if tableAnchor.isAnchored && !isTableDetected {
                    isTableDetected = true
                    print("Table surface detected!")
                    // Notify the ViewModel or trigger UI update here
                }
            }
            if let wallAnchor = content.entities.first(where: { $0.name == "wallAnchor" }) as? AnchorEntity {
                if wallAnchor.isAnchored && !isWallDetected {
                    isWallDetected = true
                    print("Wall surface detected!")
                }
            }
            viewModel.updateConnections(in: content)
        }
        .task {
            await viewModel.loadData(from: filename)
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
        .overlay(alignment: .top) {
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
