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
    
    /// Share a diagram with all connected peers
    func shareDiagram(filename: String, elements: [ElementDTO]) {
        let sharedDiagram = SharedDiagram(
            id: UUID(),
            filename: filename,
            elements: elements,
            timestamp: Date()
        )
        
        sharedDiagrams.append(sharedDiagram)
        
        // Send to all peers
        if let data = try? JSONEncoder().encode(sharedDiagram) {
            multipeerSession?.sendData(data, to: connectedPeers)
        }
        
        print("📊 Shared diagram '\(filename)' with \(connectedPeers.count) peers")
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

// MARK: - MultipeerConnectivityDelegate
extension CollaborativeSessionManager: @preconcurrency MultipeerConnectivityDelegate {
    func multipeerService(_ service: MultipeerConnectivityService, didReceiveData data: Data, from peer: MCPeerID) {
        // Try to decode as SharedDiagram first
        if let sharedDiagram = try? JSONDecoder().decode(SharedDiagram.self, from: data) {
            if !sharedDiagrams.contains(where: { $0.id == sharedDiagram.id }) {
                sharedDiagrams.append(sharedDiagram)
                print("📥 Received shared diagram '\(sharedDiagram.filename)' from \(peer.displayName)")
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
}

struct RemoveDiagramMessage: Codable {
    let filename: String
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