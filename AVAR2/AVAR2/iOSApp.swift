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
            
            // Create normalization context like visionOS
            let normalizationContext = NormalizationContext(elements: scriptOutput.elements, is2D: scriptOutput.is2D)
            var entityMap: [String: Entity] = [:]
            
            // Create individual elements (excluding line/connection elements)
            for element in scriptOutput.elements {
                // Skip elements without positions like visionOS does
                guard let coords = element.position else {
                    print("🚫 Skipping element \(element.id?.description ?? "unknown") - no position")
                    continue
                }
                
                // Skip line elements - they will be created as connections
                if element.shape?.shapeDescription?.lowercased().contains("line") == true {
                    print("🔗 Skipping line element \(element.id?.description ?? "unknown") - will create as connection")
                    continue
                }
                
                let entity = createElementEntity(for: element, normalization: normalizationContext)
                let localPos = calculateElementPosition(coords: coords, normalizationContext: normalizationContext)
                
                entity.position = localPos
                entity.generateCollisionShapes(recursive: true)
                entity.components.set(InputTargetComponent())
                rootEntity.addChild(entity)
                
                // Store in entity map for connection creation
                let elementIdKey = element.id != nil ? String(element.id!) : "element_\(UUID().uuidString.prefix(8))"
                entityMap[elementIdKey] = entity
                
                print("📍 iOS Element \(element.id?.description ?? "unknown") positioned at \(localPos)")
            }
            
            // Create connections between elements (like visionOS does)
            print("🔍 Looking for connections in \(scriptOutput.elements.count) elements")
            var connectionsCreated = 0
            for edge in scriptOutput.elements {
                print("🔍 Element \(edge.id?.description ?? "unknown"): fromId=\(edge.fromId?.description ?? "nil"), toId=\(edge.toId?.description ?? "nil")")
                if let from = edge.fromId, let to = edge.toId,
                   let line = createLineBetween(String(from), String(to), entityMap: entityMap, colorComponents: edge.color ?? edge.shape?.color) {
                    rootEntity.addChild(line)
                    connectionsCreated += 1
                    print("🔗 iOS connection created: \(from) -> \(to)")
                }
            }
            print("✅ Created \(connectionsCreated) connections total")
            
            // Apply scaling for iOS viewing (like visionOS container scaling)
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
    
    private func createElementEntity(for element: ElementDTO, normalization: NormalizationContext) -> Entity {
        // Handle RTlabel elements like visionOS
        let desc = element.shape?.shapeDescription?.lowercased() ?? ""
        if desc.contains("rtlabel") {
            // Create text-only entity for labels (simplified for iOS)
            let entity = Entity()
            entity.name = element.id != nil ? "element_\(element.id!)" : "element_\(UUID().uuidString.prefix(8))"
            
            if let text = element.shape?.text, !text.isEmpty, text.lowercased() != "nil" {
                if let textEntity = createTextEntity(text) {
                    entity.addChild(textEntity)
                }
            }
            
            return entity
        }
        
        // Use ShapeFactory approach like visionOS
        let (mesh, material) = element.meshAndMaterial(normalization: normalization)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        
        // Handle orientation for certain shapes like visionOS
        if desc.contains("rtellipse") {
            entity.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        }
        
        entity.name = element.id != nil ? "element_\(element.id!)" : "element_\(UUID().uuidString.prefix(8))"
        
        // Add label if meaningful (following visionOS logic)
        let rawText = element.shape?.text
        let labelText: String? = {
            if let t = rawText, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               t.lowercased() != "nil" {
                return t
            }
            return element.id == nil ? nil : ""
        }()
        
        if let text = labelText {
            if let labelEntity = createTextEntity(text) {
                labelEntity.position.y += 0.1
                entity.addChild(labelEntity)
            }
        }
        
        return entity
    }
    
    private func calculateElementPosition(coords: [Double], normalizationContext: NormalizationContext) -> SIMD3<Float> {
        let dims = normalizationContext.is2D ? 2 : 3
        var normalizedCoords = [Float]()
        
        for i in 0..<3 {
            if i < dims && i < coords.count {
                let coord = coords[i]
                let center = normalizationContext.positionCenters[i]
                let range = normalizationContext.positionRanges[i]
                let globalRange = normalizationContext.globalRange
                
                // Normalize: center around 0, scale by global range to preserve aspect ratio
                let normalized = Float((coord - center) / globalRange)
                normalizedCoords.append(normalized)
            } else {
                normalizedCoords.append(0)
            }
        }
        
        return SIMD3<Float>(normalizedCoords[0], normalizedCoords[1], normalizedCoords[2])
    }
    
    private func createTextEntity(_ text: String) -> Entity? {
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
    
    private func createLineBetween(_ id1: String, _ id2: String, entityMap: [String: Entity], colorComponents: [Double]?) -> ModelEntity? {
        guard let entity1 = entityMap[id1], let entity2 = entityMap[id2] else { 
            print("⚠️ Cannot create line: missing entities for \(id1) -> \(id2)")
            return nil
        }
        
        let pos1 = entity1.position
        let pos2 = entity2.position
        let lineVector = pos2 - pos1
        let length = simd_length(lineVector)
        
        // Create thin box as line (make thicker for iOS visibility)
        let lineThickness: Float = 0.01 // Much thicker than visionOS for mobile visibility
        let mesh = MeshResource.generateBox(size: SIMD3(length, lineThickness, lineThickness))
        let materialColor: UIColor = {
            if let rgba = colorComponents {
                return UIColor(
                    red: CGFloat(rgba[0]),
                    green: CGFloat(rgba[1]),
                    blue: CGFloat(rgba[2]),
                    alpha: rgba.count > 3 ? CGFloat(rgba[3]) : 1.0
                )
            }
            return .systemRed // Bright red for high visibility on iOS
        }()
        let material = SimpleMaterial(color: materialColor, isMetallic: false)
        
        let lineEntity = ModelEntity(mesh: mesh, materials: [material])
        lineEntity.position = pos1 + (lineVector / 2)
        
        // Orient the line along the vector
        if length > 0 {
            let direction = lineVector / length
            let quat = simd_quatf(from: SIMD3<Float>(1, 0, 0), to: direction)
            lineEntity.orientation = quat
        }
        
        return lineEntity
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