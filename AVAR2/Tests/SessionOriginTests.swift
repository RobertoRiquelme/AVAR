import Foundation
import simd

/// Tests for session-origin establishment: owner election and the gravity-aligned anchor pose.
///
/// These cover the logic whose failure produced the original misalignment bug. Election in
/// particular must be *provably* convergent — if two devices disagree about the owner, alignment
/// breaks silently and diagnosing it costs a two-headset session.
@main
struct SessionOriginTests {
    static func main() {
        testElectionIsPermutationInvariant()
        testElectionRequiresSelfInList()
        testElectionEmptyAndSingle()
        testTieBreakIsAntisymmetric()
        testPoseIsRigidAndUnitScale()
        testPoseIsGravityAlignedRegardlessOfHeadTilt()
        testPoseIsPlacedForwardAtDistance()
        testPoseHandlesLookingStraightDown()
        print("SessionOriginTests ✅")
    }

    // MARK: - Owner election

    /// The property that matters: every device sees `activeParticipants` in a different order
    /// (it is a `Set`), so the result must not depend on ordering. Exhaustive over all 24
    /// permutations of 4 ids.
    static func testElectionIsPermutationInvariant() {
        let ids = (0..<4).map { _ in UUID() }
        let expected = SessionOriginElection.owner(participantIDs: ids)
        precondition(expected != nil)

        var checked = 0
        for permutation in permutations(of: ids) {
            let got = SessionOriginElection.owner(participantIDs: permutation)
            assert(got == expected,
                   "Election is order-dependent: \(String(describing: got)) != \(String(describing: expected))")
            // And every device agrees on who is owner, whoever is asking.
            for id in ids {
                let isOwner = SessionOriginElection.isOwner(localID: id, participantIDs: permutation)
                assert(isOwner == (id == expected),
                       "isOwner disagreed with owner() for \(id)")
            }
            checked += 1
        }
        assert(checked == 24, "Expected 24 permutations, checked \(checked)")

        // Exactly one winner, and it is the lowest uuidString.
        let lowest = ids.map(\.uuidString).min()
        assert(expected?.uuidString == lowest, "Owner must be the lowest uuidString")
    }

    /// A device that does not yet see itself in `activeParticipants` must not claim ownership —
    /// otherwise a joining device could create a competing origin anchor.
    static func testElectionRequiresSelfInList() {
        let a = UUID(), b = UUID()
        let stranger = UUID()
        assert(!SessionOriginElection.isOwner(localID: stranger, participantIDs: [a, b]),
               "A participant absent from the list must not be owner")
        assert(!SessionOriginElection.isOwner(localID: nil, participantIDs: [a, b]),
               "A nil local id must not be owner")
    }

    static func testElectionEmptyAndSingle() {
        assert(SessionOriginElection.owner(participantIDs: []) == nil,
               "No participants means no owner")
        let solo = UUID()
        assert(SessionOriginElection.owner(participantIDs: [solo]) == solo)
        assert(SessionOriginElection.isOwner(localID: solo, participantIDs: [solo]),
               "A lone participant is its own owner")
    }

    /// The join-order race resolves from either side without extra messages: for any two distinct
    /// owners, exactly one yields. If both yielded (or neither) the session would end up with
    /// zero or two origins.
    static func testTieBreakIsAntisymmetric() {
        for _ in 0..<200 {
            let x = UUID(), y = UUID()
            let xYields = SessionOriginElection.shouldYield(toOwner: y, localOwnerID: x)
            let yYields = SessionOriginElection.shouldYield(toOwner: x, localOwnerID: y)
            assert(xYields != yYields,
                   "Exactly one side must yield (x:\(xYields) y:\(yYields))")
            // The survivor must be the same one election would have picked.
            let survivor = xYields ? y : x
            assert(SessionOriginElection.owner(participantIDs: [x, y]) == survivor,
                   "Tie-break winner must match election winner")
        }
        // Degenerate: yielding to yourself is not a yield.
        let same = UUID()
        assert(!SessionOriginElection.shouldYield(toOwner: same, localOwnerID: same),
               "Must not yield to self")
    }

    // MARK: - Gravity-aligned pose

    /// `SharedWorldRoot` asserts that worldRoot is rigid with unit scale, because several call
    /// sites pass parent-relative scale into `relativeTo: nil` transforms. The anchor pose is what
    /// feeds worldRoot, so it has to satisfy that.
    static func testPoseIsRigidAndUnitScale() {
        for tilt in [Float(-1.2), -0.4, 0, 0.5, 1.3] {
            let device = makeDevice(yaw: 0.7, pitch: tilt, at: [0.3, 1.5, -0.2])
            let pose = GravityAlignedPose.inFrontOf(deviceTransform: device, distance: 1.5)

            let cx = SIMD3<Float>(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z)
            let cy = SIMD3<Float>(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z)
            let cz = SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)

            assertClose(simd_length(cx), 1, "basis x not unit length", tol: 1e-4)
            assertClose(simd_length(cy), 1, "basis y not unit length", tol: 1e-4)
            assertClose(simd_length(cz), 1, "basis z not unit length", tol: 1e-4)
            // Orthogonal.
            assertClose(simd_dot(cx, cy), 0, "basis not orthogonal (x·y)", tol: 1e-4)
            assertClose(simd_dot(cy, cz), 0, "basis not orthogonal (y·z)", tol: 1e-4)
            assertClose(simd_dot(cx, cz), 0, "basis not orthogonal (x·z)", tol: 1e-4)
            // Homogeneous row intact.
            assertClose(pose.columns.3.w, 1, "w component must be 1", tol: 1e-6)
        }
    }

    /// The reason for yaw-only: the creator's head tilt must NOT end up in the shared frame, or
    /// every diagram on every device inherits it and surface snapping fights the anchor basis.
    static func testPoseIsGravityAlignedRegardlessOfHeadTilt() {
        let yaw: Float = 0.9
        let level = GravityAlignedPose.inFrontOf(
            deviceTransform: makeDevice(yaw: yaw, pitch: 0, at: [0, 1.6, 0]), distance: 1.5)

        for pitch in [Float(-1.0), -0.5, 0.3, 1.1] {
            let tilted = GravityAlignedPose.inFrontOf(
                deviceTransform: makeDevice(yaw: yaw, pitch: pitch, at: [0, 1.6, 0]), distance: 1.5)

            // Up axis stays world-up: that is what "gravity aligned" means.
            let up = SIMD3<Float>(tilted.columns.1.x, tilted.columns.1.y, tilted.columns.1.z)
            assertClose(up.y, 1, "up axis must be world +Y (pitch \(pitch))", tol: 1e-4)
            assertClose(up.x, 0, "up axis must have no X (pitch \(pitch))", tol: 1e-4)
            assertClose(up.z, 0, "up axis must have no Z (pitch \(pitch))", tol: 1e-4)

            // Rotation is identical to the untilted case — pitch is fully discarded.
            for column in 0..<3 {
                for row in 0..<3 {
                    assertClose(tilted[column, row], level[column, row],
                                "pitch \(pitch) leaked into basis at [\(column)][\(row)]", tol: 1e-4)
                }
            }
            // The anchor also stays at eye height rather than drifting up/down with the tilt.
            assertClose(tilted.columns.3.y, 1.6, "anchor must stay level with the eye", tol: 1e-4)
        }
    }

    static func testPoseIsPlacedForwardAtDistance() {
        let eye = SIMD3<Float>(1.0, 1.6, -0.5)
        for yaw in [Float(0), 0.5, 1.9, -2.4, Float.pi] {
            let pose = GravityAlignedPose.inFrontOf(
                deviceTransform: makeDevice(yaw: yaw, pitch: 0, at: eye), distance: 2.0)
            let position = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)

            // Horizontal distance is exactly the requested distance (Y unchanged).
            let horizontal = SIMD3<Float>(position.x - eye.x, 0, position.z - eye.z)
            assertClose(simd_length(horizontal), 2.0, "wrong forward distance at yaw \(yaw)", tol: 1e-3)
            assertClose(position.y, eye.y, "anchor should not change height", tol: 1e-4)

            // Pins the basis convention: the yaw maps +Z onto the creator's facing direction, so
            // the anchor's +Z points AWAY from the creator (and -Z back at them). This is the
            // opposite of ARKit's usual -Z-forward convention — see GravityAlignedPose's docs.
            // The absolute yaw is functionally invisible, but it must not drift silently.
            let anchorPlusZ = simd_normalize(SIMD3<Float>(pose.columns.2.x, 0, pose.columns.2.z))
            let towardAnchor = simd_normalize(horizontal)
            assertClose(simd_dot(anchorPlusZ, towardAnchor), 1,
                        "anchor +Z must point away from the creator at yaw \(yaw)", tol: 1e-3)
        }
    }

    /// Looking straight down degenerates the horizontal projection to ~zero length; normalizing it
    /// would produce NaN and poison every downstream transform.
    static func testPoseHandlesLookingStraightDown() {
        for pitch in [-Float.pi / 2, Float.pi / 2] {
            let device = makeDevice(yaw: 0, pitch: pitch, at: [0, 1.6, 0])
            let pose = GravityAlignedPose.inFrontOf(deviceTransform: device, distance: 1.5)
            for column in 0..<4 {
                for row in 0..<4 {
                    assert(pose[column, row].isFinite,
                           "Degenerate look direction produced non-finite value at [\(column)][\(row)]")
                }
            }
            let position = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            assertClose(simd_length(position - SIMD3<Float>(0, 1.6, 0)), 1.5,
                        "fallback should still place the anchor at the requested distance", tol: 1e-3)
        }
    }

    // MARK: - Helpers

    /// A device transform with the given yaw (around world Y) then pitch (around local X).
    static func makeDevice(yaw: Float, pitch: Float, at position: SIMD3<Float>) -> simd_float4x4 {
        let rotation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
        var m = simd_float4x4(rotation)
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return m
    }

    static func assertClose(_ a: Float, _ b: Float, _ message: String, tol: Float) {
        assert(abs(a - b) <= tol, "\(message) — got \(a), expected \(b) (tol \(tol))")
    }

    static func permutations<T>(of items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var result: [[T]] = []
        for (index, item) in items.enumerated() {
            var rest = items
            rest.remove(at: index)
            for tail in permutations(of: rest) {
                result.append([item] + tail)
            }
        }
        return result
    }
}
