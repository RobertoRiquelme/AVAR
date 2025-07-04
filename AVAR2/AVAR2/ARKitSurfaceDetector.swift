import RealityKit
import ARKit
import UIKit

@MainActor
final class ARKitSurfaceDetector: ObservableObject {
    private let session = ARKitSession()
    private let provider = PlaneDetectionProvider(alignments: [.horizontal, .vertical])
    let rootEntity = Entity()

    @Published var surfaceAnchors: [PlaneAnchor] = []
    @Published var isRunning = false
    @Published var errorMessage: String?

    func run() async {
        guard PlaneDetectionProvider.isSupported else {
            await MainActor.run {
                errorMessage = "PlaneDetectionProvider is NOT supported."
            }
            return
        }

        do {
            try await session.run([provider])
            await MainActor.run {
                isRunning = true
            }
            print("ARKit session is running...")
            
            for await update in provider.anchorUpdates {
                print("Surface detected: \(update.anchor.classification.description)")
                
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
            
            // Create visual representation
            createVisualEntity(for: anchor)
        }
    }
    
    private func removeSurface(_ anchor: PlaneAnchor) {
        Task { @MainActor in
            surfaceAnchors.removeAll { $0.id == anchor.id }
            
            // Remove visual entity
            if let entity = rootEntity.children.first(where: { $0.name == "surface_\(anchor.id)" }) {
                entity.removeFromParent()
            }
        }
    }
    
    private func createVisualEntity(for anchor: PlaneAnchor) {
        // Remove existing entity if it exists
        if let existingEntity = rootEntity.children.first(where: { $0.name == "surface_\(anchor.id)" }) {
            existingEntity.removeFromParent()
        }
        
        // Create new entity
        let entity = Entity()
        entity.name = "surface_\(anchor.id)"
        
        let material = UnlitMaterial(color: anchor.classification.color)
        let planeEntity = ModelEntity(
            mesh: .generatePlane(width: anchor.geometry.extent.width, height: anchor.geometry.extent.height),
            materials: [material]
        )
        planeEntity.transform = Transform(matrix: anchor.geometry.extent.anchorFromExtentTransform)
        
        let textEntity = ModelEntity(
            mesh: .generateText(anchor.classification.description)
        )
        textEntity.scale = SIMD3(0.01, 0.01, 0.01)
        
        entity.addChild(planeEntity)
        planeEntity.addChild(textEntity)
        
        // Set world position
        entity.transform = Transform(matrix: anchor.originFromAnchorTransform)
        
        rootEntity.addChild(entity)
    }
}

// Extension for surface classification colors
extension PlaneAnchor.Classification {
    var color: UIColor {
        switch self {
        case .wall:
            return UIColor.blue.withAlphaComponent(0.65)
        case .floor:
            return UIColor.red.withAlphaComponent(0.65)
        case .ceiling:
            return UIColor.green.withAlphaComponent(0.65)
        case .table:
            return UIColor.yellow.withAlphaComponent(0.65)
        case .door:
            return UIColor.brown.withAlphaComponent(0.65)
        case .seat:
            return UIColor.systemPink.withAlphaComponent(0.65)
        case .window:
            return UIColor.orange.withAlphaComponent(0.65)
        case .undetermined:
            return UIColor.lightGray.withAlphaComponent(0.65)
        case .notAvailable:
            return UIColor.gray.withAlphaComponent(0.65)
        case .unknown:
            return UIColor.black.withAlphaComponent(0.65)
        @unknown default:
            return UIColor.purple
        }
    }
}