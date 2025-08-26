#if os(iOS)
import SwiftUI
import RealityKit
import ARKit

struct iOS_ContentView: View {
    @StateObject private var arViewModel = ARViewModel()
    @ObservedObject var collaborativeSession: CollaborativeSessionManager
    @State private var showingCollaborativeSession = false
    
    var body: some View {
        ZStack {
            // AR View for iOS - Full screen
            ARViewContainer(arViewModel: arViewModel)
                .ignoresSafeArea(.all, edges: .all)
            
            // Overlay UI
            VStack {
                // Top controls
                HStack {
                    Button("Session") {
                        showingCollaborativeSession = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    
                    Spacer()
                    
                    if collaborativeSession.isSessionActive {
                        Text("●")
                            .foregroundColor(.green)
                            .font(.system(size: 16, weight: .bold))
                    }
                    
                    Button("Reset") {
                        arViewModel.resetSession()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    
                    Button("📹") {
                        arViewModel.restartARSession()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.top, 60) // Add top padding to account for status bar
                .padding(.horizontal)
                
                Spacer()
                
                // Bottom controls
                VStack(spacing: 12) {
                    if !collaborativeSession.sharedDiagrams.isEmpty {
                        VStack(spacing: 4) {
                            Text("📊 AR Diagrams: \(collaborativeSession.sharedDiagrams.count)")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("Look around to see 3D content")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: .capsule)
                    }
                    
                    HStack(spacing: 16) {
                        Button("Debug Sphere") {
                            arViewModel.placeAnchor()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        
                        Button("Clear All") {
                            arViewModel.clearAll()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                .padding(.bottom, 40) // Add bottom padding to account for home indicator
                .padding(.horizontal)
            }
        }
        .sheet(isPresented: $showingCollaborativeSession) {
            CollaborativeSessionView(sessionManager: collaborativeSession)
        }
        .onReceive(collaborativeSession.$sharedDiagrams) { diagrams in
            // Update AR view when new diagrams are received
            print("📱 iOS received \(diagrams.count) shared diagrams")
            for (index, diagram) in diagrams.enumerated() {
                print("📱 Diagram \(index): '\(diagram.filename)' with \(diagram.elements.count) elements")
            }
            arViewModel.updateSharedDiagrams(diagrams)
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let arViewModel: ARViewModel
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arViewModel.setupARView(arView)
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // Updates handled by the view model
    }
}

@MainActor
class ARViewModel: NSObject, ObservableObject {
    private var arView: ARView?
    private var arSession: ARSession?
    private var sharedDiagrams: [SharedDiagram] = []
    
    func setupARView(_ arView: ARView) {
        self.arView = arView
        self.arSession = arView.session
        
        // Configure AR session for world tracking
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isCollaborationEnabled = true
        configuration.environmentTexturing = .automatic
        
        // Add session delegate to monitor state changes
        arView.session.delegate = self
        
        arView.session.run(configuration)
        
        // Enable coaching overlay
        arView.debugOptions = []
        
        print("📱 AR session configured for iOS with collaboration enabled")
        print("📱 ARSession delegate set to monitor session state")
    }
    
    func resetSession() {
        guard let arView = arView else { return }
        
        // Clear all anchors
        arView.scene.anchors.removeAll()
        
        // Restart session
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isCollaborationEnabled = true
        configuration.environmentTexturing = .automatic
        
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        
        print("🔄 AR session reset")
    }
    
    func placeAnchor() {
        guard let arView = arView else { return }
        
        // Create a simple anchor 1 meter in front of camera
        let transform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, -1, 1)  // 1 meter forward
        )
        
        let anchor = AnchorEntity(world: transform)
        
        // Add a simple sphere as reference
        let sphereMesh = MeshResource.generateSphere(radius: 0.1)
        let sphereMaterial = SimpleMaterial(color: .blue, isMetallic: false)
        let sphereEntity = ModelEntity(mesh: sphereMesh, materials: [sphereMaterial])
        
        anchor.addChild(sphereEntity)
        arView.scene.addAnchor(anchor)
        
        print("📍 Placed reference anchor")
    }
    
    func clearAll() {
        guard let arView = arView else { return }
        arView.scene.anchors.removeAll()
        print("🗑️ Cleared all anchors")
    }
    
    func updateSharedDiagrams(_ diagrams: [SharedDiagram]) {
        guard let arView = arView else { return }
        
        self.sharedDiagrams = diagrams
        
        // Clear existing diagram entities
        for anchor in arView.scene.anchors {
            if anchor.name.hasPrefix("shared_diagram_") {
                arView.scene.removeAnchor(anchor)
            }
        }
        
        // Add new diagram entities
        for (index, diagram) in diagrams.enumerated() {
            let anchor = createDiagramAnchor(diagram: diagram, index: index, totalCount: diagrams.count)
            arView.scene.addAnchor(anchor)
        }
        
        print("📱 Updated iOS view with \(diagrams.count) shared diagrams")
    }
    
    private func createDiagramAnchor(diagram: SharedDiagram, index: Int, totalCount: Int) -> AnchorEntity {
        // Position diagrams in front of user, staggered vertically if multiple
        let yOffset = Float(index) * 0.5 - Float(totalCount - 1) * 0.25
        let transform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, yOffset, -1.5, 1)  // 1.5m forward, vertically staggered
        )
        
        let anchor = AnchorEntity(world: transform)
        anchor.name = "shared_diagram_\(diagram.filename)"
        
        print("📱 Creating AR diagram '\(diagram.filename)' with \(diagram.elements.count) elements")
        
        // Create full-scale diagram representation
        var elementCount = 0
        for (elementIndex, element) in diagram.elements.enumerated() {
            if let elementEntity = createFullScaleElement(element: element, index: elementIndex) {
                anchor.addChild(elementEntity)
                elementCount += 1
            }
        }
        
        print("📱 Added \(elementCount) visible elements to AR diagram")
        
        // Add title label positioned above the diagram
        if let titleEntity = createTitleEntity(text: diagram.filename) {
            titleEntity.position = SIMD3<Float>(0, 0.8, 0)  // Above the diagram
            anchor.addChild(titleEntity)
        }
        
        return anchor
    }
    
    private func createFullScaleElement(element: ElementDTO, index: Int) -> ModelEntity? {
        guard let position = element.position, position.count >= 3 else { 
            print("📱 ⚠️ Element \(index) missing position data")
            return nil
        }
        
        // Skip camera and edge elements for cleaner visualization
        if element.type.lowercased() == "camera" || element.type.lowercased() == "edge" {
            return nil
        }
        
        print("📱 Creating element \(index): type=\(element.type), shape=\(element.shape?.shapeDescription ?? "unknown")")
        
        // Create geometry based on shape with proper sizing
        let mesh: MeshResource
        let baseSize: Float = 0.02  // 2cm base size - visible but not overwhelming
        
        if let shapeDesc = element.shape?.shapeDescription?.lowercased() {
            switch shapeDesc {
            case let desc where desc.contains("sphere"):
                mesh = MeshResource.generateSphere(radius: baseSize)
            case let desc where desc.contains("cylinder"):
                mesh = MeshResource.generateCylinder(height: baseSize * 2, radius: baseSize)
            case let desc where desc.contains("box"), let desc where desc.contains("cube"):
                mesh = MeshResource.generateBox(size: SIMD3<Float>(baseSize, baseSize, baseSize))
            case let desc where desc.contains("line"):
                // For lines, create a thin cylinder
                mesh = MeshResource.generateCylinder(height: baseSize * 3, radius: baseSize * 0.3)
            default:
                mesh = MeshResource.generateSphere(radius: baseSize) // Default sphere
            }
        } else {
            mesh = MeshResource.generateSphere(radius: baseSize) // Default sphere
        }
        
        // Use element color or default to blue
        let color = UIColor(
            red: CGFloat(element.color?[safe: 0] ?? 0.3),
            green: CGFloat(element.color?[safe: 1] ?? 0.6),
            blue: CGFloat(element.color?[safe: 2] ?? 1.0),
            alpha: CGFloat(element.color?[safe: 3] ?? 1.0)
        )
        
        let material = SimpleMaterial(color: color, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        
        // Position element using original coordinates with reasonable scaling
        let scale: Float = 0.001  // Convert to meters - 1 unit = 1mm
        entity.position = SIMD3<Float>(
            Float(position[0]) * scale,
            Float(position[1]) * scale,
            Float(position[2]) * scale
        )
        
        // Set name for debugging
        entity.name = "element_\(index)_\(element.type)"
        
        print("📱 ✅ Created element at position (\(entity.position.x), \(entity.position.y), \(entity.position.z))")
        
        return entity
    }
    
    private func createSimplifiedElement(element: ElementDTO, index: Int) -> ModelEntity? {
        guard let position = element.position, position.count >= 3 else { return nil }
        
        // Skip camera and edge elements
        if element.type.lowercased() == "camera" || element.type.lowercased() == "edge" {
            return nil
        }
        
        // Create basic geometry based on shape
        let mesh: MeshResource
        let color = UIColor(
            red: CGFloat(element.color?[safe: 0] ?? 0.5),
            green: CGFloat(element.color?[safe: 1] ?? 0.5),
            blue: CGFloat(element.color?[safe: 2] ?? 0.5),
            alpha: CGFloat(element.color?[safe: 3] ?? 1.0)
        )
        
        if let shapeDesc = element.shape?.shapeDescription?.lowercased() {
            if shapeDesc.contains("sphere") {
                mesh = MeshResource.generateSphere(radius: 0.05)
            } else if shapeDesc.contains("cylinder") {
                mesh = MeshResource.generateCylinder(height: 0.1, radius: 0.05)
            } else if shapeDesc.contains("box") || shapeDesc.contains("cube") {
                mesh = MeshResource.generateBox(size: SIMD3<Float>(0.1, 0.1, 0.1))
            } else {
                mesh = MeshResource.generateSphere(radius: 0.05) // Default
            }
        } else {
            mesh = MeshResource.generateSphere(radius: 0.05) // Default
        }
        
        let material = SimpleMaterial(color: color, isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        
        // Scale down and position
        let scale: Float = 0.1 // Scale down for mobile viewing
        entity.position = SIMD3<Float>(
            Float(position[0]) * scale,
            Float(position[1]) * scale,
            Float(position[2]) * scale
        )
        
        return entity
    }
    
    private func createTitleEntity(text: String) -> ModelEntity? {
        // Create visible text representation for iOS
        let textMesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.005,  // Thinner extrusion
            font: .systemFont(ofSize: 0.05),  // Smaller but readable size
            containerFrame: CGRect(x: -0.5, y: -0.05, width: 1.0, height: 0.1),
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        
        // Use bright color for visibility
        let textMaterial = SimpleMaterial(color: .systemYellow, isMetallic: false)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        
        // Add slight glow effect by making it emissive
        var glowMaterial = UnlitMaterial(color: .systemYellow)
        glowMaterial.color = .init(tint: .systemYellow)
        textEntity.model?.materials = [glowMaterial]
        
        return textEntity
    }
    
    /// Restart the AR session if it gets frozen or interrupted
    func restartARSession() {
        guard let arView = arView else { return }
        
        print("📱 🔄 Restarting AR session to recover from freeze...")
        
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isCollaborationEnabled = true
        configuration.environmentTexturing = .automatic
        
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        
        print("📱 ✅ AR session restarted with collaboration enabled")
    }
}

// Helper extension for safe array access
extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - ARSessionDelegate
extension ARViewModel: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        print("📱 ❌ ARSession failed with error: \(error)")
    }
    
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        print("📱 🔴 ARSession was interrupted - camera frozen")
    }
    
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        print("📱 🟢 ARSession interruption ended - camera should resume")
        
        // Automatically restart the session with the same configuration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task { @MainActor in
                self.restartARSession()
            }
        }
    }
    
    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        print("📱 ARCamera tracking state changed: \(camera.trackingState)")
        
        switch camera.trackingState {
        case .normal:
            print("📱 ✅ Camera tracking normally")
        case .limited(let reason):
            print("📱 ⚠️ Camera tracking limited: \(reason)")
        case .notAvailable:
            print("📱 ❌ Camera tracking not available")
        @unknown default:
            print("📱 ❓ Unknown camera tracking state")
        }
    }
}

#endif