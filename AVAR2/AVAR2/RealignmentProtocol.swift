//
//  RealignmentProtocol.swift
//  AVAR2
//
//  Pure decision logic for the shared-anchor realignment handshake.
//
//  Extracted from `CollaborativeSessionManager.receiveRealignment` and
//  `confirmRealignmentAnchor` for the same reason `SessionOriginLogic` was: the rules were welded
//  to a live `GroupSession` and an `ARKitSession`, so the most intricate protocol in the app had
//  no test coverage at all. Every guard below is a transcription of the original; the manager
//  still performs all the effects (anchor creation, adoption, pose resend, timeouts, status text).
//
//  ## The handshake
//
//  One participant is the *coordinator*, elected by `SessionOriginElection` over the nearby
//  participants so both devices independently agree who it is.
//
//      peer                    coordinator
//       │  ── request ──────────▶ │              (only if the peer started it)
//       │  ◀───────── probe ───── │              "are we both on anchor X?"
//       │  ── report ───────────▶ │              "yes, X" / "no"
//       │                         │  both on X ─▶ commit
//       │  ◀──────── prepare ──── │              otherwise: here is a new anchor Y
//       │  ── ready ────────────▶ │              "I can see Y"
//       │  ◀──────── commit ───── │              adopt Y
//       │  ── applied ──────────▶ │              both confirmed
//
//  `failed` can arrive from the coordinator at any point, including from its own timeout.
//
//  ## Why the guards matter
//
//  A message accepted in the wrong state would retire a live anchor or adopt one the other
//  headset cannot see, stranding content in a frame nobody shares. The guards are the only thing
//  preventing that, and several are asymmetric (a phase valid for the coordinator is invalid for
//  the peer, and vice versa), which is exactly the kind of table that rots silently.
//

import Foundation

/// Everything the decision depends on, captured as plain values.
struct RealignmentContext: Equatable {
    /// `canRealign` in the manager: SharePlay active with exactly one nearby participant.
    var canRealign: Bool
    /// Whether this device is the elected coordinator.
    var isCoordinator: Bool
    /// The elected coordinator, used to decide whether a message came from it.
    var coordinatorID: UUID?
    /// Nearby participants; a message from anyone else is ignored outright.
    var nearbyParticipantIDs: Set<UUID>
    /// The operation currently in flight on this device, if any.
    var current: SpaceRealignment?
    /// Whether an operation is in flight (mirrors `isRealigning`).
    var isRealigning: Bool
    /// The anchor this device currently treats as the session origin.
    var sessionOriginID: UUID?
    /// Whether ARKit is tracking that origin right now.
    var sessionOriginIsTracked: Bool
    /// The replacement anchor this device created, if it is the coordinator mid-replacement.
    var replacementAnchorID: UUID?
    /// Anchors this device can currently see *and* track. `adoptRealignmentAnchor` fails without
    /// this, which is what stops a device adopting an anchor it cannot resolve.
    var trackedAnchorIDs: Set<UUID>

    init(canRealign: Bool = true,
         isCoordinator: Bool = false,
         coordinatorID: UUID? = nil,
         nearbyParticipantIDs: Set<UUID> = [],
         current: SpaceRealignment? = nil,
         isRealigning: Bool = false,
         sessionOriginID: UUID? = nil,
         sessionOriginIsTracked: Bool = false,
         replacementAnchorID: UUID? = nil,
         trackedAnchorIDs: Set<UUID> = []) {
        self.canRealign = canRealign
        self.isCoordinator = isCoordinator
        self.coordinatorID = coordinatorID
        self.nearbyParticipantIDs = nearbyParticipantIDs
        self.current = current
        self.isRealigning = isRealigning
        self.sessionOriginID = sessionOriginID
        self.sessionOriginIsTracked = sessionOriginIsTracked
        self.replacementAnchorID = replacementAnchorID
        self.trackedAnchorIDs = trackedAnchorIDs
    }
}

/// What the manager should do with an incoming message.
///
/// Each case carries the operation to store and any reply to send, so a caller — or a test
/// harness — never has to re-derive those and drift from the implementation.
enum RealignmentAction: Equatable {
    /// Rejected. The reason is for diagnosis only; nothing branches on it.
    case ignore(reason: String)
    /// Coordinator received a peer's `request`: adopt it and start probing.
    case startAndProbe(store: SpaceRealignment)
    /// Peer received `probe`: adopt it and answer whether it holds the same anchor.
    case startAndReport(store: SpaceRealignment, reply: SpaceRealignment)
    /// Coordinator confirmed both sides hold the same usable anchor: commit to it.
    case commit(store: SpaceRealignment, anchorID: UUID)
    /// Coordinator must mint a replacement anchor, then announce it with `prepare`.
    case prepareReplacement(basedOn: SpaceRealignment)
    /// Store and wait for ARKit to resolve the named anchor locally; no reply yet.
    ///
    /// `probeLocalAnchor` distinguishes the peer's `prepare` (which also reports progress and
    /// immediately retries in case the anchor already resolved) from the coordinator's untracked
    /// `ready` (which only parks the message).
    case holdForAnchor(store: SpaceRealignment, probeLocalAnchor: Bool)
    /// Peer adopts the committed anchor, resends its poses, acknowledges and finishes.
    /// Nothing is stored — `finishRealignment` clears the operation.
    case adoptAndAcknowledge(anchorID: UUID, reply: SpaceRealignment)
    /// Peer resolved the replacement anchor: tell the coordinator it is visible here.
    case sendReady(store: SpaceRealignment, reply: SpaceRealignment)
    /// Handshake completed successfully.
    case finishConfirmed
    /// Handshake abandoned.
    case finishFailed
}

enum RealignmentProtocol {
    /// Decides what to do with `message` from `sender`.
    ///
    /// Mirrors `receiveRealignment` guard for guard. Returning `.ignore` must be silent and
    /// side-effect free: a stray or replayed message is normal on a lossy link.
    static func action(for message: SpaceRealignment,
                       from sender: UUID,
                       context: RealignmentContext) -> RealignmentAction {
        guard context.canRealign else { return .ignore(reason: "cannot realign") }
        guard context.nearbyParticipantIDs.contains(sender) else {
            return .ignore(reason: "sender is not a nearby participant")
        }
        let fromCoordinator = sender == context.coordinatorID
        let current = context.current
        let matchesCurrent = current?.id == message.id

        switch message.phase {
        case .request:
            // Only the coordinator services a request, and only when idle.
            guard context.isCoordinator else { return .ignore(reason: "not the coordinator") }
            guard !context.isRealigning else { return .ignore(reason: "already realigning") }
            return .startAndProbe(store: message.changing(to: .probe,
                                                          anchorID: probeAnchor(for: message, context: context)))

        case .probe:
            // Peer side. Answers with its own anchor only if it is the same one and tracked.
            guard fromCoordinator else { return .ignore(reason: "probe not from coordinator") }
            let matching = context.sessionOriginIsTracked && context.sessionOriginID == message.anchorID
                ? message.anchorID : nil
            return .startAndReport(store: message,
                                   reply: message.changing(to: .report, anchorID: matching))

        case .report:
            guard context.isCoordinator else { return .ignore(reason: "not the coordinator") }
            guard matchesCurrent, let probe = current, probe.phase == .probe else {
                return .ignore(reason: "no matching probe in flight")
            }
            // Both sides hold the same anchor and we can track it: nothing needs replacing.
            if let anchorID = message.anchorID, probe.anchorID == anchorID,
               context.sessionOriginIsTracked, context.sessionOriginID == anchorID {
                return .commit(store: message.changing(to: .commit, anchorID: anchorID),
                               anchorID: anchorID)
            }
            return .prepareReplacement(basedOn: message)

        case .prepare:
            guard fromCoordinator else { return .ignore(reason: "prepare not from coordinator") }
            guard matchesCurrent, current?.phase == .probe else {
                return .ignore(reason: "prepare outside a probe") }
            guard message.anchorID != nil else { return .ignore(reason: "prepare without an anchor") }
            return .holdForAnchor(store: message, probeLocalAnchor: true)

        case .ready:
            guard context.isCoordinator else { return .ignore(reason: "not the coordinator") }
            guard matchesCurrent, current?.phase == .prepare else {
                return .ignore(reason: "ready outside a prepare") }
            guard let id = message.anchorID, id == context.replacementAnchorID else {
                return .ignore(reason: "ready names an unexpected anchor") }
            // Keep the previous anchor until this device can resolve the replacement too.
            guard context.trackedAnchorIDs.contains(id) else {
                return .holdForAnchor(store: message, probeLocalAnchor: false)
            }
            return .commit(store: message.changing(to: .commit, anchorID: id), anchorID: id)

        case .commit:
            guard fromCoordinator else { return .ignore(reason: "commit not from coordinator") }
            guard let operation = current, operation.id == message.id else {
                return .ignore(reason: "commit for an unknown operation") }
            guard let id = message.anchorID, operation.anchorID == id else {
                return .ignore(reason: "commit names a different anchor") }
            // `.prepare` is deliberately absent: the peer only reaches commit via `.ready`
            // (replacement) or `.probe` (same anchor).
            guard operation.phase == .ready || operation.phase == .probe else {
                return .ignore(reason: "commit in phase \(operation.phase.rawValue)") }
            // Mirrors `adoptRealignmentAnchor`, which fails when the anchor is not tracked here.
            guard context.trackedAnchorIDs.contains(id) else {
                return .ignore(reason: "commit anchor is not tracked locally") }
            return .adoptAndAcknowledge(anchorID: id,
                                        reply: message.changing(to: .applied, anchorID: id))

        case .applied:
            guard context.isCoordinator else { return .ignore(reason: "not the coordinator") }
            guard matchesCurrent, current?.phase == .commit else {
                return .ignore(reason: "applied outside a commit") }
            guard let id = message.anchorID, id == context.sessionOriginID,
                  context.sessionOriginIsTracked else {
                return .ignore(reason: "applied names an anchor we are not tracking") }
            return .finishConfirmed

        case .failed:
            guard fromCoordinator else { return .ignore(reason: "failed not from coordinator") }
            guard matchesCurrent else { return .ignore(reason: "failed for an unknown operation") }
            return .finishFailed
        }
    }

    /// The anchor a coordinator offers in its `probe`: its own origin, but only when it is
    /// tracked and the request did not explicitly ask for a replacement.
    ///
    /// `replaceAnchor` is read from the message because on `.request` nothing is stored yet.
    static func probeAnchor(for message: SpaceRealignment, context: RealignmentContext) -> UUID? {
        guard context.sessionOriginIsTracked, !message.replaceAnchor else { return nil }
        return context.sessionOriginID
    }

    /// What `confirmRealignmentAnchor` does when ARKit finally resolves an anchor locally.
    ///
    /// These are the deferred transitions: both sides can be waiting on tracking, and the
    /// handshake only advances once the anchor actually resolves.
    static func anchorResolved(_ anchorID: UUID,
                               isTracked: Bool,
                               context: RealignmentContext) -> RealignmentAction {
        guard let operation = context.current else { return .ignore(reason: "no operation") }
        guard operation.anchorID == anchorID else { return .ignore(reason: "not this operation's anchor") }
        guard isTracked else { return .ignore(reason: "anchor is not tracked") }

        if context.isCoordinator, operation.phase == .ready {
            return .commit(store: operation.changing(to: .commit, anchorID: anchorID), anchorID: anchorID)
        }
        if !context.isCoordinator, operation.phase == .prepare, context.coordinatorID != nil {
            let ready = operation.changing(to: .ready, anchorID: anchorID)
            return .sendReady(store: ready, reply: ready)
        }
        return .ignore(reason: "nothing to advance in phase \(operation.phase.rawValue)")
    }
}
