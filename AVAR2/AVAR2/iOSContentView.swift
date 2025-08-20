//
//  iOSContentView.swift
//  AVAR2
//
//  Created by Claude Code on 20-08-25.
//

#if os(iOS)
import SwiftUI
import RealityKit
import Combine

struct iOSContentView: View {
    let filename: String
    let jsonContent: String
    let onClose: () -> Void
    
    @Environment(AppModel.self) private var appModel
    @Environment(SimplifiedCollaborativeSessionManager.self) private var collaborativeManager
    @State private var rootEntity = Entity()
    @State private var isLoading = true
    @State private var loadingProgress: Float = 0.0
    
    var body: some View {
        RealityView { content in
            // Initialize the diagram entity
            rootEntity.name = "diagram_\(filename)"
            content.add(rootEntity)
            
            // Start loading the diagram
            Task {
                await loadAndDisplayDiagram()
            }
        } update: { content in
            // Handle updates if needed
        }
        .onAppear {
            print("📱 iOS ContentView appeared for: \(filename)")
        }
        .onDisappear {
            print("📱 iOS ContentView disappeared for: \(filename)")
        }
    }
    
    private func loadAndDisplayDiagram() async {
        await MainActor.run {
            isLoading = true
            loadingProgress = 0.0
        }
        
        do {
            // Load JSON content
            let data = jsonContent.data(using: .utf8) ?? Data()
            let scriptOutput = try JSONDecoder().decode(ScriptOutput.self, from: data)
            
            await MainActor.run {
                loadingProgress = 0.3
            }
            
            // Process elements
            let elementsData = scriptOutput.elements
            print("📊 iOS processing \(elementsData.count) elements for diagram: \(filename)")
            
            // Clear existing content
            rootEntity.children.removeAll()
            
            await MainActor.run {
                loadingProgress = 0.5
            }
            
            // Create elements
            var createdEntities: [Entity] = []
            for (index, elementData) in elementsData.enumerated() {
                let entity = await createElement(from: elementData, index: index)
                createdEntities.append(entity)
                
                await MainActor.run {
                    loadingProgress = 0.5 + (0.4 * Float(index + 1) / Float(elementsData.count))
                }
            }
            
            // Add all entities to root
            await MainActor.run {
                for entity in createdEntities {
                    rootEntity.addChild(entity)
                }
                
                // Apply scaling for iOS viewing
                applyiOSScaling()
                
                loadingProgress = 1.0
                isLoading = false
                
                print("✅ iOS diagram loaded successfully: \(filename) with \(createdEntities.count) entities")
            }
            
            // Send to collaborative session if active
            if collaborativeManager.isInCollaborativeSession {
                let position = rootEntity.transform.translation
                collaborativeManager.sendDiagram(filename, jsonData: jsonContent, position: position)
            }
            
        } catch {
            print("❌ iOS failed to load diagram \(filename): \(error)")
            await MainActor.run {
                isLoading = false
                // Show error state
                createErrorVisualization(error: error)
            }
        }
    }
    
    private func createElement(from elementData: ElementDTO, index: Int) async -> Entity {
        let entity = Entity()
        entity.name = "element_\(index)_\(elementData.type)"
        
        // Position
        if let position = elementData.position, position.count >= 3 {
            entity.transform.translation = SIMD3<Float>(
                Float(position[0]),
                Float(position[1]),
                Float(position[2])
            )
        }
        
        // Note: rotation and scale not supported in this ElementDTO structure
        // Default rotation and scale
        entity.transform.rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        entity.transform.scale = SIMD3<Float>(1, 1, 1)
        
        // Create visual representation
        if let shapeEntity = await createShape(for: elementData) {
            entity.addChild(shapeEntity)
        }
        
        // Add text label using type as fallback
        if let textEntity = await createTextLabel(elementData.type) {
            textEntity.position.y += 0.1 // Offset above the shape
            entity.addChild(textEntity)
        }
        
        return entity
    }
    
    private func createShape(for element: ElementDTO) async -> Entity? {
        let type = element.type
        
        let shapeEntity = Entity()
        var mesh: MeshResource?
        var materials: [RealityKit.Material] = []
        
        // Create appropriate mesh based on type or shape
        if let shape = element.shape, let shapeDesc = shape.shapeDescription {
            // Use shape description if available
            switch shapeDesc.lowercased() {
            case "box", "cube":
                mesh = MeshResource.generateBox(size: 0.1)
            case "sphere", "ball":
                mesh = MeshResource.generateSphere(radius: 0.05)
            case "cylinder":
                mesh = MeshResource.generateCylinder(height: 0.1, radius: 0.05)
            case "plane", "rectangle":
                mesh = MeshResource.generatePlane(width: 0.1, height: 0.1)
            default:
                mesh = MeshResource.generateBox(size: 0.05)
            }
        } else {
            // Fallback based on type
            switch type.lowercased() {
            case "box", "cube":
                mesh = MeshResource.generateBox(size: 0.1)
            case "sphere", "ball":
                mesh = MeshResource.generateSphere(radius: 0.05)
            case "cylinder":
                mesh = MeshResource.generateCylinder(height: 0.1, radius: 0.05)
            case "plane", "rectangle":
                mesh = MeshResource.generatePlane(width: 0.1, height: 0.1)
            default:
                mesh = MeshResource.generateBox(size: 0.05)
            }
        }
        
        // Create material
        if let mesh = mesh {
            let material: RealityKit.Material
            
            if let colorArray = element.color, colorArray.count >= 3 {
                let color = UIColor(
                    red: CGFloat(colorArray[0]),
                    green: CGFloat(colorArray[1]),
                    blue: CGFloat(colorArray[2]),
                    alpha: colorArray.count >= 4 ? CGFloat(colorArray[3]) : 1.0
                )
                material = SimpleMaterial(color: color, isMetallic: false)
            } else {
                // Default color based on element type
                let defaultColor = getDefaultColor(for: type)
                material = SimpleMaterial(color: defaultColor, isMetallic: false)
            }
            
            materials.append(material)
            
            let modelEntity = ModelEntity(mesh: mesh, materials: materials)
            shapeEntity.addChild(modelEntity)
            
            // Add interaction components for iOS
            modelEntity.components.set(InputTargetComponent())
            do {
                let collisionShape = try await ShapeResource.generateConvex(from: mesh)
                modelEntity.components.set(CollisionComponent(shapes: [collisionShape]))
            } catch {
                print("❌ Failed to generate collision shape: \(error)")
            }
        }
        
        return shapeEntity
    }
    
    private func createTextLabel(_ text: String) async -> Entity? {
        let textMesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: 0.02),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        
        let textMaterial = UnlitMaterial(color: .white)
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        
        return textEntity
    }
    
    private func applyiOSScaling() {
        // Scale down the entire diagram for mobile AR viewing
        let scaleFactor: Float = 0.3 // Much smaller for phone screens
        rootEntity.transform.scale = SIMD3<Float>(scaleFactor, scaleFactor, scaleFactor)
        
        // Position slightly above the ground
        rootEntity.transform.translation.y += 0.1
    }
    
    private func createErrorVisualization(error: Error) {
        // Create a simple error indicator
        let errorEntity = Entity()
        let mesh = MeshResource.generateBox(size: 0.05)
        let material = SimpleMaterial(color: .red, isMetallic: false)
        let modelEntity = ModelEntity(mesh: mesh, materials: [material])
        
        errorEntity.addChild(modelEntity)
        rootEntity.addChild(errorEntity)
        
        print("🚨 iOS error visualization created for: \(filename)")
    }
    
    private func getDefaultColor(for elementType: String) -> UIColor {
        switch elementType.lowercased() {
        case "box", "cube":
            return .systemBlue
        case "sphere", "ball":
            return .systemGreen
        case "cylinder":
            return .systemOrange
        case "plane", "rectangle":
            return .systemPurple
        default:
            return .systemGray
        }
    }
}

// MARK: - iOS-specific Extensions

extension Entity {
    func findChildEntity(named name: String) -> Entity? {
        if self.name == name {
            return self
        }
        
        for child in children {
            if let found = child.findChildEntity(named: name) {
                return found
            }
        }
        
        return nil
    }
}

#endif