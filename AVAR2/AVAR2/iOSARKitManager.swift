//
//  iOSARKitManager.swift
//  AVAR2
//
//  Created by Claude Code on 20-08-25.
//

#if os(iOS)
import ARKit
import RealityKit
import SwiftUI
import Combine

@MainActor
final class iOSARKitManager: NSObject, ObservableObject {
    private let arView = ARView(frame: .zero)
    private let coachingOverlay = ARCoachingOverlayView()
    
    @Published var surfaceAnchors: [ARPlaneAnchor] = []
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var entityMap: [UUID: Entity] = [:]
    @Published var isTrackingReady = false
    
    // Plane visualization toggle
    private var visualizationVisible = true
    
    let rootEntity = Entity()
    
    override init() {
        super.init()
        setupARView()
        setupCoachingOverlay()
    }
    
    private func setupARView() {
        arView.session.delegate = self
        arView.scene.addAnchor(AnchorEntity(world: [0, 0, 0]))
        arView.scene.anchors.first?.addChild(rootEntity)
        
        // Enable people occlusion and object occlusion if available
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        
        // Setup lighting
        arView.environment.lighting.resource = try? EnvironmentResource.load(named: "sunlight")
    }
    
    private func setupCoachingOverlay() {
        coachingOverlay.session = arView.session
        coachingOverlay.delegate = self
        coachingOverlay.goal = .horizontalPlane
        coachingOverlay.activatesAutomatically = true
        arView.addSubview(coachingOverlay)
        coachingOverlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            coachingOverlay.centerXAnchor.constraint(equalTo: arView.centerXAnchor),
            coachingOverlay.centerYAnchor.constraint(equalTo: arView.centerYAnchor),
            coachingOverlay.widthAnchor.constraint(equalTo: arView.widthAnchor),
            coachingOverlay.heightAnchor.constraint(equalTo: arView.heightAnchor)
        ])
    }
    
    func run() async {
        guard ARWorldTrackingConfiguration.isSupported else {
            await MainActor.run {
                errorMessage = "ARWorldTrackingConfiguration is not supported on this device."
            }
            return
        }
        
        guard !isRunning else {
            print("🚫 ARKit session already running - maintaining existing surfaces")
            return
        }
        
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        
        // Enable scene reconstruction if available
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        
        await MainActor.run {
            isRunning = true
            errorMessage = nil
        }
        
        print("🚀 iOS ARKit session started - detecting surfaces...")
    }
    
    func stop() {
        arView.session.pause()
        isRunning = false
        isTrackingReady = false
        print("⏸️ iOS ARKit session stopped")
    }
    
    func getARView() -> ARView {
        return arView
    }
    
    // MARK: - Plane Visualization
    
    @MainActor
    private func addPlaneVisualization(_ anchor: ARPlaneAnchor) {
        guard entityMap[anchor.identifier] == nil else { return }
        
        print("➕ Adding iOS plane visualization: \(anchor.identifier), classification: \(anchor.classification.description)")
        
        let entity = Entity()
        
        // Create simple plane mesh for iOS (using standard rectangle)
        // iOS ARKit geometry APIs are different, so we'll use a simple plane
        let extent = anchor.extent  // iOS uses anchor.extent as simd_float3 (x, z, y)
        let planeMesh = MeshResource.generatePlane(width: extent.x, height: extent.z)
        
        let mesh = planeMesh
        // Create material based on plane type
        let material = UnlitMaterial(color: anchor.classification.iosColor)
        
        let planeEntity = ModelEntity(mesh: mesh, materials: [material])
        planeEntity.name = "plane"
        
        // Add text label (iOS MeshResource.generateText returns non-optional)
        do {
            let textMesh = MeshResource.generateText(
                anchor.classification.description,
                extrusionDepth: 0.001,
                font: .systemFont(ofSize: 0.05)
            )
            let textEntity = ModelEntity(mesh: textMesh, materials: [UnlitMaterial(color: .white)])
            textEntity.scale = SIMD3(0.5, 0.5, 0.5)
            textEntity.position.y = 0.001
            planeEntity.addChild(textEntity)
        } catch {
            print("Failed to create text label: \(error)")
        }
        
        entity.addChild(planeEntity)
        
        // Position entity at anchor location
        entity.transform = Transform(matrix: anchor.transform)
        
        entityMap[anchor.identifier] = entity
        rootEntity.addChild(entity)
        
        // Apply current visibility state
        entity.isEnabled = visualizationVisible
    }
    
    @MainActor
    private func updatePlaneVisualization(_ anchor: ARPlaneAnchor) {
        guard let entity = entityMap[anchor.identifier],
              let planeEntity = entity.findEntity(named: "plane") as? ModelEntity else {
            return
        }
        
        print("🔄 Updating iOS plane visualization: \(anchor.identifier)")
        
        // Update plane geometry with new extent
        let extent = anchor.extent  // iOS uses anchor.extent as simd_float3 (x, z, y)
        let newMesh = MeshResource.generatePlane(width: extent.x, height: extent.z)
        planeEntity.model?.mesh = newMesh
        
        // Update position
        entity.transform = Transform(matrix: anchor.transform)
    }
    
    @MainActor
    private func removePlaneVisualization(_ anchor: ARPlaneAnchor) {
        print("🗑️ Removing iOS plane visualization: \(anchor.identifier)")
        entityMap[anchor.identifier]?.removeFromParent()
        entityMap.removeValue(forKey: anchor.identifier)
    }
    
    /// Toggle plane visualization visibility
    @MainActor
    func setVisualizationVisible(_ visible: Bool) {
        visualizationVisible = visible
        print("🎨 Setting iOS plane visualization visibility: \(visible)")
        
        for entity in entityMap.values {
            entity.isEnabled = visible
        }
    }
    
    // MARK: - Hit Testing
    
    func hitTest(at point: CGPoint) -> [ARHitTestResult] {
        return arView.hitTest(point, types: [.existingPlaneUsingExtent, .existingPlaneUsingGeometry])
    }
    
    func raycast(from point: CGPoint) -> [ARRaycastResult] {
        guard let query = arView.makeRaycastQuery(from: point, allowing: .existingPlaneGeometry, alignment: .any) else {
            return []
        }
        return arView.session.raycast(query)
    }
    
    // MARK: - 3D Content Placement
    
    func placeDiagram(at transform: simd_float4x4, content: Entity) {
        content.transform = Transform(matrix: transform)
        rootEntity.addChild(content)
    }
}

// MARK: - ARSessionDelegate

extension iOSARKitManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                Task { @MainActor in
                    surfaceAnchors.append(planeAnchor)
                    addPlaneVisualization(planeAnchor)
                }
            }
        }
    }
    
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                Task { @MainActor in
                    if let index = surfaceAnchors.firstIndex(where: { $0.identifier == planeAnchor.identifier }) {
                        surfaceAnchors[index] = planeAnchor
                    }
                    updatePlaneVisualization(planeAnchor)
                }
            }
        }
    }
    
    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                Task { @MainActor in
                    surfaceAnchors.removeAll { $0.identifier == planeAnchor.identifier }
                    removePlaneVisualization(planeAnchor)
                }
            }
        }
    }
    
    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor in
            switch camera.trackingState {
            case .normal:
                isTrackingReady = true
                errorMessage = nil
            case .limited(let reason):
                isTrackingReady = false
                switch reason {
                case .excessiveMotion:
                    errorMessage = "Move your device more slowly"
                case .insufficientFeatures:
                    errorMessage = "Point your device at a well-lit area with more detail"
                case .initializing:
                    errorMessage = "Initializing AR..."
                case .relocalizing:
                    errorMessage = "Relocalizing..."
                @unknown default:
                    errorMessage = "Limited tracking"
                }
            case .notAvailable:
                isTrackingReady = false
                errorMessage = "AR tracking not available"
            }
            
            print("📱 iOS ARKit tracking state: \(camera.trackingState)")
        }
    }
    
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            errorMessage = "AR session failed: \(error.localizedDescription)"
            isRunning = false
            isTrackingReady = false
        }
        print("❌ iOS ARKit session failed: \(error)")
    }
}

// MARK: - ARCoachingOverlayViewDelegate

extension iOSARKitManager: ARCoachingOverlayViewDelegate {
    nonisolated func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView) {
        print("🎯 iOS ARKit coaching overlay activated")
    }
    
    nonisolated func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) {
        print("✅ iOS ARKit coaching overlay deactivated - ready for interaction")
    }
}

// MARK: - ARPlaneAnchor Extensions

extension ARPlaneAnchor.Classification {
    var iosColor: UIColor {
        switch self {
        case .floor:
            return UIColor.blue.withAlphaComponent(0.3)
        case .wall:
            return UIColor.green.withAlphaComponent(0.3)
        case .ceiling:
            return UIColor.purple.withAlphaComponent(0.3)
        case .table:
            return UIColor.brown.withAlphaComponent(0.3)
        case .seat:
            return UIColor.orange.withAlphaComponent(0.3)
        case .door:
            return UIColor.red.withAlphaComponent(0.3)
        case .window:
            return UIColor.cyan.withAlphaComponent(0.3)
        default:
            return UIColor.gray.withAlphaComponent(0.3)
        }
    }
    
    var description: String {
        switch self {
        case .floor: return "Floor"
        case .wall: return "Wall"
        case .ceiling: return "Ceiling"
        case .table: return "Table"
        case .seat: return "Seat"
        case .door: return "Door"
        case .window: return "Window"
        default: return "Surface"
        }
    }
}

#endif