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

    var body: some View {
        RealityView { content in
            viewModel.loadElements(in: content)
        } update: { content in
            viewModel.updateConnections(in: content)
        }
        .task {
            await viewModel.loadData(from: filename)
        }
        // Combined drag gesture: element drag vs background pan
        .gesture(
            DragGesture(minimumDistance: 0).targetedToAnyEntity()
                .onChanged { value in
                    let name = value.entity.name
                    if name.starts(with: "element_") && !viewModel.isGraph2D {
                        viewModel.handleDragChanged(value)
                    } else if name == "graphBackground" {
                        viewModel.handlePanChanged(value)
                    }
                }
                .onEnded { value in
                    let name = value.entity.name
                    if name.starts(with: "element_") && !viewModel.isGraph2D{
                        viewModel.handleDragEnded(value)
                    } else if name == "graphBackground" {
                        viewModel.handlePanEnded(value)
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
        .overlay(alignment: .topTrailing) {
            if let onClose = onClose {
                Button(action: onClose) {
                    ZStack {
                        Circle()
                            .fill(.red)
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    .frame(width: 40, height: 40)
                }
                .padding([.top, .trailing], 16)
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
