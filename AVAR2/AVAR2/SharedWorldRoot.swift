//
//  SharedWorldRoot.swift
//  AVAR2
//
//  The shared session-origin frame that every diagram hangs from.
//

#if os(visionOS)
import RealityKit
import SwiftUI   // RealityViewContent
import simd
import OSLog

/// Whether this build ships the on-device test affordances (loopback injection, the offset
/// `worldRoot` toggle).
///
/// Deliberately **not** `#if DEBUG`. Hardware validation happens through TestFlight, which ships
/// **Release** builds — so gating on DEBUG removed precisely the tools needed to do the testing
/// from the only builds used to do it. This is a research app distributed to its own author, so
/// the affordances are always compiled; they live behind the Diagnostics disclosure and are inert
/// unless opened. Flip this to `false` (or restore a `#if DEBUG`) before any App Store build.
let includesTestAffordances = true

/// Owns the `worldRoot` entity: the parent of every diagram, positioned at this device's own
/// resolved transform for the session-origin shared `WorldAnchor`.
///
/// ## Why a parent entity rather than matrix math
///
/// With diagrams parented here, a diagram's pose in the *shared* frame is literally
/// `container.position(relativeTo: worldRoot)`. Sending that value and applying it with
/// `setPosition(_, relativeTo: worldRoot)` on the receiver is the whole synchronisation
/// mechanism — no inverse matrices, no per-message conversion, and no way for the sender's and
/// receiver's conventions to drift apart.
///
/// ## Why one root per RealityView
///
/// The app renders each diagram in its own `RealityView` (plus one for surfaces), and entity
/// hierarchies cannot span RealityViews. But they all live in the single
/// `ImmersiveSpace(id: "MainImmersive")`, so their content origins coincide — giving each one a
/// `worldRoot` at the same transform yields identical placement. That keeps every existing
/// gesture chain untouched, which is the main reason this is preferred over collapsing to one
/// RealityView with a gesture router.
///
/// ## Why `AnchorEntity` is not used
///
/// `AnchoringComponent.Target` only offers `.world(transform:)` — a static snapshot. There is no
/// target that tracks an ARKit `WorldAnchor` by id, so driving `transform` manually from
/// `anchorUpdates` is the supported path, not a workaround. It is also preferable here: it lets
/// us *freeze* the pose when `anchor.isTracked` goes false instead of letting content slew.
enum SharedWorldRoot {
    static let name = "worldRoot"

    /// Returns this RealityView's `worldRoot`, creating it if needed.
    static func findOrCreate(in content: RealityViewContent) -> Entity {
        if let existing = content.entities.first(where: { $0.name == name }) {
            return existing
        }
        let root = Entity()
        root.name = name
        content.add(root)
        return root
    }

    /// A deliberately awkward stand-in for a real session origin: offset on all three axes and
    /// rotated 37° about Y.
    ///
    /// With a single headset no origin ever resolves, so `worldRoot` sits at identity and the
    /// reparenting is only exercised in its trivial case — where parent-relative and world
    /// coordinates happen to coincide and a frame-mixing bug is invisible. Forcing a non-identity
    /// frame makes those bugs manifest on one device: the five sites fixed in `ElementViewModel`
    /// would each misplace content by this transform. The yaw is intentionally not a multiple of
    /// 90° so an axis swap cannot masquerade as correct.
    static let debugOffsetPose: simd_float4x4 = {
        var m = simd_float4x4(simd_quatf(angle: 37 * .pi / 180, axis: [0, 1, 0]))
        m.columns.3 = SIMD4<Float>(1.3, -0.4, 0.7, 1)
        return m
    }()

    /// Points `worldRoot` at the session origin.
    ///
    /// Falls back to identity when no origin is resolved yet, so content is
    /// **visible-but-unaligned** rather than invisible. Hiding it would read to users as
    /// "sharing is broken" when the truth is "alignment is still pending".
    static func apply(originFromAnchor: simd_float4x4?, to root: Entity) {
        let matrix = originFromAnchor ?? matrix_identity_float4x4
        assertRigidUnitScale(matrix)
        root.transform = Transform(matrix: matrix)
    }

    /// A handful of call sites in `ElementViewModel` pass the container's *parent-relative* scale
    /// into a `Transform` used with `relativeTo: nil` (`animateToFinalPosition`,
    /// `unsnapFromSurface`, `animateToSnapPosition`). That is only numerically correct while
    /// `worldRoot` is rigid with unit scale — which it always is, being a `WorldAnchor` pose.
    ///
    /// Rather than rewrite those three call sites for a condition that cannot currently occur,
    /// the invariant is asserted where it is established. If a future change ever gives
    /// `worldRoot` a scale, this trips in debug instead of silently producing diagrams that are
    /// subtly the wrong size on one device only.
    private static func assertRigidUnitScale(_ m: simd_float4x4) {
        let sx = simd_length(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let sy = simd_length(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let sz = simd_length(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        guard abs(sx - 1) > 1e-3 || abs(sy - 1) > 1e-3 || abs(sz - 1) > 1e-3 else { return }

        let message = "worldRoot must be rigid with unit scale (got \(sx), \(sy), \(sz)) — ElementViewModel mixes parent-relative scale with relativeTo: nil transforms"
        // `assert` is stripped in Release, and Release is what TestFlight ships — so also log,
        // or the invariant would be silently unenforced in exactly the builds run on hardware.
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "AVAR2", category: "SharedWorldRoot")
            .fault("\(message, privacy: .public)")
        assertionFailure(message)
    }
}
#endif
