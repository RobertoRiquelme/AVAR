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
    
    override init() {
        let deviceName = ProcessInfo.processInfo.hostName
        localPeerID = MCPeerID(displayName: deviceName)
        session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    /// Start hosting/advertising this device
    func startHosting() {
        stopAll()
        makeFreshSession()

        advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: ["version": "1.0", "platform": getCurrentPlatform()],
            serviceType: serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        isHosting = true
        print("🏠 Hosting as '\(localPeerID.displayName)'")
    }

    /// Start browsing for hosts
    func startBrowsing() {
        stopAll()
        makeFreshSession()

        browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        isBrowsing = true
        print("🔍 Browsing for hosts...")
    }
    
    /// Stop all services
    func stop() {
        stopAll()
        session.disconnect()
        makeFreshSession()
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
    
    private func makeFreshSession() {
        // Tear down old delegate just in case
        session.delegate = nil
        // Recreate a brand-new session
        let newSession = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        newSession.delegate = self
        session = newSession
    }

}

// MARK: - MCSessionDelegate
extension MultipeerConnectivityService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let stateStr = state == .connected ? "connected" : (state == .connecting ? "connecting" : "disconnected")
        print("📡 \(peerID.displayName): \(stateStr)")

        DispatchQueue.main.async {
            guard self.session === session else { return }
            self.delegate?.multipeerService(self, peer: peerID, didChangeState: state)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            guard self.session === session else { return }
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
        print("📥 Invitation from \(peerID.displayName)")
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("❌ Advertising failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
            guard self.advertiser === advertiser else { return }
            self.isHosting = false
            self.delegate?.multipeerService(self, didEncounterError: error, context: "advertising")
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultipeerConnectivityService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        guard info?["platform"] == "visionOS" else { return }
        DispatchQueue.main.async {
            guard self.browser === browser else { return }
            if !self.availablePeers.contains(peerID) {
                self.availablePeers.append(peerID)
            }
            self.delegate?.multipeerService(self, didUpdateAvailablePeers: self.availablePeers)

        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            guard self.browser === browser else { return }
            self.availablePeers.removeAll { $0 == peerID }
            self.delegate?.multipeerService(self, didUpdateAvailablePeers: self.availablePeers)
        }
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("❌ Browsing failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
            guard self.browser === browser else { return }
            self.isBrowsing = false
            self.delegate?.multipeerService(self, didEncounterError: error, context: "browsing")
        }
    }
}
