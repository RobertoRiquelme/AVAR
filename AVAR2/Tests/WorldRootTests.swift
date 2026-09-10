import Foundation
import RealityKit
import simd

/// Pins the RealityKit semantics that `ElementViewModel.updateWorldRoot(originFromAnchor:)`
/// depends on when it keeps locally-authored content physically stationary as the session origin
/// appears or is refined.
///
/// The fix is only a few lines, but it rests entirely on how `relativeTo:` composes through a
/// parent whose transform changes underneath. If that behaved differently — or if a future
/// RealityKit changed it — local diagrams would silently drift off the surface the user placed
/// them on, or peers would be sent the wrong anchor-relative pose. Both are invisible in a build
/// and expensive to notice on hardware, so they are asserted here.
@main
struct WorldRootTests {
    static func main() {
        testParentChangeMovesChild_theJump()
        testRestoringWorldPosePreservesPhysicalPlacement()
        testRestoredPoseYieldsCorrectAnchorRelativeValue()
        testPeerOriginatedContentMovesWithTheFrame()
        testUnitScaleParentLeavesChildScaleUntouched()
        print("WorldRootTests ✅")
    }

    /// Establishes the problem: a child keeps its parent-relative pose, so moving the parent moves
    /// the child in world space. This is the jump that local content used to exhibit the instant a
    /// session origin was established.
    static func testParentChangeMovesChild_theJump() {
        let (worldRoot, child) = makeHierarchy()
        child.setPosition(SIMD3<Float>(0, 1.0, -2.0), relativeTo: nil)
        let before = child.position(relativeTo: nil)

        worldRoot.transform = Transform(matrix: anchorPose())

        let after = child.position(relativeTo: nil)
        assert(simd_length(after - before) > 0.1,
               "Expected the child to move with its parent (the jump). before=\(before) after=\(after)")
    }

    /// The fix: capture the world pose, move the frame, restore the world pose.
    static func testRestoringWorldPosePreservesPhysicalPlacement() {
        for pose in [anchorPose(), refinementPose(), matrix_identity_float4x4] {
            let (worldRoot, child) = makeHierarchy()
            let placed = SIMD3<Float>(0.4, 1.1, -1.7)
            let placedRotation = simd_quatf(angle: 0.6, axis: simd_normalize(SIMD3<Float>(0, 1, 0.2)))
            child.setPosition(placed, relativeTo: nil)
            child.setOrientation(placedRotation, relativeTo: nil)

            let worldPosition = child.position(relativeTo: nil)
            let worldOrientation = child.orientation(relativeTo: nil)

            worldRoot.transform = Transform(matrix: pose)

            child.setPosition(worldPosition, relativeTo: nil)
            child.setOrientation(worldOrientation, relativeTo: nil)

            let finalPosition = child.position(relativeTo: nil)
            let finalOrientation = child.orientation(relativeTo: nil)
            assert(simd_length(finalPosition - placed) < 1e-4,
                   "Local content must not move. expected=\(placed) got=\(finalPosition)")
            assert(quatClose(finalOrientation, placedRotation),
                   "Local content must not rotate. expected=\(placedRotation) got=\(finalOrientation)")
        }
    }

    /// Having stayed put, the value we broadcast must be the pose *in the new shared frame* — i.e.
    /// `worldRoot⁻¹ · world`. If this were still the old (pre-origin) number, peers would keep
    /// placing the diagram at the wrong physical spot forever, since the correction is one-shot.
    static func testRestoredPoseYieldsCorrectAnchorRelativeValue() {
        let (worldRoot, child) = makeHierarchy()
        let placed = SIMD3<Float>(-0.3, 1.4, -2.2)
        child.setPosition(placed, relativeTo: nil)

        let poseBefore = child.position(relativeTo: worldRoot)
        assert(simd_length(poseBefore - placed) < 1e-4,
               "With an identity frame, the shared pose should equal the world pose")

        let anchor = anchorPose()
        let worldPosition = child.position(relativeTo: nil)
        worldRoot.transform = Transform(matrix: anchor)
        child.setPosition(worldPosition, relativeTo: nil)

        let broadcast = child.position(relativeTo: worldRoot)
        let expected = anchor.inverse * SIMD4<Float>(placed.x, placed.y, placed.z, 1)
        assert(simd_length(broadcast - SIMD3<Float>(expected.x, expected.y, expected.z)) < 1e-3,
               "Broadcast pose must be anchor-relative. got=\(broadcast) expected=\(expected)")
        // And it must actually differ from the pre-origin value, or there'd be nothing to send.
        assert(simd_length(broadcast - poseBefore) > 0.1,
               "The shared-frame pose must change when the frame changes")
    }

    /// The opposite branch: a peer's diagram must keep its parent-relative pose and move with the
    /// frame, because that movement is what puts it on the same physical spot as the owner's copy.
    /// Two devices with different local anchor transforms must converge on one physical point.
    static func testPeerOriginatedContentMovesWithTheFrame() {
        let sharedPose = SIMD3<Float>(0.25, 1.2, -1.8)

        // Device A and device B resolve the SAME physical anchor as different local transforms.
        let (rootA, childA) = makeHierarchy()
        let (rootB, childB) = makeHierarchy()
        childA.setPosition(sharedPose, relativeTo: rootA)
        childB.setPosition(sharedPose, relativeTo: rootB)

        let anchorInA = anchorPose()
        // Same physical anchor, different origin: B's transform differs by a rigid offset.
        let bFromA = rigid(translation: SIMD3<Float>(1.7, -0.2, 0.9), yaw: 0.8)
        let anchorInB = bFromA * anchorInA

        rootA.transform = Transform(matrix: anchorInA)
        rootB.transform = Transform(matrix: anchorInB)

        // Each device's world position differs (different origins) …
        let worldInA = childA.position(relativeTo: nil)
        let worldInB = childB.position(relativeTo: nil)
        assert(simd_length(worldInA - worldInB) > 0.1,
               "Different origins should give different local world coordinates")

        // … but mapping B's world position back through the origin offset lands on A's, i.e. both
        // devices are pointing at the same physical place.
        let bMappedIntoA = bFromA.inverse * SIMD4<Float>(worldInB.x, worldInB.y, worldInB.z, 1)
        assert(simd_length(SIMD3<Float>(bMappedIntoA.x, bMappedIntoA.y, bMappedIntoA.z) - worldInA) < 1e-3,
               "Peer content must converge on one physical point across devices")
    }

    /// `updateWorldRoot` restores position and orientation but not scale, because `worldRoot` is
    /// always rigid and unit-scale (asserted in `SharedWorldRoot.apply`). Confirm scale is in fact
    /// unaffected, so that omission is safe rather than an oversight.
    static func testUnitScaleParentLeavesChildScaleUntouched() {
        let (worldRoot, child) = makeHierarchy()
        child.scale = SIMD3<Float>(repeating: 0.7)
        worldRoot.transform = Transform(matrix: anchorPose())
        assert(abs(child.scale.x - 0.7) < 1e-6,
               "A rigid unit-scale parent must not change child scale, got \(child.scale.x)")
    }

    // MARK: - Helpers

    static func makeHierarchy() -> (worldRoot: Entity, child: Entity) {
        let worldRoot = Entity()
        worldRoot.name = "worldRoot"
        let child = Entity()
        child.name = "graphRoot"
        worldRoot.addChild(child)
        return (worldRoot, child)
    }

    /// A plausible session-origin pose: 1.5 m out, yaw-only, gravity aligned.
    static func anchorPose() -> simd_float4x4 {
        rigid(translation: SIMD3<Float>(0.5, 1.2, -1.5), yaw: 0.65)
    }

    /// A small ARKit refinement of that pose.
    static func refinementPose() -> simd_float4x4 {
        rigid(translation: SIMD3<Float>(0.52, 1.21, -1.47), yaw: 0.66)
    }

    static func rigid(translation: SIMD3<Float>, yaw: Float) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: [0, 1, 0]))
        m.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        return m
    }

    static func quatClose(_ a: simd_quatf, _ b: simd_quatf) -> Bool {
        // q and -q are the same rotation.
        let dot = abs(simd_dot(a.vector, b.vector))
        return abs(dot - 1) < 1e-4
    }
}
