//
//  CollabDiagnosticsView.swift
//  AVAR2
//
//  Diagnostics surface for co-located SharePlay sessions.
//
//  WHY THIS EXISTS
//  Debugging shared-anchor alignment requires two Vision Pro devices in the same room, which is
//  an expensive and hard-to-observe test setup — you cannot read a console while wearing a
//  headset next to someone else wearing one. This panel turns a two-device session into a
//  readable diagnosis: every value needed to tell "not co-located" from "anchor not created
//  yet" from "anchor created but our device hasn't resolved it" is on screen, and
//  "Copy diagnostics" produces a text blob you can diff between the two devices afterwards.
//
//  Diagrams are placed in the SharePlay shared space (scene coordinates), not relative to the
//  shared room anchor. The anchor sections below are kept as instruments: they measure how ARKit
//  positions relate to that shared space, which decides whether ARKit-derived content (plane
//  overlays, surface snapping, a room anchor) can be trusted while sharing.

import SwiftUI
import simd
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Shared space status

/// What the launcher shows about the session. It describes state; it does not claim that
/// diagrams line up, which only a two-headset look at the shared-space marker can establish.
struct SharedSpaceStatus: Equatable {
    var label: String
    var detail: String
    /// Whether this headset is in a spatial session, and so shares a coordinate space.
    var isShared: Bool
    var color: Color { isShared ? .green : .orange }
}

// MARK: - Room anchor diagnostic

/// State of the shared room anchor, in the order these conditions resolve. Diagnostic only:
/// diagram placement does not depend on it.
enum AlignmentDiagnostic: Equatable {
    /// No group session at all.
    case noSession
    /// Participants are NOT co-located. Shared world anchors can never become available.
    /// This is the case that looks identical to every other in the old UI.
    case notSpatial
    /// No participant in this session can resolve a visionOS `WorldAnchor` — e.g. the peer is the
    /// iOS companion. Diagrams are still shared and visible, just not spatially aligned.
    case alignmentNotAchievable
    /// Co-located, but ARKit hasn't reported world-anchor sharing as available yet.
    case waitingForAvailability
    /// Sharing available, but no session-origin anchor has been announced yet.
    case waitingForOwnerAnnounce
    /// We know the origin anchor's UUID but our own ARKit hasn't delivered its transform yet.
    case waitingForLocalResolve
    /// Anchor creation failed.
    case creationFailed(String)
    /// Origin resolved locally and tracked. Content is aligned.
    case aligned

    var label: String {
        switch self {
        case .noSession: return "No session"
        case .notSpatial: return "No nearby participant"
        case .alignmentNotAchievable: return "Waiting for a participant"
        case .waitingForAvailability: return "Waiting for anchor sharing"
        case .waitingForOwnerAnnounce: return "Waiting for origin anchor"
        case .waitingForLocalResolve: return "Resolving origin locally"
        case .creationFailed: return "Anchor creation failed"
        case .aligned: return "Anchor resolved"
        }
    }

    /// Plain-language explanation. `notSpatial` is the one that matters most in practice:
    /// SharePlay over FaceTime from another room looks identical in every other indicator.
    var detail: String {
        switch self {
        case .noSession:
            return "Start SharePlay and invite the other Vision Pro as a nearby participant."
        case .notSpatial:
            return "SharePlay has not detected a nearby participant. Join the same nearby SharePlay activity on both Vision Pro devices."
        case .alignmentNotAchievable:
            return "A nearby Vision Pro participant is needed for physical alignment."
        case .waitingForAvailability:
            return "Co-located. Look around the room so tracking settles; sharing usually becomes available within a few seconds."
        case .waitingForOwnerAnnounce:
            return "Waiting for the elected owner to create and announce the session-origin anchor."
        case .waitingForLocalResolve:
            return "Origin anchor UUID known. Waiting for this device's ARKit to resolve it — look toward where the owner created it."
        case .creationFailed(let why):
            return "Could not create the shared anchor: \(why)"
        case .aligned:
            return "Room anchor resolved and tracked on this device."
        }
    }

    var isHealthy: Bool { self == .aligned }

    var color: Color {
        switch self {
        case .aligned: return .green
        case .notSpatial, .creationFailed: return .red
        case .alignmentNotAchievable: return .blue
        default: return .orange
        }
    }
}

// MARK: - Panel

#if os(visionOS)
struct CollabDiagnosticsView: View {
    @ObservedObject var session: CollaborativeSessionManager
    @ObservedObject private var anchorManager: SharedWorldAnchorManager
    @Environment(AppModel.self) private var appModel
    @State private var didCopy = false

    init(session: CollaborativeSessionManager) {
        self.session = session
        self.anchorManager = session.sharedWorldAnchorManager
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                #if canImport(GroupActivities)
                if let coordinator = session.sharePlayCoordinator {
                    SharePlayDiagnosticsSection(session: session, coordinator: coordinator)
                } else {
                    Text("SharePlay coordinator unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif

                framesSection
                originSection
                diagramsSection
                trafficSection

                DiagSection("Rendering") {
                    // Surfaces the bounded mesh cache. Steady growth toward the cap across a long
                    // session means geometry keys are churning (e.g. many distinct HTTP diagrams
                    // or label strings) and meshes are being regenerated rather than reused.
                    DiagRow(label: "Cached meshes", value: "\(MeshCache.shared.count) / 512")
                    Toggle("Optimize diagram edges", isOn: Binding(
                        get: { appModel.optimizeDiagramEdges },
                        set: { appModel.optimizeDiagramEdges = $0 }
                    ))
                    .font(.caption)
                    Text("Compare with this off and on while viewing the same diagram.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if includesTestAffordances {
                    frameTestSection
                    loopbackSection
                }

                if let error = session.lastError {
                    DiagRow(label: "Last error", value: error, tint: .red)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack {
            Text("Collaboration Diagnostics")
                .font(.headline)
            Spacer()
            Button {
                copyDiagnostics()
            } label: {
                Label(didCopy ? "Copied" : "Copy diagnostics",
                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: Coordinate frames

    private var framesSection: some View {
        DiagSection("Shared space") {
            let frames = appModel.frameDiagnostics
            let status = session.sharedSpaceStatus
            DiagRow(label: "Diagram frame", value: "SharePlay shared space", tint: .blue)
            DiagRow(label: "This headset", value: status.label, tint: status.color)

            Toggle("Show shared-space marker", isOn: Binding(
                get: { appModel.showSharedSpaceMarker },
                set: { appModel.showSharedSpaceMarker = $0 }
            ))
            .font(.caption)
            caption("Turn on for BOTH headsets. Each draws a white-hubbed triad 1 m above the shared origin. If both people see it at the same physical point, diagrams will line up — this is the test of diagram alignment.")

            DiagRow(label: "Immersive space displacement", value: frames.displacementSummary, mono: true)
            caption("How far the system moved this headset's immersive space to share it. \"none\" when not in a spatial session.")

            DiagRow(label: "ARKit → scene offset", value: frames.renderedOffset.summary, mono: true,
                    tint: Self.tint(for: frames.renderedOffset))
            if case .measured = frames.metricOffset, frames.metricOffset != frames.renderedOffset {
                DiagRow(label: "…without display correction", value: frames.metricOffset.summary, mono: true)
            }
            caption("Difference between an ARKit position as reported and the same position converted into the scene by the system. Check it reads \"none\" when NOT sharing — that confirms the measurement. If it becomes non-zero while sharing, ARKit positions (plane overlay, surface snapping, room anchor) are offset from the shared space by that amount.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func tint(for measurement: FrameOffsetMeasurement) -> Color {
        switch measurement {
        case .unavailable: return .secondary
        case .measured(let offset): return offset.isNegligible ? .green : .orange
        }
    }

    // MARK: Room anchor

    private var originSection: some View {
        DiagSection("Shared room anchor (diagnostic only)") {
            caption("Not used to place diagrams. ARKit shares this anchor between nearby headsets only; it is kept to measure how ARKit positions relate to the shared space.")

            let diagnostic = session.anchorDiagnostic
            DiagRow(label: "Anchor state", value: diagnostic.label, tint: diagnostic.color)
            Text(diagnostic.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DiagRow(label: "Anchor sharing available",
                    value: session.worldAnchorSharingAvailable ? "yes" : "no",
                    tint: session.worldAnchorSharingAvailable ? .green : .orange)

            DiagRow(label: "Origin owner",
                    value: session.isSessionOriginOwner ? "this device" : "peer",
                    tint: .blue)

            if let originID = session.sessionOriginID {
                DiagRow(label: "Origin anchor", value: String(originID.uuidString.prefix(8)), mono: true)
                DiagRow(label: "Tracked",
                        value: session.sessionOriginIsTracked ? "yes" : "no (holding last pose)",
                        tint: session.sessionOriginIsTracked ? .green : .orange)
                DiagRow(label: "originFromAnchor (local)",
                        value: session.sessionOriginTransform.map(Self.formatTranslation) ?? "unresolved",
                        mono: true,
                        tint: session.sessionOriginTransform == nil ? .orange : .primary)
                if #available(visionOS 27.0, *), let correction = anchorManager.renderCorrectionSummary(for: originID) {
                    DiagRow(label: "Local render correction", value: correction, mono: true)
                    Text("Difference between this headset’s corrected and uncorrected anchor positions.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                DiagRow(label: "Anchor in scene space",
                        value: appModel.frameDiagnostics.roomAnchorInScene.map {
                            String(format: "[%.2f, %.2f, %.2f]", $0.x, $0.y, $0.z)
                        } ?? "—",
                        mono: true)
                caption("Compare both rows between the two headsets. Matching \"scene space\" values mean the shared space is physically the same for both. Matching raw values would mean ARKit already reports in the shared space.")
            } else {
                DiagRow(label: "Room anchor", value: "none", tint: .secondary)
                caption("Expected unless another Vision Pro is nearby in the same SharePlay session.")
            }

            Toggle("Show room-anchor marker (raw ARKit pose)", isOn: Binding(
                get: { appModel.showSessionOriginMarker },
                set: { appModel.showSessionOriginMarker = $0 }
            ))
            .font(.caption)
            .disabled(session.sessionOriginTransform == nil)
            caption("Yellow-hubbed triad at the anchor's raw ARKit pose. If two headsets see it at the same physical point, raw ARKit positions are valid in the shared space; if not, they need converting. Either way diagrams are unaffected.")

            if session.canRealign || session.isRealigning {
                HStack {
                    Button(session.isRealigning ? "Checking…" : "Re-check anchor") {
                        session.requestRealignment()
                    }
                    Button("Replace anchor") {
                        session.requestRealignment(replaceAnchor: true)
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(session.isRealigning)
            }
            if let result = session.realignmentStatus {
                caption(result)
            }
        }
    }

    // MARK: Single-device frame test

    private var frameTestSection: some View {
        DiagSection("Single-device frame test") {
            Toggle("Force offset worldRoot", isOn: Binding(
                get: { appModel.debugWorldRootOffset },
                set: { appModel.debugWorldRootOffset = $0 }
            ))
            .font(.caption)
            .disabled(session.isSessionActive)
            caption("Puts diagrams under a parent that is offset and yawed 37°, so drag, pinch-zoom, snap and unsnap run with parent-relative and world coordinates no longer equal. Locally placed diagrams should NOT move when you toggle it. Unavailable, and forced off, while anything is shared: it would put this headset in a private frame.")
        }
    }

    // MARK: Diagrams

    private var diagramsSection: some View {
        DiagSection("Shared diagrams (\(session.sharedDiagrams.count))") {
            if session.sharedDiagrams.isEmpty {
                Text("none").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(session.sharedDiagrams) { diagram in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(diagram.filename).font(.caption).bold()
                        Text(Self.describeDiagram(diagram))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Traffic

    private var trafficSection: some View {
        DiagSection("Message traffic") {
            if session.envelopeStats.isEmpty {
                Text("no messages yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(session.envelopeStats.keys.sorted(), id: \.self) { kind in
                    if let stat = session.envelopeStats[kind] {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(kind): ↑\(stat.sent) (\(Self.bytes(stat.bytesSent)))  ↓\(stat.received) (\(Self.bytes(stat.bytesReceived)))")
                                .font(.system(.caption2, design: .monospaced))
                            if !stat.sources.isEmpty {
                                Text("via \(stat.sources.sorted().joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let error = stat.lastError {
                                Text("last error: \(error)")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Loopback

    /// Example diagrams chosen to cover both decode shapes: one 2D (RT/RS) and one 3D. The 2D
    /// case is the one that used to be silently rebuilt as 3D on the receiver.
    private static let loopbackSamples = ["2D Tree Layout", "Ejemplo08"]

    private var loopbackSection: some View {
        DiagSection("Loopback test (DEBUG)") {
            Text("Injects a local example through the real receive path as if a peer had sent it. Verifies rendering on ONE device — no peer, no FaceTime. It will land at this device's own grid slot: appearing is not the same as being aligned.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.loopbackSamples, id: \.self) { sample in
                Button("Inject \"\(sample)\"") {
                    session.debugInjectRemoteDiagram(filename: sample)
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
    }

    // MARK: Formatting

    static func formatTranslation(_ m: simd_float4x4) -> String {
        String(format: "[%.2f, %.2f, %.2f]", m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    static func describeDiagram(_ diagram: SharedDiagram) -> String {
        var parts = ["\(diagram.elements.count) elements"]
        if let p = diagram.anchorRelativePosition {
            parts.append(String(format: "pos [%.2f, %.2f, %.2f]", p.x, p.y, p.z))
        } else {
            parts.append("pos —")
        }
        if let s = diagram.anchorRelativeScale { parts.append(String(format: "scale %.2f", s)) }
        return parts.joined(separator: "  ")
    }

    static func bytes(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fMB", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fkB", Double(n) / 1_000) }
        return "\(n)B"
    }

    // MARK: Copy

    private func copyDiagnostics() {
        #if canImport(UIKit)
        UIPasteboard.general.string = session.diagnosticsReport(extra: appModel.frameDiagnostics.reportLines())
        #endif
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { didCopy = false }
    }
}

// MARK: - SharePlay section
//
// Split into its own view so the coordinator's @Published properties are actually observed.
// `sharePlayCoordinator` is a plain property on the manager, so changes inside it do not
// re-render a view that only observes the manager.

#if canImport(GroupActivities)
private struct SharePlayDiagnosticsSection: View {
    @ObservedObject var session: CollaborativeSessionManager
    @ObservedObject var coordinator: SharePlayCoordinator

    struct ParticipantRow: Identifiable {
        let id: UUID
        let shortID: String
        let role: String
        let tint: Color
    }

    /// Precomputed so the `ForEach` body stays a single expression — a multi-statement closure
    /// here makes Swift resolve `ForEach` to its `Binding` overload and fail to infer.
    private var participantRows: [ParticipantRow] {
        coordinator.participantIDs.map { id in
            let isLocal = id == coordinator.localParticipantID
            let isNearby = coordinator.nearbyParticipantIDs.contains(id)
            return ParticipantRow(
                id: id,
                shortID: String(id.uuidString.prefix(8)),
                role: isLocal ? "local" : (isNearby ? "nearby" : "remote/far"),
                tint: isLocal ? .primary : (isNearby ? .green : .orange)
            )
        }
    }

    var body: some View {
        DiagSection("SharePlay") {
            DiagRow(label: "State", value: coordinator.sessionStateDescription,
                    tint: coordinator.sessionStateDescription == "joined" ? .green : .orange)
            DiagRow(label: "Active", value: session.isSharePlayActive ? "yes" : "no",
                    tint: session.isSharePlayActive ? .green : .secondary)
            DiagRow(label: "Activity", value: SharedSpaceActivity.activityIdentifier, mono: true)
            DiagRow(label: "Spatial experience (isSpatial)",
                    value: coordinator.isSpatial ? "yes" : "NO",
                    tint: coordinator.isSpatial ? .green : .red)

            DiagRow(label: "Local participant",
                    value: coordinator.localParticipantID.map { String($0.uuidString.prefix(8)) } ?? "—",
                    mono: true)
            // Both devices must show the SAME elected owner and DIFFERENT locals.
            // Read through `electedOriginOwnerID` so the HUD cannot drift from the real election
            // rule in `SessionOriginElection`.
            DiagRow(label: "Elected origin owner",
                    value: session.electedOriginOwnerID.map { String($0.uuidString.prefix(8)) } ?? "—",
                    mono: true,
                    tint: .blue)
            Text("Both devices must show the same elected owner and different local ids.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            DiagRow(label: "Participants", value: "\(coordinator.participantIDs.count)")
            ForEach(participantRows, id: \.id) { row in
                Text("  \(row.shortID)  \(row.role)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(row.tint)
            }

            if !session.connectedPeers.isEmpty {
                DiagRow(label: "Multipeer peers (iOS lane)",
                        value: session.connectedPeers.map(\.displayName).joined(separator: ", "))
            }
        }
    }
}
#endif

// MARK: - Small building blocks

private struct DiagSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline).bold()
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct DiagRow: View {
    let label: String
    let value: String
    var mono: Bool = false
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .system(.caption2, design: .monospaced) : .caption)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
    }
}
#endif

// MARK: - Report + diagnostic derivation

extension CollaborativeSessionManager {
    /// What the launcher shows about the SharePlay session.
    var sharedSpaceStatus: SharedSpaceStatus {
        #if canImport(GroupActivities)
        guard isSharePlayActive, let coordinator = sharePlayCoordinator else {
            return SharedSpaceStatus(label: "No session", detail: "Start SharePlay to share diagrams.", isShared: false)
        }
        guard coordinator.participantIDs.count > 1 else {
            return SharedSpaceStatus(label: "Waiting for others",
                                     detail: "SharePlay is on. Diagrams appear for others as soon as they join.",
                                     isShared: false)
        }
        if peerUsesAnchorFrame {
            return SharedSpaceStatus(
                label: "Other headset needs updating",
                detail: "Another participant is on an older AVAR2 build that places diagrams relative to a room anchor. Their diagrams will be misplaced here and yours will not appear there. Install the same build on every headset.",
                isShared: false)
        }
        // A nearby participant shares the space without a spatial Persona, so either signal counts.
        guard coordinator.isSpatial || hasNearbyParticipants else {
            return SharedSpaceStatus(
                label: "Sharing, not spatial",
                detail: "Diagrams are shared, but this headset is not in a spatial session, so they will not appear in the same place for everyone. Turn on your spatial Persona, or have the other Vision Pro join as a nearby participant.",
                isShared: false)
        }
        return SharedSpaceStatus(
            label: "Sharing one space",
            detail: "Diagrams are placed in the SharePlay shared space, so everyone in it should see them in the same place. Check with the shared-space marker in Diagnostics.",
            isShared: true)
        #else
        return SharedSpaceStatus(label: "No session", detail: "SharePlay is unavailable on this platform.", isShared: false)
        #endif
    }

    /// State of the shared room anchor. Diagnostic only — see `currentPoseAnchorID`.
    var anchorDiagnostic: AlignmentDiagnostic {
        guard isSharePlayActive, let coordinator = sharePlayCoordinator else { return .noSession }
        guard hasNearbyParticipants || worldAnchorSharingAvailable else {
            return coordinator.participantIDs.count > 1 ? .notSpatial : .alignmentNotAchievable
        }
        #if os(visionOS)
        if let failure = sharedWorldAnchorManager.lastError ?? anchorCreationFailure {
            return .creationFailed(failure)
        }
        guard worldAnchorSharingAvailable else { return .waitingForAvailability }

        // Distinguish "no origin announced yet" from "origin UUID known but our own ARKit
        // hasn't resolved it" — very different user actions (wait vs. look around).
        guard sessionOriginID != nil else { return .waitingForOwnerAnnounce }
        guard sessionOriginTransform != nil else { return .waitingForLocalResolve }
        guard sessionOriginIsTracked else { return .waitingForLocalResolve }
        return .aligned
        #else
        guard sharedAnchor != nil else { return .waitingForOwnerAnnounce }
        guard sharedAnchorUsesSharedWorld else { return .waitingForLocalResolve }
        return .aligned
        #endif
    }

    /// Plain-text snapshot for "Copy diagnostics". Two devices produce two blobs you can diff.
    func diagnosticsReport(extra: [String] = []) -> String {
        var lines: [String] = []
        lines.append("=== AVAR2 collaboration diagnostics ===")
        lines.append("platform: \(deviceModelDescription)")
        lines.append("osVersion: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("diagramFrame: SharePlay shared space (scene coordinates)")
        lines.append("sharedSpace: \(sharedSpaceStatus.label)")
        lines.append("roomAnchor (diagnostic only): \(anchorDiagnostic.label) — \(anchorDiagnostic.detail)")
        lines.append("sessionActive: \(isSessionActive)  sharePlayActive: \(isSharePlayActive)")
        lines.append("worldAnchorSharingAvailable: \(worldAnchorSharingAvailable)")

        #if canImport(GroupActivities)
        if let c = sharePlayCoordinator {
            lines.append("sharePlayState: \(c.sessionStateDescription)")
            lines.append("isSpatial: \(c.isSpatial)")
            lines.append("localParticipant: \(c.localParticipantID?.uuidString ?? "—")")
            lines.append("participants (sorted): \(c.participantIDs.map(\.uuidString).joined(separator: ", "))")
            lines.append("nearby: \(c.nearbyParticipantIDs.map(\.uuidString).joined(separator: ", "))")
        }
        #endif

        #if os(visionOS)
        lines.append("electedOriginOwner: \(electedOriginOwnerID?.uuidString ?? "—")")
        lines.append("isSessionOriginOwner: \(isSessionOriginOwner)")
        if let originID = sessionOriginID {
            lines.append("originAnchorID: \(originID)")
            lines.append("originTracked: \(sessionOriginIsTracked)")
            if #available(visionOS 27.0, *),
               let correction = sharedWorldAnchorManager.renderCorrectionSummary(for: originID) {
                lines.append("localRenderCorrection: \(correction)")
            }
            if let t = sessionOriginTransform?.columns.3 {
                lines.append(String(format: "originFromAnchor.translation (local): [%.4f, %.4f, %.4f]", t.x, t.y, t.z))
            } else {
                lines.append("originFromAnchor.translation: unresolved locally")
            }
        } else {
            lines.append("originAnchorID: none")
        }
        #endif

        lines.append(contentsOf: extra)
        lines.append("multipeerPeers: \(connectedPeers.map(\.displayName).joined(separator: ", "))")

        lines.append("--- diagrams (\(sharedDiagrams.count)) ---")
        for d in sharedDiagrams {
            let p = d.anchorRelativePosition
            let pos = p.map { String(format: "[%.4f, %.4f, %.4f]", $0.x, $0.y, $0.z) } ?? "—"
            lines.append("  \(d.filename)  elements=\(d.elements.count)  poseAnchorID=\(d.poseAnchorID?.uuidString ?? "—")  anchorRelPos=\(pos)  scale=\(d.anchorRelativeScale.map { String(format: "%.3f", $0) } ?? "—")")
        }

        lines.append("--- traffic ---")
        for kind in envelopeStats.keys.sorted() {
            guard let s = envelopeStats[kind] else { continue }
            var line = "  \(kind): sent=\(s.sent) (\(s.bytesSent)B) recv=\(s.received) (\(s.bytesReceived)B)"
            if !s.sources.isEmpty { line += " via [\(s.sources.sorted().joined(separator: ", "))]" }
            if let e = s.lastError { line += " lastError=\(e)" }
            lines.append(line)
        }

        if let error = lastError { lines.append("lastError: \(error)") }
        return lines.joined(separator: "\n")
    }

    private var deviceModelDescription: String {
        #if os(visionOS)
        return "visionOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "other"
        #endif
    }
}
