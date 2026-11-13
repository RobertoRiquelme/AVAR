//
//  FrameDiagnostics.swift
//  AVAR2
//
//  Measures how ARKit's coordinate frame relates to the RealityKit scene the app draws in.
//
//  ## Why this exists
//
//  Diagrams are shared in the **group immersive space's** coordinate system: with
//  `supportsGroupImmersiveSpace` the system gives every spatial SharePlay participant (nearby or a
//  FaceTime Persona) one shared scene frame, so a pose sent as plain scene coordinates lands in
//  the same place for everyone. Nothing in that path touches ARKit.
//
//  ARKit is a different matter. `originFromAnchorTransform` is expressed in ARKit's origin, and
//  Apple documents that the system *moves the immersive space* when a shared activity starts
//  (`immersiveSpaceDisplacement`). Whether ARKit's origin moves with it is not documented. If it
//  does not, every raw ARKit transform used as an entity transform — plane overlays, surface
//  snapping, the shared room anchor — is off by that displacement while sharing.
//
//  This file turns that open question into two numbers on the diagnostics panel:
//
//  - the immersive-space displacement, read from SwiftUI; and
//  - the ARKit → scene offset, obtained by asking the system to convert an anchor into scene
//    coordinates (visionOS 27 `coordinateSpace(correction:)`) and comparing with the raw value.
//
//  Outside a shared session both should read zero. That is the calibration step that makes the
//  second number trustworthy, since the conversion's behaviour is otherwise taken on faith.
//

import Foundation
import simd

// MARK: - Pure math (host-testable)

/// Where ARKit's origin sits in RealityKit scene coordinates.
struct FrameOffset: Equatable {
    /// Maps a raw ARKit transform into scene space: `sceneFromAnchor = sceneFromARKit * originFromAnchor`.
    var sceneFromARKit: simd_float4x4
    /// Translation part, in metres.
    var translation: SIMD3<Float>
    /// Length of `translation`, in metres.
    var distance: Float
    /// Rotation part as a single angle, in degrees.
    var angleDegrees: Float

    /// Below this the two frames are the same for any practical purpose.
    var isNegligible: Bool { distance < 0.005 && angleDegrees < 0.25 }

    var summary: String {
        isNegligible ? "none" : String(format: "%.1f cm · %.1f°", distance * 100, angleDegrees)
    }

    var vectorDescription: String {
        String(format: "[%.4f, %.4f, %.4f] m, %.2f°", translation.x, translation.y, translation.z, angleDegrees)
    }
}

enum FrameOffsetMeasurement: Equatable {
    /// No trustworthy number, with the reason shown to the person reading the panel.
    case unavailable(String)
    case measured(FrameOffset)

    var summary: String {
        switch self {
        case .unavailable(let why): return why
        case .measured(let offset): return offset.summary
        }
    }

    var vectorDescription: String {
        switch self {
        case .unavailable(let why): return "unavailable (\(why))"
        case .measured(let offset): return offset.vectorDescription
        }
    }
}

enum FrameOffsetMath {
    /// Rebuilds a rigid pose from four converted points: the frame's origin and the tips of its
    /// unit axes.
    ///
    /// Points are used instead of a "transform between spaces" call because converting a point
    /// *from* one space *into* another has only one possible meaning, whereas a transform's
    /// direction is a naming convention that is easy to get backwards.
    static func pose(origin: SIMD3<Float>, x: SIMD3<Float>, y: SIMD3<Float>, z: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(x - origin, 0),
            SIMD4<Float>(y - origin, 0),
            SIMD4<Float>(z - origin, 0),
            SIMD4<Float>(origin, 1)
        ))
    }

    /// The offset between the two frames, from one anchor seen both ways.
    ///
    /// - Parameters:
    ///   - originFromAnchor: the anchor's raw ARKit pose.
    ///   - sceneFromAnchor: the same anchor's pose in scene coordinates, from the system's own
    ///     conversion.
    ///
    /// The result does not depend on which anchor was used or where it is — only on the two
    /// frames — which is what lets a moving device anchor serve as the probe.
    static func offset(originFromAnchor: simd_float4x4, sceneFromAnchor: simd_float4x4) -> FrameOffsetMeasurement {
        guard isFinite(originFromAnchor), isFinite(sceneFromAnchor) else {
            return .unavailable("non-finite transform")
        }
        guard isRigid(sceneFromAnchor) else {
            return .unavailable("conversion was not a rigid pose")
        }
        // An unresolved conversion hands its input straight back, so the "converted" unit frame
        // comes out as identity. A real anchor is never exactly at the origin with no rotation,
        // so identity here means "nothing was converted", not "the frames agree".
        if isIdentity(sceneFromAnchor), !isIdentity(originFromAnchor) {
            return .unavailable("conversion did not resolve")
        }

        let sceneFromARKit = sceneFromAnchor * originFromAnchor.inverse
        let translation = SIMD3<Float>(sceneFromARKit.columns.3.x, sceneFromARKit.columns.3.y, sceneFromARKit.columns.3.z)
        let trace = sceneFromARKit.columns.0.x + sceneFromARKit.columns.1.y + sceneFromARKit.columns.2.z
        let cosine = max(-1, min(1, (trace - 1) / 2))
        return .measured(FrameOffset(sceneFromARKit: sceneFromARKit,
                                     translation: translation,
                                     distance: simd_length(translation),
                                     angleDegrees: acos(cosine) * 180 / .pi))
    }

    static func isFinite(_ m: simd_float4x4) -> Bool {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
        }
    }

    static func isIdentity(_ m: simd_float4x4, tolerance: Float = 1e-5) -> Bool {
        let d = m - matrix_identity_float4x4
        return [d.columns.0, d.columns.1, d.columns.2, d.columns.3].allSatisfy {
            abs($0.x) < tolerance && abs($0.y) < tolerance && abs($0.z) < tolerance && abs($0.w) < tolerance
        }
    }

    /// Unit-length, mutually perpendicular axes.
    static func isRigid(_ m: simd_float4x4, tolerance: Float = 1e-2) -> Bool {
        let x = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let y = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let z = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        return abs(simd_length(x) - 1) < tolerance && abs(simd_length(y) - 1) < tolerance
            && abs(simd_length(z) - 1) < tolerance
            && abs(simd_dot(x, y)) < tolerance && abs(simd_dot(y, z)) < tolerance && abs(simd_dot(x, z)) < tolerance
    }

    static func describe(pose m: simd_float4x4) -> String {
        let t = m.columns.3
        let trace = m.columns.0.x + m.columns.1.y + m.columns.2.z
        let angle = acos(max(-1, min(1, (trace - 1) / 2))) * 180 / .pi
        return String(format: "[%.4f, %.4f, %.4f] m, %.2f°", t.x, t.y, t.z, angle)
    }
}

// MARK: - Live measurement (visionOS)

#if os(visionOS)
import ARKit
import RealityKit
import Spatial
import QuartzCore
import Observation

/// Publishes the frame measurements for the diagnostics panel.
///
/// `@Observable` rather than part of `CollaborativeSessionManager` so a once-a-second refresh
/// re-renders only the rows that read these values, not every view observing the session.
@MainActor
@Observable
final class FrameDiagnostics {
    /// How far the system has moved the immersive space from its default position. `nil` while
    /// the immersive space is closed. Non-identity means SharePlay has established a shared space.
    var displacement: simd_float4x4?

    /// ARKit → scene offset using the transform ARKit recommends for drawing content.
    private(set) var renderedOffset: FrameOffsetMeasurement = .unavailable("immersive space is closed")
    /// The same, without ARKit's display correction — separated so a few millimetres of display
    /// correction are not mistaken for a frame offset.
    private(set) var metricOffset: FrameOffsetMeasurement = .unavailable("immersive space is closed")
    /// The shared room anchor's position in scene coordinates, when one is tracked. On two
    /// headsets these should match if the group immersive space is physically shared.
    private(set) var roomAnchorInScene: SIMD3<Float>?

    @ObservationIgnored private var session: ARKitSession?
    @ObservationIgnored private var provider: WorldTrackingProvider?
    /// Raw and converted device poses from the latest sample, for the copyable report only.
    @ObservationIgnored private var lastSample: (raw: simd_float4x4, converted: simd_float4x4)?

    var displacementSummary: String {
        guard let displacement else { return "immersive space is closed" }
        if FrameOffsetMath.isIdentity(displacement, tolerance: 1e-4) { return "none" }
        let t = displacement.columns.3
        let trace = displacement.columns.0.x + displacement.columns.1.y + displacement.columns.2.z
        let angle = acos(max(-1, min(1, (trace - 1) / 2))) * 180 / .pi
        return String(format: "%.1f cm · %.1f°", simd_length(SIMD3<Float>(t.x, t.y, t.z)) * 100, angle)
    }

    /// Samples once a second until cancelled. Call from a view inside the immersive space, whose
    /// lifetime is the lifetime of the scene being measured.
    ///
    /// - Parameters:
    ///   - scene: the RealityKit scene content is drawn in.
    ///   - roomAnchor: the shared room anchor, if one is currently tracked.
    func run(scene: @escaping @MainActor () -> RealityKit.Scene?,
             roomAnchor: @escaping @MainActor () -> WorldAnchor?) async {
        guard #available(visionOS 27.0, *) else {
            setOffsets(.unavailable("needs visionOS 27"))
            return
        }
        guard WorldTrackingProvider.isSupported else {
            setOffsets(.unavailable("world tracking is not supported here"))
            return
        }
        let session = ARKitSession()
        let provider = WorldTrackingProvider()
        self.session = session
        self.provider = provider
        defer {
            session.stop()
            self.session = nil
            self.provider = nil
            self.lastSample = nil
            self.roomAnchorInScene = nil
            setOffsets(.unavailable("immersive space is closed"))
        }
        do {
            try await session.run([provider])
        } catch {
            setOffsets(.unavailable("world tracking failed: \(error.localizedDescription)"))
            return
        }
        while !Task.isCancelled {
            sample(provider: provider, scene: scene(), roomAnchor: roomAnchor())
            try? await Task.sleep(for: .seconds(1))
        }
    }

    @available(visionOS 27.0, *)
    private func sample(provider: WorldTrackingProvider, scene: RealityKit.Scene?, roomAnchor: WorldAnchor?) {
        guard let scene else {
            setOffsets(.unavailable("scene is not ready"))
            return
        }
        guard let device = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), device.isTracked else {
            setOffsets(.unavailable("device pose is not tracked"))
            return
        }
        // Raw pose and coordinate space come from the SAME anchor value, so head movement
        // between the two reads cannot show up as a frame offset.
        let raw = device.originFromAnchorTransform
        do {
            let rendered = try Self.pose(of: device.coordinateSpace(correction: .rendered), in: scene)
            let metric = try Self.pose(of: device.coordinateSpace(correction: .none), in: scene)
            lastSample = (raw, rendered)
            publish(rendered: FrameOffsetMath.offset(originFromAnchor: raw, sceneFromAnchor: rendered),
                    metric: FrameOffsetMath.offset(originFromAnchor: raw, sceneFromAnchor: metric))
        } catch {
            setOffsets(.unavailable("conversion failed: \(error)"))
        }

        var anchorPosition: SIMD3<Float>?
        if let roomAnchor, roomAnchor.isTracked,
           let pose = try? Self.pose(of: roomAnchor.coordinateSpace(correction: .rendered), in: scene),
           !FrameOffsetMath.isIdentity(pose) {
            anchorPosition = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        }
        if !Self.nearlyEqual(anchorPosition, roomAnchorInScene) { roomAnchorInScene = anchorPosition }
    }

    /// An ARKit coordinate space's pose in scene coordinates, via the system's own conversion.
    @available(visionOS 27.0, *)
    private static func pose(of space: ARKitCoordinateSpace, in scene: RealityKit.Scene) throws -> simd_float4x4 {
        func converted(_ x: Float, _ y: Float, _ z: Float) throws -> SIMD3<Float> {
            let p = try scene.convert(value: Point3DFloat(x: x, y: y, z: z), from: space)
            return SIMD3<Float>(p.x, p.y, p.z)
        }
        return FrameOffsetMath.pose(origin: try converted(0, 0, 0),
                                    x: try converted(1, 0, 0),
                                    y: try converted(0, 1, 0),
                                    z: try converted(0, 0, 1))
    }

    private func setOffsets(_ value: FrameOffsetMeasurement) {
        publish(rendered: value, metric: value)
    }

    /// Writes only on a visible change, so a steady reading does not re-render the panel.
    private func publish(rendered: FrameOffsetMeasurement, metric: FrameOffsetMeasurement) {
        if !Self.sameReading(rendered, renderedOffset) {
            renderedOffset = rendered
            if Self.isVerbose {
                let raw = lastSample.map { FrameOffsetMath.describe(pose: $0.raw) } ?? "—"
                print("🧭 ARKit→scene offset (rendered): \(rendered.vectorDescription)  [device raw pose: \(raw)]")
            }
        }
        if !Self.sameReading(metric, metricOffset) {
            metricOffset = metric
            if Self.isVerbose { print("🧭 ARKit→scene offset (metric): \(metric.vectorDescription)") }
        }
    }

    private static let isVerbose = ProcessInfo.processInfo.environment["AVAR_VERBOSE_LOGS"] != nil

    private static func sameReading(_ a: FrameOffsetMeasurement, _ b: FrameOffsetMeasurement) -> Bool {
        switch (a, b) {
        case (.unavailable(let x), .unavailable(let y)): return x == y
        case (.measured(let x), .measured(let y)):
            return simd_distance(x.translation, y.translation) < 0.001 && abs(x.angleDegrees - y.angleDegrees) < 0.05
        default: return false
        }
    }

    private static func nearlyEqual(_ a: SIMD3<Float>?, _ b: SIMD3<Float>?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return simd_distance(x, y) < 0.001
        default: return false
        }
    }

    /// Lines for "Copy diagnostics": full vectors, so two headsets' reports can be compared.
    func reportLines() -> [String] {
        var lines = ["--- coordinate frames ---"]
        lines.append("immersiveSpaceDisplacement: " + (displacement.map(FrameOffsetMath.describe(pose:)) ?? "immersive space closed"))
        lines.append("arkitToSceneOffset (rendered): \(renderedOffset.vectorDescription)")
        lines.append("arkitToSceneOffset (metric): \(metricOffset.vectorDescription)")
        if let lastSample {
            lines.append("deviceAnchor raw originFromAnchor: \(FrameOffsetMath.describe(pose: lastSample.raw))")
            lines.append("deviceAnchor converted to scene:   \(FrameOffsetMath.describe(pose: lastSample.converted))")
        }
        if let p = roomAnchorInScene {
            lines.append(String(format: "roomAnchor in scene space: [%.4f, %.4f, %.4f]", p.x, p.y, p.z))
        } else {
            lines.append("roomAnchor in scene space: —")
        }
        return lines
    }
}
#endif
