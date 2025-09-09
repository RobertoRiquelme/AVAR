import Foundation
import RealityKit
import MultipeerConnectivity
import Combine

#if canImport(ARKit)
import ARKit
#endif

#if os(visionOS)
import RealityKitContent
#endif

/// Manages RealityKit collaborative sessions for multi-device diagram viewing
@MainActor
class CollaborativeSessionManager: NSObject, ObservableObject {
    @Published var isSessionActive = false
    @Published var connectedPeers: [MCPeerID] = []
    @Published var availablePeers: [MCPeerID] = []
    @Published var sessionState: String = "Not Connected"
    @Published var isHost = false
    @Published var lastError: String? = nil
    
    private var multipeerSession: MultipeerConnectivityService?
    #if os(iOS)
    private var arSession: ARSession?
    #endif
    private var collaborationData: CollaborationData?
    
    // Current active diagrams that should be shared
    @Published var sharedDiagrams: [SharedDiagram] = []

    // iOS-only: callback to deliver ARCollaborationData blobs to the local ARSession
    #if os(iOS)
    var onCollaborationDataReceived: ((Data) -> Void)?
    #endif
    // Marker pose callback for clients (both platforms may use it)
    var onMarkerPoseReceived: ((MarkerPoseMessage) -> Void)?
    
    override init() {
        super.init()
        setupMultipeerSession()
    }
    
    private func setupMultipeerSession() {
        multipeerSession = MultipeerConnectivityService()
        multipeerSession?.delegate = self
    }
    
    /// Start hosting a collaborative session
    func startHosting() async {
        print("🤝 Starting collaborative session as host")
        lastError = nil // Clear any previous errors
        isHost = true
        
        #if os(iOS)
        // Initialize ARSession for iOS
        await startARSession()
        #endif
        
        multipeerSession?.startHosting()
        isSessionActive = true
        sessionState = "Hosting - Waiting for peers"
    }
    
    /// Join an existing collaborative session
    func joinSession() async {
        print("🤝 Joining collaborative session")
        lastError = nil // Clear any previous errors
        isHost = false
        
        #if os(iOS)
        // Initialize ARSession for iOS
        await startARSession()
        #endif
        
        multipeerSession?.startBrowsing()
        sessionState = "Searching for hosts..."
    }

    #if os(iOS)
    /// Send ARCollaborationData to peers (iOS-only)
    func sendCollaborationData(_ data: Data, to peers: [MCPeerID]? = nil) {
        let envelope = CollaborationEnvelope(blob: data)
        guard let payload = try? JSONEncoder().encode(envelope) else { return }
        let targets = peers ?? connectedPeers
        multipeerSession?.sendData(payload, to: targets)
        print("📡 Sent ARCollaborationData (\(data.count) bytes) to \(targets.count) peer(s)")
    }
    #endif

    /// Send marker pose to connected peers
    func sendMarkerPose(markerId: String, worldPosition: SIMD3<Float>, worldOrientation: simd_quatf) {
        let msg = MarkerPoseMessage(markerId: markerId, worldPosition: worldPosition, worldOrientation: worldOrientation)
        if let data = try? JSONEncoder().encode(msg) {
            multipeerSession?.sendData(data, to: connectedPeers)
            print("📡 Sent marker pose '\(markerId)' to \(connectedPeers.count) peer(s)")
        }
    }
    
    /// Stop the collaborative session
    func stopSession() {
        print("🤝 Stopping collaborative session")
        multipeerSession?.stop()
        
        // Don't pause the ARSession - let the ARView manage it
        // The AR camera should keep running for the main AR experience
        
        isSessionActive = false
        isHost = false
        connectedPeers.removeAll()
        availablePeers.removeAll()
        sessionState = "Not Connected"
        lastError = nil
    }
    
    /// Share a diagram with all connected peers including position data
    func shareDiagram(filename: String, elements: [ElementDTO], worldPosition: SIMD3<Float>? = nil, 
                      worldOrientation: simd_quatf? = nil, worldScale: Float? = nil) {
        let sharedDiagram = SharedDiagram(
            id: UUID(),
            filename: filename,
            elements: elements,
            timestamp: Date(),
            worldPosition: worldPosition,
            worldOrientation: worldOrientation,
            worldScale: worldScale
        )
        
        sharedDiagrams.append(sharedDiagram)
        
        // Send to all peers
        if let data = try? JSONEncoder().encode(sharedDiagram) {
            multipeerSession?.sendData(data, to: connectedPeers)
        }
        
        print("📊 Shared diagram '\(filename)' with \(connectedPeers.count) peers")
        if let pos = worldPosition {
            print("   📍 Position: \(pos)")
        }
        if let orient = worldOrientation {
            print("   🔄 Orientation: \(orient)")
        }
        if let scale = worldScale {
            print("   📏 Scale: \(scale)")
        }
    }
    
    /// Remove a diagram from sharing
    func removeDiagram(filename: String) {
        sharedDiagrams.removeAll { $0.filename == filename }
        
        let removeMessage = RemoveDiagramMessage(filename: filename)
        if let data = try? JSONEncoder().encode(removeMessage) {
            multipeerSession?.sendData(data, to: connectedPeers)
        }
        
        print("🗑️ Removed shared diagram '\(filename)'")
    }
    
    /// Update the transform of an existing shared diagram
    func updateDiagramTransform(filename: String, worldPosition: SIMD3<Float>? = nil,
                                worldOrientation: simd_quatf? = nil, worldScale: Float? = nil) {
        // Update local copy
        if let index = sharedDiagrams.firstIndex(where: { $0.filename == filename }) {
            if let pos = worldPosition {
                sharedDiagrams[index].worldPosition = pos
            }
            if let orient = worldOrientation {
                sharedDiagrams[index].worldOrientation = orient
            }
            if let scale = worldScale {
                sharedDiagrams[index].worldScale = scale
            }
            
            // Send update to peers
            let updateMessage = UpdateDiagramTransformMessage(
                filename: filename,
                worldPosition: worldPosition,
                worldOrientation: worldOrientation,
                worldScale: worldScale
            )
            
            if let data = try? JSONEncoder().encode(updateMessage) {
                multipeerSession?.sendData(data, to: connectedPeers)
            }
            
            print("🔄 Updated and shared transform for diagram '\(filename)'")
        }
    }
    
    #if os(iOS)
    private func startARSession() async {
        // Don't create a new ARSession - the ARView already has one running
        // Just enable collaboration data sharing
        collaborationData = CollaborationData()
        
        print("🔧 AR collaboration enabled for \(getCurrentPlatform())")
        print("ℹ️ Using existing ARSession from ARView - no new session needed")
    }
    
    #else
    private func startARSession() async {
        print("⚠️ AR not available on this platform")
    }
    #endif
    
    private func getCurrentPlatform() -> String {
        #if os(visionOS)
        return "visionOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "macOS"
        #endif
    }
}

// MARK: - Collaboration Data Envelope (iOS)
#if os(iOS)
private struct CollaborationEnvelope: Codable {
    let kind: String = "collab"
    let blob: Data
}
#endif

// MARK: - Marker Pose Message (cross-platform)
struct MarkerPoseMessage: Codable {
    let markerId: String
    var worldPosition: SIMD3<Float>
    var worldOrientation: simd_quatf

    enum CodingKeys: String, CodingKey {
        case markerId
        case worldPositionX, worldPositionY, worldPositionZ
        case worldOrientationX, worldOrientationY, worldOrientationZ, worldOrientationW
    }

    init(markerId: String, worldPosition: SIMD3<Float>, worldOrientation: simd_quatf) {
        self.markerId = markerId
        self.worldPosition = worldPosition
        self.worldOrientation = worldOrientation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markerId = try c.decode(String.self, forKey: .markerId)
        let px = try c.decode(Float.self, forKey: .worldPositionX)
        let py = try c.decode(Float.self, forKey: .worldPositionY)
        let pz = try c.decode(Float.self, forKey: .worldPositionZ)
        worldPosition = SIMD3(px, py, pz)
        let ox = try c.decode(Float.self, forKey: .worldOrientationX)
        let oy = try c.decode(Float.self, forKey: .worldOrientationY)
        let oz = try c.decode(Float.self, forKey: .worldOrientationZ)
        let ow = try c.decode(Float.self, forKey: .worldOrientationW)
        worldOrientation = simd_quatf(ix: ox, iy: oy, iz: oz, r: ow)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(markerId, forKey: .markerId)
        try c.encode(worldPosition.x, forKey: .worldPositionX)
        try c.encode(worldPosition.y, forKey: .worldPositionY)
        try c.encode(worldPosition.z, forKey: .worldPositionZ)
        try c.encode(worldOrientation.imag.x, forKey: .worldOrientationX)
        try c.encode(worldOrientation.imag.y, forKey: .worldOrientationY)
        try c.encode(worldOrientation.imag.z, forKey: .worldOrientationZ)
        try c.encode(worldOrientation.real, forKey: .worldOrientationW)
    }
}

// MARK: - MultipeerConnectivityDelegate
extension CollaborativeSessionManager: @preconcurrency MultipeerConnectivityDelegate {
    func multipeerService(_ service: MultipeerConnectivityService, didReceiveData data: Data, from peer: MCPeerID) {
        #if os(iOS)
        // Try collaboration envelope first (binary payload wrapped in JSON)
        if let envelope = try? JSONDecoder().decode(CollaborationEnvelope.self, from: data), envelope.kind == "collab" {
            onCollaborationDataReceived?(envelope.blob)
            print("📡 Received ARCollaborationData (\(envelope.blob.count) bytes) from \(peer.displayName)")
            return
        }
        #endif

        // Marker pose message
        if let markerMsg = try? JSONDecoder().decode(MarkerPoseMessage.self, from: data) {
            onMarkerPoseReceived?(markerMsg)
            print("📡 Received marker pose '\(markerMsg.markerId)' from \(peer.displayName)")
            return
        }

        // Try to decode as SharedDiagram first
        if let sharedDiagram = try? JSONDecoder().decode(SharedDiagram.self, from: data) {
            if !sharedDiagrams.contains(where: { $0.id == sharedDiagram.id }) {
                sharedDiagrams.append(sharedDiagram)
                print("📥 Received shared diagram '\(sharedDiagram.filename)' from \(peer.displayName)")
                if let pos = sharedDiagram.worldPosition {
                    print("   📍 Position: \(pos)")
                }
            }
            return
        }
        
        // Try to decode as UpdateDiagramTransformMessage
        if let updateMessage = try? JSONDecoder().decode(UpdateDiagramTransformMessage.self, from: data) {
            if let index = sharedDiagrams.firstIndex(where: { $0.filename == updateMessage.filename }) {
                // Update the transform data for existing diagram
                if let pos = updateMessage.worldPosition {
                    sharedDiagrams[index].worldPosition = pos
                }
                if let orient = updateMessage.worldOrientation {
                    sharedDiagrams[index].worldOrientation = orient
                }
                if let scale = updateMessage.worldScale {
                    sharedDiagrams[index].worldScale = scale
                }
                print("🔄 Updated transform for diagram '\(updateMessage.filename)'")
                // Ensure @Published sends change to subscribers
                sharedDiagrams = sharedDiagrams
            }
            return
        }
        
        // Try to decode as RemoveDiagramMessage
        if let removeMessage = try? JSONDecoder().decode(RemoveDiagramMessage.self, from: data) {
            sharedDiagrams.removeAll { $0.filename == removeMessage.filename }
            print("🗑️ Received remove diagram message for '\(removeMessage.filename)'")
            return
        }
        
        print("❓ Received unknown data from \(peer.displayName)")
    }
    
    func multipeerService(_ service: MultipeerConnectivityService, didEncounterError error: Error, context: String) {
        let nsError = error as NSError
        
        if nsError.code == -72008 {
            lastError = "Network permission required: Please allow Local Network access in Settings"
            sessionState = "Permission Error"
        } else {
            lastError = "Connection error (\(nsError.code)): \(error.localizedDescription)"
            sessionState = "Connection Failed"
        }
        
        // Stop the session on critical errors
        if nsError.code == -72008 {
            isSessionActive = false
            isHost = false
        }
        
        print("🔴 Multipeer error in \(context): \(lastError ?? "unknown")")
    }
    
    func multipeerService(_ service: MultipeerConnectivityService, didUpdateAvailablePeers peers: [MCPeerID]) {
        availablePeers = peers
        print("📋 Available peers updated: \(peers.map { $0.displayName }.joined(separator: ", "))")
    }
    
    /// Manually connect to a specific peer
    func connectToPeer(_ peer: MCPeerID) {
        multipeerSession?.connectToPeer(peer)
    }
    
    func multipeerService(_ service: MultipeerConnectivityService, peer: MCPeerID, didChangeState state: MCSessionState) {
        print("🎯 CollaborativeSessionManager received state change: \(peer.displayName) → \(state)")
        
        switch state {
        case .connected:
            if !connectedPeers.contains(peer) {
                connectedPeers.append(peer)
            }
            sessionState = "Connected to \(connectedPeers.count) peer(s)"
            print("✅ Connected to \(peer.displayName) - Total peers: \(connectedPeers.count)")
            
            // Send current diagrams to new peer
            for diagram in sharedDiagrams {
                if let data = try? JSONEncoder().encode(diagram) {
                    multipeerSession?.sendData(data, to: [peer])
                    print("📤 Sent shared diagram '\(diagram.filename)' to new peer")
                }
            }
            
        case .connecting:
            sessionState = "Connecting to \(peer.displayName)..."
            print("🔄 Connecting to \(peer.displayName)")
            
        case .notConnected:
            connectedPeers.removeAll { $0 == peer }
            if connectedPeers.isEmpty {
                sessionState = isHost ? "Hosting - Waiting for peers" : "Searching for hosts..."
            } else {
                sessionState = "Connected to \(connectedPeers.count) peer(s)"
            }
            print("❌ Disconnected from \(peer.displayName) - Remaining peers: \(connectedPeers.count)")
            
        @unknown default:
            print("⚠️ Unknown session state for \(peer.displayName)")
            break
        }
    }
}

// MARK: - Supporting Types
struct SharedDiagram: Codable, Identifiable {
    let id: UUID
    let filename: String
    let elements: [ElementDTO]
    let timestamp: Date
    // Physical space positioning data
    var worldPosition: SIMD3<Float>? // World position in meters
    var worldOrientation: simd_quatf? // World orientation quaternion
    var worldScale: Float? // Uniform scale factor
    
    // Encode/decode helpers for SIMD types
    enum CodingKeys: String, CodingKey {
        case id, filename, elements, timestamp
        case worldPositionX, worldPositionY, worldPositionZ
        case worldOrientationX, worldOrientationY, worldOrientationZ, worldOrientationW
        case worldScale
    }
    
    init(id: UUID = UUID(), filename: String, elements: [ElementDTO], timestamp: Date = Date(),
         worldPosition: SIMD3<Float>? = nil, worldOrientation: simd_quatf? = nil, worldScale: Float? = nil) {
        self.id = id
        self.filename = filename
        self.elements = elements
        self.timestamp = timestamp
        self.worldPosition = worldPosition
        self.worldOrientation = worldOrientation
        self.worldScale = worldScale
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        filename = try container.decode(String.self, forKey: .filename)
        elements = try container.decode([ElementDTO].self, forKey: .elements)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        
        // Decode world position if present
        if let x = try container.decodeIfPresent(Float.self, forKey: .worldPositionX),
           let y = try container.decodeIfPresent(Float.self, forKey: .worldPositionY),
           let z = try container.decodeIfPresent(Float.self, forKey: .worldPositionZ) {
            worldPosition = SIMD3<Float>(x, y, z)
        }
        
        // Decode world orientation if present
        if let x = try container.decodeIfPresent(Float.self, forKey: .worldOrientationX),
           let y = try container.decodeIfPresent(Float.self, forKey: .worldOrientationY),
           let z = try container.decodeIfPresent(Float.self, forKey: .worldOrientationZ),
           let w = try container.decodeIfPresent(Float.self, forKey: .worldOrientationW) {
            worldOrientation = simd_quatf(ix: x, iy: y, iz: z, r: w)
        }
        
        worldScale = try container.decodeIfPresent(Float.self, forKey: .worldScale)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(filename, forKey: .filename)
        try container.encode(elements, forKey: .elements)
        try container.encode(timestamp, forKey: .timestamp)
        
        // Encode world position if present
        if let pos = worldPosition {
            try container.encode(pos.x, forKey: .worldPositionX)
            try container.encode(pos.y, forKey: .worldPositionY)
            try container.encode(pos.z, forKey: .worldPositionZ)
        }
        
        // Encode world orientation if present
        if let orient = worldOrientation {
            try container.encode(orient.imag.x, forKey: .worldOrientationX)
            try container.encode(orient.imag.y, forKey: .worldOrientationY)
            try container.encode(orient.imag.z, forKey: .worldOrientationZ)
            try container.encode(orient.real, forKey: .worldOrientationW)
        }
        
        if let scale = worldScale {
            try container.encode(scale, forKey: .worldScale)
        }
    }
}

struct RemoveDiagramMessage: Codable {
    let filename: String
}

struct UpdateDiagramTransformMessage: Codable {
    let filename: String
    var worldPosition: SIMD3<Float>?
    var worldOrientation: simd_quatf?
    var worldScale: Float?
    
    // Encode/decode helpers for SIMD types
    enum CodingKeys: String, CodingKey {
        case filename
        case worldPositionX, worldPositionY, worldPositionZ
        case worldOrientationX, worldOrientationY, worldOrientationZ, worldOrientationW
        case worldScale
    }
    
    init(filename: String, worldPosition: SIMD3<Float>? = nil, 
         worldOrientation: simd_quatf? = nil, worldScale: Float? = nil) {
        self.filename = filename
        self.worldPosition = worldPosition
        self.worldOrientation = worldOrientation
        self.worldScale = worldScale
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decode(String.self, forKey: .filename)
        
        // Decode world position if present
        if let x = try container.decodeIfPresent(Float.self, forKey: .worldPositionX),
           let y = try container.decodeIfPresent(Float.self, forKey: .worldPositionY),
           let z = try container.decodeIfPresent(Float.self, forKey: .worldPositionZ) {
            worldPosition = SIMD3<Float>(x, y, z)
        }
        
        // Decode world orientation if present
        if let x = try container.decodeIfPresent(Float.self, forKey: .worldOrientationX),
           let y = try container.decodeIfPresent(Float.self, forKey: .worldOrientationY),
           let z = try container.decodeIfPresent(Float.self, forKey: .worldOrientationZ),
           let w = try container.decodeIfPresent(Float.self, forKey: .worldOrientationW) {
            worldOrientation = simd_quatf(ix: x, iy: y, iz: z, r: w)
        }
        
        worldScale = try container.decodeIfPresent(Float.self, forKey: .worldScale)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filename, forKey: .filename)
        
        // Encode world position if present
        if let pos = worldPosition {
            try container.encode(pos.x, forKey: .worldPositionX)
            try container.encode(pos.y, forKey: .worldPositionY)
            try container.encode(pos.z, forKey: .worldPositionZ)
        }
        
        // Encode world orientation if present
        if let orient = worldOrientation {
            try container.encode(orient.imag.x, forKey: .worldOrientationX)
            try container.encode(orient.imag.y, forKey: .worldOrientationY)
            try container.encode(orient.imag.z, forKey: .worldOrientationZ)
            try container.encode(orient.real, forKey: .worldOrientationW)
        }
        
        if let scale = worldScale {
            try container.encode(scale, forKey: .worldScale)
        }
    }
}

// MARK: - CollaborationData (AR platforms)
#if os(visionOS) || os(iOS)
class CollaborationData: ObservableObject {
    #if os(iOS)
    @Published var worldMap: ARWorldMap?
    #endif
    
    init() {
        // Initialize collaboration data tracking
        print("🌍 Collaboration data initialized for AR platform")
    }
}
#else
class CollaborationData: ObservableObject {
    init() {
        print("⚠️ Collaboration data stub for non-AR platform")
    }
}
#endif
