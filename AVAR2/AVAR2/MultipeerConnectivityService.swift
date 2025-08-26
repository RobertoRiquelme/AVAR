import Foundation
import MultipeerConnectivity

protocol MultipeerConnectivityDelegate: AnyObject {
    func multipeerService(_ service: MultipeerConnectivityService, didReceiveData data: Data, from peer: MCPeerID)
    func multipeerService(_ service: MultipeerConnectivityService, peer: MCPeerID, didChangeState state: MCSessionState)
    func multipeerService(_ service: MultipeerConnectivityService, didEncounterError error: Error, context: String)
    func multipeerService(_ service: MultipeerConnectivityService, didUpdateAvailablePeers peers: [MCPeerID])
}

/// Handles MultipeerConnectivity for collaborative sessions
class MultipeerConnectivityService: NSObject, ObservableObject {
    weak var delegate: MultipeerConnectivityDelegate?
    
    private let serviceType = "avar2-collab"
    private let localPeerID: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    
    @Published var isHosting = false
    @Published var isBrowsing = false
    @Published var availablePeers: [MCPeerID] = []
    @Published var autoConnect = true // Automatically connect to first found host
    
    override init() {
        // Create unique peer ID based on device
        let deviceName = ProcessInfo.processInfo.hostName
        localPeerID = MCPeerID(displayName: deviceName)
        session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        
        super.init()
        session.delegate = self
    }
    
    /// Start hosting/advertising this device
    func startHosting() {
        stopAll() // Stop any existing services
        
        advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: [
                "version": "1.0",
                "platform": getCurrentPlatform()
            ],
            serviceType: serviceType
        )
        
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        isHosting = true
        
        print("🏠 Started hosting as '\(localPeerID.displayName)' on \(getCurrentPlatform())")
    }
    
    /// Start browsing for hosts
    func startBrowsing() {
        stopAll() // Stop any existing services
        
        browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        isBrowsing = true
        
        print("🔍 Started browsing for hosts as '\(localPeerID.displayName)'")
    }
    
    /// Stop all services
    func stop() {
        stopAll()
        session.disconnect()
    }
    
    private func stopAll() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        
        browser?.stopBrowsingForPeers()
        browser = nil
        
        availablePeers.removeAll()
        isHosting = false
        isBrowsing = false
    }
    
    /// Send data to specific peers
    func sendData(_ data: Data, to peers: [MCPeerID]) {
        guard !peers.isEmpty else { return }
        
        do {
            try session.send(data, toPeers: peers, with: .reliable)
            print("📤 Sent \(data.count) bytes to \(peers.count) peer(s)")
        } catch {
            print("❌ Failed to send data: \(error)")
        }
    }
    
    /// Connect to a discovered peer
    func connectToPeer(_ peer: MCPeerID) {
        guard let browser = browser else { 
            print("❌ Cannot connect: browser not available")
            return
        }
        
        // Check if already connected or connecting
        if session.connectedPeers.contains(peer) {
            print("ℹ️ Already connected to '\(peer.displayName)'")
            return
        }
        
        print("🤝 Inviting peer '\(peer.displayName)' to session...")
        print("   - Timeout: 30 seconds")
        print("   - Session peer count: \(session.connectedPeers.count)")
        
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 30.0)
    }
    
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

// MARK: - MCSessionDelegate
extension MultipeerConnectivityService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let stateString: String
        switch state {
        case .notConnected:
            stateString = "Not Connected"
        case .connecting:
            stateString = "Connecting"
        case .connected:
            stateString = "Connected"
        @unknown default:
            stateString = "Unknown"
        }
        
        print("📡 Session state changed: '\(peerID.displayName)' → \(stateString)")
        
        DispatchQueue.main.async {
            self.delegate?.multipeerService(self, peer: peerID, didChangeState: state)
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.delegate?.multipeerService(self, didReceiveData: data, from: peerID)
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Not used for this implementation
    }
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // Not used for this implementation
    }
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // Not used for this implementation
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension MultipeerConnectivityService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("📥 Received invitation from '\(peerID.displayName)'")
        // Auto-accept invitations when hosting
        invitationHandler(true, session)
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let nsError = error as NSError
        print("❌ Failed to start advertising: \(error)")
        print("   Error domain: \(nsError.domain)")
        print("   Error code: \(nsError.code)")
        
        // Provide specific guidance for common errors
        switch nsError.code {
        case -72008:
            print("💡 Error -72008: DNS service not running or permission denied")
            print("💡 Solutions:")
            print("   • Restart the device")
            print("   • Check that Local Network permission is granted")
            print("   • Verify NSLocalNetworkUsageDescription is in Info.plist")
        default:
            print("💡 Unknown error code: \(nsError.code)")
        }
        
        // Update state and notify delegate
        DispatchQueue.main.async {
            self.isHosting = false
            self.delegate?.multipeerService(self, didEncounterError: error, context: "advertising")
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultipeerConnectivityService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        DispatchQueue.main.async {
            if !self.availablePeers.contains(peerID) {
                self.availablePeers.append(peerID)
            }
            print("🔍 Found peer '\(peerID.displayName)' with info: \(info ?? [:])")
            
            // Notify delegate of updated peer list
            self.delegate?.multipeerService(self, didUpdateAvailablePeers: self.availablePeers)
            
            // Auto-connect to the first host we find when browsing
            if self.isBrowsing && self.autoConnect && !self.session.connectedPeers.contains(peerID) {
                print("🤝 Auto-connecting to host '\(peerID.displayName)'")
                self.connectToPeer(peerID)
            }
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.availablePeers.removeAll { $0 == peerID }
            print("📤 Lost peer '\(peerID.displayName)'")
            
            // Notify delegate of updated peer list
            self.delegate?.multipeerService(self, didUpdateAvailablePeers: self.availablePeers)
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let nsError = error as NSError
        print("❌ Failed to start browsing: \(error)")
        print("   Error domain: \(nsError.domain)")
        print("   Error code: \(nsError.code)")
        
        // Provide specific guidance for common errors
        switch nsError.code {
        case -72008:
            print("💡 Error -72008: DNS service not running or permission denied")
            print("💡 Solutions:")
            print("   • Restart the device")
            print("   • Check that Local Network permission is granted")
            print("   • Verify NSLocalNetworkUsageDescription is in Info.plist")
            print("   • Check NSBonjourServices configuration")
        case -65563:
            print("💡 Error -65563: Service type invalid or malformed")
        case -6:
            print("💡 Error -6: Parameter error - check service type format")
        default:
            print("💡 Unknown error code: \(nsError.code)")
        }
        
        // Update state and notify delegate
        DispatchQueue.main.async {
            self.isBrowsing = false
            self.delegate?.multipeerService(self, didEncounterError: error, context: "browsing")
        }
    }
}