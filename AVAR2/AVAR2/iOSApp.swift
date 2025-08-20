//
//  iOSApp.swift
//  AVAR2
//
//  Created by Claude Code on 20-08-25.
//

#if os(iOS)
import SwiftUI
import RealityKit

@main
struct AVAR2_iOS: App {
    @State private var appModel = AppModel()
    @StateObject private var httpServer = HTTPServer()
    @StateObject private var arKitManager = iOSARKitManager()
    @State private var collaborativeManager = SimplifiedCollaborativeSessionManager()
    
    var body: some SwiftUI.Scene {
        WindowGroup {
            iOSMainView()
                .environment(appModel)
                .environment(collaborativeManager)
                .environmentObject(httpServer)
                .environmentObject(arKitManager)
        }
    }
}

struct iOSMainView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SimplifiedCollaborativeSessionManager.self) private var collaborativeManager
    @EnvironmentObject private var httpServer: HTTPServer
    @EnvironmentObject private var arKitManager: iOSARKitManager
    @Environment(\.scenePhase) private var scenePhase
    
    // App state
    @State private var showingSettings = false
    @State private var isARViewVisible = true
    @State private var selectedDiagramFile: String?
    @State private var pendingPlacementTransform: simd_float4x4?
    
    // UI state
    @State private var showingToast = false
    @State private var toastMessage = ""
    @State private var toastIcon = ""
    @State private var toastColor = Color.blue
    
    var body: some View {
        ZStack {
            if isARViewVisible {
                // AR Camera view
                ARViewContainer(arManager: arKitManager)
                    .ignoresSafeArea()
                    .onAppear {
                        Task {
                            await arKitManager.run()
                        }
                    }
                    .onDisappear {
                        arKitManager.stop()
                    }
                
                // AR Status overlay
                arStatusOverlay
                
                // Main controls overlay
                mainControlsOverlay
                
                // Bottom toolbar
                bottomToolbar
                
            } else {
                // Settings/Control panel view
                settingsView
            }
            
            // Toast notification
            if showingToast {
                toastView
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                arKitManager.stop()
            } else if newPhase == .active && isARViewVisible {
                Task {
                    await arKitManager.run()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DiagramPlacementRequested"))) { notification in
            if let transform = notification.object as? simd_float4x4 {
                pendingPlacementTransform = transform
                showDiagramSelector()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DiagramPositionChanged"))) { notification in
            if let data = notification.object as? [String: Any],
               let entity = data["entity"] as? Entity,
               let position = data["position"] as? SIMD3<Float> {
                handleDiagramPositionChange(entity: entity, position: position)
            }
        }
        .task {
            setupCollaborativeCallbacks()
            setupHTTPServerCallbacks()
        }
    }
    
    @ViewBuilder
    private var arStatusOverlay: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle()
                            .fill(arKitManager.isTrackingReady ? .green : .orange)
                            .frame(width: 8, height: 8)
                        
                        Text(arKitManager.isTrackingReady ? "Tracking Ready" : "Initializing...")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    
                    if let errorMessage = arKitManager.errorMessage {
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.leading)
                    }
                    
                    Text("Surfaces: \(arKitManager.surfaceAnchors.count)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: {
                    showingSettings.toggle()
                    isARViewVisible.toggle()
                }) {
                    Image(systemName: showingSettings ? "xmark.circle.fill" : "gearshape.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .background(Circle().fill(.black.opacity(0.6)))
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .padding()
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private var mainControlsOverlay: some View {
        VStack {
            Spacer()
            
            HStack {
                Spacer()
                
                VStack(spacing: 12) {
                    // Place diagram button
                    Button(action: {
                        requestDiagramPlacement()
                    }) {
                        VStack {
                            Image(systemName: "plus.circle.fill")
                                .font(.title)
                            Text("Add Diagram")
                                .font(.caption2)
                        }
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Circle().fill(.blue.opacity(0.8)))
                    .disabled(!arKitManager.isTrackingReady)
                    
                    // Toggle plane visualization
                    Button(action: {
                        appModel.togglePlaneVisualization()
                        arKitManager.setVisualizationVisible(appModel.showPlaneVisualization)
                    }) {
                        VStack {
                            Image(systemName: appModel.showPlaneVisualization ? "eye.slash.fill" : "eye.fill")
                                .font(.title2)
                            Text("Planes")
                                .font(.caption2)
                        }
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Circle().fill(.gray.opacity(0.8)))
                }
                .padding()
            }
        }
    }
    
    @ViewBuilder
    private var bottomToolbar: some View {
        VStack {
            Spacer()
            
            HStack {
                // Collaboration status
                CollaborativeStatusButton(
                    collaborativeManager: collaborativeManager,
                    showToast: showToast
                )
                
                Spacer()
                
                // HTTP Server indicator
                if httpServer.isRunning {
                    HStack {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        
                        Text("Server Active")
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var settingsView: some View {
        NavigationView {
            List {
                Section("AR Session") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(arKitManager.isRunning ? "Running" : "Stopped")
                            .foregroundColor(arKitManager.isRunning ? .green : .red)
                    }
                    
                    HStack {
                        Text("Surfaces Detected")
                        Spacer()
                        Text("\(arKitManager.surfaceAnchors.count)")
                    }
                    
                    Toggle("Show Plane Visualization", isOn: Binding(
                        get: { appModel.showPlaneVisualization },
                        set: { newValue in
                            appModel.showPlaneVisualization = newValue
                            arKitManager.setVisualizationVisible(newValue)
                        }
                    ))
                }
                
                Section("HTTP Server") {
                    HTTPServerControlsView(httpServer: httpServer)
                }
                
                Section("Collaboration") {
                    CollaborativeSessionView(
                        collaborativeManager: collaborativeManager,
                        showToast: showToast
                    )
                }
                
                Section("Debug") {
                    Button("Reset AR Session") {
                        Task {
                            arKitManager.stop()
                            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                            await arKitManager.run()
                        }
                    }
                    
                    Button("Clear All Diagrams") {
                        appModel.clearAllDiagrams()
                        // Remove all diagram entities from AR scene
                        let entities = arKitManager.rootEntity.children.filter { entity in
                            entity.name.contains("diagram")
                        }
                        entities.forEach { $0.removeFromParent() }
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("AVAR2 Settings")
            .navigationBarItems(trailing: Button("Done") {
                showingSettings = false
                isARViewVisible = true
            })
        }
    }
    
    @ViewBuilder
    private var toastView: some View {
        VStack {
            HStack {
                Image(systemName: toastIcon)
                    .foregroundColor(toastColor)
                Text(toastMessage)
                    .foregroundColor(toastColor)
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .padding()
            
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    showingToast = false
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func showToast(message: String, icon: String, color: Color) {
        toastMessage = message
        toastIcon = icon
        toastColor = color
        
        withAnimation {
            showingToast = true
        }
    }
    
    private func requestDiagramPlacement() {
        // Show diagram selector first
        showDiagramSelector()
    }
    
    private func showDiagramSelector() {
        // This would show a picker for available diagrams
        // For now, we'll use a default diagram
        placeDiagramInFrontOfUser(filename: "Simple Tree")
    }
    
    private func placeDiagramInFrontOfUser(filename: String) {
        // Create a transform 1 meter in front of the user at their eye level
        let cameraTransform = arKitManager.getARView().session.currentFrame?.camera.transform ?? matrix_identity_float4x4
        var placementTransform = cameraTransform
        
        // Move 1 meter forward (negative Z in camera space)
        placementTransform.columns.3.z -= 1.0
        // Slightly below eye level for better visibility
        placementTransform.columns.3.y -= 0.3
        
        Task {
            // Load diagram and create 3D representation
            if let content = await loadDiagramContent(filename: filename) {
                let diagramEntity = await createDiagramEntity(filename: filename, content: content)
                arKitManager.placeDiagram(at: placementTransform, content: diagramEntity)
                
                // Send to collaborative session if active
                if collaborativeManager.isInCollaborativeSession {
                    let position = SIMD3<Float>(placementTransform.columns.3.x, placementTransform.columns.3.y, placementTransform.columns.3.z)
                    collaborativeManager.sendDiagram(filename, jsonData: content, position: position)
                }
                
                showToast(message: "Diagram placed: \(filename)", icon: "checkmark.circle.fill", color: .green)
            } else {
                showToast(message: "Failed to load: \(filename)", icon: "xmark.circle.fill", color: .red)
            }
        }
    }
    
    private func placeDiagramAtPendingLocation(filename: String) {
        guard let transform = pendingPlacementTransform else { 
            showToast(message: "Tap on a surface first", icon: "hand.point.up.left", color: .orange)
            return 
        }
        
        Task {
            // Load diagram and create 3D representation
            if let content = await loadDiagramContent(filename: filename) {
                let diagramEntity = await createDiagramEntity(filename: filename, content: content)
                arKitManager.placeDiagram(at: transform, content: diagramEntity)
                
                // Send to collaborative session if active
                if collaborativeManager.isInCollaborativeSession {
                    let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                    collaborativeManager.sendDiagram(filename, jsonData: content, position: position)
                }
                
                showToast(message: "Diagram placed: \(filename)", icon: "checkmark.circle.fill", color: .green)
            }
        }
        
        pendingPlacementTransform = nil
    }
    
    private func loadDiagramContent(filename: String) async -> String? {
        print("📁 iOS attempting to load diagram: \(filename)")
        
        guard let url = Bundle.main.url(forResource: filename, withExtension: "txt") else {
            print("❌ iOS could not find file: \(filename).txt")
            return nil
        }
        
        guard let content = try? String(contentsOf: url) else {
            print("❌ iOS could not read content from: \(url.path)")
            return nil
        }
        
        print("✅ iOS loaded diagram content: \(content.count) characters from \(filename)")
        return content
    }
    
    private func createDiagramEntity(filename: String, content: String) async -> Entity {
        let rootEntity = Entity()
        rootEntity.name = "diagram_\(filename)"
        
        do {
            // Parse the JSON content
            let data = content.data(using: .utf8) ?? Data()
            let scriptOutput = try JSONDecoder().decode(ScriptOutput.self, from: data)
            
            print("📊 iOS creating diagram with \(scriptOutput.elements.count) elements for: \(filename)")
            
            // Create elements
            for (index, elementData) in scriptOutput.elements.enumerated() {
                let elementEntity = await createElementEntity(from: elementData, index: index)
                rootEntity.addChild(elementEntity)
            }
            
            // Apply scaling for iOS viewing
            let scaleFactor: Float = 0.3 // Much smaller for phone screens
            rootEntity.transform.scale = SIMD3<Float>(scaleFactor, scaleFactor, scaleFactor)
            
            print("✅ iOS diagram created successfully: \(filename) with \(scriptOutput.elements.count) elements")
            
        } catch {
            print("❌ iOS failed to create diagram \(filename): \(error)")
            // Fallback to placeholder
            let mesh = MeshResource.generateBox(size: 0.1)
            let material = SimpleMaterial(color: .red, isMetallic: false)
            let modelEntity = ModelEntity(mesh: mesh, materials: [material])
            rootEntity.addChild(modelEntity)
        }
        
        return rootEntity
    }
    
    private func createElementEntity(from elementData: ElementDTO, index: Int) async -> Entity {
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
        
        // Default rotation and scale
        entity.transform.rotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        entity.transform.scale = SIMD3<Float>(1, 1, 1)
        
        // Create visual representation
        if let shapeEntity = await createShapeEntity(for: elementData) {
            entity.addChild(shapeEntity)
        }
        
        // Add text label using type as identifier
        if let textEntity = await createTextEntity(elementData.type) {
            textEntity.position.y += 0.1 // Offset above the shape
            entity.addChild(textEntity)
        }
        
        return entity
    }
    
    private func createShapeEntity(for element: ElementDTO) async -> Entity? {
        let type = element.type
        let shapeEntity = Entity()
        var mesh: MeshResource?
        
        // Create appropriate mesh based on type or shape
        if let shape = element.shape, let shapeDesc = shape.shapeDescription {
            // Use shape description if available
            switch shapeDesc.lowercased() {
            case "box", "cube":
                mesh = MeshResource.generateBox(size: 0.1)
            case "sphere", "ball", "uvsphere":
                mesh = MeshResource.generateSphere(radius: 0.05)
            case "cylinder":
                mesh = MeshResource.generateCylinder(height: 0.1, radius: 0.05)
            case "line":
                // Create thin cylinder for lines
                if let extent = shape.extent, extent.count >= 3 {
                    let length = max(Float(extent[1]), 0.05) // Use Y component for length
                    mesh = MeshResource.generateCylinder(height: length, radius: 0.005) // Very thin
                } else {
                    mesh = MeshResource.generateCylinder(height: 0.1, radius: 0.005)
                }
            case "plane", "rectangle":
                mesh = MeshResource.generatePlane(width: 0.1, height: 0.1)
            default:
                print("⚠️ Unknown shape description: '\(shapeDesc)'")
                mesh = MeshResource.generateBox(size: 0.05)
            }
        } else {
            // Fallback based on type (for elements without shape info)
            switch type.lowercased() {
            case "box", "cube":
                mesh = MeshResource.generateBox(size: 0.1)
            case "sphere", "ball", "uvsphere":
                mesh = MeshResource.generateSphere(radius: 0.05)
            case "cylinder":
                mesh = MeshResource.generateCylinder(height: 0.1, radius: 0.05)
            case "plane", "rectangle":
                mesh = MeshResource.generatePlane(width: 0.1, height: 0.1)
            case "camera":
                // Camera represented as a small box
                mesh = MeshResource.generateBox(size: 0.06)
            case "line":
                // Default line
                mesh = MeshResource.generateCylinder(height: 0.1, radius: 0.005)
            default:
                print("⚠️ Unknown element type: '\(type)'")
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
                let defaultColor = getDefaultColorForElement(type: type)
                material = SimpleMaterial(color: defaultColor, isMetallic: false)
            }
            
            let modelEntity = ModelEntity(mesh: mesh, materials: [material])
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
    
    private func createTextEntity(_ text: String) async -> Entity? {
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
    
    private func getDefaultColorForElement(type: String) -> UIColor {
        switch type.lowercased() {
        case "box", "cube":
            return .systemBlue
        case "sphere", "ball", "uvsphere":
            return .systemGreen
        case "cylinder":
            return .systemOrange
        case "plane", "rectangle":
            return .systemPurple
        case "line":
            return .systemBrown
        case "camera":
            return .systemYellow
        default:
            return .systemGray
        }
    }
    
    private func handleDiagramPositionChange(entity: Entity, position: SIMD3<Float>) {
        if collaborativeManager.isInCollaborativeSession {
            collaborativeManager.sendDiagramPosition(entity.name, position: position)
        }
    }
    
    private func setupCollaborativeCallbacks() {
        collaborativeManager.onDiagramReceived = { diagramData in
            Task { @MainActor in
                // Create and place received diagram
                let entity = await createDiagramEntity(filename: diagramData.filename, content: diagramData.jsonData)
                let transform = simd_float4x4(
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(diagramData.position.x, diagramData.position.y, diagramData.position.z, 1)
                )
                arKitManager.placeDiagram(at: transform, content: entity)
                
                showToast(
                    message: "Received diagram: \(diagramData.filename)",
                    icon: "arrow.down.circle.fill",
                    color: .green
                )
            }
        }
    }
    
    private func setupHTTPServerCallbacks() {
        // Start HTTP server
        if !httpServer.isRunning {
            httpServer.start()
        }
        
        // Handle received diagrams
        httpServer.onJSONReceived = { scriptOutput in
            Task { @MainActor in
                // Convert and place HTTP diagram
                let filename = "http_diagram_\(UUID().uuidString.prefix(8))"
                let jsonData = try? JSONEncoder().encode(scriptOutput)
                let jsonString = String(data: jsonData ?? Data(), encoding: .utf8) ?? ""
                
                let entity = await createDiagramEntity(filename: filename, content: jsonString)
                
                // Place at default location (in front of user)
                let transform = simd_float4x4(
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, -1, 1) // 1 meter in front
                )
                
                arKitManager.placeDiagram(at: transform, content: entity)
                
                showToast(
                    message: "HTTP diagram received",
                    icon: "network",
                    color: .blue
                )
            }
        }
    }
}

// MARK: - Supporting Views

struct CollaborativeStatusButton: View {
    let collaborativeManager: SimplifiedCollaborativeSessionManager
    let showToast: (String, String, Color) -> Void
    @State private var showingFullControls = false
    
    var body: some View {
        Button(action: {
            showingFullControls.toggle()
        }) {
            HStack {
                Image(systemName: collaborativeManager.isInCollaborativeSession ? "person.2.fill" : "person.2")
                    .foregroundColor(collaborativeManager.isInCollaborativeSession ? .green : .gray)
                
                if collaborativeManager.isInCollaborativeSession {
                    Text("\(collaborativeManager.sessionParticipantCount)")
                        .font(.caption)
                        .fontWeight(.bold)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
        }
        .sheet(isPresented: $showingFullControls) {
            NavigationView {
                CollaborativeSessionView(
                    collaborativeManager: collaborativeManager,
                    showToast: showToast
                )
                .navigationTitle("Collaboration")
                .navigationBarItems(trailing: Button("Done") {
                    showingFullControls = false
                })
            }
        }
    }
}

struct HTTPServerControlsView: View {
    @ObservedObject var httpServer: HTTPServer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(httpServer.isRunning ? "Stop Server" : "Start Server") {
                    if httpServer.isRunning {
                        httpServer.stop()
                    } else {
                        httpServer.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                
                Spacer()
                
                Text(httpServer.isRunning ? "Running" : "Stopped")
                    .font(.caption)
                    .foregroundColor(httpServer.isRunning ? .green : .red)
            }
            
            if httpServer.isRunning {
                Text("URL: \(httpServer.serverURL)")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            
            Text("Status: \(httpServer.serverStatus)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#endif