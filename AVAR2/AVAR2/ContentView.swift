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
    @State private var isTableDetected: Bool = false
    @State private var isWallDetected: Bool = false
    @State private var detectedTableAnchors: [AnchorEntity] = []
    @State private var detectedWallAnchors: [AnchorEntity] = []
    @State private var sceneReconstructionProvider: SceneReconstructionProvider?
    @State private var planeDetectionProvider: PlaneDetectionProvider?
    @State private var currentSceneContent: RealityViewContent?
    
    /// Creates fallback surface anchors for simulator testing
    func createFallbackAnchors() {
        #if os(visionOS)
        // Create a mock table anchor positioned below user
        let tableAnchor = AnchorEntity(.plane(.horizontal, classification: .table, minimumBounds: [1.0, 1.0]))
        tableAnchor.name = "simulatorTableAnchor"
        tableAnchor.setPosition(SIMD3<Float>(0, -0.5, -1.5), relativeTo: nil)
        
        // Add visual highlight for fallback testing
        let tableHighlightMesh = MeshResource.generatePlane(width: 1.0, depth: 1.0)
        let tableHighlightMaterial = UnlitMaterial(color: UIColor.green.withAlphaComponent(0.5))
        let tableHighlight = ModelEntity(mesh: tableHighlightMesh, materials: [tableHighlightMaterial])
        tableHighlight.name = "surfaceHighlight_table"
        tableAnchor.addChild(tableHighlight)
        
        detectedTableAnchors.append(tableAnchor)
        viewModel.addDetectedSurfaceAnchor(tableAnchor)
        
        // Create a mock wall anchor positioned in front of user
        let wallAnchor = AnchorEntity(.plane(.vertical, classification: .wall, minimumBounds: [2.0, 2.0]))
        wallAnchor.name = "simulatorWallAnchor" 
        wallAnchor.setPosition(SIMD3<Float>(0, 0, -2.0), relativeTo: nil)
        wallAnchor.setOrientation(simd_quatf(angle: 0, axis: [0, 1, 0]), relativeTo: nil)
        
        // Add visual highlight for fallback testing
        let wallHighlightMesh = MeshResource.generatePlane(width: 2.0, depth: 2.0)
        let wallHighlightMaterial = UnlitMaterial(color: UIColor.blue.withAlphaComponent(0.5))
        let wallHighlight = ModelEntity(mesh: wallHighlightMesh, materials: [wallHighlightMaterial])
        wallHighlight.name = "surfaceHighlight_wall"
        // Rotate wall to be vertical
        wallHighlight.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(1, 0, 0))
        wallAnchor.addChild(wallHighlight)
        
        // Add white box at center of fallback wall
        let whiteBoxMesh = MeshResource.generateBox(size: 0.1)
        let whiteBoxMaterial = UnlitMaterial(color: UIColor.white)
        let whiteBoxEntity = ModelEntity(mesh: whiteBoxMesh, materials: [whiteBoxMaterial])
        whiteBoxEntity.name = "wallCenterBox_simulator"
        whiteBoxEntity.position = SIMD3<Float>(0, 0, 0.05)
        wallAnchor.addChild(whiteBoxEntity)
        
        detectedWallAnchors.append(wallAnchor)
        viewModel.addDetectedSurfaceAnchor(wallAnchor)
        
        print("✅ Created fallback anchors for simulator: 1 table (below), 1 wall (front)")
        print("📱 Simulator Mode: Surface snapping will work with these mock surfaces")
        #endif
    }
    
    func setupARKitProviders() async {
        #if os(visionOS)
        print("🚀 Starting ARKit setup...")
        let session = ARKitSession()
        let sceneReconstruction = SceneReconstructionProvider()
        // Enable detection of ALL plane types including floors and ceilings
        let planeDetection = PlaneDetectionProvider(alignments: [.horizontal, .vertical])
        print("🔎 PlaneDetection configured for: horizontal + vertical planes")
        print("🔎 PlaneDetection supported: \(PlaneDetectionProvider.isSupported)")
        print("🔎 SceneReconstruction supported: \(SceneReconstructionProvider.isSupported)")
        
        // Check if any providers are supported before requesting authorization
        guard SceneReconstructionProvider.isSupported || PlaneDetectionProvider.isSupported else {
            print("No ARKit providers are supported - skipping authorization and creating fallback anchors")
            createFallbackAnchors()
            return
        }
        
        let authorizationResult = await session.requestAuthorization(for: [.worldSensing])
        
        for (authorizationType, authorizationStatus) in authorizationResult {
            print("🔐 Authorization status for \(authorizationType): \(authorizationStatus)")
            if authorizationStatus != .allowed {
                print("❌ Failed to get authorization for \(authorizationType)")
            } else {
                print("✅ Authorization granted for \(authorizationType)")
            }
        }
        
        do {
            // Check if providers are supported before running
            var providersToRun: [DataProvider] = []
            
            if SceneReconstructionProvider.isSupported {
                providersToRun.append(sceneReconstruction)
                print("Scene reconstruction is supported")
            } else {
                print("Scene reconstruction is not supported (likely running in simulator)")
            }
            
            if PlaneDetectionProvider.isSupported {
                providersToRun.append(planeDetection)
                print("Plane detection is supported")
            } else {
                print("Plane detection is not supported (likely running in simulator)")
            }
            
            // Only run ARKit session if we have supported providers
            if !providersToRun.isEmpty {
                try await session.run(providersToRun)
                
                if SceneReconstructionProvider.isSupported {
                    self.sceneReconstructionProvider = sceneReconstruction
                }
                
                if PlaneDetectionProvider.isSupported {
                    self.planeDetectionProvider = planeDetection
                    print("👁️ Starting plane detection monitoring...")
                    // Start monitoring plane updates only if plane detection is supported
                    await monitorPlaneUpdates(provider: planeDetection)
                    
                    // Add fallback anchors after a delay if no real surfaces detected
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        if self.viewModel.detectedSurfaceAnchors.isEmpty {
                            print("⚠️ No real surfaces detected after 5s, creating fallback anchors")
                            self.createFallbackAnchors()
                        } else {
                            print("✅ Real surfaces detected, skipping fallback anchors")
                        }
                    }
                } else {
                    print("❌ PlaneDetectionProvider not supported")
                }
                
                print("ARKit session started successfully with \(providersToRun.count) provider(s)")
            } else {
                print("No ARKit providers are supported - app will run without surface detection")
                // Create fallback anchors for simulator testing
                createFallbackAnchors()
            }
        } catch {
            print("Failed to start ARKit session: \(error)")
            // Create fallback anchors if ARKit fails
            createFallbackAnchors()
        }
        #endif
    }
    
    func monitorPlaneUpdates(provider: PlaneDetectionProvider) async {
        #if os(visionOS)
        for await update in provider.anchorUpdates {
            let anchor = update.anchor
            
            switch update.event {
            case .added:
                handlePlaneAdded(anchor: anchor)
            case .updated:
                handlePlaneUpdated(anchor: anchor)
            case .removed:
                handlePlaneRemoved(anchor: anchor)
            }
        }
        #endif
    }
    
    @MainActor
    func handlePlaneAdded(anchor: PlaneAnchor) {
        #if os(visionOS)
        print("🔍 RAW ARKit Plane: \(anchor.classification), alignment: \(anchor.alignment)")
        print("📍 RAW Position: \(anchor.originFromAnchorTransform.translation)")
        print("🔄 RAW Transform: \(anchor.originFromAnchorTransform)")
        
        // Don't create custom AnchorEntity - use the ARKit anchor directly
        // Create a simple Entity to hold our highlight
        let anchorEntity = Entity()
        anchorEntity.name = "detectedPlane_\(anchor.id)"
        
        // Set the exact position and orientation from ARKit
        anchorEntity.setPosition(anchor.originFromAnchorTransform.translation, relativeTo: nil)
        anchorEntity.setOrientation(simd_quatf(anchor.originFromAnchorTransform), relativeTo: nil)
        
        // Create visual highlight that exactly matches the detected plane
        let planeWidth = anchor.geometry.extent.width
        let planeHeight = anchor.geometry.extent.height
        
        // Choose color based on surface type
        let highlightColor: UIColor = {
            switch anchor.classification {
            case .table:
                return UIColor.green.withAlphaComponent(0.6)
            case .wall:
                return UIColor.blue.withAlphaComponent(0.6)
            case .floor:
                return UIColor.brown.withAlphaComponent(0.6)
            case .ceiling:
                return UIColor.gray.withAlphaComponent(0.6)
            default:
                return UIColor.yellow.withAlphaComponent(0.6)
            }
        }()
        
        // Create a plane mesh that matches the detected surface exactly
        let highlightMesh = MeshResource.generatePlane(width: planeWidth, depth: planeHeight)
        let highlightMaterial = UnlitMaterial(color: highlightColor)
        let highlightEntity = ModelEntity(mesh: highlightMesh, materials: [highlightMaterial])
        highlightEntity.name = "surfaceHighlight_\(anchor.classification)"
        
        // Apply a tiny offset based on the plane's normal to prevent z-fighting
        let normalOffset: Float = 0.001
        if anchor.alignment == .horizontal {
            // For horizontal planes (tables, floors, ceilings)
            if anchor.classification == .ceiling {
                highlightEntity.position.y = -normalOffset  // Slightly below ceiling
            } else {
                highlightEntity.position.y = normalOffset   // Slightly above floor/table
            }
        } else {
            // For vertical planes (walls)
            highlightEntity.position.z = normalOffset   // Slightly in front of wall
        }
        
        // Disable surface highlighting - comment out the line below
        // anchorEntity.addChild(highlightEntity)
        
        // The entity will be added to scene via the wrapper anchor
        
        // Create an AnchorEntity wrapper for compatibility with existing tracking
        let wrapperAnchor = AnchorEntity()
        wrapperAnchor.name = anchorEntity.name
        wrapperAnchor.addChild(anchorEntity)
        
        // Track ALL surfaces, not just tables and walls
        if anchor.classification == .table {
            detectedTableAnchors.append(wrapperAnchor)
        } else if anchor.classification == .wall {
            detectedWallAnchors.append(wrapperAnchor)
            
            // Add white box at center of wall
            let whiteBoxMesh = MeshResource.generateBox(size: 0.1)
            let whiteBoxMaterial = UnlitMaterial(color: UIColor.white)
            let whiteBoxEntity = ModelEntity(mesh: whiteBoxMesh, materials: [whiteBoxMaterial])
            whiteBoxEntity.name = "wallCenterBox_\(anchor.id)"
            
            // Position the box at the center of the wall
            // The box should be positioned slightly in front of the wall surface
            whiteBoxEntity.position = SIMD3<Float>(0, 0, 0.05)
            
            anchorEntity.addChild(whiteBoxEntity)
        }
        
        viewModel.addDetectedSurfaceAnchor(wrapperAnchor)
        print("✨ Added \(anchor.classification) surface - \(planeWidth)x\(planeHeight)m")
        print("📋 Total detected surfaces in ViewModel: \(viewModel.detectedSurfaceAnchors.count)")
        #endif
    }
    
    @MainActor
    func handlePlaneUpdated(anchor: PlaneAnchor) {
        #if os(visionOS)
        // Find and update the corresponding anchor entity
        let allAnchors = detectedTableAnchors + detectedWallAnchors + viewModel.detectedSurfaceAnchors
        if let existingEntity = allAnchors.first(where: { $0.name == "detectedPlane_\(anchor.id)" }) {
            // Update position and orientation
            existingEntity.setPosition(anchor.originFromAnchorTransform.translation, relativeTo: nil)
            existingEntity.setOrientation(simd_quatf(anchor.originFromAnchorTransform), relativeTo: nil)
            
            // Only update highlight if size changed significantly (to prevent blinking)
            if let existingHighlight = existingEntity.children.first(where: { $0.name.contains("surfaceHighlight") }) as? ModelEntity {
                let currentBounds = existingHighlight.visualBounds(relativeTo: existingEntity)
                let newWidth = anchor.geometry.extent.width
                let newHeight = anchor.geometry.extent.height
                let currentWidth = currentBounds.extents.x * 2
                let currentDepth = currentBounds.extents.z * 2
                
                // Only update if size changed by more than 10cm
                if abs(newWidth - currentWidth) > 0.1 || abs(newHeight - currentDepth) > 0.1 {
                    existingHighlight.removeFromParent()
                    
                    let newMesh = MeshResource.generatePlane(width: newWidth, depth: newHeight)
                    existingHighlight.model?.mesh = newMesh
                    existingEntity.addChild(existingHighlight)
                    
                    print("📏 Updated \(anchor.classification) size: \(newWidth)x\(newHeight)m")
                }
            }
        }
        #endif
    }
    
    @MainActor
    func handlePlaneRemoved(anchor: PlaneAnchor) {
        #if os(visionOS)
        // Find and remove the corresponding anchor entity
        let allAnchors = detectedTableAnchors + detectedWallAnchors
        if let entityToRemove = allAnchors.first(where: { $0.name == "detectedPlane_\(anchor.id)" }) {
            detectedTableAnchors.removeAll { $0 === entityToRemove }
            detectedWallAnchors.removeAll { $0 === entityToRemove }
            viewModel.removeDetectedSurfaceAnchor(entityToRemove)
        }
        #endif
    }
    
    // Removed complex surface highlighting - using simpler approach above
    
    var body: some View {
        RealityView { content in
            currentSceneContent = content
            viewModel.loadElements(in: content, onClose: onClose)
        } update: { content in
            currentSceneContent = content
            // Add fallback anchors to the content if they exist
            for anchor in detectedTableAnchors + detectedWallAnchors {
                if !content.entities.contains(anchor) {
                    content.add(anchor)
                }
            }
            // The surface detection is now handled by ARKit providers
            // Just update connections as needed
            viewModel.updateConnections(in: content)
        }
        .task {
            await viewModel.loadData(from: filename)
            await setupARKitProviders()
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
