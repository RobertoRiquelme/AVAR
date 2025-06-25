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
    @State private var detectedTableAnchors: [AnchorEntity] = []
    @State private var detectedWallAnchors: [AnchorEntity] = []
    
    func makeSurfaceHighlight(isTable: Bool) -> ModelEntity {
        print("Highlighting \(isTable ? "table" : "wall") detected!")

        let size: SIMD2<Float> = [0.5, 0.5]
        // Main plane (semi-transparent fill)
        let mesh = MeshResource.generatePlane(width: size.x, depth: size.y)
        let fillColor = isTable ? UIColor.systemGreen.withAlphaComponent(0.2) : UIColor.systemBlue.withAlphaComponent(0.2)
        let fillMaterial = UnlitMaterial(color: fillColor)

        let highlight = ModelEntity(mesh: mesh, materials: [fillMaterial])
        highlight.name = isTable ? "tableHighlight" : "wallHighlight"
        // Glowing border: thin slightly larger plane, higher alpha
        let borderWidth: Float = 0.01
        let borderMesh = MeshResource.generatePlane(width: size.x + borderWidth, depth: size.y + borderWidth)
        let borderColor = isTable ? UIColor.green.withAlphaComponent(0.8) : UIColor.blue.withAlphaComponent(0.8)
        let borderMaterial = UnlitMaterial(color: borderColor)
        let borderEntity = ModelEntity(mesh: borderMesh, materials: [borderMaterial])
        borderEntity.name = isTable ? "tableBorder" : "wallBorder"
        highlight.addChild(borderEntity)

        // Raise above surface a bit to avoid z-fighting
        if isTable {
            highlight.position.y = 0.01
            borderEntity.position.y = 0.001
        } else {
            highlight.orientation = simd_quatf(angle: -.pi/2, axis: [1, 0, 0])
            borderEntity.orientation = simd_quatf(angle: -.pi/2, axis: [1, 0, 0])
            highlight.position.z = 0.01
            borderEntity.position.z = 0.001
        }

        highlight.scale = SIMD3<Float>(repeating: 1.0)
        return highlight
    }
    
    var body: some View {
        RealityView { content in
            // Insert invisible anchors for table & wall detection
            let tableAnchor = AnchorEntity(
                plane: .horizontal,
                classification: .table,
                minimumBounds: [0.5, 0.5]
            )
            tableAnchor.name = "tableAnchor"
            content.add(tableAnchor)
            
            let wallAnchor = AnchorEntity(
                plane: .vertical,
                classification: .wall,
                minimumBounds: [0.5, 0.5]
            )
            wallAnchor.name = "wallAnchor"
            content.add(wallAnchor)
            
            // Save to ViewModel or local state if needed
            viewModel.tableAnchor = tableAnchor
            viewModel.wallAnchor = wallAnchor

            viewModel.loadElements(in: content, onClose: onClose)
        } update: { content in
            // Check detection state
            // Detect all tables
            
            let allAnchors = content.entities.compactMap { $0 as? AnchorEntity }
            
            for anchor in allAnchors {
                // Only process horizontal/vertical planes
                guard anchor.isAnchored else { continue }
                let anchoring = anchor.anchoring
                var isTable = false
                var isWall = false
                switch anchoring.target {
                    case .plane(let planeAlignment, let classification, _):
                        isTable = planeAlignment == .horizontal && classification == .table
                        isWall = planeAlignment == .vertical && classification == .wall
                    default:
                        break
                }

                // Add highlight if not present and not already in our tracked lists
                if isTable {
                    if !detectedTableAnchors.contains(where: { $0 === anchor }) {
                        detectedTableAnchors.append(anchor)
                        print("Table surface detected!")
                        //if anchor.findEntity(named: "tableHighlight") == nil {
                            let highlight = makeSurfaceHighlight(isTable: true)
                            anchor.addChild(highlight)
                        //}
                    }
                } else if isWall {
                    if !detectedWallAnchors.contains(where: { $0 === anchor }) {
                        detectedWallAnchors.append(anchor)
                        print("Wall surface detected!")
                        //if anchor.findEntity(named: "wallHighlight") == nil {
                            let highlight = makeSurfaceHighlight(isTable: false)
                            anchor.addChild(highlight)
                        //}
                    }
                } else {
                    // If you want to highlight any other classification/plane, you can handle them here!
                    // For example:
                    // if anchor.findEntity(named: "genericHighlight") == nil {
                    //     let highlight = makeSurfaceHighlight(isTable: true) // or make a new style
                    //     anchor.addChild(highlight)
                    // }
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
