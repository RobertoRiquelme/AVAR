#if os(iOS)
import SwiftUI
import RealityKit
import ARKit

struct iOS_ContentView: View {
    @StateObject private var arViewModel = ARViewModel()
    @ObservedObject var collaborativeSession: CollaborativeSessionManager
    @State private var showingCollaborativeSession = false
    @State private var showingHelp = false
    
    var body: some View {
        ZStack {
            // AR View for iOS - Full screen
            ARViewContainer(arViewModel: arViewModel)
                .ignoresSafeArea(.all, edges: .all)
        }
        // Floating controls menu (bottom-right)
        .overlay(alignment: .bottomTrailing) {
            Menu {
                Button {
                    showingCollaborativeSession = true
                } label: { Label("Session", systemImage: "person.2.wave.2") }

                Section(header: Text("Alignment")) {
                    Button {
                        arViewModel.alignmentMode = .marker
                        arViewModel.onAlignmentModeChanged()
                    } label: { Label("Marker", systemImage: arViewModel.alignmentMode == .marker ? "checkmark" : "scope") }

                    Button {
                        arViewModel.alignmentMode = .oneShot
                        arViewModel.onAlignmentModeChanged()
                    } label: { Label("One‑shot", systemImage: arViewModel.alignmentMode == .oneShot ? "checkmark" : "dot.scope") }

                    if arViewModel.availableMarkerIds.count > 1 {
                        Menu("Choose Marker") {
                            ForEach(arViewModel.availableMarkerIds, id: \.self) { id in
                                Button {
                                    arViewModel.selectedMarkerId = id
                                    arViewModel.selectedMarkerDidChange()
                                } label: {
                                    Label(id, systemImage: arViewModel.selectedMarkerId == id ? "checkmark" : "qrcode.viewfinder")
                                }
                            }
                        }
                    }
                }

                Section(header: Text("Layout")) {
                    Button { arViewModel.resetMapping() } label: { Label("Recenter Layout", systemImage: "viewfinder") }
                }

                Section(header: Text("AR")) {
                    Button { arViewModel.restartARSession() } label: { Label("Reset AR", systemImage: "camera.rotate") }
                }

                Section(header: Text("Debug")) {
                    Button { arViewModel.placeAnchor() } label: { Label("Place Debug Sphere", systemImage: "circle.grid.cross") }
                    Button(role: .destructive) { arViewModel.clearAll() } label: { Label("Clear All", systemImage: "trash") }
                }

                Button { showingHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
            } label: {
                Label("Controls", systemImage: "slider.horizontal.3")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: .capsule)
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
        // Bottom status strip
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    if !arViewModel.selectedMarkerId.isEmpty {
                        Label { HStack(spacing: 4) {
                            Text("\(arViewModel.selectedMarkerId)")
                            if let d = arViewModel.markerDistance { Text(String(format: "· %.2fm", d)) }
                        }} icon: {
                            Image(systemName: arViewModel.markerFound ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(arViewModel.markerFound ? .green : .orange)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: .capsule)
                    }

                    if !collaborativeSession.sharedDiagrams.isEmpty {
                        Label("AR Diagrams: \(collaborativeSession.sharedDiagrams.count)", systemImage: "chart.bar")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: .capsule)
                    }
                    Spacer()
                }
                .padding(.bottom, 6)
            }
            .padding(.horizontal)
            .background(.ultraThinMaterial)
        }
        .sheet(isPresented: $showingCollaborativeSession) {
            CollaborativeSessionView(sessionManager: collaborativeSession)
        }
        .sheet(isPresented: $showingHelp) {
            NavigationView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("iOS Overlay Guide").font(.headline)
                    Group {
                        Label("Session", systemImage: "person.2.wave.2").font(.subheadline)
                        Text("Start/join a multi‑device session.").font(.caption).foregroundColor(.secondary)
                    }
                    Group {
                        Label("Align: Marker / One‑shot", systemImage: "scope").font(.subheadline)
                        Text("Marker aligns to a printed image seen by both devices. One‑shot places content in front of you once.").font(.caption).foregroundColor(.secondary)
                    }
                    Group {
                        Label("Marker menu", systemImage: "qrcode.viewfinder").font(.subheadline)
                        Text("Choose which printed marker ID to use.").font(.caption).foregroundColor(.secondary)
                    }
                    Group {
                        Label("Recenter Layout", systemImage: "viewfinder").font(.subheadline)
                        Text("Bring the whole layout back in front of you.").font(.caption).foregroundColor(.secondary)
                    }
                    Group {
                        Label("Reset AR", systemImage: "camera.rotate").font(.subheadline)
                        Text("Restart tracking if the camera stalls.").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { showingHelp = false } } }
            }
        }
        .onAppear {
            arViewModel.attachCollaborativeSession(collaborativeSession)
        }
        .onReceive(collaborativeSession.$sharedDiagrams) { diagrams in
            // Update AR view when new diagrams are received
            print("📱 iOS received \(diagrams.count) shared diagrams")
            for (index, diagram) in diagrams.enumerated() {
                print("📱 Diagram \(index): '\(diagram.filename)' with \(diagram.elements.count) elements")
            }
            arViewModel.updateSharedDiagrams(diagrams)
        }
        .onChange(of: arViewModel.selectedMarkerId) { _, _ in
            arViewModel.selectedMarkerDidChange()
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
    private weak var collaborativeSession: CollaborativeSessionManager?
    // Marker-based alignment
    private var currentHostMarker: simd_float4x4?
    private var currentLocalMarker: simd_float4x4?
    @Published var availableMarkerIds: [String] = []
    @Published var selectedMarkerId: String = ""
    @Published var markerFound: Bool = false
    @Published var markerDistance: Float? = nil
    // Track multiple markers
    private var localMarkers: [String: simd_float4x4] = [:]
    private var hostMarkers: [String: simd_float4x4] = [:]
    // Alignment mode
    enum AlignmentMode: Hashable { case marker, oneShot }
    @Published var alignmentMode: AlignmentMode = .marker
    // Separate mappings so they don't override each other
    private var markerHostToLocalTransform: simd_float4x4?
    private var oneShotHostToLocalTransform: simd_float4x4?
    // Mapping from host (visionOS) world space to local (iOS) AR world space
    // Computed once from the first diagram that contains a world transform
    
    func setupARView(_ arView: ARView) {
        self.arView = arView
        self.arSession = arView.session
        self.arSession?.delegate = self
        
        // Configure AR session for world tracking
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isCollaborationEnabled = true
        configuration.environmentTexturing = .automatic
        // Load reference images from asset catalog group "AR Resources"
        if let refImages = ARReferenceImage.referenceImages(inGroupNamed: "AR Resources", bundle: nil) {
            configuration.detectionImages = refImages
            configuration.maximumNumberOfTrackedImages = 1
            print("🖼️ Enabled image detection (\(refImages.count) image(s))")
            availableMarkerIds = refImages.compactMap({ $0.name }).sorted()
            if selectedMarkerId.isEmpty { selectedMarkerId = availableMarkerIds.first ?? "" }
        } else {
            print("⚠️ No AR Reference Images found in group 'AR Resources'")
        }
        
        // Add session delegate to monitor state changes
        arView.session.delegate = self
        
        arView.session.run(configuration)
        
        // Enable coaching overlay
        arView.debugOptions = []
        
        print("📱 AR session configured for iOS with collaboration enabled")
        print("📱 ARSession delegate set to monitor session state")
    }

    func attachCollaborativeSession(_ session: CollaborativeSessionManager) {
        self.collaborativeSession = session
        #if os(iOS)
        // Route incoming collaboration packets to our ARSession
        session.onCollaborationDataReceived = { [weak self] blob in
            guard let self = self, let arSession = self.arSession else { return }
            do {
                if let collab = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARSession.CollaborationData.self, from: blob) {
                    arSession.update(with: collab)
                }
            } catch {
                print("❌ Failed to decode ARCollaborationData: \(error)")
            }
        }
        // Receive host marker pose
        session.onMarkerPoseReceived = { [weak self] msg in
            guard let self = self else { return }
            let host = Self.buildMatrix(position: msg.worldPosition, orientation: msg.worldOrientation)
            self.hostMarkers[msg.markerId] = host
            if msg.markerId == self.selectedMarkerId {
                self.currentHostMarker = host
                print("📡 Host marker '\(msg.markerId)' received. Recomputing mapping…")
                self.recomputeMappingIfPossible()
            }
        }
        #endif
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

        // Establish a stable mapping from host world space to our local AR world space
        // Use the first diagram that provides a world transform as the reference.
        if alignmentMode == .oneShot,
           oneShotHostToLocalTransform == nil,
           let reference = diagrams.first(where: { $0.worldPosition != nil }) {
            let hostRef = Self.makeHostTransform(from: reference)
            let desiredLocal = simd_float4x4(
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, 0, -1.5, 1)
            )
            oneShotHostToLocalTransform = desiredLocal * hostRef.inverse
            print("📐 Established one‑shot mapping from reference diagram '\(reference.filename)'")
        }
        
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
        // Use host→local mapping when available; otherwise, place in front of user
        let transform: simd_float4x4

        // Choose mapping based on mode
        let activeMapping: simd_float4x4? = {
            switch alignmentMode {
            case .marker: return markerHostToLocalTransform
            case .oneShot: return oneShotHostToLocalTransform
            }
        }()

        if let hostToLocal = activeMapping, diagram.worldPosition != nil {
            // Map host world transform into our local AR world
            let hostMatrix = Self.makeHostTransform(from: diagram)
            transform = hostToLocal * hostMatrix
            print("📍 Placing '\(diagram.filename)' via host→local mapping")
        } else if alignmentMode == .oneShot, diagram.worldPosition != nil {
            // If we have a host transform but no mapping yet, place using host transform directly
            // (will be remapped on next update once mapping exists)
            transform = Self.makeHostTransform(from: diagram)
            print("📍 Temporarily using raw host transform for '\(diagram.filename)'")
        } else {
            // Fall back to default positioning if no world position provided
            let yOffset = Float(index) * 0.5 - Float(totalCount - 1) * 0.25
            transform = simd_float4x4(
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, yOffset, -1.5, 1)
            )
            print("📍 Using default position for '\(diagram.filename)' (no world position provided)")
        }
        
        let anchor = AnchorEntity(world: transform)
        anchor.name = "shared_diagram_\(diagram.filename)"
        
        // Apply scale if provided
        if let worldScale = diagram.worldScale {
            anchor.scale = SIMD3<Float>(repeating: worldScale)
            print("📏 Applying scale \(worldScale) to '\(diagram.filename)'")
        }
        
        print("📱 Creating AR diagram '\(diagram.filename)' with \(diagram.elements.count) elements")
        
        // Determine if this is a 2D or 3D diagram
        let is2D = diagram.elements.allSatisfy { element in
            guard let position = element.position, position.count >= 3 else { return true }
            return position[2] == 0 // z-coordinate is 0 for 2D diagrams
        }
        
        // Create a container for normalized positioning
        let diagramContainer = Entity()
        diagramContainer.name = "diagram_container"
        
        // Calculate normalization context for proper scaling
        let normalizationContext = NormalizationContext(elements: diagram.elements, is2D: is2D)
        
        // Create full-scale diagram representation with proper normalization
        var elementCount = 0
        for (elementIndex, element) in diagram.elements.enumerated() {
            if let elementEntity = createNormalizedElement(element: element, index: elementIndex, normalization: normalizationContext) {
                diagramContainer.addChild(elementEntity)
                elementCount += 1
            }
        }
        
        // Add connections between elements
        for edge in diagram.elements {
            if let from = edge.fromId, let to = edge.toId {
                if let connectionEntity = createConnection(from: from, to: to, in: diagramContainer, color: edge.color) {
                    diagramContainer.addChild(connectionEntity)
                }
            }
        }
        
        anchor.addChild(diagramContainer)
        
        print("📱 Added \(elementCount) visible elements to AR diagram")
        
        // Add title label positioned above the diagram
        if let titleEntity = createTitleEntity(text: diagram.filename) {
            titleEntity.position = SIMD3<Float>(0, 0.8, 0)  // Above the diagram
            anchor.addChild(titleEntity)
        }
        
        return anchor
    }

    // Build a 4x4 transform matrix from a SharedDiagram's host world position and orientation
    private static func makeHostTransform(from diagram: SharedDiagram) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        if let worldOrient = diagram.worldOrientation {
            let rotationMatrix = simd_matrix4x4(worldOrient)
            matrix = matrix * rotationMatrix
        }
        if let worldPos = diagram.worldPosition {
            matrix.columns.3 = SIMD4<Float>(worldPos.x, worldPos.y, worldPos.z, 1.0)
        }
        return matrix
    }

    // Public helper to reset the mapping (e.g., user taps Recenter)
    func resetMapping() {
        markerHostToLocalTransform = nil
        oneShotHostToLocalTransform = nil
        print("🧭 Host→local mapping reset; will re-establish on next update")
        updateSharedDiagrams(sharedDiagrams)
    }
    
    private func createNormalizedElement(element: ElementDTO, index: Int, normalization: NormalizationContext) -> ModelEntity? {
        guard let position = element.position else { 
            print("📱 ⚠️ Element \(index) missing position data")
            return nil
        }
        
        // Skip camera and edge elements for cleaner visualization
        if element.type.lowercased() == "camera" || element.type.lowercased() == "edge" || 
           element.shape?.shapeDescription?.lowercased() == "line" {
            return nil
        }
        
        // Create mesh and material using the element's properties
        let (mesh, material) = element.meshAndMaterial(normalization: normalization)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        
        // Calculate normalized position
        let dims = normalization.positionCenters.count
        let rawX = position.count > 0 ? position[0] : 0
        let rawY = position.count > 1 ? position[1] : 0
        let rawZ = dims > 2 && position.count > 2 ? position[2] : 0
        let globalRange = normalization.globalRange
        
        let normX = (rawX - normalization.positionCenters[0]) / globalRange * 2
        let normY = (rawY - normalization.positionCenters[1]) / globalRange * 2
        let normZ = dims > 2 ? (rawZ - normalization.positionCenters[2]) / globalRange * 2 : 0
        
        let yPos = normalization.is2D ? -Float(normY) : Float(normY)
        entity.position = SIMD3<Float>(Float(normX), yPos, Float(normZ))
        
        // Store ID for connection lookups
        entity.name = element.id ?? "element_\(index)"
        
        print("📱 ✅ Created normalized element '\(entity.name)' at position (\(entity.position.x), \(entity.position.y), \(entity.position.z))")
        
        return entity
    }
    
    private func createConnection(from: String, to: String, in container: Entity, color: [Double]?) -> ModelEntity? {
        // Find entities by name
        var fromEntity: Entity? = nil
        var toEntity: Entity? = nil
        
        for child in container.children {
            if child.name == from {
                fromEntity = child
            }
            if child.name == to {
                toEntity = child
            }
            if fromEntity != nil && toEntity != nil {
                break
            }
        }
        
        guard let entity1 = fromEntity, let entity2 = toEntity else {
            print("📱 ⚠️ Could not find entities for connection from '\(from)' to '\(to)'")
            return nil
        }
        
        let pos1 = entity1.position
        let pos2 = entity2.position
        let lineVector = pos2 - pos1
        let length = simd_length(lineVector)
        
        guard length > 0 else { return nil }
        
        let mesh = MeshResource.generateBox(size: SIMD3(length, 0.002, 0.002))
        let materialColor: UIColor = {
            if let rgba = color {
                return UIColor(
                    red: CGFloat(rgba[safe: 0] ?? 0.5),
                    green: CGFloat(rgba[safe: 1] ?? 0.5),
                    blue: CGFloat(rgba[safe: 2] ?? 0.5),
                    alpha: CGFloat(rgba[safe: 3] ?? 1.0)
                )
            }
            return .gray
        }()
        
        let material = SimpleMaterial(color: materialColor, isMetallic: false)
        let lineEntity = ModelEntity(mesh: mesh, materials: [material])
        lineEntity.position = pos1 + (lineVector / 2)
        
        // Orient the line along the vector
        let direction = lineVector / length
        let quat = simd_quatf(from: SIMD3<Float>(1, 0, 0), to: direction)
        lineEntity.orientation = quat
        
        return lineEntity
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

    // MARK: - Marker Mapping
    private func recomputeMappingIfPossible() {
        guard !selectedMarkerId.isEmpty,
              let local = localMarkers[selectedMarkerId],
              let host = hostMarkers[selectedMarkerId] else {
            return
        }
        currentLocalMarker = local
        currentHostMarker = host
        // host→local mapping M = local * inverse(host)
        markerHostToLocalTransform = local * host.inverse
        print("🧭 Host→local mapping updated from markers")
        // Re-place existing diagrams using the new mapping
        updateSharedDiagrams(sharedDiagrams)
    }

    private static func buildMatrix(position: SIMD3<Float>, orientation: simd_quatf) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m = m * simd_matrix4x4(orientation)
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return m
    }

    func selectedMarkerDidChange() {
        if let local = localMarkers[selectedMarkerId] {
            markerFound = true
            updateMarkerDistance(local)
        } else {
            markerFound = false
            markerDistance = nil
        }
        recomputeMappingIfPossible()
    }

    private func updateMarkerDistance(_ markerTransform: simd_float4x4) {
        guard let frame = arSession?.currentFrame else { markerDistance = nil; return }
        let cam = frame.camera.transform
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let markerPos = SIMD3<Float>(markerTransform.columns.3.x, markerTransform.columns.3.y, markerTransform.columns.3.z)
        markerDistance = simd_length(markerPos - camPos)
    }

    func onAlignmentModeChanged() {
        switch alignmentMode {
        case .marker:
            // Clear one‑shot mapping; rely on marker mapping
            oneShotHostToLocalTransform = nil
        case .oneShot:
            // Clear marker mapping; recompute one‑shot on next update
            markerHostToLocalTransform = nil
        }
        updateSharedDiagrams(sharedDiagrams)
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

    #if os(iOS)
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            if let imageAnchor = anchor as? ARImageAnchor {
                let name = imageAnchor.referenceImage.name ?? "marker"
                let transform = imageAnchor.transform
                Task { @MainActor in
                    self.localMarkers[name] = transform
                    self.markerFound = (name == self.selectedMarkerId)
                    self.updateMarkerDistance(transform)
                    if name == self.selectedMarkerId {
                        print("🖼️ Local marker added: \(name)")
                        self.recomputeMappingIfPossible()
                    }
                    // Optionally share local marker pose to help peers
                    let pos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                    let rot = simd_quatf(transform)
                    self.collaborativeSession?.sendMarkerPose(markerId: name, worldPosition: pos, worldOrientation: rot)
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            if let imageAnchor = anchor as? ARImageAnchor {
                let name = imageAnchor.referenceImage.name ?? "marker"
                let transform = imageAnchor.transform
                Task { @MainActor in
                    self.localMarkers[name] = transform
                    if name == self.selectedMarkerId {
                        self.markerFound = true
                        self.updateMarkerDistance(transform)
                        print("🖼️ Local marker updated: \(name)")
                        self.recomputeMappingIfPossible()
                    }
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didOutputCollaborationData data: ARSession.CollaborationData) {
        // Archive and send to peers
        do {
            let blob = try NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: true)
            Task { @MainActor in
                self.collaborativeSession?.sendCollaborationData(blob)
            }
        } catch {
            print("❌ Failed to archive ARCollaborationData: \(error)")
        }
    }
    #endif
}


#endif
