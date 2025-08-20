#if os(visionOS)
import RealityKit
import ARKit
import UIKit
import SwiftUI

@MainActor
final class ARKitSurfaceDetector: ObservableObject {
    private let session = ARKitSession()
    private let provider = PlaneDetectionProvider(alignments: [.horizontal, .vertical])
    let rootEntity = Entity()

    @Published var surfaceAnchors: [PlaneAnchor] = []
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var entityMap: [UUID: Entity] = [:]
    
    // Debug: plane visualization toggle
    private var visualizationVisible = true

    func run() async {
        guard PlaneDetectionProvider.isSupported else {
            await MainActor.run {
                errorMessage = "PlaneDetectionProvider is NOT supported."
            }
            return
        }

        guard !isRunning else {
            print("🚫 ARKit session already running - PERSISTENT surfaces maintained")
            return
        }

        do {
            try await session.run([provider])
            await MainActor.run {
                isRunning = true
            }
            print("🚀 ARKit session STARTED - detecting surfaces for entire app session...")
            
            for await update in provider.anchorUpdates {
                print("🔍 Surface update: \(update.anchor.classification.description) - \(update.event)")
                
                // Skip windows
                if update.anchor.classification == .window { continue }

                switch update.event {
                case .added, .updated:
                    updateSurface(update.anchor)
                case .removed:
                    removeSurface(update.anchor)
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "ARKit session error: \(error)"
            }
            print("ARKit session error: \(error)")
        }
    }
    
    private func updateSurface(_ anchor: PlaneAnchor) {
        Task { @MainActor in
            // Update or add surface anchor
            if let index = surfaceAnchors.firstIndex(where: { $0.id == anchor.id }) {
                surfaceAnchors[index] = anchor
            } else {
                surfaceAnchors.append(anchor)
            }
            
            // Create or update visual representation
            await updatePlaneVisualization(anchor)
        }
    }
    
    private func removeSurface(_ anchor: PlaneAnchor) {
        Task { @MainActor in
            surfaceAnchors.removeAll { $0.id == anchor.id }
            removePlaneVisualization(anchor)
        }
    }
    
    @MainActor
    private func updatePlaneVisualization(_ anchor: PlaneAnchor) {
        if let entity = entityMap[anchor.id] {
            print("🔄 Updating existing plane visualization: \(anchor.id), classification: \(anchor.classification.description)")
            let planeEntity = entity.findEntity(named: "plane") as! ModelEntity
            let newMesh = MeshResource.generatePlane(width: anchor.geometry.extent.width, height: anchor.geometry.extent.height)
            planeEntity.model!.mesh = newMesh
            planeEntity.transform = Transform(matrix: anchor.geometry.extent.anchorFromExtentTransform)
        } else {
            print("➕ Adding new plane visualization: \(anchor.id), classification: \(anchor.classification.description)")
            // Create a new entity to represent this plane
            let entity = Entity()
            
            // Create plane visualization with color based on classification
            let material = UnlitMaterial(color: anchor.classification.color)
            let planeEntity = ModelEntity(
                mesh: .generatePlane(width: anchor.geometry.extent.width, height: anchor.geometry.extent.height),
                materials: [material]
            )
            planeEntity.name = "plane"
            planeEntity.transform = Transform(matrix: anchor.geometry.extent.anchorFromExtentTransform)
            
            // Add classification label
            let textEntity = ModelEntity(
                mesh: .generateText(anchor.classification.description)
            )
            textEntity.scale = SIMD3(0.01, 0.01, 0.01)
            
            entity.addChild(planeEntity)
            planeEntity.addChild(textEntity)
            
            entityMap[anchor.id] = entity
            rootEntity.addChild(entity)
        }
        
        // Update entity position and orientation in world space
        entityMap[anchor.id]?.transform = Transform(matrix: anchor.originFromAnchorTransform)
        
        // Apply current visibility state
        entityMap[anchor.id]?.isEnabled = visualizationVisible
    }
    
    @MainActor
    private func removePlaneVisualization(_ anchor: PlaneAnchor) {
        print("🗑️ Removing plane visualization: \(anchor.id)")
        entityMap[anchor.id]?.removeFromParent()
        entityMap.removeValue(forKey: anchor.id)
    }
    
    /// Toggle plane visualization visibility for debugging
    @MainActor
    func setVisualizationVisible(_ visible: Bool) {
        visualizationVisible = visible
        print("🎨 Setting plane visualization visibility: \(visible)")
        
        // Update visibility of all existing plane entities
        for entity in entityMap.values {
            entity.isEnabled = visible
        }
    }
}
#endif
