//
//  iOSARViewContainer.swift
//  AVAR2
//
//  Created by Claude Code on 20-08-25.
//

#if os(iOS)
import SwiftUI
import ARKit
import RealityKit

struct ARViewContainer: UIViewRepresentable {
    let arManager: iOSARKitManager
    
    func makeUIView(context: Context) -> ARView {
        let arView = arManager.getARView()
        
        // Setup gesture recognizers for interaction
        setupGestureRecognizers(arView: arView, context: context)
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        // Update ARView if needed
    }
    
    private func setupGestureRecognizers(arView: ARView, context: Context) {
        // Tap gesture for placing diagrams
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
        
        // Pan gesture for moving diagrams
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        arView.addGestureRecognizer(panGesture)
        
        // Pinch gesture for scaling diagrams
        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        arView.addGestureRecognizer(pinchGesture)
        
        // Rotation gesture for rotating diagrams
        let rotationGesture = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation(_:)))
        arView.addGestureRecognizer(rotationGesture)
        
        // Allow simultaneous gestures
        tapGesture.delegate = context.coordinator
        panGesture.delegate = context.coordinator
        pinchGesture.delegate = context.coordinator
        rotationGesture.delegate = context.coordinator
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(arManager: arManager)
    }
    
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let arManager: iOSARKitManager
        private var selectedEntity: Entity?
        private var initialTransform: Transform?
        
        init(arManager: iOSARKitManager) {
            self.arManager = arManager
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let location = gesture.location(in: gesture.view)
            let arView = arManager.getARView()
            
            // Try to hit test existing entities first
            if let hitEntity = arView.entity(at: location) {
                // Select/deselect entity
                if selectedEntity == hitEntity {
                    deselectEntity()
                } else {
                    selectEntity(hitEntity)
                }
                return
            }
            
            // If no entity hit, try to place new diagram
            let raycastResults = arManager.raycast(from: location)
            guard let result = raycastResults.first else { return }
            
            // Notify about placement location
            NotificationCenter.default.post(
                name: NSNotification.Name("DiagramPlacementRequested"),
                object: result.worldTransform
            )
            
            print("📍 iOS placement requested at: \(result.worldTransform.columns.3)")
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let selectedEntity = selectedEntity else { return }
            
            let location = gesture.location(in: gesture.view)
            let arView = arManager.getARView()
            
            switch gesture.state {
            case .began:
                initialTransform = selectedEntity.transform
                
            case .changed:
                // Perform raycast to get new position
                let raycastResults = arManager.raycast(from: location)
                if let result = raycastResults.first {
                    selectedEntity.transform.translation = SIMD3<Float>(
                        result.worldTransform.columns.3.x,
                        result.worldTransform.columns.3.y + 0.1, // Offset slightly above surface
                        result.worldTransform.columns.3.z
                    )
                }
                
            case .ended, .cancelled:
                // Send position update to collaborative session
                if let appModel = getAppModel() {
                    let position = selectedEntity.transform.translation
                    // Notify about position change
                    NotificationCenter.default.post(
                        name: NSNotification.Name("DiagramPositionChanged"),
                        object: ["entity": selectedEntity, "position": position]
                    )
                }
                
            default:
                break
            }
        }
        
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let selectedEntity = selectedEntity else { return }
            
            switch gesture.state {
            case .began:
                initialTransform = selectedEntity.transform
                
            case .changed:
                let scale = Float(gesture.scale)
                if let initialTransform = initialTransform {
                    selectedEntity.transform.scale = initialTransform.scale * scale
                }
                
            case .ended:
                gesture.scale = 1.0
                
            default:
                break
            }
        }
        
        @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
            guard let selectedEntity = selectedEntity else { return }
            
            switch gesture.state {
            case .began:
                initialTransform = selectedEntity.transform
                
            case .changed:
                let rotation = Float(gesture.rotation)
                if let initialTransform = initialTransform {
                    // Rotate around Y-axis
                    let rotationQuat = simd_quatf(angle: rotation, axis: SIMD3<Float>(0, 1, 0))
                    selectedEntity.transform.rotation = initialTransform.rotation * rotationQuat
                }
                
            case .ended:
                gesture.rotation = 0
                
            default:
                break
            }
        }
        
        private func selectEntity(_ entity: Entity) {
            // Deselect previous entity
            deselectEntity()
            
            selectedEntity = entity
            
            // Add selection visual indicator
            let outlineMaterial = UnlitMaterial(color: .yellow)
            
            // Create outline effect (simplified approach)
            if let modelEntity = entity as? ModelEntity {
                // Store original materials
                entity.components[SelectionComponent.self] = SelectionComponent(
                    originalMaterials: modelEntity.model?.materials ?? []
                )
                
                // Apply selection material
                let selectionMaterials = modelEntity.model?.materials.map { _ in outlineMaterial } ?? []
                modelEntity.model?.materials = selectionMaterials
            }
            
            print("🎯 iOS entity selected: \(entity.name)")
        }
        
        private func deselectEntity() {
            guard let selectedEntity = selectedEntity else { return }
            
            // Restore original materials
            if let modelEntity = selectedEntity as? ModelEntity,
               let selectionComponent = selectedEntity.components[SelectionComponent.self] {
                modelEntity.model?.materials = selectionComponent.originalMaterials
                selectedEntity.components.remove(SelectionComponent.self)
            }
            
            self.selectedEntity = nil
            print("🎯 iOS entity deselected")
        }
        
        private func getAppModel() -> AppModel? {
            // This would need to be injected or accessed through environment
            return nil
        }
        
        // MARK: - UIGestureRecognizerDelegate
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Allow pinch and rotation to work together
            return (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIRotationGestureRecognizer) ||
                   (gestureRecognizer is UIRotationGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer)
        }
    }
}

// Component to store original materials for selection
struct SelectionComponent: Component {
    let originalMaterials: [RealityKit.Material]
}

#endif