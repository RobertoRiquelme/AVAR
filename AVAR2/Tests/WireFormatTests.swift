import Foundation
import simd

/// Tests for everything that crosses the wire between participants.
///
/// The headline test is `testSessionOriginMessageCarriesNoTransform`, which enforces the
/// project's governing invariant: **a `WorldAnchor`'s transform must never be transmitted between
/// visionOS devices, only its UUID.** Transmitting it overwrites each peer's correct local value
/// with a meaningless foreign one, which is precisely what made diagrams appear scattered. That
/// invariant is easy to re-break with a well-meaning "just include the transform too" change, so
/// it is asserted here rather than only documented.
@main
struct WireFormatTests {
    static func main() {
        testSessionOriginMessageCarriesNoTransform()
        testSessionOriginRoundTrip()
        testEnvelopeRoundTripForEveryCase()
        testEnvelopeKindsAreUniqueAndStable()
        testSharedDiagramPreservesIs2D()
        testSharedDiagramIs2DBackCompatWhenKeyAbsent()
        testSharedDiagramTransformRoundTrip()
        testScriptOutputMemberwiseInit()
        testScriptOutputDecodesAllFourFormats()
        print("WireFormatTests ✅")
    }

    // MARK: - The invariant

    /// Encodes a `SessionOriginMessage` and asserts the JSON contains no 4x4 matrix, no float
    /// array, and no transform-ish key. A regression here means alignment is broken again.
    static func testSessionOriginMessageCarriesNoTransform() {
        let message = SessionOriginMessage(anchorID: UUID(), ownerParticipantID: UUID())
        let data = try! JSONEncoder().encode(message)
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Only these two keys, ever.
        assert(Set(object.keys) == ["anchorID", "ownerParticipantID"],
               "SessionOriginMessage gained unexpected keys: \(object.keys.sorted()). A transform must never be added — see the invariant in CollaborativeSessionManager.")

        // Belt and braces: no value anywhere is a numeric array (a flattened matrix would be).
        for (key, value) in object {
            assert(!(value is [Any]),
                   "Key '\(key)' encodes an array — a flattened transform must never be on the wire")
            assert(value is String,
                   "Key '\(key)' should be a UUID string, got \(type(of: value))")
        }

        let json = String(data: data, encoding: .utf8)!.lowercased()
        for banned in ["matrix", "transform", "originfromanchor", "columns"] {
            assert(!json.contains(banned),
                   "SessionOriginMessage JSON contains '\(banned)': \(json)")
        }
    }

    static func testSessionOriginRoundTrip() {
        let anchorID = UUID(), ownerID = UUID()
        let data = try! JSONEncoder().encode(SessionOriginMessage(anchorID: anchorID, ownerParticipantID: ownerID))
        let decoded = try! JSONDecoder().decode(SessionOriginMessage.self, from: data)
        assert(decoded.anchorID == anchorID, "anchorID lost in round trip")
        assert(decoded.ownerParticipantID == ownerID, "ownerParticipantID lost in round trip")
    }

    // MARK: - Envelope

    /// Every envelope case must survive encode → decode as the same case. A mismatch means peers
    /// silently drop or misroute that message type.
    static func testEnvelopeRoundTripForEveryCase() {
        let cases: [SharedSpaceEnvelope] = [
            .anchor(SharedAnchorMessage(transform: matrix_identity_float4x4)),
            .sessionOrigin(SessionOriginMessage(anchorID: UUID(), ownerParticipantID: UUID())),
            .diagram(SharedDiagram(filename: "d", elements: [], is2D: true)),
            .transform(UpdateDiagramTransformMessage(filename: "d",
                                                     worldPosition: SIMD3<Float>(1, 2, 3),
                                                     worldOrientation: simd_quatf(angle: 0.5, axis: [0, 1, 0]),
                                                     worldScale: 0.7)),
            .remove(RemoveDiagramMessage(filename: "d")),
            .arCollaboration(Data([1, 2, 3])),
            .elementMoved(ElementPositionMessage(filename: "d", elementId: "e",
                                                 localPosition: SIMD3<Float>(0, 1, 0))),
            .sessionEnded(SessionEndedMessage(byHost: "host", reason: nil, at: Date())),
            .participantLeft(ParticipantLeftMessage(peerName: "peer", at: Date())),
        ]

        for envelope in cases {
            let data = try! JSONEncoder().encode(envelope)
            let decoded = try! JSONDecoder().decode(SharedSpaceEnvelope.self, from: data)
            assert(decoded.kind == envelope.kind,
                   "Envelope case changed across round trip: \(envelope.kind) -> \(decoded.kind)")
        }

        // Every case in the enum is covered above.
        assert(Set(cases.map(\.kind)).count == cases.count, "Duplicate cases in the fixture list")
    }

    /// `kind` labels the diagnostics traffic counters. Duplicates would silently merge two message
    /// types into one row and hide a failure.
    static func testEnvelopeKindsAreUniqueAndStable() {
        let expected: Set<String> = ["anchor", "sessionOrigin", "diagram", "transform", "remove",
                                     "arCollaboration", "elementMoved", "sessionEnded", "participantLeft"]
        let actual: Set<String> = [
            SharedSpaceEnvelope.anchor(SharedAnchorMessage(transform: matrix_identity_float4x4)).kind,
            SharedSpaceEnvelope.sessionOrigin(SessionOriginMessage(anchorID: UUID(), ownerParticipantID: UUID())).kind,
            SharedSpaceEnvelope.diagram(SharedDiagram(filename: "d", elements: [])).kind,
            SharedSpaceEnvelope.transform(UpdateDiagramTransformMessage(filename: "d")).kind,
            SharedSpaceEnvelope.remove(RemoveDiagramMessage(filename: "d")).kind,
            SharedSpaceEnvelope.arCollaboration(Data()).kind,
            SharedSpaceEnvelope.elementMoved(ElementPositionMessage(filename: "d", elementId: "e",
                                                                    localPosition: .zero)).kind,
            SharedSpaceEnvelope.sessionEnded(SessionEndedMessage(byHost: "h", reason: nil, at: Date())).kind,
            SharedSpaceEnvelope.participantLeft(ParticipantLeftMessage(peerName: "p", at: Date())).kind,
        ]
        assert(actual == expected, "Envelope kinds drifted: \(actual.symmetricDifference(expected))")
    }

    // MARK: - SharedDiagram

    /// `is2D` changes rendering substantially (Y sign, handle/close-button Z offsets, per-element
    /// input targets, wall-vs-floor snapping). It used to be unrecoverable on the receiver, so
    /// every 2D RT/RS diagram was rebuilt as 3D and the two devices looked different even with
    /// perfect anchoring.
    static func testSharedDiagramPreservesIs2D() {
        for flag in [true, false] {
            let diagram = SharedDiagram(filename: "x", elements: [], is2D: flag)
            let data = try! JSONEncoder().encode(diagram)
            let decoded = try! JSONDecoder().decode(SharedDiagram.self, from: data)
            assert(decoded.is2D == flag, "is2D=\(flag) lost across the wire")
        }
    }

    /// `is2D` is decoded with `decodeIfPresent` so an older build (or the iOS lane) that omits the
    /// key still decodes rather than throwing and dropping the whole diagram.
    static func testSharedDiagramIs2DBackCompatWhenKeyAbsent() {
        let json = """
        {"id":"\(UUID().uuidString)","filename":"legacy","elements":[],"timestamp":0}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(SharedDiagram.self, from: json) else {
            fatalError("Legacy payload without is2D must still decode")
        }
        assert(decoded.is2D == false, "Missing is2D should default to false, got \(decoded.is2D)")
        assert(decoded.filename == "legacy")
    }

    static func testSharedDiagramTransformRoundTrip() {
        let position = SIMD3<Float>(0.25, -1.5, 3.125)
        let orientation = simd_quatf(angle: 0.75, axis: simd_normalize(SIMD3<Float>(0, 1, 0.5)))
        let diagram = SharedDiagram(filename: "x", elements: [], is2D: false,
                                    worldPosition: position,
                                    worldOrientation: orientation,
                                    worldScale: 0.42)
        let data = try! JSONEncoder().encode(diagram)
        let decoded = try! JSONDecoder().decode(SharedDiagram.self, from: data)

        guard let p = decoded.worldPosition, let o = decoded.worldOrientation, let s = decoded.worldScale else {
            fatalError("Transform fields lost across the wire")
        }
        assert(simd_length(p - position) < 1e-5, "position drifted: \(p) vs \(position)")
        assert(abs(s - 0.42) < 1e-6, "scale drifted: \(s)")
        assert(simd_length(o.imag - orientation.imag) < 1e-5 && abs(o.real - orientation.real) < 1e-5,
               "orientation drifted: \(o) vs \(orientation)")

        // Absent transform stays absent rather than decoding as zero — nil and (0,0,0) mean
        // different things to the receiver.
        let bare = try! JSONEncoder().encode(SharedDiagram(filename: "y", elements: []))
        let bareDecoded = try! JSONDecoder().decode(SharedDiagram.self, from: bare)
        assert(bareDecoded.worldPosition == nil, "Missing position must stay nil")
        assert(bareDecoded.worldOrientation == nil, "Missing orientation must stay nil")
        assert(bareDecoded.worldScale == nil, "Missing scale must stay nil")
    }

    // MARK: - ScriptOutput

    /// The memberwise init exists so a received diagram can be handed to the renderer in memory,
    /// replacing a JSON-to-disk round trip that forced `is2D = false`.
    static func testScriptOutputMemberwiseInit() {
        let output = ScriptOutput(elements: [], is2D: true, id: 42)
        assert(output.is2D, "memberwise init must preserve is2D")
        assert(output.id == 42, "memberwise init must preserve id")
        assert(output.elements.isEmpty)

        let noID = ScriptOutput(elements: [], is2D: false)
        assert(noID.id == nil, "id should default to nil")
        assert(!noID.is2D)
    }

    /// The decoder is deliberately tolerant of four input shapes. `is2D` is derived from which key
    /// was used, so these assertions pin the mapping that the renderer depends on.
    static func testScriptOutputDecodesAllFourFormats() {
        let element = """
        {"position":[0,0,0],"shape":{"shapeDescription":"RWBox","extent":[1,1,1]}}
        """

        // 1. bare array -> 3D
        let array = "[\(element)]".data(using: .utf8)!
        let a = try! JSONDecoder().decode(ScriptOutput.self, from: array)
        assert(!a.is2D, "bare array should decode as 3D")
        assert(a.elements.count == 1, "bare array lost elements")

        // 2. {"elements": []} -> 3D
        let elements = "{\"elements\":[\(element)]}".data(using: .utf8)!
        let e = try! JSONDecoder().decode(ScriptOutput.self, from: elements)
        assert(!e.is2D, "'elements' key should decode as 3D")
        assert(e.elements.count == 1)

        // 3. {"RTelements": []} -> 2D  (this is the case the old disk round-trip destroyed)
        let rt = "{\"RTelements\":[\(element)]}".data(using: .utf8)!
        let r = try! JSONDecoder().decode(ScriptOutput.self, from: rt)
        assert(r.is2D, "'RTelements' MUST decode as 2D")
        assert(r.elements.count == 1)

        // 4. {"nodes": [], "edges": []} -> 2D, merged
        let rs = "{\"nodes\":[\(element)],\"edges\":[\(element)]}".data(using: .utf8)!
        let s = try! JSONDecoder().decode(ScriptOutput.self, from: rs)
        assert(s.is2D, "'nodes'/'edges' MUST decode as 2D")
        assert(s.elements.count == 2, "nodes and edges should be merged, got \(s.elements.count)")

        // Optional root id, accepted as Int / Double / String.
        for raw in ["123", "123.0", "\"123\""] {
            let withID = "{\"elements\":[\(element)],\"id\":\(raw)}".data(using: .utf8)!
            let decoded = try! JSONDecoder().decode(ScriptOutput.self, from: withID)
            assert(decoded.id == 123, "root id \(raw) should decode to 123, got \(String(describing: decoded.id))")
        }
    }
}
