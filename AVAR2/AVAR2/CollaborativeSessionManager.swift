import Foundation
import RealityKit
import MultipeerConnectivity
import Combine
import simd
import OSLog
#if canImport(GroupActivities)
import GroupActivities
#endif

#if canImport(ARKit)
import ARKit
#endif

#if os(visionOS)
import RealityKitContent
#endif

private let collabLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "CollaborativeSession")

/// Manages collaborative sessions for multi-device diagram viewing.
///
/// ## Alignment invariant (visionOS 26+)
///
/// **A `WorldAnchor`'s `originFromAnchorTransform` must NEVER be transmitted between
/// visionOS devices. Only its UUID crosses the wire.**
///
/// Every device has a private, unrelated ARKit world origin. The system's shared-anchor
/// mechanism guarantees that the *same anchor UUID resolves to the same physical point on
/// every nearby participant, expressed in that participant's own origin*. The transform is
/// therefore already correct and already **different** on each device. Sending one device's
/// value and applying it on another is not "syncing" — it overwrites a correct local value
/// with a meaningless foreign one, which is what made diagrams appear scattered and
/// unaligned.
///
/// So what actually crosses the wire is:
/// - the session-origin anchor **UUID** (see `SharedWorldAnchorManager`), and
/// - diagram transforms expressed **relative to that anchor**.
///
/// Each device resolves the anchor's transform locally from its own
/// `WorldTrackingProvider.anchorUpdates`. Shared anchors are also never persisted — per the
/// ARKit headers their lifetime is limited to the SharePlay session — so re-creating one per
/// session is the normal path, not an error path.
///
/// ## Transports
/// - SharePlay (GroupActivities) for visionOS↔visionOS.
/// - MultipeerConnectivity for the iOS companion, which is receive-only and cannot resolve a
///   visionOS `WorldAnchor`; it keeps using the legacy `SharedAnchorMessage` handshake.

@MainActor
class CollaborativeSessionManager: NSObject, ObservableObject {
    struct DiagramTransform {
        let position: SIMD3<Float>
        let orientation: simd_quatf
        let scale: Float
    }
    // MARK: - Published State
    @Published var isSessionActive = false
    @Published var connectedPeers: [MCPeerID] = []
    @Published var availablePeers: [MCPeerID] = []
    @Published var sessionState: String = "Not Connected"
    @Published var isHost = false
    @Published var lastError: String? = nil
    @Published var isSharePlayActive = false
    @Published var pendingAlert: SessionAlert? = nil

    // visionOS 26+: Nearby participant tracking
    @Published var nearbyParticipantCount: Int = 0
    @Published var hasNearbyParticipants: Bool = false
    @Published var worldAnchorSharingAvailable: Bool = false
    @Published private(set) var sharedAnchorUsesSharedWorld: Bool = false
    /// Description of the most recent shared-anchor creation failure, surfaced in the HUD.
    /// Cleared on the next successful creation.
    @Published private(set) var anchorCreationFailure: String?

    private var multipeerSession: MultipeerConnectivityService?
    #if os(iOS)
    private var arSession: ARSession?
    #endif

    // Current active diagrams that should be shared
    @Published var sharedDiagrams: [SharedDiagram] = []
    /// The active anchor, in the legacy `SharedWorldAnchor` shape.
    ///
    /// Two different roles depending on platform, deliberately:
    /// - **iOS**: the authoritative anchor, produced from an `ARFrame` camera transform and
    ///   exchanged via `SharedAnchorMessage`. An iPhone cannot resolve a visionOS shared
    ///   `WorldAnchor`, so it keeps its own legacy handshake.
    /// - **visionOS**: a read-only *mirror* of the authoritative `sessionOrigin*` state, kept only
    ///   so existing UI (and the `SharedDiagram` payload shared with iOS) need not be rewritten.
    ///   Only `.id` is ever read here.
    ///
    /// On visionOS the mirror has exactly three writers — `onAnchorUpdated`, `onAnchorRemoved` and
    /// `clearSessionOrigin()` — each of which sets `sharedAnchor` and
    /// `sharedAnchorUsesSharedWorld` together. Never write one without the other: the original bug
    /// was precisely this flag being clobbered out of step with the anchor it described. Prefer
    /// reading `sessionOriginID` / `sessionOriginTransform` / `sessionOriginIsTracked` in new code.
    @Published var sharedAnchor: SharedWorldAnchor? = nil

    /// Per-envelope-type traffic counters, surfaced in the diagnostics HUD.
    ///
    /// This exists because a failed send is otherwise invisible: `messenger.send` errors were
    /// swallowed by a `catch` that only printed. With these, "nothing happened" becomes
    /// "we sent one 1.3 MB `.diagram` and got <error>", which is the difference between
    /// guessing and diagnosing during a two-device session.
    @Published private(set) var envelopeStats: [String: EnvelopeStat] = [:]

    struct EnvelopeStat: Equatable {
        var sent = 0
        var received = 0
        var bytesSent = 0
        var bytesReceived = 0
        var lastError: String?
        /// Transport labels seen for this envelope type, e.g. "SharePlay", "peer-name".
        var sources: Set<String> = []
    }

    func noteEnvelopeSent(_ kind: String, bytes: Int, error: String? = nil) {
        var stat = envelopeStats[kind] ?? EnvelopeStat()
        stat.sent += 1
        stat.bytesSent += bytes
        if let error { stat.lastError = error }
        envelopeStats[kind] = stat
    }

    func noteEnvelopeReceived(_ kind: String, bytes: Int, source: String) {
        var stat = envelopeStats[kind] ?? EnvelopeStat()
        stat.received += 1
        stat.bytesReceived += bytes
        stat.sources.insert(source)
        envelopeStats[kind] = stat
    }

    private var localDiagramTransforms: [String: DiagramTransform] = [:]

    // Shared world anchors. Deployment target is visionOS 26.0, so no availability gate.
    // Note: shared anchors are never persisted (ARKit: lifetime == the SharePlay session),
    // so there is deliberately no on-disk cache here.
    #if os(visionOS)
    let sharedWorldAnchorManager = SharedWorldAnchorManager()

    // MARK: - Session origin
    //
    // Exactly one shared WorldAnchor per session acts as the common frame. Its UUID is the only
    // thing that crosses the wire; each device resolves the transform itself.

    /// UUID of the session-origin anchor, once known (created locally or adopted from a peer).
    @Published private(set) var sessionOriginID: UUID?
    /// This device's own `originFromAnchorTransform` for that anchor. **Never transmitted.**
    @Published private(set) var sessionOriginTransform: simd_float4x4?
    /// Whether ARKit is currently tracking the origin anchor. When false we keep the last good
    /// transform rather than moving content.
    @Published private(set) var sessionOriginIsTracked = false

    /// An origin UUID learned from a peer that our own ARKit has not resolved yet.
    private var pendingSessionOriginID: UUID?
    /// The anchor this device created, if it won the election. Used to drop ours on tie-break.
    private var ownedAnchorID: UUID?
    private var sessionOriginTask: Task<Void, Never>?

    /// True when this device should create the session-origin anchor.
    /// Election logic lives in `SessionOriginElection` so it can be tested exhaustively.
    var isSessionOriginOwner: Bool {
        #if canImport(GroupActivities)
        guard let coordinator = sharePlayCoordinator else { return false }
        return SessionOriginElection.isOwner(localID: coordinator.localParticipantID,
                                             participantIDs: coordinator.participantIDs)
        #else
        return false
        #endif
    }

    /// The elected owner, for diagnostics. Both devices must display the same value.
    var electedOriginOwnerID: UUID? {
        #if canImport(GroupActivities)
        return SessionOriginElection.owner(participantIDs: sharePlayCoordinator?.participantIDs ?? [])
        #else
        return nil
        #endif
    }
    #endif

    // iOS-only: callback to deliver ARCollaborationData blobs to the local ARSession
    #if os(iOS)
    var onCollaborationDataReceived: ((Data) -> Void)?
    #endif

    // Shared world anchor callback
    var onSharedAnchorReceived: ((SharedAnchorMessage) -> Void)?

    #if canImport(GroupActivities)
    private(set) var sharePlayCoordinator: SharePlayCoordinator?
    private var sharePlayParticipantCount = 0
    #endif

    override init() {
        super.init()
        setupMultipeerSession()

        #if canImport(GroupActivities)
        let coordinator = SharePlayCoordinator()
        coordinator.onDataReceived = { [weak self] data in
            self?.handleIncomingPayload(data, source: "SharePlay")
        }
        coordinator.onSessionJoined = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                print("✅ SharePlay session joined, isHost=\(coordinator.isHost)")
                self.isSharePlayActive = true
                self.isSessionActive = true
                self.sessionState = "SharePlay active"
                self.isHost = coordinator.isHost

                #if os(visionOS)
                await self.startSharedWorldAnchorManager()
                self.startSessionOriginLoop()
                #endif

                self.resendStateToSharePlay()
            }
        }
        coordinator.onSessionEnded = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                print("🛑 SharePlay session ended")
                self.isSharePlayActive = false
                self.sharePlayParticipantCount = 0
                self.nearbyParticipantCount = 0
                self.hasNearbyParticipants = false

                #if os(visionOS)
                self.stopSessionOriginLoop()
                self.sharedWorldAnchorManager.stop()
                // Shared anchors die with the SharePlay session by design (ARKit: lifetime is
                // the session), so clearing here is the normal path, not an error path.
                self.clearSessionOrigin()
                #endif

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
                self.isHost = coordinator.isHost

                if self.isHost && count > 1 {
                    self.resendStateToSharePlay()
                }
            }
        }
        coordinator.onNearbyParticipantsChanged = { [weak self] participants in
            guard let self else { return }
            Task { @MainActor in
                self.nearbyParticipantCount = participants.count
                self.hasNearbyParticipants = !participants.isEmpty
                if !participants.isEmpty {
                    self.sessionState = "SharePlay: \(participants.count) nearby"
                }
            }
        }
        sharePlayCoordinator = coordinator
        #endif
    }

    // MARK: - visionOS 26+ Shared World Anchors

    #if os(visionOS)
    private func startSharedWorldAnchorManager() async {
        let manager = sharedWorldAnchorManager

        // Set up callbacks
        // THE ONLY writer of `sessionOriginTransform`.
        //
        // Filtered by UUID: `onAnchorUpdated` fires for EVERY shared anchor in the session,
        // including other participants'. The old code wrote whichever arrived last into a single
        // global slot with no diagram↔anchor correlation, so the "shared anchor" was effectively
        // random. The owner also reads its transform here rather than reusing the matrix it
        // passed to `addSharedAnchor`, so both devices resolve it through one identical path.
        manager.onAnchorUpdated = { [weak self] anchor in
            guard let self else { return }
            Task { @MainActor in
                guard anchor.id == (self.sessionOriginID ?? self.pendingSessionOriginID) else {
                    print("↩️ Ignoring shared anchor \(anchor.id) — not the session origin")
                    return
                }
                self.sessionOriginID = anchor.id
                self.pendingSessionOriginID = nil
                self.sessionOriginIsTracked = anchor.isTracked
                if anchor.isTracked {
                    // Keep the last good transform when tracking drops, rather than yanking
                    // content to a stale pose.
                    self.sessionOriginTransform = anchor.originFromAnchorTransform
                }

                // Mirror into the legacy fields the existing UI/iOS lane still reads.
                self.sharedAnchor = SharedWorldAnchor(
                    id: anchor.id.uuidString,
                    transform: anchor.originFromAnchorTransform,
                    confidence: 1.0,
                    timestamp: Date(),
                    worldMapData: nil
                )
                self.sharedAnchorUsesSharedWorld = true
                self.anchorCreationFailure = nil
            }
        }

        manager.onAnchorRemoved = { [weak self] anchorID in
            print("🗑️ Shared anchor removed: \(anchorID)")
            Task { @MainActor in
                guard let self, anchorID == self.sessionOriginID else { return }
                self.sessionOriginID = nil
                self.sessionOriginTransform = nil
                self.sessionOriginIsTracked = false
                if self.ownedAnchorID == anchorID { self.ownedAnchorID = nil }
                self.sharedAnchor = nil
                self.sharedAnchorUsesSharedWorld = false
            }
        }

        manager.onSharingAvailabilityChanged = { [weak self] available in
            guard let self else { return }
            Task { @MainActor in
                self.worldAnchorSharingAvailable = available
                print("🔄 World anchor sharing: \(available ? "available" : "unavailable")")
            }
        }

        await manager.start()
        print("✅ SharedWorldAnchorManager started for SharePlay session")
    }

    /// Create a shared anchor in front of the user
    func createSharedAnchorInFrontOfUser(distance: Float = 1.5) async throws -> UUID {
        let anchor = try await sharedWorldAnchorManager.createSharedAnchorInFrontOfUser(distance: distance)
        return anchor.id
    }

    /// Ensure a shared world anchor exists for the current SharePlay session.
    ///
    /// Safe to call repeatedly — the retry loop below is the primary driver; this remains for the
    /// manual "Create Shared Anchor" button.
    func ensureSharedWorldAnchorInFrontOfUser(distance: Float = 1.5) async {
        guard isSessionOriginOwner else { return }
        guard sessionOriginID == nil, pendingSessionOriginID == nil else { return }
        guard worldAnchorSharingAvailable else {
            print("⚠️ Shared world anchors not available yet")
            return
        }
        await createAndAnnounceSessionOrigin(distance: distance)
    }

    private func createAndAnnounceSessionOrigin(distance: Float) async {
        do {
            let anchorID = try await createSharedAnchorInFrontOfUser(distance: distance)
            ownedAnchorID = anchorID
            // Adopt our own id so `onAnchorUpdated`'s UUID filter lets the transform through.
            sessionOriginID = anchorID
            anchorCreationFailure = nil
            announceSessionOrigin(anchorID)
            print("📍 Created + announced session origin anchor \(anchorID)")
        } catch {
            anchorCreationFailure = error.localizedDescription
            print("❌ Failed to create session origin anchor: \(error)")
        }
    }

    private func announceSessionOrigin(_ anchorID: UUID) {
        #if canImport(GroupActivities)
        guard let ownerID = sharePlayCoordinator?.localParticipantID else { return }
        broadcast(.sessionOrigin(SessionOriginMessage(anchorID: anchorID, ownerParticipantID: ownerID)))
        #endif
    }

    /// Drives session-origin creation and re-announcement.
    ///
    /// This replaces five fire-once call sites that all ran immediately on join — when
    /// `worldAnchorSharingAvailability` is still `.unavailable`, because it only becomes
    /// available *after* a nearby SharePlay session exists. They never retried, so in practice
    /// the real shared anchor was never created at all.
    func startSessionOriginLoop() {
        sessionOriginTask?.cancel()
        sessionOriginTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isSharePlayActive else { break }

                let participantCount = self.sharePlayCoordinator?.participantIDs.count ?? 0
                let canCreate = self.worldAnchorSharingAvailable
                    && self.isSpatialSession
                    && participantCount >= 2

                if self.sessionOriginID == nil, self.pendingSessionOriginID == nil,
                   self.isSessionOriginOwner, canCreate {
                    await self.createAndAnnounceSessionOrigin(distance: 1.5)
                }

                // Idempotent re-announce so late joiners learn the origin without extra plumbing.
                if self.isSessionOriginOwner, let id = self.sessionOriginID {
                    self.announceSessionOrigin(id)
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopSessionOriginLoop() {
        sessionOriginTask?.cancel()
        sessionOriginTask = nil
    }

    func clearSessionOrigin() {
        sessionOriginID = nil
        pendingSessionOriginID = nil
        ownedAnchorID = nil
        sessionOriginTransform = nil
        sessionOriginIsTracked = false
        sharedAnchor = nil
        sharedAnchorUsesSharedWorld = false
    }

    /// Handles a peer's origin announcement.
    ///
    /// Tie-break: if both devices raced and each created an anchor, the one owned by the
    /// lower participant UUID wins and the other drops its anchor. This converges to a single
    /// origin regardless of message ordering, which matters because a device briefly sees only
    /// itself in `activeParticipants` while joining and can elect itself.
    func handleSessionOriginAnnouncement(_ message: SessionOriginMessage, source: String) {
        guard message.anchorID != sessionOriginID else { return }

        #if canImport(GroupActivities)
        if let mineOwner = sharePlayCoordinator?.localParticipantID,
           ownedAnchorID != nil,
           SessionOriginElection.shouldYield(toOwner: message.ownerParticipantID, localOwnerID: mineOwner) {
            // Their owner id sorts lower: yield.
            print("🤝 Yielding session origin to \(message.ownerParticipantID) (lower id)")
            if let mine = ownedAnchorID {
                Task { try? await sharedWorldAnchorManager.removeAnchor(mine) }
            }
            ownedAnchorID = nil
            sessionOriginID = nil
            sessionOriginTransform = nil
            sessionOriginIsTracked = false
        } else if ownedAnchorID != nil {
            // We own the lower id — keep ours and let the re-announce loop assert it.
            print("🤝 Keeping our session origin; ignoring announcement from \(message.ownerParticipantID)")
            return
        }
        #endif

        // Wait for OUR OWN anchorUpdates to resolve this UUID. We deliberately do not receive a
        // transform here — see the invariant at the top of this file.
        pendingSessionOriginID = message.anchorID
        print("📡 Adopted session origin \(message.anchorID) from \(source); awaiting local resolve")
    }
    #endif
    
    private func setupMultipeerSession() {
        multipeerSession = MultipeerConnectivityService()
        multipeerSession?.delegate = self
    }

/// Start hosting a collaborative session
    func startHosting() async {
        print("🤝 Starting host session on \(getCurrentPlatform())")
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
    }

    /// Join an existing collaborative session
    func joinSession() async {
        print("🤝 Joining session on \(getCurrentPlatform())")
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

    // NOTE: `broadcastCurrentSharedAnchor` / `currentSharedSpaceTransform` were deleted.
    // They transmitted the sender's head pose in the sender's private ARKit origin (or, far
    // more often, `matrix_identity_float4x4`, because their only source was the Enterprise-
    // gated `SharedCoordinateSpaceProvider` which cannot run without a managed entitlement).
    // Transmitting an anchor transform between visionOS devices is always wrong — see the
    // alignment invariant at the top of this file.

    #if os(iOS)
    /// Send ARCollaborationData to peers (iOS-only)
    func sendCollaborationData(_ data: Data, to peers: [MCPeerID]? = nil) {
        broadcast(.arCollaboration(data), to: peers)
        print("📡 Sent ARCollaborationData (\(data.count) bytes)")
    }
    #endif

    #if os(iOS)
    /// Broadcast a shared world anchor so iOS peers can align their content spaces.
    ///
    /// iOS-only by design: an iPhone cannot resolve a visionOS shared `WorldAnchor`, so the
    /// iOS lane keeps using this legacy `ARFrame`-camera-transform handshake. visionOS must
    /// never call this — see the alignment invariant at the top of this file.
    func sendSharedAnchor(_ anchor: SharedAnchorMessage, to peers: [MCPeerID]? = nil) {
        sharedAnchor = SharedWorldAnchor(id: anchor.anchorId,
                                         transform: anchor.matrix,
                                         confidence: anchor.confidence,
                                         timestamp: anchor.timestamp,
                                         worldMapData: anchor.worldMapData)
        sharedAnchorUsesSharedWorld = false
        broadcast(.anchor(anchor), to: peers)
    }
    #endif
    
    /// Stop the collaborative session on THIS device only.
    ///
    /// Deliberately does not broadcast `.sessionEnded`: this is a per-device button, and the
    /// receive handler for that message wipes every peer's diagrams. One participant leaving
    /// must not tear down everyone else's session.
    func stopSession() {
        print("🤝 Stopping collaborative session (this device only)")

        multipeerSession?.stop()
        
        // Don't pause the ARSession - let the ARView manage it
        // The AR camera should keep running for the main AR experience
        
        isSessionActive = false
        isHost = false
        connectedPeers.removeAll()
        availablePeers.removeAll()
        sessionState = "Not Connected"
        lastError = nil
        sharedAnchor = nil
        sharedAnchorUsesSharedWorld = false
#if canImport(GroupActivities)
        sharePlayCoordinator?.stop()
        isSharePlayActive = false
#endif
#if os(visionOS)
        stopSessionOriginLoop()
        sharedWorldAnchorManager.stop()
        clearSessionOrigin()
#endif
    }
    
    /// Share a diagram with all connected peers including position data
    func shareDiagram(filename: String, elements: [ElementDTO], is2D: Bool = false,
                      anchorRelativePosition: SIMD3<Float>? = nil,
                      anchorRelativeOrientation: simd_quatf? = nil, anchorRelativeScale: Float? = nil) {

#if os(iOS)
        // iOS is receive-only. Structured as #if/#else rather than an early `return` so the rest
        // of the body is not compiled-but-unreachable on iOS (which warned).
        print("ℹ️ Ignoring shareDiagram request on iOS client; iOS is receive-only")
#else

        // `anchorRelativePosition` / `anchorRelativeOrientation` already arrive in the shared session-origin frame
        // (see `ElementViewModel.getSharedTransform`), so there is nothing to convert here.
        //
        // This replaces a duplicated block that computed position via `anchor.transform.inverse`
        // but orientation via `simd_quatf(anchor.transform).inverse` — inconsistent with each
        // other, and both operating on a transform that was frequently the identity matrix or a
        // stale value restored from disk.
        let finalPosition = anchorRelativePosition
        let finalOrientation = anchorRelativeOrientation

        #if os(visionOS)
        // No origin anchor yet? Ask for a real shared WorldAnchor. Never fabricate one from a
        // head pose, and never broadcast a transform — see the invariant at the top of this file.
        if sessionOriginID == nil {
            Task { [weak self] in
                await self?.ensureSharedWorldAnchorInFrontOfUser()
            }
        }
        #endif

        let sharedDiagram = SharedDiagram(
            id: UUID(),
            filename: filename,
            elements: elements,
            timestamp: Date(),
            is2D: is2D,
            anchorRelativePosition: finalPosition,
            anchorRelativeOrientation: finalOrientation,
            anchorRelativeScale: anchorRelativeScale
        )

        sharedDiagrams.append(sharedDiagram)

        // Send to all peers
        broadcast(.diagram(sharedDiagram))

        print("📊 Shared diagram '\(filename)' with \(connectedPeers.count) peers")
        if let pos = finalPosition {
            print("   📍 Position: \(pos)")
        }
        if let orient = finalOrientation {
            print("   🔄 Orientation: \(orient)")
        }
        if let scale = anchorRelativeScale {
            print("   📏 Scale: \(scale)")
        }
#endif
    }

    func cacheLocalDiagramTransform(filename: String,
                                    position: SIMD3<Float>,
                                    orientation: simd_quatf,
                                    scale: Float) {
        localDiagramTransforms[filename] = DiagramTransform(position: position, orientation: orientation, scale: scale)
    }

    func cachedTransform(for filename: String) -> DiagramTransform? {
        localDiagramTransforms[filename]
    }

    /// Injects a local example back through the **production receive path** as if it had arrived
    /// from a peer, under the name `remote_<filename>`.
    ///
    /// This is the loopback harness: it makes "does a remote diagram render, with correct
    /// geometry and correct 2D-vs-3D handling?" answerable on a SINGLE device, with no peer, no
    /// FaceTime call and no transport. It exercises `handleSharedEnvelope` → `$sharedDiagrams` →
    /// the materialization handler → `ElementViewModel`, which is where the real bugs were.
    ///
    /// It deliberately does NOT test alignment — a loopback diagram lands at this device's own
    /// grid slot. Appearing and being aligned are separate claims, verified separately.
    func debugInjectRemoteDiagram(filename: String) {
        do {
            let output = try DiagramDataLoader.loadScriptOutput(from: filename)
            let injected = SharedDiagram(
                filename: "remote_\(filename)",
                elements: output.elements,
                is2D: output.is2D
            )
            print("🧪 Loopback: injecting '\(injected.filename)' (\(output.elements.count) elements, is2D=\(output.is2D))")
            handleSharedEnvelope(.diagram(injected), source: "loopback")
        } catch {
            lastError = "Loopback injection failed: \(error.localizedDescription)"
            print("❌ Loopback injection failed: \(error)")
        }
    }

    /// Whether a shared spatial origin is even achievable in this session.
    ///
    /// False when no participant can resolve a visionOS `WorldAnchor` — most importantly when the
    /// peer is the **iOS companion**, which aligns via its own legacy `SharedAnchorMessage`
    /// handshake instead. Callers must not block on the origin when this is false, or they wait
    /// forever: `worldAnchorSharingAvailability` only reports `.available` for a SharePlay session
    /// with nearby *visionOS* participants.
    var isAlignmentAchievable: Bool {
        #if os(visionOS)
        return isSpatialSession || worldAnchorSharingAvailable
        #else
        return false
        #endif
    }

    /// Whether participants are actually co-located, i.e. `localParticipantState.isSpatial`.
    /// Shared world anchors can only ever become available when this is true.
    var isSpatialSession: Bool {
        #if canImport(GroupActivities)
        return sharePlayCoordinator?.isSpatial ?? false
        #else
        return false
        #endif
    }
    
    /// Remove a diagram from sharing
    @MainActor
    func removeDiagram(filename: String) {
        // Exact match only. The previous bidirectional `hasPrefix` matching meant removing
        // "foo" also removed "foo_123" (and vice versa) on every peer.
        let before = sharedDiagrams.count
        sharedDiagrams.removeAll { $0.filename == filename }

        // 🔔 Force a Combine publish even if the array mutates in-place
        sharedDiagrams = sharedDiagrams

        // Broadcast to peers
        let removeMessage = RemoveDiagramMessage(filename: filename)
        broadcast(.remove(removeMessage))

        let after = sharedDiagrams.count
        print("🗑️ removeDiagram('\(filename)'): \(before - after) removed; now \(after) remaining")
    }
    
    /// Update the transform of an existing shared diagram
    func updateDiagramTransform(filename: String, anchorRelativePosition: SIMD3<Float>? = nil,
                                anchorRelativeOrientation: simd_quatf? = nil, anchorRelativeScale: Float? = nil) {
        // Update local copy
        guard let index = sharedDiagrams.firstIndex(where: { $0.filename == filename }) else {
            return
        }

        // Already in the shared session-origin frame — see shareDiagram(...) above.
        let finalPosition = anchorRelativePosition
        let finalOrientation = anchorRelativeOrientation

        if let pos = finalPosition {
            sharedDiagrams[index].anchorRelativePosition = pos
        }
        if let orient = finalOrientation {
            sharedDiagrams[index].anchorRelativeOrientation = orient
        }
        if let scale = anchorRelativeScale {
            sharedDiagrams[index].anchorRelativeScale = scale
        }

        if let pos = anchorRelativePosition, let orient = anchorRelativeOrientation, let scale = anchorRelativeScale {
            localDiagramTransforms[filename] = DiagramTransform(position: pos, orientation: orient, scale: scale)
        }

        // Send update to peers (fast path - no error checking needed during drag)
        let updateMessage = UpdateDiagramTransformMessage(
            filename: filename,
            anchorRelativePosition: finalPosition,
            anchorRelativeOrientation: finalOrientation,
            anchorRelativeScale: anchorRelativeScale
        )

        // Encode and broadcast (JSONEncoder is cached per thread by Swift)
        broadcast(.transform(updateMessage))

        // Remove expensive print during frequent updates
        // print("🔄 Updated and shared transform for diagram '\(filename)'")
    }

    // MARK: 2c — Public API to send per-element edits and update local state
    @MainActor
    func updateElementPosition(filename: String,
                               elementId: String,
                               localPosition: SIMD3<Float>) {
        // 1) Broadcast to all peers
        let payload = ElementPositionMessage(filename: filename,
                                             elementId: elementId,
                                             localPosition: localPosition)
        broadcast(.elementMoved(payload))

        // 2) Update our authoritative local model (rebuild diagram with edited elements)
        guard let dIndex = sharedDiagrams.firstIndex(where: { $0.filename == filename }) else {
            return
        }
        let old = sharedDiagrams[dIndex]

        // SharedDiagram.elements is 'let', so rebuild a new array then a new diagram
        var newElements = old.elements
        if let eIndex = newElements.firstIndex(where: { $0.id == elementId }) {
            var updated = newElements[eIndex]
            // Store local (container) coords as Doubles for consistency with other fields.
            updated.position = [Double(localPosition.x),
                                Double(localPosition.y),
                                Double(localPosition.z)]
            newElements[eIndex] = updated

            let newDiagram = SharedDiagram(
                id: old.id,
                filename: old.filename,
                elements: newElements,
                timestamp: Date(),                      // refresh timestamp on edit
                is2D: old.is2D,
                anchorRelativePosition: old.anchorRelativePosition,
                anchorRelativeOrientation: old.anchorRelativeOrientation,
                anchorRelativeScale: old.anchorRelativeScale
            )
            sharedDiagrams[dIndex] = newDiagram
            // 🔔 Force a publish
            sharedDiagrams = sharedDiagrams
        }
    }
    
    #if os(iOS)
        private func startARSession() async {
            // Don't create a new ARSession - the ARView already has one running
            // Just enable collaboration data sharing
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
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            print("❌ Failed to encode message: \(error.localizedDescription)")
            lastError = "Failed to encode message: \(error.localizedDescription)"
            noteEnvelopeSent(envelope.kind, bytes: 0, error: "encode: \(error.localizedDescription)")
            return
        }

        noteEnvelopeSent(envelope.kind, bytes: data.count)

        if let peers = peers {
            if !peers.isEmpty {
                multipeerSession?.sendData(data, to: peers)
            }
        } else if !connectedPeers.isEmpty {
            multipeerSession?.sendData(data, to: connectedPeers)
        }

        #if canImport(GroupActivities)
        if peers == nil {
            print("🔍 broadcast: Checking SharePlay (isActive=\(sharePlayCoordinator?.isActive ?? false))")
            if sharePlayCoordinator?.isActive == true {
                sendToSharePlay(data, kind: envelope.kind)
            }
        }
        #endif
    }

    private func resendStateToSharePlay() {
        #if canImport(GroupActivities)
            guard sharePlayCoordinator?.isActive == true else { return }
            // Deliberately does NOT resend the anchor. Serializing our local
            // `originFromAnchorTransform` overwrote the peer's own (different, correct) value
            // for the same physical anchor — the single most destructive line in the old code.
            for diagram in sharedDiagrams {
                if let data = try? JSONEncoder().encode(SharedSpaceEnvelope.diagram(diagram)) {
                    sendToSharePlay(data, kind: "diagram")
                }
            }
        #endif
    }

    #if canImport(GroupActivities)
        private func sendToSharePlay(_ data: Data, kind: String) {
            guard sharePlayCoordinator?.isActive == true else {
                print("⚠️ sendToSharePlay skipped: SharePlay not active (isActive=\(sharePlayCoordinator?.isActive ?? false))")
                return
            }
            print("📤 sendToSharePlay: Sending \(data.count) bytes via SharePlay")
            Task { [weak self] in
                guard let self else { return }
                if let error = await self.sharePlayCoordinator?.send(data) {
                    // Record it rather than only printing — a 1.3 MB diagram silently failing
                    // here is exactly the failure mode the HUD needs to make visible.
                    self.noteEnvelopeSent(kind, bytes: 0, error: error)
                }
            }
        }
    #endif

    // NOTE: anchor persistence (`persistSharedAnchor` / `restorePersistedAnchor` /
    // `clearPersistedAnchor` / `PersistedAnchor`) was deleted. Shared world anchors are never
    // persisted by ARKit — their lifetime is the SharePlay session — so a `shared_anchor.json`
    // reloaded at init could only ever seed a stale, wrong transform. It also kept
    // `ensureSharedWorldAnchorInFrontOfUser`'s `sharedAnchor == nil` guard permanently false,
    // meaning the real shared anchor was never created.
    //
    // `makeSharedAnchorMessage` was deleted with it: its only remaining callers serialized a
    // local ARKit transform onto the wire.

    @MainActor
    private func handleIncomingPayload(_ data: Data, source: String) {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(SharedSpaceEnvelope.self, from: data) {
            noteEnvelopeReceived(envelope.kind, bytes: data.count, source: source)
            handleSharedEnvelope(envelope, source: source)
            return
        }

        noteEnvelopeReceived("undecodable", bytes: data.count, source: source)
        print("❓ Received unknown data from \(source)")
    }
}

@MainActor
private extension CollaborativeSessionManager {
    func handleSharedEnvelope(_ envelope: SharedSpaceEnvelope, source: String) {
        switch envelope {
        case .anchor(let anchorMsg):
            #if os(iOS)
                // iOS lane only: an iPhone can't resolve a visionOS shared WorldAnchor, so it
                // still aligns off this legacy camera-transform handshake.
                sharedAnchor = SharedWorldAnchor(id: anchorMsg.anchorId,
                                                 transform: anchorMsg.matrix,
                                                 confidence: anchorMsg.confidence,
                                                 timestamp: anchorMsg.timestamp,
                                                 worldMapData: anchorMsg.worldMapData)
                sharedAnchorUsesSharedWorld = false
                onSharedAnchorReceived?(anchorMsg)
                print("📡 Received shared anchor '\(anchorMsg.anchorId)' from \(source)")
            #else
                // visionOS: IGNORE the transform. Applying a peer's
                // `originFromAnchorTransform` overwrites our own correct value for the same
                // physical anchor and resets `sharedAnchorUsesSharedWorld`, which is what
                // scattered the diagrams. Our transform comes only from our own ARKit
                // `anchorUpdates`.
                print("ℹ️ Ignoring inbound anchor transform '\(anchorMsg.anchorId)' from \(source) (visionOS resolves shared anchors locally)")
            #endif

        case .sessionOrigin(let message):
            #if os(visionOS)
                handleSessionOriginAnnouncement(message, source: source)
            #else
                print("ℹ️ Ignoring session-origin announcement on non-visionOS platform")
            #endif

        case .diagram(let sharedDiagram):
            if !sharedDiagrams.contains(where: { $0.id == sharedDiagram.id }) {
                sharedDiagrams.append(sharedDiagram)
                print("📥 Received shared diagram '\(sharedDiagram.filename)' from \(source)")
                if let pos = sharedDiagram.anchorRelativePosition {
                    print("   📍 Position: \(pos)")
                }
            } else if let index = sharedDiagrams.firstIndex(where: { $0.id == sharedDiagram.id }) {
                sharedDiagrams[index] = sharedDiagram
                sharedDiagrams = sharedDiagrams
            }

        case .transform(let updateMessage):
            if let index = sharedDiagrams.firstIndex(where: { $0.filename == updateMessage.filename }) {
                if let pos = updateMessage.anchorRelativePosition {
                    sharedDiagrams[index].anchorRelativePosition = pos
                }
                if let orient = updateMessage.anchorRelativeOrientation {
                    sharedDiagrams[index].anchorRelativeOrientation = orient
                }
                if let scale = updateMessage.anchorRelativeScale {
                    sharedDiagrams[index].anchorRelativeScale = scale
                }
                print("🔄 Updated transform for diagram '\(updateMessage.filename)' from \(source)")
                sharedDiagrams = sharedDiagrams
            }

        case .remove(let removeMessage):
            let target = removeMessage.filename
            let before = sharedDiagrams.count
            // Exact match only — see removeDiagram(filename:).
            sharedDiagrams.removeAll { $0.filename == target }
            // 🔔 Force a Combine publish so all subscribers refresh
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
                        is2D: old.is2D,
                        anchorRelativePosition: old.anchorRelativePosition,
                        anchorRelativeOrientation: old.anchorRelativeOrientation,
                        anchorRelativeScale: old.anchorRelativeScale
                    )
                    sharedDiagrams[dIndex] = newDiagram
                    // 🔔 Force a Combine publish so all subscribers refresh
                    sharedDiagrams = sharedDiagrams
                    print("✏️ Element '\(p.elementId)' moved in '\(p.filename)' from \(source)")
                } else {
                    print("⚠️ Received elementMoved for unknown element '\(p.elementId)' in '\(p.filename)'")
                }
            } else {
                print("⚠️ Received elementMoved for unknown diagram '\(p.filename)'")
            }
            
        case .sessionEnded(let info):
            // Clear all shared state so AR views will remove content
            sharedDiagrams.removeAll()
            sharedDiagrams = sharedDiagrams // force Combine publish
            sharedAnchor = nil
            sharedAnchorUsesSharedWorld = false
            isSessionActive = false
            sessionState = "Session ended by \(info.byHost)"
            // 🛎️ surface a UI pop-up
            pendingAlert = SessionAlert(
                title: "Session Ended",
                message: "The host (\(info.byHost)) ended the session. All shared diagrams were removed."
            )
            print("🛑 Session ended by \(info.byHost) from \(source)")

        case .participantLeft(let left):
            // Keep session, just inform UI
            pendingAlert = SessionAlert(title: "Participant Left",
                                        message: "\(left.peerName) left the session.")
            print("👋 Participant left: \(left.peerName) from \(source)")
            
        }
    }
}

// MARK: - MultipeerConnectivityDelegate
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
                broadcast(.diagram(diagram), to: [peer])
                print("📤 Sent shared diagram '\(diagram.filename)' to new peer")
            }

            // Deliberately no anchor resend here. On visionOS `sharedAnchor` holds our own
            // local `originFromAnchorTransform`, and putting that on the wire is precisely the
            // invariant violation documented at the top of this file. iOS peers produce their
            // own anchor from their ARFrame and broadcast it themselves.

        case .connecting:
            sessionState = "Connecting to \(peer.displayName)..."
            print("🔄 Connecting to \(peer.displayName)")
            
        case .notConnected:
            connectedPeers.removeAll { $0 == peer }
            
            let msg = ParticipantLeftMessage(peerName: peer.displayName, at: Date())
            broadcast(.participantLeft(msg))
            // Optional: local pop-up too
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

// MARK: - Supporting Types
struct SharedDiagram: Codable, Identifiable {
    let id: UUID
    let filename: String
    let elements: [ElementDTO]
    let timestamp: Date
    /// Whether this is a 2D (RT/RS) diagram. Transmitted because it changes rendering
    /// substantially — Y sign, handle/close-button Z offsets, per-element input targets and
    /// wall-vs-floor snapping all depend on it. Without it the receiver rebuilt every 2D diagram
    /// as 3D, so the two devices looked different even with perfect anchoring.
    var is2D: Bool = false
    // MARK: Pose
    //
    // The diagram's pose **relative to the shared session-origin anchor** (`SharedWorldRoot`),
    // never world space. Producers use `ElementViewModel.getSharedTransform()`
    // (`position(relativeTo: worldRoot)`); consumers apply them with
    // `setPosition(_, relativeTo: worldRoot)`. A world-space value must never be put here — world
    // coordinates are private to a device and are not comparable across participants.
    //
    // Scale is frame-independent (`worldRoot` is rigid and unit-scale, asserted in
    // `SharedWorldRoot.apply`); it carries the `anchorRelative` prefix only so the three pose
    // fields read as one group, not to imply a second scale exists in another frame.
    //
    // The JSON keys are still `worldPositionX`, `worldOrientationW`, `worldScale` and so on — see
    // `CodingKeys` below. They were deliberately left alone so the wire format is unchanged for
    // the iOS lane and any build that predates this rename.
    var anchorRelativePosition: SIMD3<Float>?
    var anchorRelativeOrientation: simd_quatf?
    var anchorRelativeScale: Float?

    // Encode/decode helpers for SIMD types
    enum CodingKeys: String, CodingKey {
        case id, filename, elements, timestamp, is2D
        case worldPositionX, worldPositionY, worldPositionZ
        case worldOrientationX, worldOrientationY, worldOrientationZ, worldOrientationW
        case worldScale
    }

    init(id: UUID = UUID(), filename: String, elements: [ElementDTO], timestamp: Date = Date(),
         is2D: Bool = false,
         anchorRelativePosition: SIMD3<Float>? = nil, anchorRelativeOrientation: simd_quatf? = nil, anchorRelativeScale: Float? = nil) {
        self.id = id
        self.filename = filename
        self.elements = elements
        self.timestamp = timestamp
        self.is2D = is2D
        self.anchorRelativePosition = anchorRelativePosition
        self.anchorRelativeOrientation = anchorRelativeOrientation
        self.anchorRelativeScale = anchorRelativeScale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        filename = try container.decode(String.self, forKey: .filename)
        elements = try container.decode([ElementDTO].self, forKey: .elements)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        // decodeIfPresent keeps the wire format compatible with iOS and older builds.
        is2D = try container.decodeIfPresent(Bool.self, forKey: .is2D) ?? false

        // Decode world position if present
        if let x = try container.decodeIfPresent(Float.self, forKey: .worldPositionX),
           let y = try container.decodeIfPresent(Float.self, forKey: .worldPositionY),
           let z = try container.decodeIfPresent(Float.self, forKey: .worldPositionZ) {
            anchorRelativePosition = SIMD3<Float>(x, y, z)
        }
        
        // Decode world orientation if present
        if let x = try container.decodeIfPresent(Float.self, forKey: .worldOrientationX),
           let y = try container.decodeIfPresent(Float.self, forKey: .worldOrientationY),
           let z = try container.decodeIfPresent(Float.self, forKey: .worldOrientationZ),
           let w = try container.decodeIfPresent(Float.self, forKey: .worldOrientationW) {
            anchorRelativeOrientation = simd_quatf(ix: x, iy: y, iz: z, r: w)
        }
        
        anchorRelativeScale = try container.decodeIfPresent(Float.self, forKey: .worldScale)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(filename, forKey: .filename)
        try container.encode(elements, forKey: .elements)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(is2D, forKey: .is2D)

        // Encode world position if present
        if let pos = anchorRelativePosition {
            try container.encode(pos.x, forKey: .worldPositionX)
            try container.encode(pos.y, forKey: .worldPositionY)
            try container.encode(pos.z, forKey: .worldPositionZ)
        }
        
        // Encode world orientation if present
        if let orient = anchorRelativeOrientation {
            try container.encode(orient.imag.x, forKey: .worldOrientationX)
            try container.encode(orient.imag.y, forKey: .worldOrientationY)
            try container.encode(orient.imag.z, forKey: .worldOrientationZ)
            try container.encode(orient.real, forKey: .worldOrientationW)
        }
        
        if let scale = anchorRelativeScale {
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

/// Announces which shared `WorldAnchor` is the session origin.
///
/// ⚠️ INVARIANT: this message carries a **UUID only**. Do not add a transform field to it, and do
/// not add one to any message on the visionOS↔visionOS path. Each device's
/// `originFromAnchorTransform` for the same physical anchor is expressed in that device's own
/// private ARKit origin, so it is already correct locally and meaningless remotely. Transmitting
/// it overwrites a correct value with a foreign one — that was the root cause of diagrams
/// appearing scattered and unaligned.
struct SessionOriginMessage: Codable {
    let anchorID: UUID
    /// Participant that created the anchor. Used purely as a deterministic tie-break when two
    /// devices race to create an origin.
    let ownerParticipantID: UUID
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
    /// visionOS session-origin announcement: anchor UUID only, never a transform.
    case sessionOrigin(SessionOriginMessage)
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

    /// Stable label for diagnostics counters.
    var kind: String {
        switch self {
        case .anchor: return "anchor"
        case .sessionOrigin: return "sessionOrigin"
        case .diagram: return "diagram"
        case .transform: return "transform"
        case .remove: return "remove"
        case .arCollaboration: return "arCollaboration"
        case .elementMoved: return "elementMoved"
        case .sessionEnded: return "sessionEnded"
        case .participantLeft: return "participantLeft"
        }
    }

    private enum EnvelopeType: String, Codable {
        case anchor
        case sessionOrigin
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
        case .sessionOrigin(let message):
            try container.encode(EnvelopeType.sessionOrigin, forKey: .type)
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
        case .sessionOrigin:
            let msg = try container.decode(SessionOriginMessage.self, forKey: .payload)
            self = .sessionOrigin(msg)
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

struct RemoveDiagramMessage: Codable {
    let filename: String
}

struct UpdateDiagramTransformMessage: Codable {
    let filename: String
    // Anchor-relative, like `SharedDiagram`'s pose fields. JSON keys remain `world*` for wire
    // compatibility — see `CodingKeys` below.
    var anchorRelativePosition: SIMD3<Float>?
    var anchorRelativeOrientation: simd_quatf?
    var anchorRelativeScale: Float?
    
    // Encode/decode helpers for SIMD types
    enum CodingKeys: String, CodingKey {
        case filename
        case worldPositionX, worldPositionY, worldPositionZ
        case worldOrientationX, worldOrientationY, worldOrientationZ, worldOrientationW
        case worldScale
    }
    
    init(filename: String, anchorRelativePosition: SIMD3<Float>? = nil,
         anchorRelativeOrientation: simd_quatf? = nil, anchorRelativeScale: Float? = nil) {
        self.filename = filename
        self.anchorRelativePosition = anchorRelativePosition
        self.anchorRelativeOrientation = anchorRelativeOrientation
        self.anchorRelativeScale = anchorRelativeScale
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decode(String.self, forKey: .filename)
        
        // Decode world position if present
        if let x = try container.decodeIfPresent(Float.self, forKey: .worldPositionX),
           let y = try container.decodeIfPresent(Float.self, forKey: .worldPositionY),
           let z = try container.decodeIfPresent(Float.self, forKey: .worldPositionZ) {
            anchorRelativePosition = SIMD3<Float>(x, y, z)
        }
        
        // Decode world orientation if present
        if let x = try container.decodeIfPresent(Float.self, forKey: .worldOrientationX),
           let y = try container.decodeIfPresent(Float.self, forKey: .worldOrientationY),
           let z = try container.decodeIfPresent(Float.self, forKey: .worldOrientationZ),
           let w = try container.decodeIfPresent(Float.self, forKey: .worldOrientationW) {
            anchorRelativeOrientation = simd_quatf(ix: x, iy: y, iz: z, r: w)
        }
        
        anchorRelativeScale = try container.decodeIfPresent(Float.self, forKey: .worldScale)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filename, forKey: .filename)
        
        // Encode world position if present
        if let pos = anchorRelativePosition {
            try container.encode(pos.x, forKey: .worldPositionX)
            try container.encode(pos.y, forKey: .worldPositionY)
            try container.encode(pos.z, forKey: .worldPositionZ)
        }
        
        // Encode world orientation if present
        if let orient = anchorRelativeOrientation {
            try container.encode(orient.imag.x, forKey: .worldOrientationX)
            try container.encode(orient.imag.y, forKey: .worldOrientationY)
            try container.encode(orient.imag.z, forKey: .worldOrientationZ)
            try container.encode(orient.real, forKey: .worldOrientationW)
        }
        
        if let scale = anchorRelativeScale {
            try container.encode(scale, forKey: .worldScale)
        }
    }
}

/// Lightweight per-element position update (container-local coordinates)
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
import GroupActivities

/// Participant info for tracking nearby users
struct ParticipantInfo: Identifiable, Equatable {
    let id: UUID
    let isLocal: Bool
    let isNearby: Bool
    var pose: simd_float4x4?

    static func == (lhs: ParticipantInfo, rhs: ParticipantInfo) -> Bool {
        lhs.id == rhs.id && lhs.isNearby == rhs.isNearby
    }
}

@MainActor
final class SharePlayCoordinator: ObservableObject {
    // MARK: - Callbacks
    var onDataReceived: ((Data) -> Void)?
    var onSessionJoined: (() -> Void)?
    var onSessionEnded: (() -> Void)?
    var onParticipantsChanged: ((Int) -> Void)?
    var onNearbyParticipantsChanged: (([ParticipantInfo]) -> Void)?

    // MARK: - Published State
    @Published private(set) var nearbyParticipants: [ParticipantInfo] = []
    @Published private(set) var totalParticipantCount: Int = 0
    @Published private(set) var isHost: Bool = false
    @Published private(set) var localParticipantPose: simd_float4x4?

    // MARK: - Diagnostics mirrors
    // `currentSession` stays private, so the HUD reads these instead.

    /// Textual `GroupSession.State` for the HUD ("none" / "waiting" / "joined" / "invalidated").
    @Published private(set) var sessionStateDescription: String = "none"
    /// This device's participant id.
    @Published private(set) var localParticipantID: UUID?
    /// All active participant ids, **sorted by uuidString**. This ordering is the input to
    /// session-origin owner election, replacing `activeParticipants.first` on an unordered Set
    /// (which made the host role a coin flip that could differ per device and flip mid-session).
    @Published private(set) var participantIDs: [UUID] = []
    /// Ids of participants that are physically nearby (co-located).
    @Published private(set) var nearbyParticipantIDs: Set<UUID> = []
    /// `SystemCoordinator.localParticipantState.isSpatial` — the best "are we actually in the
    /// same room" signal. Shared world anchors can never become available when this is false.
    @Published private(set) var isSpatial: Bool = false

    // MARK: - Public Properties
    var isActive: Bool { currentSession != nil }
    var hasNearbyParticipants: Bool { !nearbyParticipants.isEmpty }

    // MARK: - Private Properties
    private var currentSession: GroupSession<SharedSpaceActivity>?
    private var messenger: GroupSessionMessenger?
    #if os(visionOS)
    private var systemCoordinator: SystemCoordinator?
    #endif

    private var messageTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var participantsTask: Task<Void, Never>?
    private var localParticipantTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        listenerTask = Task { [weak self] in
            await self?.listenForSessions()
        }
    }

    deinit {
        listenerTask?.cancel()
    }

    // MARK: - Public API

    func start() async {
        let activity = SharedSpaceActivity()
        let result = await activity.prepareForActivation()

        switch result {
        case .activationPreferred:
            do {
                _ = try await activity.activate()
                print("✅ SharePlay activated")
            } catch {
                print("❌ SharePlay activation failed: \(error.localizedDescription)")
            }
        case .activationDisabled:
            print("⚠️ SharePlay disabled (not in FaceTime?)")
        case .cancelled:
            print("ℹ️ SharePlay cancelled")
        @unknown default:
            break
        }
    }

    func stop() {
        messageTask?.cancel()
        stateTask?.cancel()
        participantsTask?.cancel()
        localParticipantTask?.cancel()

        messageTask = nil
        stateTask = nil
        participantsTask = nil
        localParticipantTask = nil

        messenger = nil
        #if os(visionOS)
        systemCoordinator = nil
        #endif

        // leave() only — never end(). end() terminates the activity for EVERY participant,
        // so one person pressing Stop killed the whole session.
        currentSession?.leave()
        currentSession = nil

        nearbyParticipants.removeAll()
        totalParticipantCount = 0
        isHost = false
        localParticipantPose = nil

        sessionStateDescription = "none"
        localParticipantID = nil
        participantIDs = []
        nearbyParticipantIDs = []
        isSpatial = false

        onSessionEnded?()
        print("🛑 SharePlay session stopped")
    }

    /// Sends over the group session. Returns `nil` on success, or a description of the failure.
    ///
    /// Returning the error instead of only printing it is what lets the diagnostics HUD show
    /// *why* a large `.diagram` payload never arrived.
    @discardableResult
    func send(_ data: Data) async -> String? {
        guard let messenger else {
            print("❌ SharePlay send failed: messenger is nil")
            return "messenger is nil"
        }
        do {
            try await messenger.send(data)
            print("✅ SharePlay message sent successfully (\(data.count) bytes)")
            return nil
        } catch {
            print("❌ SharePlay send failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }


    // MARK: - Private Methods

    private func listenForSessions() async {
        for await session in SharedSpaceActivity.sessions() {
            await configureSession(session)
        }
    }

    private func configureSession(_ session: GroupSession<SharedSpaceActivity>) async {
        // Clean up previous session. leave() only — end() would terminate the previous
        // activity for everyone, including the peer who just invited us.
        currentSession?.leave()

        currentSession = session
        messenger = GroupSessionMessenger(session: session)

        // Configure SystemCoordinator for visionOS 26+
        #if os(visionOS)
        if let coordinator = await session.systemCoordinator {
            self.systemCoordinator = coordinator
            var config = SystemCoordinator.Configuration()
            config.supportsGroupImmersiveSpace = true
            config.spatialTemplatePreference = .sideBySide
            coordinator.configuration = config

            localParticipantTask?.cancel()
            localParticipantTask = Task { [weak self] in
                await self?.observeLocalParticipantState(coordinator: coordinator)
            }
        }
        #endif

        // Message receiving task
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            guard let messenger = self?.messenger else { return }
            print("📡 SharePlay: Started listening for messages")
            for await (data, _) in messenger.messages(of: Data.self) {
                print("📥 SharePlay: Received message (\(data.count) bytes)")
                await MainActor.run { [weak self] in
                    self?.onDataReceived?(data)
                }
            }
            print("📡 SharePlay: Message listener ended")
        }

        // Session state monitoring.
        //
        // `onSessionJoined` fires from HERE, not straight after `session.join()`. Previously it
        // was invoked synchronously on the line after join(), so the initial state push ran
        // against a session that had not reached `.joined` yet and every message was silently
        // dropped.
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            for await state in session.$state.values {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    switch state {
                    case .waiting:
                        self.sessionStateDescription = "waiting"
                    case .joined:
                        self.sessionStateDescription = "joined"
                        self.onSessionJoined?()
                    case .invalidated(let reason):
                        self.sessionStateDescription = "invalidated (\(reason.localizedDescription))"
                        self.messenger = nil
                        self.currentSession = nil
                        #if os(visionOS)
                        self.systemCoordinator = nil
                        #endif
                        self.onSessionEnded?()
                    @unknown default:
                        self.sessionStateDescription = "unknown"
                    }
                }
                if case .invalidated = state { break }
            }
        }

        // Participant monitoring
        participantsTask?.cancel()
        participantsTask = Task { [weak self] in
            for await participants in session.$activeParticipants.values {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.totalParticipantCount = participants.count
                    let local = session.localParticipant
                    self.localParticipantID = local.id

                    // Deterministic, convergent ordering. `activeParticipants` is an unordered
                    // Set, so `.first` gave a different answer on each device.
                    self.participantIDs = participants
                        .map(\.id)
                        .sorted { $0.uuidString < $1.uuidString }

                    // Retained only for legacy Multipeer/UI use. NOTHING about spatial
                    // alignment may depend on a host role — see `isSessionOriginOwner`.
                    self.isHost = self.participantIDs.first == local.id

                    var nearbyInfos: [ParticipantInfo] = []
                    var nearbyIDs: Set<UUID> = []
                    for participant in participants {
                        let isLocal = participant == session.localParticipant
                        let info = ParticipantInfo(
                            id: participant.id,
                            isLocal: isLocal,
                            isNearby: participant.isNearbyWithLocalParticipant
                        )
                        if info.isNearby && !isLocal {
                            nearbyInfos.append(info)
                            nearbyIDs.insert(participant.id)
                        }
                    }
                    self.nearbyParticipants = nearbyInfos
                    self.nearbyParticipantIDs = nearbyIDs
                    self.onParticipantsChanged?(participants.count)
                    self.onNearbyParticipantsChanged?(nearbyInfos)
                }
            }
        }

        session.join()
    }

    #if os(visionOS)
    private func observeLocalParticipantState(coordinator: SystemCoordinator) async {
        for await localState in coordinator.localParticipantStates {
            await MainActor.run { [weak self] in
                guard let self else { return }
                // `isSpatial` distinguishes "SharePlay over FaceTime from another room" (where
                // shared world anchors can never become available) from genuine co-location.
                self.isSpatial = localState.isSpatial
                if let pose = localState.pose {
                    // Convert Pose3D to simd_float4x4
                    let matrix = simd_float4x4(pose)
                    self.localParticipantPose = matrix
                }
            }
        }
    }
    #endif
}

// MARK: - SharedSpaceActivity

struct SharedSpaceActivity: GroupActivity {
    static var activityIdentifier: String { "org.riquelme.avar2.sharedspace" }

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "AVAR2 Shared Space"
        metadata.subtitle = "Collaborate on diagrams in AR"
        metadata.type = .generic
        metadata.supportsContinuationOnTV = false
        return metadata
    }
}
#endif

// NOTE: AVAR2's own `CollaborationData` class was removed — it wrapped an `ARWorldMap` that was
// never populated or read, and its only reference was a property assigned once and never used.
// The live iOS collaboration path uses Apple's `ARSession.CollaborationData` via
// `sendCollaborationData(_:)` / `onCollaborationDataReceived`, which are unaffected.
