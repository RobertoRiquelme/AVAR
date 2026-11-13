import Foundation
import MultipeerConnectivity
import Combine
import simd

/// Drives `CollaborativeSessionManager` through its real receive path.
///
/// Messages go in through the Multipeer delegate method, which is the same door a live peer
/// uses, so decoding, bookkeeping and the publishers the views listen to are all exercised.
/// What this cannot show is delivery itself — that needs two devices.
@main
struct ReceivePathTests {
    @MainActor static func main() async {
        testAddRemoveAndReAdd()
        testClientSideClose()
        testOldBuildPeerIsFlagged()
        testWithdrawRemovesOnlyThisDevicesDiagrams()
        testNodeMoveReachesTheViewAndTheModelInDataCoordinates()
        testNodeMoveFromAnOlderPeerLeavesTheModelAlone()
        testOwnerReceivesAPeersNodeMove()
        testSendingANodeMoveRecordsDataCoordinates()
        testEveryBundledDiagramFitsSharePlayAndSurvivesFraming()
        testALargeDiagramArrivesThroughFrames()
        await testWaitingForSendsIsBounded()
        print("ReceivePathTests ✅")
    }

    @MainActor final class Rig {
        let manager = CollaborativeSessionManager()
        let service = MultipeerConnectivityService()
        let peer = MCPeerID(displayName: "host")
        var removals: [String] = []
        var moves: [ElementPositionMessage] = []
        private var bag: Set<AnyCancellable> = []

        init() {
            manager.receivedDiagramRemoval.sink { [unowned self] in self.removals.append($0) }.store(in: &bag)
            manager.receivedElementMove.sink { [unowned self] in self.moves.append($0) }.store(in: &bag)
        }

        func position(of elementId: String, in filename: String) -> [Double]? {
            manager.sharedDiagrams.first { $0.filename == filename }?
                .elements.first { $0.id == elementId }?.position
        }

        func deliver(_ envelope: SharedSpaceEnvelope) {
            deliver(raw: try! JSONEncoder().encode(envelope))
        }

        func deliver(raw data: Data) {
            manager.multipeerService(service, didReceiveData: data, from: peer)
        }

        var ids: [UUID] { manager.sharedDiagrams.map(\.id) }
    }

    /// The reported bug: the host removed a diagram and the client kept showing it.
    @MainActor static func testAddRemoveAndReAdd() {
        let rig = Rig()
        let d = SharedDiagram(filename: "A", elements: [], is2D: false)
        rig.deliver(.diagram(d))
        assert(rig.ids == [d.id], "diagram from host appears on client")
        assert(!rig.manager.isLocallyShared(d), "client does not treat it as its own")

        rig.deliver(.remove(RemoveDiagramMessage(filename: "A", diagramID: d.id)))
        assert(rig.ids.isEmpty, "host remove clears it on client")
        assert(rig.removals == ["A"], "client is told to close the view")

        // A snapshot of the same instance that was already in flight must not reopen it.
        rig.deliver(.diagram(d))
        assert(rig.ids.isEmpty, "late copy of a removed instance must not reopen it")

        // The host adding the same file again is a new instance and must work.
        let d2 = SharedDiagram(filename: "A", elements: [], is2D: false)
        rig.deliver(.diagram(d2))
        assert(rig.ids == [d2.id], "re-adding the same file later works")

        rig.deliver(.remove(RemoveDiagramMessage(filename: "A", diagramID: d.id)))
        assert(rig.ids == [d2.id], "a stale remove for the old instance leaves the new one")

        rig.deliver(.remove(RemoveDiagramMessage(filename: "A")))
        assert(rig.ids.isEmpty, "a remove without an id still removes by filename")

        // Messages can overtake each other: the remove for a diagram arrives before the diagram
        // itself. The diagram must still not open when it finally turns up.
        let late = SharedDiagram(filename: "L", elements: [], is2D: false)
        rig.deliver(.remove(RemoveDiagramMessage(filename: "L", diagramID: late.id)))
        rig.deliver(.diagram(late))
        assert(rig.ids.isEmpty, "a diagram whose removal arrived first must not open")
    }

    @MainActor static func testClientSideClose() {
        let rig = Rig()
        let d = SharedDiagram(filename: "B", elements: [], is2D: false)
        rig.deliver(.diagram(d))
        rig.manager.removeDiagram(filename: "B")
        assert(rig.ids.isEmpty, "client-side close forgets the diagram")
        rig.deliver(.diagram(d))
        assert(rig.ids.isEmpty, "a resend from the host does not bring it back")
    }

    /// A pose relative to a room anchor only comes from a build that predates the shared-space
    /// frame. It must be flagged, and the diagram must still be shown rather than hidden.
    @MainActor static func testOldBuildPeerIsFlagged() {
        let rig = Rig()
        rig.deliver(.diagram(SharedDiagram(filename: "S", elements: [], is2D: false,
                                           anchorRelativePosition: [0, 1, -1])))
        assert(!rig.manager.peerUsesAnchorFrame, "scene-frame poses raise no warning")

        let old = SharedDiagram(filename: "C", elements: [], is2D: false,
                                anchorRelativePosition: [0, 1, -1], poseAnchorID: UUID())
        rig.deliver(.diagram(old))
        assert(rig.manager.peerUsesAnchorFrame, "an anchor-relative pose marks the peer as an old build")
        assert(rig.ids.contains(old.id), "its diagram is still shown")
    }

    // MARK: Node moves

    static func nodes() -> [ElementDTO] {
        let json = #"[{"id":"a","type":"node","position":[0,0,0]},{"id":"b","type":"node","position":[100,200,300]}]"#
        return try! JSONDecoder().decode([ElementDTO].self, from: Data(json.utf8))
    }

    /// A peer's node drag must reach the open view (to move the live node) and land in the model
    /// in the diagram's data coordinates — not the container-local value, which every rebuild
    /// would normalise a second time.
    @MainActor static func testNodeMoveReachesTheViewAndTheModelInDataCoordinates() {
        let rig = Rig()
        rig.deliver(.diagram(SharedDiagram(filename: "G", elements: nodes(), is2D: false)))
        rig.deliver(.elementMoved(ElementPositionMessage(filename: "G", elementId: "b",
                                                         localPosition: [0.25, 0.5, -0.1],
                                                         dataPosition: [150, 250, 350])))
        assert(rig.moves.count == 1 && rig.moves[0].elementId == "b", "the view is told to move the node")
        assert(rig.moves[0].dataPosition == [150, 250, 350])
        assert(rig.position(of: "b", in: "G") == [150, 250, 350], "model holds data coordinates, got \(String(describing: rig.position(of: "b", in: "G")))")
        assert(rig.position(of: "a", in: "G") == [0, 0, 0], "other nodes untouched")

        // A move for a diagram we do not have is dropped without telling any view.
        rig.deliver(.elementMoved(ElementPositionMessage(filename: "nope", elementId: "b", localPosition: [0, 0, 0])))
        assert(rig.moves.count == 1)
    }

    /// A message without data coordinates (an older build) still moves the live node, but must
    /// not write its container-local position into the model.
    @MainActor static func testNodeMoveFromAnOlderPeerLeavesTheModelAlone() {
        let rig = Rig()
        rig.deliver(.diagram(SharedDiagram(filename: "G", elements: nodes(), is2D: false)))
        // An older build's message is exactly this build's message without the new key, so
        // encode one with no data coordinates and confirm the key really is absent on the wire.
        let legacy = try! JSONEncoder().encode(SharedSpaceEnvelope.elementMoved(
            ElementPositionMessage(filename: "G", elementId: "b", localPosition: [0.25, 0.5, -0.1])))
        assert(!String(decoding: legacy, as: UTF8.self).contains("dataPosition"), "nil must not be encoded")

        rig.deliver(raw: legacy)
        assert(rig.moves.count == 1 && rig.moves[0].dataPosition == nil, "the live node is still moved")
        assert(rig.position(of: "b", in: "G") == [100, 200, 300], "model must keep its data coordinates")
    }

    /// The other direction: this device owns the diagram and a peer drags one of its nodes.
    @MainActor static func testOwnerReceivesAPeersNodeMove() {
        #if os(visionOS)
        let rig = Rig()
        rig.manager.shareDiagram(filename: "mine", elements: nodes())
        rig.deliver(.elementMoved(ElementPositionMessage(filename: "mine", elementId: "a",
                                                         localPosition: [0, 0, 0], dataPosition: [5, 6, 7])))
        assert(rig.moves.count == 1, "the owner's view is told as well")
        assert(rig.position(of: "a", in: "mine") == [5, 6, 7])
        #endif
    }

    @MainActor static func testSendingANodeMoveRecordsDataCoordinates() {
        #if os(visionOS)
        let rig = Rig()
        rig.manager.shareDiagram(filename: "mine", elements: nodes())
        rig.manager.updateElementPosition(filename: "mine", elementId: "b",
                                          localPosition: [0.9, 0.9, 0.9], dataPosition: [1, 2, 3])
        assert(rig.position(of: "b", in: "mine") == [1, 2, 3], "sender's model holds data coordinates")
        assert(rig.moves.isEmpty, "a local move is not echoed back to the local view")

        rig.manager.updateElementPosition(filename: "mine", elementId: "b", localPosition: [0.1, 0.1, 0.1])
        assert(rig.position(of: "b", in: "mine") == [1, 2, 3], "without data coordinates the model is left alone")
        #endif
    }

    /// Exit waits for queued removals before leaving SharePlay. That wait must end by itself: a
    /// send that never returns must not leave the Exit button dead.
    @MainActor static func testWaitingForSendsIsBounded() async {
        let clock = ContinuousClock()

        let stuck = Task<Void, Never> { try? await Task.sleep(for: .seconds(600)) }
        let started = clock.now
        await CollaborativeSessionManager.wait(for: stuck, upTo: .milliseconds(200))
        let waited = clock.now - started
        assert(waited >= .milliseconds(150) && waited < .seconds(5), "a stuck send must be given up on, waited \(waited)")
        assert(!stuck.isCancelled, "the send itself is left running, not cancelled")
        stuck.cancel()

        let quick = Task<Void, Never> {}
        let startedQuick = clock.now
        await CollaborativeSessionManager.wait(for: quick, upTo: .seconds(30))
        assert(clock.now - startedQuick < .seconds(5), "a finished queue must not wait out the timeout")
    }

    // MARK: Large diagrams

    /// SharePlay's documented message limit. Frames are held far below it because the limit is on
    /// the encoded message and the messenger's encoding of `Data` is not documented.
    static let sharePlayLimit = 256 * 1024

    static func bundledDiagrams() -> [(name: String, output: ScriptOutput)] {
        guard let dir = ProcessInfo.processInfo.environment["AVAR2_RESOURCES"] else {
            fatalError("AVAR2_RESOURCES must point at AVAR2/Resources")
        }
        let files = try! FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".txt") }.sorted()
        return files.compactMap { file in
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let output = try? JSONDecoder().decode(ScriptOutput.self, from: data) else { return nil }
            return (String(file.dropLast(4)), output)
        }
    }

    static func envelope(_ name: String, _ output: ScriptOutput) -> Data {
        try! JSONEncoder().encode(SharedSpaceEnvelope.diagram(
            SharedDiagram(filename: name, elements: output.elements, is2D: output.is2D,
                          anchorRelativePosition: [0, 1, -1],
                          anchorRelativeOrientation: simd_quatf(angle: 0.3, axis: [0, 1, 0]),
                          anchorRelativeScale: 0.7)))
    }

    /// The bundled "3000" example is a byte-for-byte copy of the 1000-node one, so build a real
    /// one: three copies of it with distinct ids.
    static func threeThousandNodeDiagram() -> ScriptOutput {
        guard let base = bundledDiagrams().first(where: { $0.name == "Ejemplo03-1000" })?.output else {
            fatalError("Ejemplo03-1000 is missing")
        }
        // `ElementDTO.id` is immutable, so rename through JSON: ids, and the edge endpoints
        // that refer to them.
        let objects = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(base.elements)) as! [[String: Any]]
        var renamed: [[String: Any]] = []
        for copy in 0..<3 {
            for var object in objects {
                for key in ["id", "from_id", "to_id", "from", "to"] {
                    if let value = object[key] as? String { object[key] = "\(copy)-\(value)" }
                    else if let value = object[key] as? Int { object[key] = "\(copy)-\(value)" }
                }
                renamed.append(object)
            }
        }
        let elements = try! JSONDecoder().decode([ElementDTO].self, from: JSONSerialization.data(withJSONObject: renamed))
        assert(elements.count == base.elements.count * 3)
        assert(Set(elements.compactMap(\.id)).count == elements.compactMap(\.id).count, "ids must be distinct")
        return ScriptOutput(elements: elements, is2D: base.is2D)
    }

    /// What actually goes to the messenger for each bundled diagram: every message stays far
    /// under the limit, and the receiver gets the envelope back byte for byte.
    @MainActor static func testEveryBundledDiagramFitsSharePlayAndSurvivesFraming() {
        var diagrams = bundledDiagrams()
        assert(diagrams.count >= 30, "expected the bundled examples, found \(diagrams.count)")
        diagrams.append(("synthetic-3000", threeThousandNodeDiagram()))

        var framedNames: [String] = []
        for (name, output) in diagrams {
            let payload = envelope(name, output)
            let frames = PayloadFraming.frames(for: payload)
            assert(!frames.isEmpty, "\(name) produced nothing to send")
            let largest = frames.map(\.count).max()!
            assert(largest <= PayloadFraming.maxFrameSize, "\(name): a \(largest)-byte message")
            assert(largest * 4 / 3 < sharePlayLimit * 3 / 4, "\(name): too close to the limit even before overhead")

            if frames.count == 1, !PayloadFraming.isFrame(frames[0]) {
                assert(frames[0] == payload, "\(name) fits and must be sent untouched")
                continue
            }
            framedNames.append("\(name)×\(frames.count)")
            var reassembler = PayloadReassembler()
            var result = PayloadReassembler.Outcome.incomplete
            for frame in frames.reversed() { result = reassembler.receive(frame, from: PayloadReassembler.unknownSender) }
            assert(result == .complete(payload), "\(name) did not come back intact")
        }
        // The diagrams that used to be too large must be among those now framed.
        assert(framedNames.contains { $0.hasPrefix("Ejemplo03-1000") }, "framed: \(framedNames)")
        assert(framedNames.contains { $0.hasPrefix("synthetic-3000") }, "framed: \(framedNames)")
        let synthetic = envelope("synthetic-3000", threeThousandNodeDiagram())
        assert(synthetic.count > sharePlayLimit, "the synthetic diagram must be one that could not be sent whole")
        assert(PayloadFraming.frames(for: synthetic).count > 1, "…and must need more than one frame even compressed")
        print("  framed for SharePlay: \(framedNames.joined(separator: ", "))")
    }

    /// End to end through the manager: frames of a large diagram, out of order, become one
    /// diagram with every element — and nothing appears before the last frame.
    @MainActor static func testALargeDiagramArrivesThroughFrames() {
        let rig = Rig()
        let output = threeThousandNodeDiagram()
        let frames = PayloadFraming.frames(for: envelope("big", output))
        assert(frames.count > 1)

        let shuffled = Array(frames.dropFirst()) + [frames[0]]
        for frame in shuffled.dropLast() {
            rig.deliver(raw: frame)
            assert(rig.manager.sharedDiagrams.isEmpty, "nothing may appear from a partial payload")
        }
        rig.deliver(raw: shuffled.last!)
        assert(rig.manager.sharedDiagrams.count == 1, "the diagram appears once the last frame is in")
        assert(rig.manager.sharedDiagrams[0].elements.count == output.elements.count, "with every element")
        assert(rig.manager.sharedDiagrams[0].filename == "big")
        assert(rig.manager.envelopeStats["undecodable"] == nil, "a frame must never be handed on as if it were a message")

        // A damaged frame is reported and ignored; it must not take the session down with it.
        var damaged = frames[0]
        damaged[21] = 0xFF; damaged[22] = 0xFF
        rig.deliver(raw: damaged)
        assert(rig.manager.sharedDiagrams.count == 1)
        assert(rig.manager.envelopeStats.keys.contains { $0.hasPrefix("frame rejected") }, "a rejected frame is visible in the traffic stats")
    }

    /// Leaving the immersive space withdraws what this device shared — and nothing else. A
    /// participant's exit must not delete other people's diagrams for everyone.
    @MainActor static func testWithdrawRemovesOnlyThisDevicesDiagrams() {
        let rig = Rig()
        let theirs = SharedDiagram(filename: "theirs", elements: [], is2D: false)
        rig.deliver(.diagram(theirs))
        #if os(visionOS)
        rig.manager.shareDiagram(filename: "mine-1", elements: [])
        rig.manager.shareDiagram(filename: "mine-2", elements: [])
        assert(rig.manager.sharedDiagrams.count == 3)
        let removesBefore = rig.manager.envelopeStats["remove"]?.sent ?? 0

        rig.manager.withdrawLocalDiagrams()
        assert(rig.ids == [theirs.id], "only this device's diagrams are withdrawn")
        // The counter is bumped when a message is queued, so this shows which removals were
        // attempted (two, both ours) — not that a transport delivered them.
        assert((rig.manager.envelopeStats["remove"]?.sent ?? 0) - removesBefore == 2,
               "one removal per local diagram, none for the received one")

        // The same file can be shared again afterwards; a stale entry used to block this.
        rig.manager.shareDiagram(filename: "mine-1", elements: [])
        assert(rig.manager.sharedDiagrams.contains { $0.filename == "mine-1" }, "re-sharing after withdrawal works")
        #endif
    }
}
