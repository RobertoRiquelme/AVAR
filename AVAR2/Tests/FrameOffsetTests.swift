import Foundation
import simd

/// The arithmetic behind the "ARKit → scene offset" diagnostic.
///
/// The live number comes from a system conversion that cannot run outside an immersive space, so
/// what can be pinned here is everything around it: that a known offset is recovered exactly,
/// that the answer does not depend on which anchor was used as the probe (the probe is the
/// moving device anchor), and that a conversion which silently did nothing is reported as
/// "unavailable" rather than as a large, convincing offset.
@main
struct FrameOffsetTests {
    static func main() {
        testNoOffsetWhenFramesAgree()
        testKnownOffsetIsRecoveredFromAnyAnchor()
        testUnresolvedConversionIsNotReportedAsAnOffset()
        testRejectsNonRigidAndNonFiniteInput()
        testPoseFromConvertedPoints()
        testNegligibleThreshold()
        print("FrameOffsetTests ✅")
    }

    static func pose(yawDegrees: Float, pitchDegrees: Float = 0, translation: SIMD3<Float>) -> simd_float4x4 {
        let q = simd_quatf(angle: yawDegrees * .pi / 180, axis: [0, 1, 0])
            * simd_quatf(angle: pitchDegrees * .pi / 180, axis: [1, 0, 0])
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4<Float>(translation, 1)
        return m
    }

    static let anchors: [simd_float4x4] = [
        pose(yawDegrees: 0, translation: [0, 1.6, 0]),
        pose(yawDegrees: 73, pitchDegrees: -20, translation: [2.5, 1.4, -3]),
        pose(yawDegrees: -140, pitchDegrees: 35, translation: [-4, 0.2, 1.1]),
    ]

    static func testNoOffsetWhenFramesAgree() {
        for anchor in anchors {
            guard case .measured(let offset) = FrameOffsetMath.offset(originFromAnchor: anchor, sceneFromAnchor: anchor)
            else { fatalError("agreeing frames must measure") }
            assert(offset.distance < 1e-4 && offset.angleDegrees < 0.05, "expected zero, got \(offset.summary)")
            assert(offset.isNegligible && offset.summary == "none")
        }
    }

    /// The whole point of the diagnostic: if the scene is displaced from ARKit by D, the result
    /// is D — whichever anchor happened to be sampled and wherever the head was.
    static func testKnownOffsetIsRecoveredFromAnyAnchor() {
        let sceneFromARKit = pose(yawDegrees: 37, translation: [1.3, -0.4, 0.7])
        for anchor in anchors {
            let result = FrameOffsetMath.offset(originFromAnchor: anchor, sceneFromAnchor: sceneFromARKit * anchor)
            guard case .measured(let offset) = result else { fatalError("expected a measurement, got \(result)") }
            assert(simd_distance(offset.translation, [1.3, -0.4, 0.7]) < 1e-3, "translation \(offset.translation)")
            assert(abs(offset.angleDegrees - 37) < 0.05, "angle \(offset.angleDegrees)")
            assert(abs(offset.distance - simd_length(SIMD3<Float>(1.3, -0.4, 0.7))) < 1e-3)
            assert(!offset.isNegligible)
            // And the recovered matrix really maps raw ARKit poses into the scene.
            let rebuilt = offset.sceneFromARKit * anchor
            assert(simd_distance(rebuilt.columns.3, (sceneFromARKit * anchor).columns.3) < 1e-3)
        }
    }

    /// A conversion that cannot resolve returns its input unchanged, so the rebuilt pose is
    /// identity. Taken at face value that would read as "offset = the whole anchor pose".
    static func testUnresolvedConversionIsNotReportedAsAnOffset() {
        for anchor in anchors {
            let result = FrameOffsetMath.offset(originFromAnchor: anchor, sceneFromAnchor: matrix_identity_float4x4)
            guard case .unavailable(let why) = result else { fatalError("identity conversion was reported as \(result)") }
            assert(why.contains("did not resolve"), why)
        }
        // Both identity is a real (if unlikely) agreement, not an unresolved conversion.
        guard case .measured(let offset) = FrameOffsetMath.offset(originFromAnchor: matrix_identity_float4x4,
                                                                  sceneFromAnchor: matrix_identity_float4x4)
        else { fatalError("identity/identity must measure") }
        assert(offset.isNegligible)
    }

    static func testRejectsNonRigidAndNonFiniteInput() {
        var scaled = anchors[1]
        scaled.columns.0 *= 2
        guard case .unavailable = FrameOffsetMath.offset(originFromAnchor: anchors[1], sceneFromAnchor: scaled)
        else { fatalError("scaled pose accepted") }

        var broken = anchors[1]
        broken.columns.3.x = .nan
        guard case .unavailable = FrameOffsetMath.offset(originFromAnchor: anchors[1], sceneFromAnchor: broken)
        else { fatalError("NaN pose accepted") }
        guard case .unavailable = FrameOffsetMath.offset(originFromAnchor: broken, sceneFromAnchor: anchors[1])
        else { fatalError("NaN raw pose accepted") }
    }

    /// The live code rebuilds a pose from four converted points; that reconstruction must return
    /// exactly the pose that produced the points.
    static func testPoseFromConvertedPoints() {
        for m in anchors {
            func convert(_ p: SIMD3<Float>) -> SIMD3<Float> {
                let v = m * SIMD4<Float>(p, 1)
                return SIMD3<Float>(v.x, v.y, v.z)
            }
            let rebuilt = FrameOffsetMath.pose(origin: convert([0, 0, 0]), x: convert([1, 0, 0]),
                                               y: convert([0, 1, 0]), z: convert([0, 0, 1]))
            for c in 0..<4 { assert(simd_distance(rebuilt[c], m[c]) < 1e-4, "column \(c)") }
            assert(FrameOffsetMath.isRigid(rebuilt))
        }
    }

    static func testNegligibleThreshold() {
        let base = anchors[0]
        func measured(_ d: simd_float4x4) -> FrameOffset {
            guard case .measured(let o) = FrameOffsetMath.offset(originFromAnchor: base, sceneFromAnchor: d * base)
            else { fatalError() }
            return o
        }
        assert(measured(pose(yawDegrees: 0, translation: [0.002, 0, 0])).isNegligible, "2 mm is noise")
        assert(!measured(pose(yawDegrees: 0, translation: [0.02, 0, 0])).isNegligible, "2 cm is an offset")
        assert(!measured(pose(yawDegrees: 2, translation: [0, 0, 0])).isNegligible, "2° is an offset")
    }
}
