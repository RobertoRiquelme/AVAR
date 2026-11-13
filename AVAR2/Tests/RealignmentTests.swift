import Foundation

/// Drives two simulated headsets through the realignment handshake.
///
/// Realignment is the most intricate protocol in the app and the only one that can *retire a live
/// anchor*. A message accepted in the wrong state can adopt an anchor the other headset cannot
/// see, stranding every diagram in a frame nobody shares — and that failure is invisible without
/// two physical Vision Pros in one room. The guards are the only thing preventing it, several are
/// asymmetric between coordinator and peer, and nothing exercised them before this file.
///
/// The harness drives the real decision function and applies only the state updates each decision
/// hands back. The one piece it models by hand is `adoptRealignmentAnchor` — it fails closed on an
/// untracked anchor, exactly as the manager's does; keep the two in step.
@main
struct RealignmentTests {
    static func main() {
        testSameAnchorConfirmsWithoutCreatingOne()
        testReplacementPathWhenAnchorsDisagree()
        testPeerInitiatedRequestIsServicedByCoordinator()
        testDeferredPrepareWaitsForLocalTracking()
        testDeferredReadyWaitsForCoordinatorTracking()
        testCommitIsRefusedWhenAnchorIsNotTrackedLocally()
        testRejectsMessagesFromNonCoordinator()
        testRejectsCoordinatorOnlyPhasesOnThePeer()
        testRejectsWrongOperationID()
        testRejectsReadyNamingAnUnexpectedAnchor()
        testRejectsCommitWhilePeerIsStillPreparing()
        testRejectsStrangersAndDisabledSessions()
        testSimultaneousRequestsCollapseToOne()
        testFailedFromCoordinatorEndsIt()
        testRejectsEveryPhaseOutsideItsExpectedPhase()
        testRejectsEveryPhaseForAnotherOperation()
        testPeerReportsNothingForAnAnchorItCannotTrack()
        testReportOnlyShortCircuitsWhenBothSidesReallyShareTheAnchor()
        testCoordinatorsOwnAnchorResolvingDoesNotAdvance()
        testPeerCannotAnswerReadyWithoutACoordinator()
        testRejectsPrepareWithoutAnAnchor()
        testRejectsCommitAndFailedForTheWrongOperation()
        testRejectsAppliedTheCoordinatorCannotBack()
        testRejectsReplayedPhases()
        testPeerDropsItsOwnRequestWhenTheCoordinatorProbesFirst()
        testAnchorResolvedIgnoresEverythingElse()
        testCommitIsNotAtomic()
        testChangingPreservesIdentityAndResetsAnchor()
        testProbeOffersOriginOnlyWhenUsable()
        print("RealignmentTests ✅")
    }

    // MARK: - Harness

    static let coordinatorID = UUID(uuidString: "00000000-0000-0000-0000-00000000AAAA")!
    static let peerID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-00000000BBBB")!

    /// One simulated device. `apply` performs exactly the state changes the real manager makes
    /// for each action — nothing more, so the test cannot invent transitions.
    struct Device {
        var id: UUID
        var context: RealignmentContext
        private(set) var outbox: [SpaceRealignment] = []
        private(set) var finished: Bool?          // true = confirmed, false = failed
        private(set) var lastIgnoreReason: String?

        init(id: UUID, isCoordinator: Bool, origin: UUID? = nil, originTracked: Bool = false,
             tracked: Set<UUID> = []) {
            self.id = id
            self.context = RealignmentContext(
                canRealign: true, isCoordinator: isCoordinator, coordinatorID: coordinatorID,
                nearbyParticipantIDs: Set([coordinatorID, peerID]).subtracting([id]),
                sessionOriginID: origin, sessionOriginIsTracked: originTracked,
                trackedAnchorIDs: tracked)
        }

        mutating func receive(_ message: SpaceRealignment, from sender: UUID) -> RealignmentAction {
            let action = RealignmentProtocol.action(for: message, from: sender, context: context)
            apply(action, message: message)
            return action
        }

        /// ARKit resolved an anchor locally.
        mutating func resolve(_ anchorID: UUID) -> RealignmentAction {
            context.trackedAnchorIDs.insert(anchorID)
            let action = RealignmentProtocol.anchorResolved(anchorID, isTracked: true, context: context)
            apply(action, message: context.current ?? SpaceRealignment(id: UUID(), phase: .failed,
                                                                      anchorID: nil, replaceAnchor: false))
            return action
        }

        private mutating func apply(_ action: RealignmentAction, message: SpaceRealignment) {
            switch action {
            case .ignore(let reason):
                lastIgnoreReason = reason
            case .startAndProbe(let store):
                context.current = store; context.isRealigning = true; outbox.append(store)
            case .startAndReport(let store, let reply):
                context.current = store; context.isRealigning = true; outbox.append(reply)
            case .commit(let store, let anchorID):
                adopt(anchorID); context.current = store; outbox.append(store)
            case .prepareReplacement(let basedOn):
                // The manager mints an anchor asynchronously; the test does that explicitly.
                context.current = basedOn.changing(to: .prepare)
            case .holdForAnchor(let store, _):
                context.current = store
            case .adoptAndAcknowledge(let anchorID, let reply):
                adopt(anchorID); outbox.append(reply); finished = true; context.current = nil
                context.isRealigning = false
            case .sendReady(let store, let reply):
                context.current = store; outbox.append(reply)
            case .finishConfirmed:
                finished = true; context.current = nil; context.isRealigning = false
            case .finishFailed:
                finished = false; context.current = nil; context.isRealigning = false
            }
        }

        /// Mirrors `adoptRealignmentAnchor`, including its refusal to adopt an untracked anchor.
        @discardableResult
        private mutating func adopt(_ anchorID: UUID) -> Bool {
            guard context.trackedAnchorIDs.contains(anchorID) else { return false }
            context.sessionOriginID = anchorID
            context.sessionOriginIsTracked = true
            return true
        }

        /// Coordinator mints the replacement anchor and announces it.
        mutating func mintReplacement(_ anchorID: UUID) -> SpaceRealignment {
            context.replacementAnchorID = anchorID
            context.trackedAnchorIDs.insert(anchorID)
            let prepare = (context.current ?? SpaceRealignment(id: UUID(), phase: .prepare,
                                                               anchorID: nil, replaceAnchor: true))
                .changing(to: .prepare, anchorID: anchorID)
            context.current = prepare
            outbox.append(prepare)
            return prepare
        }

        mutating func takeLast() -> SpaceRealignment { outbox.removeLast() }
    }

    static func pair(sharedOrigin: UUID?, tracked: Bool) -> (Device, Device) {
        let anchors: Set<UUID> = (sharedOrigin != nil && tracked) ? [sharedOrigin!] : []
        return (Device(id: coordinatorID, isCoordinator: true, origin: sharedOrigin,
                       originTracked: tracked, tracked: anchors),
                Device(id: peerID, isCoordinator: false, origin: sharedOrigin,
                       originTracked: tracked, tracked: anchors))
    }

    static func request(replace: Bool = false) -> SpaceRealignment {
        SpaceRealignment(id: UUID(), phase: .request, anchorID: nil, replaceAnchor: replace)
    }

    // MARK: - Happy paths

    /// Both headsets already agree on a tracked anchor: the handshake should confirm it and
    /// create nothing. Minting a replacement here would needlessly retire a working anchor.
    static func testSameAnchorConfirmsWithoutCreatingOne() {
        let origin = UUID()
        var (coord, peer) = pair(sharedOrigin: origin, tracked: true)

        // Coordinator starts: probe carries the shared anchor.
        let probe = RealignmentProtocol.action(for: request(), from: peerID, context: coord.context)
        guard case .startAndProbe(let stored) = probe else { fail("expected probe, got \(probe)") }
        assert(stored.anchorID == origin, "probe should offer the tracked origin")
        coord.context.current = stored; coord.context.isRealigning = true

        // Peer reports it holds the same anchor.
        let report = peer.receive(stored, from: coordinatorID)
        guard case .startAndReport(_, let reply) = report else { fail("expected report, got \(report)") }
        assert(reply.anchorID == origin, "peer should confirm the same anchor")

        // Coordinator commits to it.
        let commit = coord.receive(reply, from: peerID)
        guard case .commit(_, let anchorID) = commit else { fail("expected commit, got \(commit)") }
        assert(anchorID == origin, "must commit the existing anchor, not a new one")

        // Peer adopts and acknowledges; coordinator finishes.
        let adopt = peer.receive(coord.takeLast(), from: coordinatorID)
        guard case .adoptAndAcknowledge(let adopted, let applied) = adopt else {
            fail("expected adopt, got \(adopt)") }
        assert(adopted == origin)
        assert(peer.finished == true, "peer should finish confirmed")

        let done = coord.receive(applied, from: peerID)
        assert(done == .finishConfirmed, "coordinator should finish confirmed, got \(done)")
        assert(coord.context.sessionOriginID == origin && peer.context.sessionOriginID == origin,
               "both devices must end on the same anchor")
    }

    /// The anchors disagree, so the coordinator mints a replacement and both adopt it.
    static func testReplacementPathWhenAnchorsDisagree() {
        let coordAnchor = UUID(), peerAnchor = UUID(), replacement = UUID()
        var coord = Device(id: coordinatorID, isCoordinator: true, origin: coordAnchor,
                           originTracked: true, tracked: [coordAnchor])
        var peer = Device(id: peerID, isCoordinator: false, origin: peerAnchor,
                          originTracked: true, tracked: [peerAnchor])

        guard case .startAndProbe(let probe) = RealignmentProtocol.action(
            for: request(), from: peerID, context: coord.context) else { fail("probe") }
        coord.context.current = probe; coord.context.isRealigning = true

        // Peer holds a different anchor → reports nil.
        guard case .startAndReport(_, let reply) = peer.receive(probe, from: coordinatorID) else {
            fail("report") }
        assert(reply.anchorID == nil, "peer must not claim an anchor it does not hold")

        // Coordinator decides a replacement is needed.
        let decision = coord.receive(reply, from: peerID)
        guard case .prepareReplacement = decision else { fail("expected prepareReplacement, got \(decision)") }

        let prepare = coord.mintReplacement(replacement)
        assert(prepare.anchorID == replacement)

        // Peer parks it, then resolves the anchor and reports ready.
        guard case .holdForAnchor = peer.receive(prepare, from: coordinatorID) else { fail("hold") }
        guard case .sendReady(_, let ready) = peer.resolve(replacement) else { fail("ready") }
        assert(ready.anchorID == replacement)

        // Coordinator commits; peer adopts; coordinator finishes.
        guard case .commit(_, let committed) = coord.receive(ready, from: peerID) else { fail("commit") }
        assert(committed == replacement)
        guard case .adoptAndAcknowledge(_, let applied) = peer.receive(coord.takeLast(), from: coordinatorID)
        else { fail("adopt") }
        assert(coord.receive(applied, from: peerID) == .finishConfirmed)
        assert(coord.context.sessionOriginID == replacement && peer.context.sessionOriginID == replacement,
               "both must land on the replacement")
    }

    /// The non-coordinator may start it; the coordinator still runs it.
    static func testPeerInitiatedRequestIsServicedByCoordinator() {
        let origin = UUID()
        var (coord, _) = pair(sharedOrigin: origin, tracked: true)
        let action = coord.receive(request(), from: peerID)
        guard case .startAndProbe(let probe) = action else { fail("expected probe, got \(action)") }
        assert(probe.phase == .probe && probe.anchorID == origin)
    }

    // MARK: - Deferred transitions (the ones that need tracking to catch up)

    /// A peer that cannot yet see the replacement must wait, not refuse.
    static func testDeferredPrepareWaitsForLocalTracking() {
        let replacement = UUID()
        var peer = Device(id: peerID, isCoordinator: false, origin: UUID(), originTracked: true)
        let probe = SpaceRealignment(id: UUID(), phase: .probe, anchorID: nil, replaceAnchor: true)
        peer.context.current = probe; peer.context.isRealigning = true

        let prepare = probe.changing(to: .prepare, anchorID: replacement)
        guard case .holdForAnchor(_, let probeLocal) = peer.receive(prepare, from: coordinatorID) else {
            fail("expected hold") }
        assert(probeLocal, "prepare should retry the local anchor immediately")
        assert(peer.outbox.isEmpty, "must not answer ready before it can see the anchor")

        guard case .sendReady = peer.resolve(replacement) else { fail("expected ready after resolve") }
    }

    /// The coordinator must also wait for its own copy to track before committing.
    static func testDeferredReadyWaitsForCoordinatorTracking() {
        let replacement = UUID()
        var coord = Device(id: coordinatorID, isCoordinator: true, origin: UUID(), originTracked: true)
        let prepare = SpaceRealignment(id: UUID(), phase: .prepare, anchorID: replacement, replaceAnchor: true)
        coord.context.current = prepare
        coord.context.replacementAnchorID = replacement      // minted, but not tracked yet

        let ready = prepare.changing(to: .ready, anchorID: replacement)
        guard case .holdForAnchor(_, let probeLocal) = coord.receive(ready, from: peerID) else {
            fail("expected hold while untracked") }
        assert(!probeLocal, "ready only parks the message")
        assert(coord.outbox.isEmpty, "must not commit an anchor it cannot see")

        guard case .commit = coord.resolve(replacement) else { fail("expected commit once tracked") }
    }

    /// Adoption must fail closed: a commit for an anchor this device cannot track is ignored,
    /// leaving the previous origin in place rather than stranding content.
    static func testCommitIsRefusedWhenAnchorIsNotTrackedLocally() {
        let origin = UUID(), replacement = UUID()
        var peer = Device(id: peerID, isCoordinator: false, origin: origin, originTracked: true,
                          tracked: [origin])
        let ready = SpaceRealignment(id: UUID(), phase: .ready, anchorID: replacement, replaceAnchor: true)
        peer.context.current = ready

        let action = peer.receive(ready.changing(to: .commit, anchorID: replacement), from: coordinatorID)
        guard case .ignore(let reason) = action else { fail("expected ignore, got \(action)") }
        assert(reason.contains("not tracked"), reason)
        assert(peer.context.sessionOriginID == origin, "origin must be left untouched")
    }

    // MARK: - Rejections

    /// Each message is set up so it *would* be accepted from the coordinator — otherwise the test
    /// passes on the operation-id guard and proves nothing about who sent it.
    static func testRejectsMessagesFromNonCoordinator() {
        let stranger = UUID(uuidString: "11111111-0000-0000-0000-0000000000CC")!
        let anchor = UUID()
        let op = SpaceRealignment(id: UUID(), phase: .probe, anchorID: anchor, replaceAnchor: true)

        func peerHolding(_ phase: SpaceRealignment.Phase) -> RealignmentContext {
            var peer = Device(id: peerID, isCoordinator: false, origin: anchor, originTracked: true,
                              tracked: [anchor])
            peer.context.nearbyParticipantIDs = [coordinatorID, stranger]
            peer.context.current = op.changing(to: phase, anchorID: anchor)
            peer.context.isRealigning = true
            return peer.context
        }

        // (incoming phase, the state that would make it valid from the coordinator)
        let cases: [(SpaceRealignment.Phase, SpaceRealignment.Phase)] =
            [(.probe, .probe), (.prepare, .probe), (.commit, .ready), (.failed, .probe)]
        for (incoming, held) in cases {
            let context = peerHolding(held)
            let message = op.changing(to: incoming, anchorID: anchor)
            // Sanity: the coordinator *is* allowed to send this in this state.
            if case .ignore(let why) = RealignmentProtocol.action(for: message, from: coordinatorID,
                                                                  context: context) {
                fail("setup is vacuous — coordinator's \(incoming) was refused too: \(why)")
            }
            let action = RealignmentProtocol.action(for: message, from: stranger, context: context)
            guard case .ignore(let reason) = action else {
                fail("\(incoming) from a non-coordinator was accepted: \(action)") }
            assert(reason.contains("not from coordinator"), "\(incoming): \(reason)")
        }
    }

    /// Phases only the coordinator may act on must be refused by the peer. Each context is first
    /// shown to be accepted *as* the coordinator, then offered unchanged to a non-coordinator — so
    /// the role guard is the only thing that can refuse it.
    static func testRejectsCoordinatorOnlyPhasesOnThePeer() {
        let anchor = UUID()
        let op = SpaceRealignment(id: UUID(), phase: .request, anchorID: nil, replaceAnchor: false)
        // (incoming, phase held when it arrives; nil = nothing in flight)
        let cases: [(SpaceRealignment.Phase, SpaceRealignment.Phase?)] =
            [(.request, nil), (.report, .probe), (.ready, .prepare), (.applied, .commit)]
        for (incoming, held) in cases {
            var context = RealignmentContext(
                isCoordinator: true, coordinatorID: coordinatorID,
                nearbyParticipantIDs: [coordinatorID, peerID],
                current: held.map { op.changing(to: $0, anchorID: anchor) },
                isRealigning: held != nil,
                sessionOriginID: anchor, sessionOriginIsTracked: true,
                replacementAnchorID: anchor, trackedAnchorIDs: [anchor])
            let message = op.changing(to: incoming, anchorID: anchor)
            if case .ignore(let why) = RealignmentProtocol.action(for: message, from: peerID, context: context) {
                fail("setup is vacuous — the coordinator refused \(incoming) too: \(why)")
            }
            context.isCoordinator = false
            let action = RealignmentProtocol.action(for: message, from: peerID, context: context)
            guard case .ignore(let reason) = action else {
                fail("a non-coordinator acted on \(incoming): \(action)") }
            assert(reason == "not the coordinator", "\(incoming): \(reason)")
        }
    }

    /// A message from a previous, abandoned operation must not disturb the current one.
    static func testRejectsWrongOperationID() {
        let origin = UUID()
        var coord = Device(id: coordinatorID, isCoordinator: true, origin: origin,
                           originTracked: true, tracked: [origin])
        let live = SpaceRealignment(id: UUID(), phase: .probe, anchorID: origin, replaceAnchor: false)
        coord.context.current = live
        let stale = SpaceRealignment(id: UUID(), phase: .report, anchorID: origin, replaceAnchor: false)
        guard case .ignore = coord.receive(stale, from: peerID) else {
            fail("accepted a report from a different operation") }
        assert(coord.context.current == live, "the live operation must be untouched")
    }

    static func testRejectsReadyNamingAnUnexpectedAnchor() {
        let minted = UUID(), other = UUID()
        var coord = Device(id: coordinatorID, isCoordinator: true, origin: UUID(), originTracked: true,
                           tracked: [minted, other])
        let prepare = SpaceRealignment(id: UUID(), phase: .prepare, anchorID: minted, replaceAnchor: true)
        coord.context.current = prepare
        coord.context.replacementAnchorID = minted

        let action = coord.receive(prepare.changing(to: .ready, anchorID: other), from: peerID)
        guard case .ignore(let reason) = action else { fail("accepted a foreign anchor: \(action)") }
        assert(reason.contains("unexpected anchor"), reason)
    }

    /// `.prepare` is deliberately absent from the commit guard — the peer only reaches commit
    /// through `.ready` or `.probe`. Pin it so a future edit cannot widen it silently.
    static func testRejectsCommitWhilePeerIsStillPreparing() {
        let replacement = UUID()
        var peer = Device(id: peerID, isCoordinator: false, origin: UUID(), originTracked: true,
                          tracked: [replacement])
        let prepare = SpaceRealignment(id: UUID(), phase: .prepare, anchorID: replacement, replaceAnchor: true)
        peer.context.current = prepare

        let action = peer.receive(prepare.changing(to: .commit, anchorID: replacement), from: coordinatorID)
        guard case .ignore(let reason) = action else {
            fail("commit accepted while still preparing: \(action)") }
        assert(reason.contains("phase prepare"), reason)
    }

    static func testRejectsStrangersAndDisabledSessions() {
        let origin = UUID()
        var coord = Device(id: coordinatorID, isCoordinator: true, origin: origin, originTracked: true)
        let message = SpaceRealignment(id: UUID(), phase: .request, anchorID: nil, replaceAnchor: false)

        // Someone who is not a nearby participant.
        guard case .ignore(let r1) = RealignmentProtocol.action(for: message, from: UUID(),
                                                                context: coord.context)
        else { fail("accepted a stranger") }
        assert(r1.contains("nearby"), r1)

        // Realignment unavailable (e.g. the other headset dropped out).
        coord.context.canRealign = false
        guard case .ignore(let r2) = RealignmentProtocol.action(for: message, from: peerID,
                                                                context: coord.context)
        else { fail("accepted while unable to realign") }
        assert(r2.contains("cannot realign"), r2)
    }

    /// A second request arriving while one is in flight must not start an overlapping operation.
    /// (The both-users-tap-at-once case is `testPeerDropsItsOwnRequestWhenTheCoordinatorProbesFirst`.)
    static func testSimultaneousRequestsCollapseToOne() {
        let origin = UUID()
        var coord = Device(id: coordinatorID, isCoordinator: true, origin: origin,
                           originTracked: true, tracked: [origin])
        guard case .startAndProbe = coord.receive(request(), from: peerID) else { fail("first request") }
        let second = coord.receive(request(), from: peerID)
        guard case .ignore(let reason) = second else { fail("second request started a new op: \(second)") }
        assert(reason.contains("already realigning"), reason)
    }

    /// Every phase that depends on the operation already being in a particular phase. Each is
    /// offered in a *wrong but plausible* phase; accepting one skips a step of the handshake.
    static func testRejectsEveryPhaseOutsideItsExpectedPhase() {
        let anchor = UUID()
        let op = SpaceRealignment(id: UUID(), phase: .probe, anchorID: anchor, replaceAnchor: true)

        // (incoming, who receives it, the phases it must be refused in, expected reason fragment)
        let cases: [(SpaceRealignment.Phase, Bool, [SpaceRealignment.Phase], String)] = [
            (.report,  true,  [.report, .prepare, .ready, .commit], "no matching probe"),
            (.prepare, false, [.prepare, .ready, .commit, .request], "prepare outside a probe"),
            (.ready,   true,  [.probe, .ready, .commit, .report],   "ready outside a prepare"),
            (.applied, true,  [.probe, .prepare, .ready, .applied], "applied outside a commit"),
        ]
        for (incoming, toCoordinator, wrongPhases, fragment) in cases {
            for held in wrongPhases {
                var device = Device(id: toCoordinator ? coordinatorID : peerID,
                                    isCoordinator: toCoordinator, origin: anchor,
                                    originTracked: true, tracked: [anchor])
                device.context.current = op.changing(to: held, anchorID: anchor)
                device.context.replacementAnchorID = anchor
                device.context.isRealigning = true
                let action = RealignmentProtocol.action(for: op.changing(to: incoming, anchorID: anchor),
                                                        from: toCoordinator ? peerID : coordinatorID,
                                                        context: device.context)
                guard case .ignore(let reason) = action else {
                    fail("\(incoming) was accepted while in phase \(held): \(action)") }
                assert(reason.contains(fragment), "\(incoming) in \(held): \(reason)")
            }
        }
    }

    /// The operation id is what separates a live handshake from a stale or abandoned one. Each
    /// message is valid in every respect except its id, and is first shown to be accepted with
    /// the right one — so only the id guard can be what refuses it.
    static func testRejectsEveryPhaseForAnotherOperation() {
        let anchor = UUID()
        let live = SpaceRealignment(id: UUID(), phase: .probe, anchorID: anchor, replaceAnchor: true)
        // (incoming, receiver is coordinator, phase the receiver holds)
        let cases: [(SpaceRealignment.Phase, Bool, SpaceRealignment.Phase)] = [
            (.report, true, .probe), (.prepare, false, .probe), (.ready, true, .prepare),
            (.commit, false, .ready), (.applied, true, .commit), (.failed, false, .probe),
        ]
        for (incoming, toCoordinator, held) in cases {
            var device = Device(id: toCoordinator ? coordinatorID : peerID, isCoordinator: toCoordinator,
                                origin: anchor, originTracked: true, tracked: [anchor])
            device.context.current = live.changing(to: held, anchorID: anchor)
            device.context.replacementAnchorID = anchor
            device.context.isRealigning = true
            let sender = toCoordinator ? peerID : coordinatorID

            let genuine = live.changing(to: incoming, anchorID: anchor)
            if case .ignore(let why) = RealignmentProtocol.action(for: genuine, from: sender,
                                                                  context: device.context) {
                fail("setup is vacuous — the genuine \(incoming) was refused: \(why)")
            }
            let stale = SpaceRealignment(id: UUID(), phase: incoming, anchorID: anchor, replaceAnchor: true)
            let action = RealignmentProtocol.action(for: stale, from: sender, context: device.context)
            guard case .ignore = action else {
                fail("\(incoming) for a different operation was accepted: \(action)") }
        }
    }

    /// Holding the probe's anchor ID is not enough — the peer must be *tracking* it. Reporting an
    /// untracked anchor would let the coordinator confirm an origin this headset cannot place.
    static func testPeerReportsNothingForAnAnchorItCannotTrack() {
        let origin = UUID()
        var peer = Device(id: peerID, isCoordinator: false, origin: origin, originTracked: false)
        let probe = SpaceRealignment(id: UUID(), phase: .probe, anchorID: origin, replaceAnchor: false)
        guard case .startAndReport(_, let reply) = peer.receive(probe, from: coordinatorID) else {
            fail("report") }
        assert(reply.anchorID == nil, "must not vouch for an untracked anchor")
    }

    /// The same-anchor short-circuit needs three things at once: the report names the anchor the
    /// probe offered, the coordinator's origin still *is* that anchor, and it is tracked. Losing
    /// any one must fall through to a replacement — otherwise the coordinator "confirms" an
    /// anchor one side is not actually on.
    static func testReportOnlyShortCircuitsWhenBothSidesReallyShareTheAnchor() {
        let anchor = UUID(), other = UUID()
        func decide(probeAnchor: UUID?, origin: UUID, tracked: Bool) -> RealignmentAction {
            var coord = Device(id: coordinatorID, isCoordinator: true, origin: origin,
                               originTracked: tracked, tracked: tracked ? [origin] : [])
            let probe = SpaceRealignment(id: UUID(), phase: .probe, anchorID: probeAnchor,
                                         replaceAnchor: false)
            coord.context.current = probe
            return RealignmentProtocol.action(for: probe.changing(to: .report, anchorID: anchor),
                                              from: peerID, context: coord.context)
        }
        // All three hold → commit, so the three refusals below are attributable.
        guard case .commit = decide(probeAnchor: anchor, origin: anchor, tracked: true) else {
            fail("baseline same-anchor report did not commit") }

        for (label, action) in [
            ("the probe offered no anchor", decide(probeAnchor: nil, origin: anchor, tracked: true)),
            ("the coordinator lost tracking", decide(probeAnchor: anchor, origin: anchor, tracked: false)),
            ("the coordinator's origin moved on", decide(probeAnchor: anchor, origin: other, tracked: true)),
        ] {
            guard case .prepareReplacement = action else {
                fail("committed although \(label): \(action)") }
        }
    }

    /// The coordinator's own replacement anchor resolves locally almost immediately — long before
    /// the peer has seen it. That must not commit (the peer has not said `ready`), and the
    /// coordinator must not send itself a `ready` either.
    static func testCoordinatorsOwnAnchorResolvingDoesNotAdvance() {
        let replacement = UUID()
        var coord = Device(id: coordinatorID, isCoordinator: true, origin: UUID(), originTracked: true)
        let prepare = SpaceRealignment(id: UUID(), phase: .prepare, anchorID: replacement,
                                       replaceAnchor: true)
        coord.context.current = prepare
        coord.context.replacementAnchorID = replacement

        let action = coord.resolve(replacement)
        guard case .ignore = action else {
            fail("coordinator advanced on its own anchor before the peer was ready: \(action)") }
        assert(coord.outbox.isEmpty && coord.context.current == prepare)
    }

    /// With no elected coordinator there is nobody to send `ready` to; the peer must keep waiting
    /// rather than move to `.ready` with the message undelivered.
    static func testPeerCannotAnswerReadyWithoutACoordinator() {
        let replacement = UUID()
        var context = RealignmentContext(isCoordinator: false, coordinatorID: nil)
        context.current = SpaceRealignment(id: UUID(), phase: .prepare, anchorID: replacement,
                                           replaceAnchor: true)
        guard case .ignore = RealignmentProtocol.anchorResolved(replacement, isTracked: true,
                                                                context: context) else {
            fail("peer moved to ready with no coordinator to tell") }
        context.coordinatorID = coordinatorID
        guard case .sendReady = RealignmentProtocol.anchorResolved(replacement, isTracked: true,
                                                                   context: context) else {
            fail("baseline: peer should answer ready once a coordinator exists") }
    }

    /// A `prepare` with no anchor would park the peer forever waiting on an anchor that was never
    /// named — the handshake would only end on the coordinator's timeout.
    static func testRejectsPrepareWithoutAnAnchor() {
        var peer = Device(id: peerID, isCoordinator: false, origin: UUID(), originTracked: true)
        let probe = SpaceRealignment(id: UUID(), phase: .probe, anchorID: nil, replaceAnchor: true)
        peer.context.current = probe
        let action = peer.receive(probe.changing(to: .prepare), from: coordinatorID)
        guard case .ignore(let reason) = action else { fail("accepted an anchorless prepare: \(action)") }
        assert(reason.contains("without an anchor"), reason)
    }

    static func testRejectsCommitAndFailedForTheWrongOperation() {
        let anchor = UUID(), other = UUID()
        var peer = Device(id: peerID, isCoordinator: false, origin: anchor, originTracked: true,
                          tracked: [anchor, other])
        let live = SpaceRealignment(id: UUID(), phase: .ready, anchorID: anchor, replaceAnchor: true)
        peer.context.current = live

        // Wrong operation id.
        let alien = SpaceRealignment(id: UUID(), phase: .commit, anchorID: anchor, replaceAnchor: true)
        guard case .ignore(let r1) = peer.receive(alien, from: coordinatorID) else {
            fail("accepted a commit from another operation") }
        assert(r1.contains("unknown operation"), r1)

        // Right operation, different anchor than the one this device agreed to.
        guard case .ignore(let r2) = peer.receive(live.changing(to: .commit, anchorID: other),
                                                  from: coordinatorID) else {
            fail("accepted a commit naming a different anchor") }
        assert(r2.contains("different anchor"), r2)

        // `failed` for an operation we never started.
        guard case .ignore(let r3) = peer.receive(alien.changing(to: .failed), from: coordinatorID) else {
            fail("accepted a failed for an unknown operation") }
        assert(r3.contains("unknown operation"), r3)
        assert(peer.context.current == live, "the live operation must survive all three")
    }

    /// `applied` is the peer saying "I adopted it too". The coordinator must only believe it if its
    /// own origin really is that anchor and tracked — otherwise it reports success on a split.
    static func testRejectsAppliedTheCoordinatorCannotBack() {
        let anchor = UUID(), other = UUID()
        func coordinator(origin: UUID?, tracked: Bool) -> RealignmentContext {
            var c = Device(id: coordinatorID, isCoordinator: true, origin: origin,
                           originTracked: tracked, tracked: tracked && origin != nil ? [origin!] : [])
            c.context.current = SpaceRealignment(id: UUID(), phase: .commit, anchorID: anchor,
                                                 replaceAnchor: true)
            return c.context
        }
        for (origin, tracked, label) in [(other, true, "a different anchor"),
                                         (anchor, false, "an untracked anchor"),
                                         (UUID?.none, false, "no origin at all")] {
            var context = coordinator(origin: origin, tracked: tracked)
            let applied = context.current!.changing(to: .applied, anchorID: anchor)
            guard case .ignore(let reason) = RealignmentProtocol.action(for: applied, from: peerID,
                                                                        context: context) else {
                fail("coordinator confirmed with \(label)") }
            assert(reason.contains("not tracking"), "\(label): \(reason)")
            context.current = nil
        }
    }

    /// A lossy link redelivers messages. A phase replayed after the handshake has moved on must be
    /// a no-op, not a step backwards.
    static func testRejectsReplayedPhases() {
        let origin = UUID()
        var (coord, peer) = pair(sharedOrigin: origin, tracked: true)
        guard case .startAndProbe(let probe) = coord.receive(request(), from: peerID) else { fail("probe") }
        guard case .startAndReport(_, let report) = peer.receive(probe, from: coordinatorID) else { fail("report") }
        guard case .commit(_, _) = coord.receive(report, from: peerID) else { fail("commit") }
        let commit = coord.takeLast()

        // The peer's own report, redelivered after the coordinator already committed.
        guard case .ignore = coord.receive(report, from: peerID) else { fail("replayed report advanced the coordinator") }

        guard case .adoptAndAcknowledge(_, let applied) = peer.receive(commit, from: coordinatorID)
        else { fail("adopt") }
        // The commit, redelivered after the peer finished: nothing in flight any more.
        guard case .ignore(let reason) = peer.receive(commit, from: coordinatorID) else {
            fail("replayed commit restarted a finished operation") }
        assert(reason.contains("unknown operation"), reason)

        assert(coord.receive(applied, from: peerID) == .finishConfirmed)
        guard case .ignore = coord.receive(applied, from: peerID) else { fail("replayed applied") }
    }

    /// Both users tap at once: the peer has already sent its own `request` and is holding it when
    /// the coordinator's probe for *its* operation arrives. The probe wins — otherwise the two
    /// devices run two operations and each ignores the other's.
    static func testPeerDropsItsOwnRequestWhenTheCoordinatorProbesFirst() {
        let origin = UUID()
        var peer = Device(id: peerID, isCoordinator: false, origin: origin, originTracked: true,
                          tracked: [origin])
        let mine = request()
        peer.context.current = mine            // our own request, awaiting a probe
        peer.context.isRealigning = true

        let theirs = request().changing(to: .probe, anchorID: origin)
        let action = peer.receive(theirs, from: coordinatorID)
        guard case .startAndReport(let store, let reply) = action else {
            fail("peer refused the coordinator's probe while holding its own request: \(action)") }
        assert(store.id == theirs.id && reply.id == theirs.id,
               "the peer must switch to the coordinator's operation, not answer for its own")
        assert(peer.context.current?.id == theirs.id)
    }

    /// `anchorResolved` fires for every anchor ARKit updates, so everything but the two deferred
    /// transitions must be a silent no-op.
    static func testAnchorResolvedIgnoresEverythingElse() {
        let anchor = UUID(), unrelated = UUID()
        var context = RealignmentContext(isCoordinator: false, coordinatorID: coordinatorID)

        // Nothing in flight.
        guard case .ignore = RealignmentProtocol.anchorResolved(anchor, isTracked: true, context: context)
        else { fail("advanced with no operation") }

        context.current = SpaceRealignment(id: UUID(), phase: .prepare, anchorID: anchor, replaceAnchor: true)
        // Some other anchor resolved.
        guard case .ignore(let r1) = RealignmentProtocol.anchorResolved(unrelated, isTracked: true,
                                                                        context: context)
        else { fail("advanced on an unrelated anchor") }
        assert(r1.contains("not this operation"), r1)
        // Ours, but not tracked yet.
        guard case .ignore(let r2) = RealignmentProtocol.anchorResolved(anchor, isTracked: false,
                                                                        context: context)
        else { fail("advanced on an untracked anchor") }
        assert(r2.contains("not tracked"), r2)
        // Ours and tracked, but in a phase with nothing to do.
        context.current = context.current!.changing(to: .commit, anchorID: anchor)
        guard case .ignore(let r3) = RealignmentProtocol.anchorResolved(anchor, isTracked: true,
                                                                        context: context)
        else { fail("advanced from .commit") }
        assert(r3.contains("nothing to advance"), r3)
        // The peer must not take the coordinator's `.ready` → commit transition.
        context.current = context.current!.changing(to: .ready, anchorID: anchor)
        guard case .ignore = RealignmentProtocol.anchorResolved(anchor, isTracked: true, context: context)
        else { fail("a non-coordinator committed on its own") }
    }

    /// **Pinned, not endorsed.** Commit is not atomic: the coordinator adopts the anchor before it
    /// sends `commit`, so a peer that answered `ready` and then lost tracking refuses the commit
    /// and the handshake ends with the two headsets on *different* origins. Nothing in the
    /// handshake rolls the coordinator back. (Outside the handshake, the coordinator's 1 s origin
    /// re-announce should bring the peer over once the operation has timed out — that path is in
    /// the manager and is not exercised here.) This records the behaviour so a deliberate change
    /// is visible; it does not assert it is right. Not reproduced on two headsets.
    static func testCommitIsNotAtomic() {
        let coordAnchor = UUID(), peerAnchor = UUID(), replacement = UUID()
        var coord = Device(id: coordinatorID, isCoordinator: true, origin: coordAnchor,
                           originTracked: true, tracked: [coordAnchor, replacement])
        var peer = Device(id: peerID, isCoordinator: false, origin: peerAnchor,
                          originTracked: true, tracked: [peerAnchor])
        coord.context.replacementAnchorID = replacement
        let prepare = SpaceRealignment(id: UUID(), phase: .prepare, anchorID: replacement,
                                       replaceAnchor: true)
        coord.context.current = prepare
        peer.context.current = prepare.changing(to: .probe)

        // The peer goes through the real path to `.ready`…
        guard case .holdForAnchor = peer.receive(prepare, from: coordinatorID) else { fail("hold") }
        guard case .sendReady(_, let ready) = peer.resolve(replacement) else { fail("ready") }
        assert(peer.context.current?.phase == .ready)
        // …then loses tracking of the anchor before the commit arrives.
        peer.context.trackedAnchorIDs.remove(replacement)

        guard case .commit = coord.receive(ready, from: peerID) else { fail("commit") }
        assert(coord.context.sessionOriginID == replacement, "coordinator adopts before sending")

        guard case .ignore(let reason) = peer.receive(coord.takeLast(), from: coordinatorID) else {
            fail("peer adopted an anchor it cannot track") }
        assert(reason == "commit anchor is not tracked locally", reason)
        assert(peer.context.sessionOriginID == peerAnchor, "peer keeps its old origin")
        assert(peer.outbox.count == 1, "no `applied` is sent, so the coordinator can only time out")
        assert(coord.context.sessionOriginID != peer.context.sessionOriginID,
               "pinned: the handshake itself can end with the two devices on different origins")
    }

    static func testFailedFromCoordinatorEndsIt() {
        let op = SpaceRealignment(id: UUID(), phase: .probe, anchorID: nil, replaceAnchor: false)
        var peer = Device(id: peerID, isCoordinator: false, origin: UUID())
        peer.context.current = op
        assert(peer.receive(op.changing(to: .failed), from: coordinatorID) == .finishFailed)
        assert(peer.finished == false && peer.context.current == nil)
    }

    // MARK: - Value semantics

    /// `changing(to:)` defaults `anchorID` to nil, so a transition *drops* the anchor unless it is
    /// re-passed. Every call site depends on that; pin it so the default cannot be "fixed" into
    /// carrying the old anchor, which would let a stale anchor ride along into a new phase.
    static func testChangingPreservesIdentityAndResetsAnchor() {
        let id = UUID(), anchor = UUID()
        let original = SpaceRealignment(id: id, phase: .probe, anchorID: anchor, replaceAnchor: true)

        let dropped = original.changing(to: .failed)
        assert(dropped.id == id && dropped.replaceAnchor, "identity and intent must survive")
        assert(dropped.anchorID == nil, "anchorID must reset unless passed explicitly")

        let kept = original.changing(to: .commit, anchorID: anchor)
        assert(kept.anchorID == anchor && kept.phase == .commit)
    }

    /// The probe offers the current origin only when it is usable and no replacement was asked for.
    static func testProbeOffersOriginOnlyWhenUsable() {
        let origin = UUID()
        var ctx = RealignmentContext(isCoordinator: true, sessionOriginID: origin,
                                     sessionOriginIsTracked: true)
        assert(RealignmentProtocol.probeAnchor(for: request(), context: ctx) == origin)

        // Explicit "Replace Shared Anchor" must never reuse the current one.
        assert(RealignmentProtocol.probeAnchor(for: request(replace: true), context: ctx) == nil,
               "replaceAnchor must force a new anchor")

        // An untracked origin is not worth offering.
        ctx.sessionOriginIsTracked = false
        assert(RealignmentProtocol.probeAnchor(for: request(), context: ctx) == nil,
               "an untracked origin must not be offered")
    }

    static func fail(_ message: String) -> Never {
        fatalError("RealignmentTests: \(message)")
    }
}
