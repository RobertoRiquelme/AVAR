import Foundation
import RealityKit
import MultipeerConnectivity
import Combine
import simd
#if canImport(GroupActivities)
import GroupActivities
#endif

#if canImport(ARKit)
import ARKit
#endif

#if os(visionOS)
import RealityKitContent
#endif

/// Manages RealityKit collaborative sessions for multi-device diagram viewing
///
/// This version uses a **world-space model** for diagrams:
/// - `SharedDiagram.worldPosition/worldOrientation` are always in a shared world space.
/// - iOS / visionOS / others place diagrams directly from these world transforms.
/// - The shared anchor is used only to share `ARWorldMap` (iOS) or shared-space state,
///   not for extra transform math on diagram placement.
///

@MainActor
class CollaborativeSessionManager: NSObject, ObservableObject {
    @Published var isSessionActive = false
    @Published var connectedPeers: [MCPeerID] = []
    @Published var availablePeers: [MCPeerID] = []
    @Published var sessionState: String = "Not Connected"
    @Published var isHost = false
    @Published var lastError: String? = nil
    @Published var isSharePlayActive = false
    @Published var pendingAlert: SessionAlert? = nil
    
    private var multipeerSession: MultipeerConnectivityService?
    #if os(iOS)
    private var arSession: ARSession?
    #endif
    private var collaborationData: CollaborationData?
    
    // Current active diagrams that should be shared
    @Published var sharedDiagrams: [SharedDiagram] = []
    @Published var sharedAnchor: SharedWorldAnchor? = nil
    private let anchorStorageURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("shared_anchor.json")
    }()

    #if os(visionOS)
    @available(visionOS 26.0, *)
    private var sharedSpaceCoordinator: VisionOSSharedSpaceCoordinator?
    private var sharedSpaceTask: Task<Void, Never>?
    #endif

    #if os(iOS)
    var onCollaborationDataReceived: ((Data) -> Void)?
    #endif
    var onSharedAnchorReceived: ((SharedAnchorMessage) -> Void)?

    #if canImport(GroupActivities)
    private var sharePlayCoordinator: SharePlayCoordinator?
    private var sharePlayParticipantCount = 0
    #endif

    override init() {
        super.init()
        setupMultipeerSession()
        restorePersistedAnchor()

        #if canImport(GroupActivities)
        let coordinator = SharePlayCoordinator()
        coordinator.onDataReceived = { [weak self] data in
            self?.handleIncomingPayload(data, source: "SharePlay")
        }
        coordinator.onSessionJoined = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.isSharePlayActive = true
                self.isSessionActive = true
                self.sessionState = "SharePlay active"
                #if os(visionOS)
                self.startSharedSpaceCoordinatorIfNeeded()
                #endif
                self.resendStateToSharePlay()
            }
        }
        coordinator.onSessionEnded = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isSharePlayActive = false
                self.sharePlayParticipantCount = 0
                if self.connectedPeers.isEmpty {
                    self.isSessionActive = false
                    self.sessionState = self.isHost ? "Hosting - Waiting for peers" : "Not Connected"
                }
            }
        }
        coordinator.onParticipantsChanged = { [weak self] (count: Int) in
            guard let self else { return }
            Task { @MainActor in
                self.sharePlayParticipantCount = count
                let noun = count == 1 ? "participant" : "participants"
                self.sessionState = "SharePlay: \(count) \(noun)"
                if self.isHost && count > 1 {
                    self.resendStateToSharePlay()
                }
            }
        }
        sharePlayCoordinator = coordinator
        #endif

        #if os(visionOS)
        if #available(visionOS 26.0, *) {
            sharedSpaceCoordinator = buildSharedSpaceCoordinator()
        }
        #endif
    }
    
    private func setupMultipeerSession() {
        multipeerSession = MultipeerConnectivityService()
        multipeerSession?.delegate = self
    }
    
    #if os(visionOS)
    @available(visionOS 26.0, *)
    private func buildSharedSpaceCoordinator() -> VisionOSSharedSpaceCoordinator {
        let c = VisionOSSharedSpaceCoordinator()
        c.onCoordinateData = { [weak self] (message: SharedCoordinateSpaceMessage) in
            self?.broadcast(.coordinate(message))
        }
        c.onSharingEnabledChanged = { (available: Bool) in
            print("🌐 Shared coordinate \(available ? "enabled" : "disabled")")
        }
        c.onError = { (error: Error) in
            print("❌ Shared coordinate space error: \(error)")
        }
        return c
    }
    #endif

    func startHosting() async {
        print("🤝 Starting collaborative session as host")
        lastError = nil
        isHost = true

        #if os(iOS)
        await startARSession()
        #endif

        #if canImport(GroupActivities)
        sessionState = "Starting SharePlay session..."
        await sharePlayCoordinator?.start()
        #else
        sessionState = "Hosting - Waiting for peers"
        #endif

        multipeerSession?.startHosting()
        isSessionActive = true
        #if os(visionOS)
        startSharedSpaceCoordinatorIfNeeded()
        #endif
    }
    
    func joinSession() async {
        print("🤝 Joining collaborative session")
        lastError = nil
        isHost = false

        #if os(iOS)
        await startARSession()
        #endif

        #if canImport(GroupActivities)
        sessionState = "Requesting SharePlay access..."
        await sharePlayCoordinator?.start()
        #else
        sessionState = "Searching for hosts..."
        #endif

        multipeerSession?.startBrowsing()
        #if os(visionOS)
        startSharedSpaceCoordinatorIfNeeded()
        #endif
    }

    #if canImport(GroupActivities)
    func startSharePlay() async {
        await sharePlayCoordinator?.start()
    }

    func stopSharePlay() {
        sharePlayCoordinator?.stop()
        isSharePlayActive = false
    }
    #endif

    #if os(visionOS)
    func broadcastCurrentSharedAnchor(confidence: Float = 1.0) {
        let transform: simd_float4x4
        if #available(visionOS 26.0, *), let latest = sharedSpaceCoordinator?.latestDeviceTransform {
            transform = latest
        } else {
            transform = matrix_identity_float4x4
        }
        let message = SharedAnchorMessage(confidence: confidence, transform: transform)
        sendSharedAnchor(message)
    }

    var currentSharedSpaceTransform: simd_float4x4 {
        if #available(visionOS 26.0, *), let latest = sharedSpaceCoordinator?.latestDeviceTransform {
            return latest
        }
        return matrix_identity_float4x4
    }
    #endif

    #if os(iOS)
    func sendCollaborationData(_ data: Data, to peers: [MCPeerID]? = nil) {
        broadcast(.arCollaboration(data), to: peers)
        print("📡 Sent ARCollaborationData (\(data.count) bytes)")
    }
    #endif

    func sendSharedAnchor(_ anchor: SharedAnchorMessage, to peers: [MCPeerID]? = nil) {
        sharedAnchor = SharedWorldAnchor(id: anchor.anchorId,
                                         transform: anchor.matrix,
                                         confidence: anchor.confidence,
                                         timestamp: anchor.timestamp,
                                         worldMapData: anchor.worldMapData)
        persistSharedAnchor(anchor: sharedAnchor)

        broadcast(.anchor(anchor), to: peers)
    }
    
    func stopSession() {
        print("🤝 Stopping collaborative session")
    
        let msg = SessionEndedMessage(byHost: UIDevice.current.name, reason: "Host ended the session", at: Date())
        broadcast(.sessionEnded(msg))

        multipeerSession?.stop()
        
        isSessionActive = false
        isHost = false
        connectedPeers.removeAll()
        availablePeers.removeAll()
        sessionState = "Not Connected"
        lastError = nil
        sharedAnchor = nil
        persistSharedAnchor(anchor: nil)
        #if canImport(GroupActivities)
        sharePlayCoordinator?.stop()
        isSharePlayActive = false
        #endif
        #if os(visionOS)
        sharedSpaceTask?.cancel()
        sharedSpaceTask = nil
        if #available(visionOS 26.0, *) {
            sharedSpaceCoordinator?.stop()
            sharedSpaceCoordinator = nil
        }
        #endif
    }
    
    /// Share a diagram with all connected peers including position data
    func shareDiagram(filename: String,
                      elements: [ElementDTO],
                      worldPosition: SIMD3<Float>? = nil,
                      worldOrientation: simd_quatf? = nil,
                      worldScale: Float? = nil) {

        #if os(iOS)
        // En iOS somos sólo cliente: no iniciamos share de diagramas
        print("ℹ️ Ignoring shareDiagram request on iOS client; iOS is receive-only")
        return
        #endif

        // ✅ Guardar y enviar SIEMPRE en WORLD SPACE del host (sin restar el anchor)
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

        broadcast(.diagram(sharedDiagram))

        print("📊 Shared diagram '\(filename)' with \(connectedPeers.count) peers")
        if let pos = worldPosition {
            print("   🌍 WORLD position: \(pos)")
        }
        if let orient = worldOrientation {
            print("   🔄 Orientation: \(orient)")
        }
        if let scale = worldScale {
            print("   📏 Scale: \(scale)")
        }
    }


    /// HOST-SIDE HELPERS (visionOS):
    /// Always send diagram transforms in **world space** derived from the RealityKit entity.
    #if os(visionOS)
    func shareDiagramFromEntity(filename: String,
                                rootEntity: Entity,
                                elements: [ElementDTO],
                                scaleOverride: Float? = nil) {
        let worldMatrix = rootEntity.transformMatrix(relativeTo: nil)

        let scale = scaleOverride ?? rootEntity.scale(relativeTo: nil).x

        // Si tenemos anchor compartido, convertimos a coordenadas locales del anchor
        if let anchor = sharedAnchor {
            let anchorMatrix = anchor.transform
            let localMatrix = simd_inverse(anchorMatrix) * worldMatrix

            let localPosition = localMatrix.translationVector
            let localOrientation = simd_quatf(localMatrix)

            print("👑 HOST shareDiagramFromEntity '\(filename)' local (anchor) pos =", localPosition)

            shareDiagram(
                filename: filename,
                elements: elements,
                worldPosition: localPosition,        // ⚠️ ahora es LOCAL al anchor
                worldOrientation: localOrientation,
                worldScale: scale
            )
        } else {
            // Fallback: si no hay anchor, enviamos world tal cual
            let position = SIMD3<Float>(
                worldMatrix.columns.3.x,
                worldMatrix.columns.3.y,
                worldMatrix.columns.3.z
            )
            let orientation = simd_quatf(worldMatrix)

            print("👑 HOST shareDiagramFromEntity '\(filename)' WORLD pos =", position)

            shareDiagram(
                filename: filename,
                elements: elements,
                worldPosition: position,
                worldOrientation: orientation,
                worldScale: scale
            )
        }
    }
    #endif


    #if os(visionOS)
    func updateDiagramTransformFromEntity(filename: String,
                                          rootEntity: Entity,
                                          scaleOverride: Float? = nil) {
        let worldMatrix = rootEntity.transformMatrix(relativeTo: nil)
        let scale = scaleOverride ?? rootEntity.scale(relativeTo: nil).x

        if let anchor = sharedAnchor {
            let anchorMatrix = anchor.transform
            let localMatrix = simd_inverse(anchorMatrix) * worldMatrix

            let localPosition = localMatrix.translationVector
            let localOrientation = simd_quatf(localMatrix)

            print("👑 HOST updateDiagramTransformFromEntity '\(filename)' local (anchor) pos =", localPosition)

            updateDiagramTransform(
                filename: filename,
                worldPosition: localPosition,       // ⚠️ LOCAL al anchor
                worldOrientation: localOrientation,
                worldScale: scale
            )
        } else {
            // Fallback: si no hay anchor, usamos world directamente
            let position = SIMD3<Float>(
                worldMatrix.columns.3.x,
                worldMatrix.columns.3.y,
                worldMatrix.columns.3.z
            )
            let orientation = simd_quatf(worldMatrix)

            print("👑 HOST updateDiagramTransformFromEntity '\(filename)' WORLD pos =", position)

            updateDiagramTransform(
                filename: filename,
                worldPosition: position,
                worldOrientation: orientation,
                worldScale: scale
            )
        }
    }
    #endif

    
    @MainActor
    func removeDiagram(filename: String) {
        let before = sharedDiagrams.count
        sharedDiagrams.removeAll { d in
            d.filename == filename ||
            d.filename.hasPrefix(filename) ||
            filename.hasPrefix(d.filename)
        }

        sharedDiagrams = sharedDiagrams

        let removeMessage = RemoveDiagramMessage(filename: filename)
        broadcast(.remove(removeMessage))

        let after = sharedDiagrams.count
        print("🗑️ removeDiagram('\(filename)'): \(before - after) removed; now \(after) remaining")
    }
    
    
    /// Update the transform of an existing shared diagram
    func updateDiagramTransform(filename: String,
                                worldPosition: SIMD3<Float>? = nil,
                                worldOrientation: simd_quatf? = nil,
                                worldScale: Float? = nil) {
        // Actualizar copia local
        guard let index = sharedDiagrams.firstIndex(where: { $0.filename == filename }) else {
            return
        }

        if let pos = worldPosition {
            // ✅ Guardar SIEMPRE en WORLD SPACE del host (sin usar sharedAnchor)
            sharedDiagrams[index].worldPosition = pos
            print("📐 updateDiagramTransform: storing WORLD position \(pos) for '\(filename)'")
        }

        if let orient = worldOrientation {
            sharedDiagrams[index].worldOrientation = orient
        }
        if let scale = worldScale {
            sharedDiagrams[index].worldScale = scale
        }

        // Enviamos también WORLD SPACE a los peers
        let updateMessage = UpdateDiagramTransformMessage(
            filename: filename,
            worldPosition: worldPosition,
            worldOrientation: worldOrientation,
            worldScale: worldScale
        )

        broadcast(.transform(updateMessage))
    }




    @MainActor
    func updateElementPosition(filename: String,
                               elementId: String,
                               localPosition: SIMD3<Float>) {
        let payload = ElementPositionMessage(filename: filename,
                                             elementId: elementId,
                                             localPosition: localPosition)
        broadcast(.elementMoved(payload))

        guard let dIndex = sharedDiagrams.firstIndex(where: { $0.filename == filename }) else {
            return
        }
        let old = sharedDiagrams[dIndex]

        var newElements = old.elements
        if let eIndex = newElements.firstIndex(where: { $0.id == elementId }) {
            var updated = newElements[eIndex]
            updated.position = [Double(localPosition.x),
                                Double(localPosition.y),
                                Double(localPosition.z)]
            newElements[eIndex] = updated

            let newDiagram = SharedDiagram(
                id: old.id,
                filename: old.filename,
                elements: newElements,
                timestamp: Date(),
                worldPosition: old.worldPosition,
                worldOrientation: old.worldOrientation,
                worldScale: old.worldScale
            )
            sharedDiagrams[dIndex] = newDiagram
            sharedDiagrams = sharedDiagrams
        }
    }
    
    #if os(iOS)
    private func startARSession() async {
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

    private func broadcast(_ envelope: SharedSpaceEnvelope, to peers: [MCPeerID]? = nil) {
        guard let data = try? JSONEncoder().encode(envelope) else {
            print("❌ Failed to encode SharedSpaceEnvelope \(envelope)")
            return
        }
        if let peers = peers {
            if !peers.isEmpty {
                multipeerSession?.sendData(data, to: peers)
            }
        } else if !connectedPeers.isEmpty {
            multipeerSession?.sendData(data, to: connectedPeers)
        }
        #if canImport(GroupActivities)
        if peers == nil {
            sendToSharePlay(data)
        }
        #endif
    }

    private func resendStateToSharePlay() {
        #if canImport(GroupActivities)
        guard sharePlayCoordinator?.isActive == true else { return }
        if let anchor = sharedAnchor,
           let data = try? JSONEncoder().encode(SharedSpaceEnvelope.anchor(makeSharedAnchorMessage(from: anchor))) {
            sendToSharePlay(data)
        }
        for diagram in sharedDiagrams {
            if let data = try? JSONEncoder().encode(SharedSpaceEnvelope.diagram(diagram)) {
                sendToSharePlay(data)
            }
        }
        #endif
    }

    #if canImport(GroupActivities)
    private func sendToSharePlay(_ data: Data) {
        guard sharePlayCoordinator?.isActive == true else { return }
        Task { [weak self] in
            await self?.sharePlayCoordinator?.send(data)
        }
    }
    #endif

    private func makeSharedAnchorMessage(from anchor: SharedWorldAnchor) -> SharedAnchorMessage {
        SharedAnchorMessage(anchorId: anchor.id,
                            timestamp: anchor.timestamp,
                            confidence: anchor.confidence,
                            transform: anchor.transform,
                            worldMapData: anchor.worldMapData)
    }

    private func persistSharedAnchor(anchor: SharedWorldAnchor?) {
        guard let anchor else {
            clearPersistedAnchor()
            return
        }
        let persisted = PersistedAnchor(anchor: anchor)
        do {
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: anchorStorageURL, options: .atomic)
        } catch {
            print("⚠️ Failed to persist shared anchor: \(error)")
        }
    }

    private func restorePersistedAnchor() {
        guard let data = try? Data(contentsOf: anchorStorageURL),
              let persisted = try? JSONDecoder().decode(PersistedAnchor.self, from: data) else {
            return
        }
        sharedAnchor = SharedWorldAnchor(id: persisted.id,
                                         transform: persisted.makeMatrix(),
                                         confidence: persisted.confidence,
                                         timestamp: persisted.timestamp,
                                         worldMapData: persisted.worldMapData)
    }

    private func clearPersistedAnchor() {
        try? FileManager.default.removeItem(at: anchorStorageURL)
    }

    @MainActor
    private func handleIncomingPayload(_ data: Data, source: String) {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(SharedSpaceEnvelope.self, from: data) {
            handleSharedEnvelope(envelope, source: source)
            return
        }

        print("❓ Received unknown data from \(source)")
    }
}

@MainActor
private extension CollaborativeSessionManager {
    func handleSharedEnvelope(_ envelope: SharedSpaceEnvelope, source: String) {
        switch envelope {
        case .anchor(let anchorMsg):
            sharedAnchor = SharedWorldAnchor(id: anchorMsg.anchorId,
                                             transform: anchorMsg.matrix,
                                             confidence: anchorMsg.confidence,
                                             timestamp: anchorMsg.timestamp,
                                             worldMapData: anchorMsg.worldMapData)
            persistSharedAnchor(anchor: sharedAnchor)
            onSharedAnchorReceived?(anchorMsg)
            print("📡 Received shared anchor '\(anchorMsg.anchorId)' from \(source)")

        case .coordinate(let coordinateMsg):
            #if os(visionOS)
            if #available(visionOS 26.0, *) {
                sharedSpaceCoordinator?.pushCoordinateData(coordinateMsg)
            }
            #else
            print("ℹ️ Ignoring shared coordinate payload (unsupported platform)")
            #endif

        case .diagram(let sharedDiagram):
            if !sharedDiagrams.contains(where: { $0.id == sharedDiagram.id }) {
                sharedDiagrams.append(sharedDiagram)
                print("📥 Received shared diagram '\(sharedDiagram.filename)' from \(source)")
                if let pos = sharedDiagram.worldPosition {
                    print("   🌍 WORLD Position: \(pos)")
                }
            } else if let index = sharedDiagrams.firstIndex(where: { $0.id == sharedDiagram.id }) {
                sharedDiagrams[index] = sharedDiagram
                sharedDiagrams = sharedDiagrams
            }

        case .transform(let updateMessage):
            if let index = sharedDiagrams.firstIndex(where: { $0.filename == updateMessage.filename }) {
                if let pos = updateMessage.worldPosition {
                    sharedDiagrams[index].worldPosition = pos
                }
                if let orient = updateMessage.worldOrientation {
                    sharedDiagrams[index].worldOrientation = orient
                }
                if let scale = updateMessage.worldScale {
                    sharedDiagrams[index].worldScale = scale
                }
                print("🔄 Updated WORLD transform for diagram '\(updateMessage.filename)' from \(source)")
                sharedDiagrams = sharedDiagrams
            }

        case .remove(let removeMessage):
            let target = removeMessage.filename
            let before = sharedDiagrams.count
            sharedDiagrams.removeAll { d in
                d.filename == target ||
                d.filename.hasPrefix(target) ||
                target.hasPrefix(d.filename)
            }
            sharedDiagrams = sharedDiagrams
            let after = sharedDiagrams.count
            print("🗑️ Received remove for '\(target)' from \(source). Removed \(before - after); now \(after).")
            
        case .arCollaboration(let blob):
            #if os(iOS)
            onCollaborationDataReceived?(blob)
            print("📡 Received ARCollaborationData (\(blob.count) bytes) from \(source)")
            #else
            print("ℹ️ Ignoring ARCollaborationData payload on non-iOS platform")
            #endif

        case .elementMoved(let p):
            if let dIndex = sharedDiagrams.firstIndex(where: { $0.filename == p.filename }) {
                let old = sharedDiagrams[dIndex]
                var newElements = old.elements
                if let eIndex = newElements.firstIndex(where: { $0.id == p.elementId }) {
                    var updated = newElements[eIndex]
                    updated.position = [Double(p.localPosition.x),
                                        Double(p.localPosition.y),
                                        Double(p.localPosition.z)]
                    newElements[eIndex] = updated

                    let newDiagram = SharedDiagram(
                        id: old.id,
                        filename: old.filename,
                        elements: newElements,
                        timestamp: Date(),
                        worldPosition: old.worldPosition,
                        worldOrientation: old.worldOrientation,
                        worldScale: old.worldScale
                    )
                    sharedDiagrams[dIndex] = newDiagram
                    sharedDiagrams = sharedDiagrams
                    print("✏️ Element '\(p.elementId)' moved in '\(p.filename)' from \(source)")
                } else {
                    print("⚠️ Received elementMoved for unknown element '\(p.elementId)' in '\(p.filename)'")
                }
            } else {
                print("⚠️ Received elementMoved for unknown diagram '\(p.filename)'")
            }
            
        case .sessionEnded(let info):
            sharedDiagrams.removeAll()
            sharedDiagrams = sharedDiagrams
            sharedAnchor = nil
            persistSharedAnchor(anchor: nil)
            isSessionActive = false
            sessionState = "Session ended by \(info.byHost)"
            pendingAlert = SessionAlert(
                title: "Session Ended",
                message: "The host (\(info.byHost)) ended the session. All shared diagrams were removed."
            )
            print("🛑 Session ended by \(info.byHost) from \(source)")

        case .participantLeft(let left):
            pendingAlert = SessionAlert(title: "Participant Left",
                                        message: "\(left.peerName) left the session.")
            print("👋 Participant left: \(left.peerName) from \(source)")
            
        }
    }
}

#if os(visionOS)
extension CollaborativeSessionManager {
    private func startSharedSpaceCoordinatorIfNeeded() {
        guard #available(visionOS 26.0, *) else { return }
        if sharedSpaceCoordinator == nil {
            sharedSpaceCoordinator = buildSharedSpaceCoordinator()
        }
        guard let coordinator = sharedSpaceCoordinator else { return }
        sharedSpaceTask?.cancel()
        sharedSpaceTask = Task { [weak coordinator] in
            await coordinator?.start()
        }
    }
}
#endif

extension CollaborativeSessionManager: @preconcurrency MultipeerConnectivityDelegate {
    func multipeerService(_ service: MultipeerConnectivityService, didReceiveData data: Data, from peer: MCPeerID) {
        handleIncomingPayload(data, source: peer.displayName)
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
            
            for diagram in sharedDiagrams {
                broadcast(.diagram(diagram), to: [peer])
                print("📤 Sent shared diagram '\(diagram.filename)' to new peer")
            }

            if let anchor = sharedAnchor {
                broadcast(.anchor(makeSharedAnchorMessage(from: anchor)), to: [peer])
                print("📤 Sent shared anchor '\(anchor.id)' to new peer")
            }
            
        case .connecting:
            sessionState = "Connecting to \(peer.displayName)..."
            print("🔄 Connecting to \(peer.displayName)")
            
        case .notConnected:
            connectedPeers.removeAll { $0 == peer }
            
            let msg = ParticipantLeftMessage(peerName: peer.displayName, at: Date())
            broadcast(.participantLeft(msg))
            pendingAlert = SessionAlert(title: "Participant Left",
                                        message: "\(peer.displayName) left the session.")
            
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

struct SharedDiagram: Codable, Identifiable {
    let id: UUID
    let filename: String
    let elements: [ElementDTO]
    let timestamp: Date
    // WORLD-space positioning data
    var worldPosition: SIMD3<Float>?
    var worldOrientation: simd_quatf?
    var worldScale: Float?
    
    enum CodingKeys: String, CodingKey {
        case id, filename, elements, timestamp
        case worldPositionX, worldPositionY, worldPositionZ
        case worldOrientationX, worldOrientationY, worldOrientationZ, worldOrientationW
        case worldScale
    }
    
    init(id: UUID = UUID(),
         filename: String,
         elements: [ElementDTO],
         timestamp: Date = Date(),
         worldPosition: SIMD3<Float>? = nil,
         worldOrientation: simd_quatf? = nil,
         worldScale: Float? = nil) {
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
        
        if let x = try container.decodeIfPresent(Float.self, forKey: .worldPositionX),
           let y = try container.decodeIfPresent(Float.self, forKey: .worldPositionY),
           let z = try container.decodeIfPresent(Float.self, forKey: .worldPositionZ) {
            worldPosition = SIMD3<Float>(x, y, z)
        }
        
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
        
        if let pos = worldPosition {
            try container.encode(pos.x, forKey: .worldPositionX)
            try container.encode(pos.y, forKey: .worldPositionY)
            try container.encode(pos.z, forKey: .worldPositionZ)
        }
        
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

struct SharedAnchorMessage: Codable {
    var anchorId: String
    var timestamp: Date
    var confidence: Float
    var matrix: simd_float4x4
    var worldMapData: Data?

    enum CodingKeys: String, CodingKey {
        case anchorId
        case timestamp
        case confidence
        case matrixElements
        case worldMapData
    }

    init(anchorId: String = UUID().uuidString,
         timestamp: Date = Date(),
         confidence: Float = 1.0,
         transform: simd_float4x4,
         worldMapData: Data? = nil) {
        self.anchorId = anchorId
        self.timestamp = timestamp
        self.confidence = confidence
        self.matrix = transform
        self.worldMapData = worldMapData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anchorId = try container.decode(String.self, forKey: .anchorId)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        confidence = try container.decode(Float.self, forKey: .confidence)
        let elements = try container.decode([Float].self, forKey: .matrixElements)
        matrix = SharedAnchorMessage.makeMatrix(from: elements)
        worldMapData = try container.decodeIfPresent(Data.self, forKey: .worldMapData)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(anchorId, forKey: .anchorId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(SharedAnchorMessage.flatten(matrix), forKey: .matrixElements)
        try container.encodeIfPresent(worldMapData, forKey: .worldMapData)
    }

    static func flatten(_ matrix: simd_float4x4) -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(16)
        for column in 0..<4 {
            values.append(matrix[column, 0])
            values.append(matrix[column, 1])
            values.append(matrix[column, 2])
            values.append(matrix[column, 3])
        }
        return values
    }

    static func makeMatrix(from values: [Float]) -> simd_float4x4 {
        guard values.count == 16 else { return matrix_identity_float4x4 }
        var columns: [SIMD4<Float>] = []
        columns.reserveCapacity(4)
        for column in 0..<4 {
            columns.append(SIMD4<Float>(values[column * 4 + 0],
                                        values[column * 4 + 1],
                                        values[column * 4 + 2],
                                        values[column * 4 + 3]))
        }
        return simd_float4x4(columns)
    }
}

struct SharedWorldAnchor {
    let id: String
    let transform: simd_float4x4
    let confidence: Float
    let timestamp: Date
    let worldMapData: Data?
}

struct SharedCoordinateSpaceMessage: Codable {
    let payload: Data
    let recipientIdentifiers: [UUID]
}

struct SessionEndedMessage: Codable {
    let byHost: String
    let reason: String?
    let at: Date
}

struct ParticipantLeftMessage: Codable {
    let peerName: String
    let at: Date
}

struct SessionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}


enum SharedSpaceEnvelope: Codable {
    case anchor(SharedAnchorMessage)
    case coordinate(SharedCoordinateSpaceMessage)
    case diagram(SharedDiagram)
    case transform(UpdateDiagramTransformMessage)
    case remove(RemoveDiagramMessage)
    case arCollaboration(Data)
    case elementMoved(ElementPositionMessage)
    case sessionEnded(SessionEndedMessage)
    case participantLeft(ParticipantLeftMessage)

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum EnvelopeType: String, Codable {
        case anchor
        case coordinate
        case diagram
        case transform
        case remove
        case arCollaboration
        case elementMoved
        case sessionEnded
        case participantLeft
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .anchor(let message):
            try container.encode(EnvelopeType.anchor, forKey: .type)
            try container.encode(message, forKey: .payload)
        case .coordinate(let message):
            try container.encode(EnvelopeType.coordinate, forKey: .type)
            try container.encode(message, forKey: .payload)
        case .diagram(let diagram):
            try container.encode(EnvelopeType.diagram, forKey: .type)
            try container.encode(diagram, forKey: .payload)
        case .transform(let update):
            try container.encode(EnvelopeType.transform, forKey: .type)
            try container.encode(update, forKey: .payload)
        case .remove(let remove):
            try container.encode(EnvelopeType.remove, forKey: .type)
            try container.encode(remove, forKey: .payload)
        case .arCollaboration(let data):
            try container.encode(EnvelopeType.arCollaboration, forKey: .type)
            try container.encode(data, forKey: .payload)
        case .elementMoved(let msg):
            try container.encode(EnvelopeType.elementMoved, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .sessionEnded(let m):
            try container.encode(EnvelopeType.sessionEnded, forKey: .type)
            try container.encode(m, forKey: .payload)
        case .participantLeft(let m):
            try container.encode(EnvelopeType.participantLeft, forKey: .type)
            try container.encode(m, forKey: .payload)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let envelopeType = try container.decode(EnvelopeType.self, forKey: .type)
        switch envelopeType {
        case .anchor:
            let msg = try container.decode(SharedAnchorMessage.self, forKey: .payload)
            self = .anchor(msg)
        case .coordinate:
            let msg = try container.decode(SharedCoordinateSpaceMessage.self, forKey: .payload)
            self = .coordinate(msg)
        case .diagram:
            let diagram = try container.decode(SharedDiagram.self, forKey: .payload)
            self = .diagram(diagram)
        case .transform:
            let update = try container.decode(UpdateDiagramTransformMessage.self, forKey: .payload)
            self = .transform(update)
        case .remove:
            let remove = try container.decode(RemoveDiagramMessage.self, forKey: .payload)
            self = .remove(remove)
        case .arCollaboration:
            let data = try container.decode(Data.self, forKey: .payload)
            self = .arCollaboration(data)
        case .elementMoved:
            let msg = try container.decode(ElementPositionMessage.self, forKey: .payload)
            self = .elementMoved(msg)
        case .sessionEnded:
            let msg = try container.decode(SessionEndedMessage.self, forKey: .payload)
            self = .sessionEnded(msg)
        case .participantLeft:
            let msg = try container.decode(ParticipantLeftMessage.self, forKey: .payload)
            self = .participantLeft(msg)
        }
    }
}

private struct PersistedAnchor: Codable {
    let id: String
    let timestamp: Date
    let confidence: Float
    let matrix: [Float]
    let worldMapData: Data?

    init(anchor: SharedWorldAnchor) {
        id = anchor.id
        timestamp = anchor.timestamp
        confidence = anchor.confidence
        matrix = SharedAnchorMessage.flatten(anchor.transform)
        worldMapData = anchor.worldMapData
    }

    func makeMatrix() -> simd_float4x4 {
        SharedAnchorMessage.makeMatrix(from: matrix)
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
    
    enum CodingKeys: String, CodingKey {
        case filename
        case worldPositionX, worldPositionY, worldPositionZ
        case worldOrientationX, worldOrientationY, worldOrientationZ, worldOrientationW
        case worldScale
    }
    
    init(filename: String,
         worldPosition: SIMD3<Float>? = nil,
         worldOrientation: simd_quatf? = nil,
         worldScale: Float? = nil) {
        self.filename = filename
        self.worldPosition = worldPosition
        self.worldOrientation = worldOrientation
        self.worldScale = worldScale
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decode(String.self, forKey: .filename)
        
        if let x = try container.decodeIfPresent(Float.self, forKey: .worldPositionX),
           let y = try container.decodeIfPresent(Float.self, forKey: .worldPositionY),
           let z = try container.decodeIfPresent(Float.self, forKey: .worldPositionZ) {
            worldPosition = SIMD3<Float>(x, y, z)
        }
        
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
        
        if let pos = worldPosition {
            try container.encode(pos.x, forKey: .worldPositionX)
            try container.encode(pos.y, forKey: .worldPositionY)
            try container.encode(pos.z, forKey: .worldPositionZ)
        }
        
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

struct ElementPositionMessage: Codable {
    let filename: String
    let elementId: String
    var localPosition: SIMD3<Float>

    enum CodingKeys: String, CodingKey {
        case filename
        case elementId
        case localPosX, localPosY, localPosZ
    }

    init(filename: String, elementId: String, localPosition: SIMD3<Float>) {
        self.filename = filename
        self.elementId = elementId
        self.localPosition = localPosition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filename = try c.decode(String.self, forKey: .filename)
        elementId = try c.decode(String.self, forKey: .elementId)
        let x = try c.decode(Float.self, forKey: .localPosX)
        let y = try c.decode(Float.self, forKey: .localPosY)
        let z = try c.decode(Float.self, forKey: .localPosZ)
        localPosition = SIMD3<Float>(x, y, z)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(filename, forKey: .filename)
        try c.encode(elementId, forKey: .elementId)
        try c.encode(localPosition.x, forKey: .localPosX)
        try c.encode(localPosition.y, forKey: .localPosY)
        try c.encode(localPosition.z, forKey: .localPosZ)
    }
}

#if canImport(GroupActivities)
@MainActor
final class SharePlayCoordinator {
    var onDataReceived: ((Data) -> Void)?
    var onSessionJoined: (() -> Void)?
    var onSessionEnded: (() -> Void)?
    var onParticipantsChanged: ((Int) -> Void)?

    var isActive: Bool { currentSession != nil }

    private var currentSession: GroupSession<SharedSpaceActivity>?
    private var messenger: GroupSessionMessenger?
    private var messageTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var participantsTask: Task<Void, Never>?

    init() {
        listenerTask = Task { [weak self] in
            await self?.listenForSessions()
        }
    }

    deinit {
        listenerTask?.cancel()
    }

    func start() async {
        do {
            let activity = SharedSpaceActivity()
            let result = await activity.prepareForActivation()
            if result == .activationPreferred {
                do {
                    try await activity.activate()
                } catch {
                    print("❌ SharePlay activation failed: \(error)")
                }
            }
        } catch {
            print("❌ SharePlay activation failed: \(error)")
        }
    }

    func stop() {
        messageTask?.cancel()
        stateTask?.cancel()
        participantsTask?.cancel()
        messageTask = nil
        stateTask = nil
        participantsTask = nil
        messenger = nil
        currentSession?.leave()
        currentSession?.end()
        currentSession = nil
        onSessionEnded?()
    }

    func send(_ data: Data) async {
        guard let messenger else { return }
        do {
            try await messenger.send(data)
        } catch {
            print("❌ SharePlay send failed: \(error)")
        }
    }

    private func listenForSessions() async {
        for await session in SharedSpaceActivity.sessions() {
            configureSession(session)
        }
    }

    private func configureSession(_ session: GroupSession<SharedSpaceActivity>) {
        currentSession?.leave()
        currentSession?.end()
        currentSession = session
        messenger = GroupSessionMessenger(session: session)

        messageTask?.cancel()
        messageTask = Task {
            guard let messenger = messenger else { return }
            for await (data, _) in messenger.messages(of: Data.self) {
                await MainActor.run { [weak self] in
                    self?.onDataReceived?(data)
                }
            }
        }

        stateTask?.cancel()
        stateTask = Task {
            for await state in session.$state.values {
                if case .invalidated = state {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.messenger = nil
                        self.currentSession = nil
                        self.onSessionEnded?()
                    }
                    break
                }
            }
        }

        participantsTask?.cancel()
        participantsTask = Task {
            for await participants in session.$activeParticipants.values {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.onParticipantsChanged?(participants.count)
                }
            }
        }

        session.join()
        onSessionJoined?()
    }
}

struct SharedSpaceActivity: GroupActivity {
    static var activityIdentifier: String { "org.riquelme.avar2.sharedspace" }

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "AVAR2 Shared Space"
        metadata.type = .generic
        return metadata
    }
}
#endif

#if os(visionOS) || os(iOS)
class CollaborationData: ObservableObject {
    #if os(iOS)
    @Published var worldMap: ARWorldMap?
    #endif
    
    init() {
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
