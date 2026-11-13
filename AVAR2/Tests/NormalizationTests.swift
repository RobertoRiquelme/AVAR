import Foundation
import simd

/// The data ↔ container mapping a dragged node goes through.
///
/// A node's position is read from its entity in container-local metres and written back to the
/// shared model in the diagram's data coordinates. If the two directions are not exact inverses,
/// every drag nudges the node on whichever device rebuilds from the model (the iPhone, a late
/// joiner).
@main
struct NormalizationTests {
    static func main() {
        testForwardMatchesTheOriginalFormula()
        testRoundTrip3D()
        testRoundTrip2DFlipsY()
        testZeroRangeDoesNotDivideByZero()
        testOutsideTheOriginalBounds()
        print("NormalizationTests ✅")
    }

    static func elements(_ positions: [[Double]]) -> [ElementDTO] {
        let json = "[" + positions.enumerated().map { i, p in
            "{\"id\":\"n\(i)\",\"type\":\"node\",\"position\":[\(p.map { String($0) }.joined(separator: ","))]}"
        }.joined(separator: ",") + "]"
        return try! JSONDecoder().decode([ElementDTO].self, from: Data(json.utf8))
    }

    static func close(_ a: [Double], _ b: [Double], tolerance: Double) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// The forward mapping was moved out of `ElementViewModel`; it must still place nodes exactly
    /// where it did, or every diagram shifts.
    static func testForwardMatchesTheOriginalFormula() {
        let context = NormalizationContext(elements: elements([[0, 0, 0], [10, 20, 40]]), is2D: false)
        // centers (5, 10, 20), global range 40 → (x - c) / 40 * 2
        let p = context.containerPosition(forData: [10, 20, 40])
        assert(simd_distance(p, [0.25, 0.5, 1.0]) < 1e-6, "got \(p)")
        let q = context.containerPosition(forData: [0, 0, 0])
        assert(simd_distance(q, [-0.25, -0.5, -1.0]) < 1e-6, "got \(q)")
        // Missing components read as zero, as before.
        assert(simd_distance(context.containerPosition(forData: [5]), [0, -0.5, -1.0]) < 1e-6)
    }

    static func testRoundTrip3D() {
        let context = NormalizationContext(elements: elements([[-120, 4, 900], [310, 77, -45], [8, 8, 8]]), is2D: false)
        for data in [[-120.0, 4, 900], [310, 77, -45], [8, 8, 8], [1.5, -3.25, 1234.5]] {
            let back = context.dataPosition(forContainer: context.containerPosition(forData: data))
            // Float precision across a range of ~1000 units.
            assert(close(back, data, tolerance: 1e-3), "\(data) came back as \(back)")
        }
        // And the other way round, from where an entity actually is.
        for position in [SIMD3<Float>(0.3, -0.7, 0.9), SIMD3<Float>(-1, 1, 0)] {
            let again = context.containerPosition(forData: context.dataPosition(forContainer: position))
            assert(simd_distance(again, position) < 1e-5, "\(position) came back as \(again)")
        }
    }

    /// 2D diagrams draw Y downwards, and report two data coordinates, not three.
    static func testRoundTrip2DFlipsY() {
        let context = NormalizationContext(elements: elements([[0, 0], [200, 100]]), is2D: true)
        let p = context.containerPosition(forData: [200, 100])
        assert(p.y < 0, "2D Y must be flipped, got \(p)")
        assert(p.z == 0, "2D has no depth")
        let back = context.dataPosition(forContainer: p)
        assert(back.count == 2, "2D data has two coordinates, got \(back)")
        assert(close(back, [200, 100], tolerance: 1e-3), "came back as \(back)")
        // A stray Z on the entity must not leak into 2D data.
        assert(context.dataPosition(forContainer: [p.x, p.y, 0.4]).count == 2)
    }

    /// All nodes at one point: every range is zero and is replaced by 1.
    static func testZeroRangeDoesNotDivideByZero() {
        let context = NormalizationContext(elements: elements([[7, 7, 7], [7, 7, 7]]), is2D: false)
        let p = context.containerPosition(forData: [7, 7, 7])
        assert(p.x.isFinite && p.y.isFinite && p.z.isFinite && simd_length(p) < 1e-6, "got \(p)")
        let back = context.dataPosition(forContainer: [0.5, 0, -0.5])
        assert(back.allSatisfy(\.isFinite), "got \(back)")
        assert(close(context.dataPosition(forContainer: context.containerPosition(forData: back)), back, tolerance: 1e-4))
    }

    /// A node dragged past the diagram's original extent still maps back exactly, using the
    /// context it was dragged in.
    static func testOutsideTheOriginalBounds() {
        let context = NormalizationContext(elements: elements([[0, 0, 0], [10, 10, 10]]), is2D: false)
        let far = SIMD3<Float>(3, -4, 5)
        let data = context.dataPosition(forContainer: far)
        assert(data[0] > 10 && data[1] < 0 && data[2] > 10, "expected to leave the bounds, got \(data)")
        assert(simd_distance(context.containerPosition(forData: data), far) < 1e-4)
    }
}
