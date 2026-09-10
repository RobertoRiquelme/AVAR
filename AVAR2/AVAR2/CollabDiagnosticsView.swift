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
//  THE ONE COUNTERINTUITIVE READING
//  The session-origin transform MUST DIFFER between the two devices. It is each device's own
//  `originFromAnchorTransform` for the same physical anchor, expressed in that device's own
//  private ARKit origin. If the two devices ever show the SAME translation here, a transform
//  leaked onto the wire and alignment is broken. The panel says so inline.
//

import SwiftUI
import simd
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Alignment diagnostic

/// Why content is (or isn't) aligned right now, in the order these conditions resolve.
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
        case .notSpatial: return "NOT co-located"
        case .alignmentNotAchievable: return "Shared, not aligned"
        case .waitingForAvailability: return "Waiting for anchor sharing"
        case .waitingForOwnerAnnounce: return "Waiting for origin anchor"
        case .waitingForLocalResolve: return "Resolving origin locally"
        case .creationFailed: return "Anchor creation failed"
        case .aligned: return "Aligned"
        }
    }

    /// Plain-language explanation. `notSpatial` is the one that matters most in practice:
    /// SharePlay over FaceTime from another room looks identical in every other indicator.
    var detail: String {
        switch self {
        case .noSession:
            return "Start SharePlay from a FaceTime call with the other device."
        case .notSpatial:
            return "Participants are not in the same room — shared world anchors are unavailable, so diagrams cannot align. Each device places them independently."
        case .alignmentNotAchievable:
            return "This peer cannot resolve a visionOS world anchor (e.g. the iPhone companion), so spatial alignment is not possible. Diagrams are still shared and visible — useful for checking content, transforms and 2D/3D handling, but not physical alignment."
        case .waitingForAvailability:
            return "Co-located. Look around the room so tracking settles; sharing usually becomes available within a few seconds."
        case .waitingForOwnerAnnounce:
            return "Waiting for the elected owner to create and announce the session-origin anchor."
        case .waitingForLocalResolve:
            return "Origin anchor UUID known. Waiting for this device's ARKit to resolve it — look toward where the owner created it."
        case .creationFailed(let why):
            return "Could not create the shared anchor: \(why)"
        case .aligned:
            return "Session origin resolved and tracked on this device."
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
    @Environment(AppModel.self) private var appModel
    @State private var didCopy = false

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

                originSection
                diagramsSection
                trafficSection

                DiagSection("Rendering") {
                    // Surfaces the bounded mesh cache. Steady growth toward the cap across a long
                    // session means geometry keys are churning (e.g. many distinct HTTP diagrams
                    // or label strings) and meshes are being regenerated rather than reused.
                    DiagRow(label: "Cached meshes", value: "\(MeshCache.shared.count) / 512")
                }

                if includesTestAffordances { loopbackSection }

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

    // MARK: Session origin

    private var originSection: some View {
        DiagSection("Session origin (shared WorldAnchor)") {
            let diagnostic = session.alignmentDiagnostic
            DiagRow(label: "Alignment", value: diagnostic.label, tint: diagnostic.color)
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
                // The whole point, stated where it will be read:
                Text("⚠️ This translation MUST DIFFER between the two devices. It is this device's own transform for the same physical anchor. Identical values on both devices mean a transform leaked onto the wire.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DiagRow(label: "Origin anchor", value: "none", tint: .orange)
            }

            Toggle("Show origin marker in space", isOn: Binding(
                get: { appModel.showSessionOriginMarker },
                set: { appModel.showSessionOriginMarker = $0 }
            ))
            .font(.caption)
            .disabled(session.sessionOriginTransform == nil)

            Text("Turn this on on BOTH devices: each draws an axis triad at its own resolved transform. If the two triads occupy the same physical point, alignment works — independently of diagram rendering.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Force offset worldRoot (single-device test)", isOn: Binding(
                get: { appModel.debugWorldRootOffset },
                set: { appModel.debugWorldRootOffset = $0 }
            ))
            .font(.caption)
            .disabled(session.sessionOriginTransform != nil)

            Text("With one headset worldRoot sits at identity, where parent-relative and world coordinates coincide and a frame-mixing bug cannot show. This forces a non-identity frame (offset + 37° yaw) so drag, pinch-zoom, snap and unsnap exercise the real code path. Locally placed diagrams should NOT move when you toggle it — that is the jump fix working. Disabled once a real session origin exists.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        UIPasteboard.general.string = session.diagnosticsReport()
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
            DiagRow(label: "Co-located (isSpatial)",
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
    /// Current alignment state, derived from the signals available on this device.
    var alignmentDiagnostic: AlignmentDiagnostic {
        if let failure = anchorCreationFailure { return .creationFailed(failure) }

        #if canImport(GroupActivities)
        guard isSharePlayActive, let coordinator = sharePlayCoordinator else { return .noSession }
        // Only meaningful once there is somebody else in the session.
        if coordinator.participantIDs.count > 1 && !coordinator.isSpatial { return .notSpatial }
        #else
        guard isSessionActive else { return .noSession }
        #endif

        // Distinguish "alignment is pending" from "alignment is impossible in this session".
        // Without this, an iPhone peer looks like a broken visionOS pairing.
        if !isAlignmentAchievable { return .alignmentNotAchievable }
        guard worldAnchorSharingAvailable else { return .waitingForAvailability }

        #if os(visionOS)
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
    func diagnosticsReport() -> String {
        var lines: [String] = []
        lines.append("=== AVAR2 collaboration diagnostics ===")
        lines.append("platform: \(deviceModelDescription)")
        lines.append("alignment: \(alignmentDiagnostic.label) — \(alignmentDiagnostic.detail)")
        lines.append("sessionActive: \(isSessionActive)  sharePlayActive: \(isSharePlayActive)")
        lines.append("worldAnchorSharingAvailable: \(worldAnchorSharingAvailable)")

        #if canImport(GroupActivities)
        if let c = sharePlayCoordinator {
            lines.append("sharePlayState: \(c.sessionStateDescription)")
            lines.append("isSpatial: \(c.isSpatial)")
            lines.append("localParticipant: \(c.localParticipantID?.uuidString ?? "—")")
            lines.append("electedOriginOwner: \(c.participantIDs.first?.uuidString ?? "—")")
            lines.append("participants (sorted): \(c.participantIDs.map(\.uuidString).joined(separator: ", "))")
            lines.append("nearby: \(c.nearbyParticipantIDs.map(\.uuidString).joined(separator: ", "))")
        }
        #endif

        #if os(visionOS)
        lines.append("isSessionOriginOwner: \(isSessionOriginOwner)")
        if let originID = sessionOriginID {
            lines.append("originAnchorID: \(originID)")
            lines.append("originTracked: \(sessionOriginIsTracked)")
            if let t = sessionOriginTransform?.columns.3 {
                // Expected to DIFFER between devices — see the note in the panel.
                lines.append(String(format: "originFromAnchor.translation: [%.4f, %.4f, %.4f]  (MUST DIFFER between devices)", t.x, t.y, t.z))
            } else {
                lines.append("originFromAnchor.translation: unresolved locally")
            }
        } else {
            lines.append("originAnchorID: none")
        }
        #endif

        lines.append("multipeerPeers: \(connectedPeers.map(\.displayName).joined(separator: ", "))")

        lines.append("--- diagrams (\(sharedDiagrams.count)) ---")
        for d in sharedDiagrams {
            let p = d.anchorRelativePosition
            let pos = p.map { String(format: "[%.4f, %.4f, %.4f]", $0.x, $0.y, $0.z) } ?? "—"
            lines.append("  \(d.filename)  elements=\(d.elements.count)  anchorRelPos=\(pos)  scale=\(d.anchorRelativeScale.map { String(format: "%.3f", $0) } ?? "—")")
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
