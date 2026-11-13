import Foundation
import RealityKit
import MultipeerConnectivity
import Combine
import CoreTransferable
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
/// ## The shared frame
///
/// Diagram poses cross the wire as plain RealityKit **scene coordinates**. The SharePlay session
/// is configured with `supportsGroupImmersiveSpace`, so the system gives every spatial
/// participant — a nearby Vision Pro or a FaceTime spatial Persona — one shared immersive-space
/// frame in which identical transforms land in the same place. No ARKit value is involved in
/// placing a diagram. See `currentPoseAnchorID` for the single seam.
///
/// ## The room anchor (diagnostic only)
///
/// A shared `WorldAnchor` is still created between nearby headsets, and the realignment
/// handshake still runs, but nothing they produce reaches content. They are instruments for
/// `FrameDiagnostics`, which measures whether raw ARKit transforms are valid scene transforms
/// while sharing.
///
/// One rule about that anchor still holds: **its `originFromAnchorTransform` must never be
/// transmitted between visionOS devices — only its UUID.** Each device resolves the transform
/// from its own `WorldTrackingProvider.anchorUpdates`; a peer's value is in the peer's frame.
/// Shared anchors are never persisted (ARKit: lifetime == the SharePlay session), so creating
/// one per session is the normal path.
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
        let anchorID: UUID?
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
    // Current active diagrams that should be shared
    @Published var sharedDiagrams: [SharedDiagram] = []
    let receivedDiagramRemoval = PassthroughSubject<String, Never>()
    let receivedDiagramTransform = PassthroughSubject<SharedDiagram, Never>()
    private var closedDiagramIDs: Set<UUID> = []
    private var locallySharedDiagramIDs: Set<UUID> = []
    #if os(visionOS)
    private var sharePlayReceivedDiagramIDs: Set<UUID> = []
    #endif
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
        if let error {
            stat.lastError = error
        } else {
            stat.sent += 1
            stat.bytesSent += bytes
        }
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

    /// Set when a peer sends a pose relative to a room anchor, which only builds before the
    /// shared-space frame do. Those poses are not scene coordinates, so that peer's diagrams land
    /// in the wrong place here — and this build's diagrams never appear there. Surfaced in the
    /// status so a mixed-build session is recognised instead of debugged.
    @Published private(set) var peerUsesAnchorFrame = false
    private var coordinatorObservation: AnyCancellable?

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

    /// The participant responsible for the current session origin.
    private var sessionOriginOwnerID: UUID?
    private var isCreatingSessionOrigin = false
    private var originGeneration = UUID()
    /// The anchor this device created, if it won the election. Used to drop ours on tie-break.
    private var ownedAnchorID: UUID?
    private var sessionOriginTask: Task<Void, Never>?
    @Published private(set) var isRealigning = false
    @Published private(set) var realignmentStatus: String?
    private var realignment: SpaceRealignment?
    private var realignmentTask: Task<Void, Never>?
    private var realignmentTimeout: Task<Void, Never>?
    private var replacementAnchorID: UUID?
    private var supersededAnchorID: UUID?
    private var retiredOriginIDs: Set<UUID> = []

    var canRealign: Bool {
        isSharePlayActive && sharePlayCoordinator?.nearbyParticipantIDs.count == 1
    }

    /// True when this device should create the session-origin anchor.
    /// Election logic lives in `SessionOriginElection` so it can be tested exhaustively.
    var isSessionOriginOwner: Bool {
        #if canImport(GroupActivities)
        guard let coordinator = sharePlayCoordinator else { return false }
        guard let localID = coordinator.localParticipantID else { return false }
        return localID == electedOriginOwnerID
        #else
        return false
        #endif
    }

    /// The elected owner, for diagnostics. Both devices must display the same value.
    var electedOriginOwnerID: UUID? {
        #if canImport(GroupActivities)
        guard let coordinator = sharePlayCoordinator, let local = coordinator.localParticipantID,
              !coordinator.nearbyParticipantIDs.isEmpty else { return nil }
        return sessionOriginOwnerID ?? SessionOriginElection.owner(
            participantIDs: Array(coordinator.nearbyParticipantIDs.union([local]))
        )
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
        coordinator.onDataReceived = { [weak self] data, senderID in
            self?.handleIncomingPayload(data, source: "SharePlay", senderID: senderID)
        }
        coordinator.onSessionJoined = { [weak self] in
            guard let self else { return }
            let sessionID = coordinator.sessionID
            Task { @MainActor in
                guard coordinator.sessionID == sessionID, coordinator.isActive else { return }
                print("✅ SharePlay session joined, isHost=\(coordinator.isHost)")
                self.sharePlayStartError = nil
                self.isSharePlayActive = true
                self.isSessionActive = true
                self.sessionState = "SharePlay active"
                self.isHost = coordinator.isHost

                #if os(visionOS)
                self.startSessionOriginLoop()
                #endif

                self.resendStateToSharePlay()
            }
        }
        coordinator.onSessionEnded = { [weak self] in
            guard let self else { return }
            print("🛑 SharePlay session ended")
            self.isSharePlayActive = false
            self.sharePlaySendTask?.cancel()
            self.sharePlaySendTask = nil
            self.sharePlayParticipantCount = 0
            self.nearbyParticipantCount = 0
            self.hasNearbyParticipants = false

            #if os(visionOS)
            self.finishRealignment(nil)
            self.retiredOriginIDs.removeAll()
            self.peerUsesAnchorFrame = false
            self.stopSessionOriginLoop()
            self.sharedWorldAnchorManager.stop()
            self.worldAnchorSharingAvailable = false
            self.discardSharePlayDiagrams()
            // Shared anchors die with the SharePlay session by design (ARKit: lifetime is
            // the session), so clearing here is the normal path, not an error path.
            self.clearSessionOrigin()
            #endif

            self.isSessionActive = self.companionMode != .idle
            self.sessionState = self.isSessionActive ? "iPhone companion active" : "Not Connected"
        }
        coordinator.onParticipantsChanged = { [weak self] (count: Int) in
            guard let self else { return }
            Task { @MainActor in
                self.sharePlayParticipantCount = count
                let noun = count == 1 ? "participant" : "participants"
                self.sessionState = "SharePlay: \(count) \(noun)"
                self.isHost = coordinator.isHost

                if count > 1 {
                    self.resendStateToSharePlay()
                }
            }
        }
        coordinator.onNearbyParticipantsChanged = { [weak self] participants in
            guard let self else { return }
            Task { @MainActor in
                self.nearbyParticipantCount = participants.count
                self.hasNearbyParticipants = !participants.isEmpty
                #if os(visionOS)
                if self.isRealigning && participants.count != 1 {
                    self.finishRealignment("The nearby SharePlay participants changed. Try again once both headsets are connected.")
                }
                #endif
                if !participants.isEmpty {
                    self.sessionState = "SharePlay: \(participants.count) nearby"
                }
            }
        }
        sharePlayCoordinator = coordinator
        // `sharedSpaceStatus` reads the coordinator, but the launcher and the immersive HUD
        // observe only this manager. Without this, a session that becomes spatial after joining
        // (FaceTime, where nothing else republishes) would keep showing "not spatial".
        coordinatorObservation = coordinator.$isSpatial.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        #endif
    }

    // MARK: - visionOS 26+ Shared World Anchors

    #if os(visionOS)
    private func startSharedWorldAnchorManager() async {
        let manager = sharedWorldAnchorManager

        manager.onAnchorUpdated = { [weak self] anchor in
            self?.resolveSessionOrigin(anchor)
            self?.confirmRealignmentAnchor(anchor)
        }
        manager.onAnchorRemoved = { [weak self] anchorID in
            guard let self, anchorID == self.sessionOriginID else { return }
            if self.isRealigning {
                self.sessionOriginIsTracked = false
                if self.ownedAnchorID == anchorID { self.ownedAnchorID = nil }
            } else {
                self.clearSessionOrigin()
            }
        }
        manager.onSharingAvailabilityChanged = { [weak self] available in
            self?.worldAnchorSharingAvailable = available
        }

        await manager.start()
        if let error = manager.lastError { anchorCreationFailure = error }
    }

    private func resolveSessionOrigin(_ anchor: WorldAnchor) {
        guard anchor.id == sessionOriginID else { return }
        if sessionOriginIsTracked != anchor.isTracked {
            sessionOriginIsTracked = anchor.isTracked
        }
        guard anchor.isTracked else { return }

        // Use the transform from this device's ARKit, whether the update arrived before or
        // after the SharePlay announcement. Repeated identical updates need no scene work.
        let transform = anchor.originFromAnchorTransform
        if sessionOriginTransform != transform {
            sessionOriginTransform = transform
        }
        if sharedAnchor?.id != anchor.id.uuidString {
            sharedAnchor = SharedWorldAnchor(id: anchor.id.uuidString,
                                             transform: transform,
                                             confidence: 1.0,
                                             timestamp: Date(),
                                             worldMapData: nil)
            sharedAnchorUsesSharedWorld = true
        }
        anchorCreationFailure = nil
    }

    /// All creation paths share the same guard because adding an ARKit anchor suspends.
    func ensureSharedWorldAnchorInFrontOfUser(distance: Float = 1.5) async {
        guard isSharePlayActive, worldAnchorSharingAvailable,
              sessionOriginID == nil, !isCreatingSessionOrigin, !isRealigning,
              let ownerID = electedOriginOwnerID, isSessionOriginOwner else { return }
        let generation = originGeneration
        isCreatingSessionOrigin = true
        defer {
            if generation == originGeneration { isCreatingSessionOrigin = false }
        }
        do {
            let anchor = try await sharedWorldAnchorManager.createSharedAnchorInFrontOfUser(distance: distance)
            guard generation == originGeneration, isSharePlayActive,
                  isSessionOriginOwner, sessionOriginID == nil, !isRealigning else {
                try? await sharedWorldAnchorManager.removeAnchor(anchor.id)
                return
            }
            ownedAnchorID = anchor.id
            sessionOriginOwnerID = ownerID
            sessionOriginID = anchor.id
            anchorCreationFailure = nil
            if let tracked = sharedWorldAnchorManager.sharedAnchors[anchor.id] {
                resolveSessionOrigin(tracked)
            }
            announceSessionOrigin(anchor.id)
        } catch {
            guard generation == originGeneration else { return }
            anchorCreationFailure = error.localizedDescription
        }
    }

    // Use the same election on both devices even if they disagree about the current anchor.
    private var realignmentCoordinatorID: UUID? {
        guard let coordinator = sharePlayCoordinator, let local = coordinator.localParticipantID else { return nil }
        return SessionOriginElection.owner(participantIDs: Array(coordinator.nearbyParticipantIDs.union([local])))
    }

    private var coordinatesRealignment: Bool {
        guard let local = sharePlayCoordinator?.localParticipantID else { return false }
        return local == realignmentCoordinatorID
    }

    func requestRealignment(replaceAnchor: Bool = false) {
        guard canRealign, !isRealigning, !isCreatingSessionOrigin, let owner = realignmentCoordinatorID else { return }
        let request = SpaceRealignment(id: UUID(), phase: .request, anchorID: nil,
                                       replaceAnchor: replaceAnchor)
        if coordinatesRealignment {
            // Same rule as the inbound `.request` path, so the local and remote entry points
            // cannot drift apart.
            let probe = request.changing(to: .probe,
                                         anchorID: RealignmentProtocol.probeAnchor(for: request,
                                                                                   context: realignmentContext))
            startRealignment(probe)
            sendRealignment(probe)
        } else {
            startRealignment(request)
            sendRealignment(request, to: owner)
        }
    }

    private func startRealignment(_ message: SpaceRealignment) {
        realignment = message
        isRealigning = true
        realignmentStatus = "Checking alignment with the other Vision Pro…"
        realignmentTimeout?.cancel()
        realignmentTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.realignment?.id == message.id else { return }
            if self.coordinatesRealignment {
                self.sendRealignment(message.changing(to: .failed))
            }
            self.finishRealignment("The other Vision Pro didn’t confirm alignment. Try again with both visors in the same room.")
        }
    }

    private func finishRealignment(_ status: String?, confirmed: Bool = false) {
        realignmentTimeout?.cancel()
        realignmentTimeout = nil
        realignmentTask?.cancel()
        realignmentTask = nil
        if let candidate = replacementAnchorID, candidate != ownedAnchorID {
            Task { try? await sharedWorldAnchorManager.removeAnchor(candidate) }
        }
        if confirmed, let supersededAnchorID {
            Task { try? await sharedWorldAnchorManager.removeAnchor(supersededAnchorID) }
        }
        supersededAnchorID = nil
        replacementAnchorID = nil
        realignment = nil
        isRealigning = false
        realignmentStatus = status
    }

    private func prepareReplacement(for operation: SpaceRealignment) {
        realignment = operation.changing(to: .prepare)
        realignmentStatus = "Finding a new shared anchor…"
        realignmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let anchor = try await self.sharedWorldAnchorManager.createSharedAnchorInFrontOfUser()
                guard !Task.isCancelled, self.realignment?.id == operation.id else {
                    try? await self.sharedWorldAnchorManager.removeAnchor(anchor.id)
                    return
                }
                self.replacementAnchorID = anchor.id
                let prepare = operation.changing(to: .prepare, anchorID: anchor.id)
                self.realignment = prepare
                self.sendRealignment(prepare)
            } catch {
                guard !Task.isCancelled, self.realignment?.id == operation.id else { return }
                self.sendRealignment(operation.changing(to: .failed))
                self.finishRealignment("Couldn’t create a shared anchor. Check tracking and try again.")
            }
        }
    }

    /// ARKit resolved an anchor locally; this is where the deferred transitions happen —
    /// both sides can be parked waiting on tracking.
    private func confirmRealignmentAnchor(_ anchor: WorldAnchor) {
        guard let operation = realignment else { return }
        let action = RealignmentProtocol.anchorResolved(anchor.id, isTracked: anchor.isTracked,
                                                        context: realignmentContext)
        // Called from every anchor update, so an unrelated anchor must stay silent rather than
        // logging an "ignored" line per update.
        if case .ignore = action { return }
        perform(action, message: operation, sender: realignmentCoordinatorID ?? UUID())
    }

    /// Current protocol state as plain values, for `RealignmentProtocol`.
    private var realignmentContext: RealignmentContext {
        RealignmentContext(
            canRealign: canRealign,
            isCoordinator: coordinatesRealignment,
            coordinatorID: realignmentCoordinatorID,
            nearbyParticipantIDs: sharePlayCoordinator?.nearbyParticipantIDs ?? [],
            current: realignment,
            isRealigning: isRealigning,
            sessionOriginID: sessionOriginID,
            sessionOriginIsTracked: sessionOriginIsTracked,
            replacementAnchorID: replacementAnchorID,
            trackedAnchorIDs: Set(sharedWorldAnchorManager.sharedAnchors.filter { $0.value.isTracked }.keys)
        )
    }

    /// Applies an incoming realignment message.
    ///
    /// All the guards live in `RealignmentProtocol.action(for:from:context:)` so the transition
    /// table can be tested; the effects stay here.
    private func receiveRealignment(_ message: SpaceRealignment, from sender: UUID) {
        perform(RealignmentProtocol.action(for: message, from: sender, context: realignmentContext),
                message: message, sender: sender)
    }

    private func perform(_ action: RealignmentAction, message: SpaceRealignment, sender: UUID) {
        switch action {
        case .ignore(let reason):
            debugLogRealignment("ignored \(message.phase.rawValue): \(reason)")

        case .startAndProbe(let probe):
            // `probe` already carries the anchor `RealignmentProtocol.probeAnchor` chose.
            startRealignment(probe)
            sendRealignment(probe)

        case .startAndReport(let store, let reply):
            startRealignment(store)
            sendRealignment(reply, to: sender)

        case .commit(let commit, _):
            commitRealignment(commit)

        case .prepareReplacement(let basedOn):
            prepareReplacement(for: basedOn)

        case .holdForAnchor(let store, let probeLocalAnchor):
            realignment = store
            if probeLocalAnchor {
                realignmentStatus = "Locating the new shared anchor…"
                if let id = store.anchorID, let anchor = sharedWorldAnchorManager.sharedAnchors[id] {
                    confirmRealignmentAnchor(anchor)
                }
            }

        case .adoptAndAcknowledge(let anchorID, let reply):
            guard adoptRealignmentAnchor(anchorID, owner: sender) else { return }
            resendRealignedPoses(anchorID: anchorID)
            sendRealignment(reply, to: sender)
            finishRealignment(realignmentConfirmedStatus, confirmed: true)

        case .sendReady(let store, let reply):
            realignment = store
            if let owner = realignmentCoordinatorID { sendRealignment(reply, to: owner) }

        case .finishConfirmed:
            finishRealignment(realignmentConfirmedStatus, confirmed: true)

        case .finishFailed:
            finishRealignment("Realignment couldn’t finish. Check the other Vision Pro and try again.")
        }
    }

    private var realignmentConfirmedStatus: String {
        "Both headsets confirmed the room anchor. This does not move diagrams; they are placed in the shared space."
    }

    private func debugLogRealignment(_ text: String) {
        if ProcessInfo.processInfo.environment["AVAR_VERBOSE_LOGS"] != nil { print("🔁 realignment: \(text)") }
    }

    private func commitRealignment(_ commit: SpaceRealignment) {
        guard let anchorID = commit.anchorID, let owner = realignmentCoordinatorID,
              adoptRealignmentAnchor(anchorID, owner: owner) else { return }
        realignment = commit
        sendRealignment(commit)
        resendRealignedPoses(anchorID: anchorID)
    }

    private func adoptRealignmentAnchor(_ id: UUID, owner: UUID) -> Bool {
        guard let anchor = sharedWorldAnchorManager.sharedAnchors[id], anchor.isTracked else { return false }
        let previousOwnedAnchor = ownedAnchorID
        if sessionOriginID != id {
            if let previous = sessionOriginID { retiredOriginIDs.insert(previous) }
            sessionOriginOwnerID = owner
        }
        sessionOriginID = id
        if id == replacementAnchorID {
            ownedAnchorID = id
        } else if ownedAnchorID != id {
            ownedAnchorID = nil
        }
        resolveSessionOrigin(anchor)
        if let previousOwnedAnchor, previousOwnedAnchor != id {
            supersededAnchorID = previousOwnedAnchor
        }
        return true
    }

    private func resendRealignedPoses(anchorID: UUID) {
        // When the anchor changes, ContentView republishes its rebased pose as it updates.
        // For the same anchor, resend the last authoritative pose of each locally shared diagram.
        for diagram in sharedDiagrams where isLocallyShared(diagram) && diagram.hasPose(relativeTo: anchorID) {
            let pose = UpdateDiagramTransformMessage(filename: diagram.filename,
                                                      anchorRelativePosition: diagram.anchorRelativePosition,
                                                      anchorRelativeOrientation: diagram.anchorRelativeOrientation,
                                                      anchorRelativeScale: diagram.anchorRelativeScale,
                                                      poseAnchorID: anchorID, diagramID: diagram.id)
            sendSharePlayEnvelope(.transform(pose))
        }
    }

    private func sendRealignment(_ message: SpaceRealignment, to participant: UUID? = nil) {
        sendSharePlayEnvelope(.realignment(message), to: participant)
    }

    private func sendSharePlayEnvelope(_ envelope: SharedSpaceEnvelope, to participant: UUID? = nil) {
        if let data = try? JSONEncoder().encode(envelope) {
            noteEnvelopeSent(envelope.kind, bytes: data.count)
            sendToSharePlay(data, kind: envelope.kind, to: participant)
        }
    }

    private func announceSessionOrigin(_ anchorID: UUID) {
        #if canImport(GroupActivities)
        guard let ownerID = sharePlayCoordinator?.localParticipantID else { return }
        sendSharePlayEnvelope(.sessionOrigin(SessionOriginMessage(anchorID: anchorID,
                                                                  ownerParticipantID: ownerID)))
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

                #if canImport(GroupActivities)
                if let owner = self.sessionOriginOwnerID,
                   let coordinator = self.sharePlayCoordinator,
                   !coordinator.participantIDs.contains(owner) {
                    self.clearSessionOrigin()
                }
                #endif

                if !self.sharedWorldAnchorManager.isRunning {
                    await self.startSharedWorldAnchorManager()
                }
                guard !Task.isCancelled, self.isSharePlayActive else { break }
                await self.ensureSharedWorldAnchorInFrontOfUser()

                // Re-announce only an anchor created here, including to late joiners.
                if !self.isRealigning, let id = self.ownedAnchorID {
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
        originGeneration = UUID()
        isCreatingSessionOrigin = false
        sessionOriginOwnerID = nil
        ownedAnchorID = nil
        sessionOriginTransform = nil
        sessionOriginID = nil
        sessionOriginIsTracked = false
        sharedAnchor = nil
        sharedAnchorUsesSharedWorld = false
        anchorCreationFailure = nil
    }

    func handleSessionOriginAnnouncement(_ message: SessionOriginMessage, source: String) {
        guard source == "SharePlay", isSharePlayActive else { return }
        #if canImport(GroupActivities)
        guard let coordinator = sharePlayCoordinator,
              coordinator.nearbyParticipantIDs.contains(message.ownerParticipantID) else { return }
        #endif
        guard message.anchorID != sessionOriginID, !retiredOriginIDs.contains(message.anchorID),
              !isRealigning else { return }

        if let owner = sessionOriginOwnerID, message.ownerParticipantID != owner,
           !SessionOriginElection.shouldYield(toOwner: message.ownerParticipantID, localOwnerID: owner) {
            return
        }
        let oldOwnedAnchorID = ownedAnchorID
        clearSessionOrigin()
        sessionOriginOwnerID = message.ownerParticipantID
        sessionOriginID = message.anchorID
        if let anchor = sharedWorldAnchorManager.sharedAnchors[message.anchorID] {
            resolveSessionOrigin(anchor)
        }
        if let oldOwnedAnchorID {
            Task { try? await sharedWorldAnchorManager.removeAnchor(oldOwnedAnchorID) }
        }
    }
    #endif
    
    private func setupMultipeerSession() {
        multipeerSession = MultipeerConnectivityService()
        multipeerSession?.delegate = self
    }

    enum CompanionMode {
        case idle, advertising, browsing
    }

    @Published private(set) var companionMode: CompanionMode = .idle
    @Published private(set) var connectingCompanion: MCPeerID?
    @Published private(set) var isStartingSharePlay = false
    @Published private(set) var sharePlayStartError: String?

    func startCompanionConnection() {
        guard companionMode == .idle else { return }
        lastError = nil
        #if os(visionOS)
        companionMode = .advertising
        multipeerSession?.startHosting()
        #elseif os(iOS)
        companionMode = .browsing
        multipeerSession?.startBrowsing()
        #endif
        isSessionActive = isSharePlayActive || companionMode != .idle
    }

    func stopCompanionConnection() {
        companionMode = .idle
        connectingCompanion = nil
        connectedPeers.removeAll()
        availablePeers.removeAll()
        multipeerSession?.stop()
        isSessionActive = isSharePlayActive
        #if os(iOS)
        if !isSharePlayActive {
            sharedDiagrams.removeAll()
            closedDiagramIDs.removeAll()
            sharedAnchor = nil
        }
        #endif
    }

    #if canImport(GroupActivities)
    func startSharePlay() async {
        guard let coordinator = sharePlayCoordinator, !coordinator.isActive,
              !isStartingSharePlay else { return }
        isStartingSharePlay = true
        sharePlayStartError = nil
        defer { isStartingSharePlay = false }

        do {
            try await coordinator.start()
        } catch {
            sharePlayStartError = error.localizedDescription
        }
    }

    func stopSharePlay() {
        sharePlayCoordinator?.stop()
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
    
    /// Share a diagram with all connected peers including position data
    func shareDiagram(filename: String, elements: [ElementDTO], is2D: Bool = false,
                      anchorRelativePosition: SIMD3<Float>? = nil,
                      anchorRelativeOrientation: simd_quatf? = nil, anchorRelativeScale: Float? = nil,
                      poseAnchorID: UUID? = nil) {

#if os(iOS)
        // iOS is receive-only. Structured as #if/#else rather than an early `return` so the rest
        // of the body is not compiled-but-unreachable on iOS (which warned).
        print("ℹ️ Ignoring shareDiagram request on iOS client; iOS is receive-only")
#else

        guard !sharedDiagrams.contains(where: { $0.filename == filename }) else { return }

        let sharedDiagram = SharedDiagram(
            filename: filename,
            elements: elements,
            is2D: is2D,
            anchorRelativePosition: anchorRelativePosition,
            anchorRelativeOrientation: anchorRelativeOrientation,
            anchorRelativeScale: anchorRelativeScale,
            poseAnchorID: poseAnchorID
        )

        locallySharedDiagramIDs.insert(sharedDiagram.id)
        sharedDiagrams.append(sharedDiagram)

        // Send to all peers
        broadcast(.diagram(sharedDiagram))

        print("📊 Shared diagram '\(filename)' with \(connectedPeers.count) peers")

#endif
    }

    func cacheLocalDiagramTransform(filename: String,
                                    position: SIMD3<Float>,
                                    orientation: simd_quatf,
                                    scale: Float) {
        localDiagramTransforms[filename] = DiagramTransform(position: position, orientation: orientation,
                                                            scale: scale, anchorID: currentPoseAnchorID)
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

    /// The anchor that diagram poses on the wire are relative to. **Always `nil`.**
    ///
    /// Poses are plain RealityKit scene coordinates. With `supportsGroupImmersiveSpace`, the
    /// system gives every spatial participant — nearby or a FaceTime Persona — one shared
    /// immersive-space frame, in which identical transforms land in the same place. That is the
    /// only frame every participant can resolve: a shared `WorldAnchor` never reaches a remote
    /// participant, and its raw ARKit transform is not known to be a valid scene transform while
    /// the immersive space is displaced (see `FrameDiagnostics`).
    ///
    /// This is the single seam between the room anchor and content. The anchor, the session
    /// origin and the realignment handshake still run, but only as diagnostics. To pose content
    /// relative to an anchor again, this is the property to change — together with a way to hold
    /// back a pose until the receiver can resolve that anchor.
    var currentPoseAnchorID: UUID? { nil }

    #if os(visionOS)
    private func discardSharePlayDiagrams() {
        let removed = sharedDiagrams.filter {
            sharePlayReceivedDiagramIDs.contains($0.id) ||
            (connectedPeers.isEmpty && isLocallyShared($0))
        }
        let received = removed.filter { !isLocallyShared($0) }
        let removedIDs = Set(removed.map(\.id))
        sharedDiagrams.removeAll { removedIDs.contains($0.id) }
        locallySharedDiagramIDs.subtract(removedIDs)
        sharePlayReceivedDiagramIDs.removeAll()
        closedDiagramIDs.removeAll()
        for diagram in received { receivedDiagramRemoval.send(diagram.filename) }
    }
    #endif

    func isLocallyShared(_ diagram: SharedDiagram) -> Bool {
        locallySharedDiagramIDs.contains(diagram.id)
    }

    /// Remove a diagram from sharing and prevent in-flight snapshots from reopening it.
    func removeDiagram(filename: String) {
        guard let diagram = sharedDiagrams.first(where: { $0.filename == filename }) else {
            localDiagramTransforms.removeValue(forKey: filename)
            return
        }
        forgetSharedDiagram(diagram)
        broadcast(.remove(RemoveDiagramMessage(filename: filename, diagramID: diagram.id)))
    }

    private func forgetSharedDiagram(_ diagram: SharedDiagram) {
        closedDiagramIDs.insert(diagram.id)
        locallySharedDiagramIDs.remove(diagram.id)
        #if os(visionOS)
        sharePlayReceivedDiagramIDs.remove(diagram.id)
        #endif
        localDiagramTransforms.removeValue(forKey: diagram.filename)
        sharedDiagrams.removeAll { $0.id == diagram.id }
    }

    /// Update the transform of an existing shared diagram
    func updateDiagramTransform(filename: String, anchorRelativePosition: SIMD3<Float>? = nil,
                                anchorRelativeOrientation: simd_quatf? = nil, anchorRelativeScale: Float? = nil) {
        if let position = anchorRelativePosition, let orientation = anchorRelativeOrientation,
           let scale = anchorRelativeScale {
            cacheLocalDiagramTransform(filename: filename, position: position, orientation: orientation, scale: scale)
        }
        guard let index = sharedDiagrams.firstIndex(where: { $0.filename == filename }) else {
            return
        }

        let diagram = sharedDiagrams[index]
        var updated = diagram
        updated.anchorRelativePosition = anchorRelativePosition ?? diagram.anchorRelativePosition
        updated.anchorRelativeOrientation = anchorRelativeOrientation ?? diagram.anchorRelativeOrientation
        updated.anchorRelativeScale = anchorRelativeScale ?? diagram.anchorRelativeScale
        updated.poseAnchorID = currentPoseAnchorID
        sharedDiagrams[index] = updated

        let updateMessage = UpdateDiagramTransformMessage(
            filename: filename,
            anchorRelativePosition: anchorRelativePosition,
            anchorRelativeOrientation: anchorRelativeOrientation,
            anchorRelativeScale: anchorRelativeScale,
            poseAnchorID: updated.poseAnchorID,
            diagramID: diagram.id
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
                anchorRelativeScale: old.anchorRelativeScale,
                poseAnchorID: old.poseAnchorID
            )
            sharedDiagrams[dIndex] = newDiagram
            // 🔔 Force a publish
            sharedDiagrams = sharedDiagrams
        }
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
            for diagram in sharedDiagrams where isLocallyShared(diagram) {
                if let data = try? JSONEncoder().encode(SharedSpaceEnvelope.diagram(diagram)) {
                    sendToSharePlay(data, kind: "diagram")
                }
            }
        #endif
    }

    #if canImport(GroupActivities)
        private var sharePlaySendTask: Task<Void, Never>?
        private func sendToSharePlay(_ data: Data, kind: String, to participant: UUID? = nil) {
            guard sharePlayCoordinator?.isActive == true else {
                print("⚠️ sendToSharePlay skipped: SharePlay not active (isActive=\(sharePlayCoordinator?.isActive ?? false))")
                return
            }
            print("📤 sendToSharePlay: Sending \(data.count) bytes via SharePlay")
            guard let coordinator = sharePlayCoordinator,
                  let sessionID = coordinator.sessionID else { return }
            let previous = sharePlaySendTask
            sharePlaySendTask = Task { [weak self, weak coordinator] in
                await previous?.value
                guard !Task.isCancelled, let self, let coordinator, coordinator.sessionID == sessionID else { return }
                if let error = await coordinator.send(data, to: participant) {
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
    private func handleIncomingPayload(_ data: Data, source: String, senderID: UUID? = nil) {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(SharedSpaceEnvelope.self, from: data) {
            noteEnvelopeReceived(envelope.kind, bytes: data.count, source: source)
            handleSharedEnvelope(envelope, source: source, senderID: senderID)
            return
        }

        noteEnvelopeReceived("undecodable", bytes: data.count, source: source)
        print("❓ Received unknown data from \(source)")
    }
}

@MainActor
private extension CollaborativeSessionManager {
    func handleSharedEnvelope(_ envelope: SharedSpaceEnvelope, source: String, senderID: UUID? = nil) {
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

        case .realignment(let message):
            #if os(visionOS)
            if let senderID { receiveRealignment(message, from: senderID) }
            #endif

        case .diagram(let sharedDiagram):
            guard !closedDiagramIDs.contains(sharedDiagram.id) else { return }
            if sharedDiagram.poseAnchorID != nil, !peerUsesAnchorFrame { peerUsesAnchorFrame = true }
            // The same diagram can arrive over Multipeer before SharePlay. As soon as we
            // know it is in SharePlay, require the shared frame without overwriting its pose.
            if sharedDiagrams.contains(where: { $0.id == sharedDiagram.id }) {
                #if os(visionOS)
                if source == "SharePlay", sharePlayReceivedDiagramIDs.insert(sharedDiagram.id).inserted {
                    objectWillChange.send()
                }
                #endif
                return
            }
            guard !sharedDiagrams.contains(where: { $0.filename == sharedDiagram.filename }) else { return }
            #if os(visionOS)
            if source == "SharePlay" { sharePlayReceivedDiagramIDs.insert(sharedDiagram.id) }
            #endif
            sharedDiagrams.append(sharedDiagram)

        case .transform(let updateMessage):
            if updateMessage.poseAnchorID != nil, !peerUsesAnchorFrame { peerUsesAnchorFrame = true }
            guard let index = sharedDiagrams.firstIndex(where: {
                $0.filename == updateMessage.filename &&
                (updateMessage.diagramID == nil || $0.id == updateMessage.diagramID)
            }) else { return }
            #if os(visionOS)
            if let poseAnchorID = updateMessage.poseAnchorID,
               retiredOriginIDs.contains(poseAnchorID) { return }
            #endif
            var diagram = sharedDiagrams[index]
            diagram.anchorRelativePosition = updateMessage.anchorRelativePosition ?? diagram.anchorRelativePosition
            diagram.anchorRelativeOrientation = updateMessage.anchorRelativeOrientation ?? diagram.anchorRelativeOrientation
            diagram.anchorRelativeScale = updateMessage.anchorRelativeScale ?? diagram.anchorRelativeScale
            diagram.poseAnchorID = updateMessage.poseAnchorID
            sharedDiagrams[index] = diagram
            if let position = diagram.anchorRelativePosition, let orientation = diagram.anchorRelativeOrientation,
               let scale = diagram.anchorRelativeScale, isLocallyShared(diagram) {
                localDiagramTransforms[diagram.filename] = DiagramTransform(
                    position: position, orientation: orientation, scale: scale, anchorID: diagram.poseAnchorID
                )
            }
            receivedDiagramTransform.send(diagram)

        case .remove(let removeMessage):
            if let id = removeMessage.diagramID { closedDiagramIDs.insert(id) }
            guard let diagram = sharedDiagrams.first(where: {
                $0.filename == removeMessage.filename &&
                (removeMessage.diagramID == nil || $0.id == removeMessage.diagramID)
            }) else { return }
            forgetSharedDiagram(diagram)
            receivedDiagramRemoval.send(diagram.filename)

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
                        anchorRelativeScale: old.anchorRelativeScale,
                        poseAnchorID: old.poseAnchorID
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
        
        if context == "advertising" || context == "browsing" || nsError.code == -72008 {
            stopCompanionConnection()
        }
        
        print("🔴 Multipeer error in \(context): \(lastError ?? "unknown")")
    }
    
    func multipeerService(_ service: MultipeerConnectivityService, didUpdateAvailablePeers peers: [MCPeerID]) {
        guard companionMode == .browsing else { return }
        availablePeers = peers
        print("📋 Available peers updated: \(peers.map { $0.displayName }.joined(separator: ", "))")
    }
    
    /// Manually connect to a specific peer
    func connectToPeer(_ peer: MCPeerID) {
        guard companionMode == .browsing, connectingCompanion == nil,
              availablePeers.contains(peer) else { return }
        lastError = nil
        connectingCompanion = peer
        multipeerSession?.connectToPeer(peer)
    }
    
    func multipeerService(_ service: MultipeerConnectivityService, peer: MCPeerID, didChangeState state: MCSessionState) {
        guard companionMode != .idle else { return }
        print("🎯 CollaborativeSessionManager received state change: \(peer.displayName) → \(state)")
        
        switch state {
        case .connected:
            if connectingCompanion == peer { connectingCompanion = nil }
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
            if connectingCompanion == peer {
                connectingCompanion = nil
                lastError = "Could not connect to \(peer.displayName). Check that it is still allowing iPhone connections and try again."
            }
            connectedPeers.removeAll { $0 == peer }
            
            if connectedPeers.isEmpty && !isSharePlayActive {
                sessionState = companionMode == .advertising ? "Waiting for iPhone" : "Looking for Vision Pro"
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
    // The diagram's pose in the **shared scene frame**: the group immersive space, which
    // SharePlay makes common to every spatial participant. Producers use
    // `ElementViewModel.getSharedTransform()` (`position(relativeTo: worldRoot)`); consumers apply
    // them with `setPosition(_, relativeTo: worldRoot)`. `worldRoot` sits at the scene origin, so
    // these are scene coordinates. The `anchorRelative` names and `poseAnchorID` date from when
    // poses were relative to a shared room anchor; `poseAnchorID` is now always `nil`.
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
    var poseAnchorID: UUID?

    func hasPose(relativeTo anchorID: UUID?) -> Bool {
        guard let anchorID else { return false }
        return poseAnchorID == anchorID && anchorRelativePosition != nil
    }

    // Encode/decode helpers for SIMD types
    enum CodingKeys: String, CodingKey {
        case id, filename, elements, timestamp, is2D, poseAnchorID
        case worldPositionX, worldPositionY, worldPositionZ
        case worldOrientationX, worldOrientationY, worldOrientationZ, worldOrientationW
        case worldScale
    }

    init(id: UUID = UUID(), filename: String, elements: [ElementDTO], timestamp: Date = Date(),
         is2D: Bool = false,
         anchorRelativePosition: SIMD3<Float>? = nil, anchorRelativeOrientation: simd_quatf? = nil, anchorRelativeScale: Float? = nil,
         poseAnchorID: UUID? = nil) {
        self.id = id
        self.filename = filename
        self.elements = elements
        self.timestamp = timestamp
        self.is2D = is2D
        self.anchorRelativePosition = anchorRelativePosition
        self.anchorRelativeOrientation = anchorRelativeOrientation
        self.anchorRelativeScale = anchorRelativeScale
        self.poseAnchorID = poseAnchorID
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
        poseAnchorID = try container.decodeIfPresent(UUID.self, forKey: .poseAnchorID)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(filename, forKey: .filename)
        try container.encode(elements, forKey: .elements)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(is2D, forKey: .is2D)
        try container.encodeIfPresent(poseAnchorID, forKey: .poseAnchorID)

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

struct SpaceRealignment: Codable, Equatable {
    enum Phase: String, Codable {
        case request, probe, report, prepare, ready, commit, applied, failed
    }

    let id: UUID
    let phase: Phase
    let anchorID: UUID?
    let replaceAnchor: Bool

    func changing(to phase: Phase, anchorID: UUID? = nil) -> Self {
        Self(id: id, phase: phase, anchorID: anchorID, replaceAnchor: replaceAnchor)
    }
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
    case realignment(SpaceRealignment)
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
        case .realignment: return "realignment"
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
        case realignment
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
        case .realignment(let message):
            try container.encode(EnvelopeType.realignment, forKey: .type)
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
        case .realignment:
            self = .realignment(try container.decode(SpaceRealignment.self, forKey: .payload))
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
    var diagramID: UUID? = nil
}

struct UpdateDiagramTransformMessage: Codable {
    let filename: String
    var poseAnchorID: UUID?
    var diagramID: UUID?
    // Anchor-relative, like `SharedDiagram`'s pose fields. JSON keys remain `world*` for wire
    // compatibility — see `CodingKeys` below.
    var anchorRelativePosition: SIMD3<Float>?
    var anchorRelativeOrientation: simd_quatf?
    var anchorRelativeScale: Float?
    
    // Encode/decode helpers for SIMD types
    enum CodingKeys: String, CodingKey {
        case filename, poseAnchorID, diagramID
        case worldPositionX, worldPositionY, worldPositionZ
        case worldOrientationX, worldOrientationY, worldOrientationZ, worldOrientationW
        case worldScale
    }
    
    init(filename: String, anchorRelativePosition: SIMD3<Float>? = nil,
         anchorRelativeOrientation: simd_quatf? = nil, anchorRelativeScale: Float? = nil,
         poseAnchorID: UUID? = nil, diagramID: UUID? = nil) {
        self.filename = filename
        self.poseAnchorID = poseAnchorID
        self.diagramID = diagramID
        self.anchorRelativePosition = anchorRelativePosition
        self.anchorRelativeOrientation = anchorRelativeOrientation
        self.anchorRelativeScale = anchorRelativeScale
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decode(String.self, forKey: .filename)
        poseAnchorID = try container.decodeIfPresent(UUID.self, forKey: .poseAnchorID)
        diagramID = try container.decodeIfPresent(UUID.self, forKey: .diagramID)
        
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
        try container.encodeIfPresent(poseAnchorID, forKey: .poseAnchorID)
        try container.encodeIfPresent(diagramID, forKey: .diagramID)
        
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
    var onDataReceived: ((Data, UUID) -> Void)?
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
    /// Whether the system has made the local participant spatial, including remote spatial Personas.
    @Published private(set) var isSpatial: Bool = false

    // MARK: - Public Properties
    var isActive: Bool { currentSession != nil }
    var sessionID: UUID? { currentSession?.id }
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

    func start() async throws {
        _ = try await SharedSpaceActivity().activate()
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
    func send(_ data: Data, to participantID: UUID? = nil) async -> String? {
        guard let messenger else {
            print("❌ SharePlay send failed: messenger is nil")
            return "messenger is nil"
        }
        do {
            if let participantID {
                guard let participant = currentSession?.activeParticipants.first(where: { $0.id == participantID })
                else { return "SharePlay participant is no longer connected" }
                try await messenger.send(data, to: .only([participant]))
            } else {
                try await messenger.send(data)
            }
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
        if currentSession != nil { stop() }

        currentSession = session
        messenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)

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
            for await (data, context) in messenger.messages(of: Data.self) {
                print("📥 SharePlay: Received message (\(data.count) bytes)")
                await MainActor.run { [weak self] in
                    guard let self, self.currentSession?.id == session.id else { return }
                    self.onDataReceived?(data, context.source.id)
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
                    guard let self, self.currentSession?.id == session.id else { return }
                    switch state {
                    case .waiting:
                        self.sessionStateDescription = "waiting"
                    case .joined:
                        self.sessionStateDescription = "joined"
                        self.onSessionJoined?()
                    case .invalidated(let reason):
                        self.currentSession = nil
                        self.stop()
                        self.sessionStateDescription = "invalidated (\(reason.localizedDescription))"
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
                    guard let self, self.currentSession?.id == session.id else { return }
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

struct SharedSpaceActivity: GroupActivity, Transferable {
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
