import Foundation
import simd

@main
struct LayoutTests {
    static func main() {
        var coordinator = DiagramLayoutCoordinator(spacing: 1.0, skipBehindUser: true, maxSearchRadius: 3)
        let base = SIMD3<Float>(0, 0, -2)

        let p0 = coordinator.position(for: "diagram0", basePosition: base)
        assert(p0 == base, "First diagram should use base position")

        var seenPositions: Set<SIMD3<Float>> = [p0]
        for index in 1...8 {
            let filename = "diagram\(index)"
            let position = coordinator.position(for: filename, basePosition: base)
            assert(position.z <= -2, "Diagrams should never spawn behind the user (z: \(position.z))")
            assert(!seenPositions.contains(position), "Duplicate position assigned for \(filename)")
            seenPositions.insert(position)
        }

        // Fill up available radius to trigger fallback logic
        for index in 9...40 {
            _ = coordinator.position(for: "diagram_fallback_\(index)", basePosition: base)
        }

        let farPosition = coordinator.position(for: "diagram_far", basePosition: base)
        assert(farPosition.z < -2, "Fallback placement should continue forward (z: \(farPosition.z))")

        coordinator.release(filename: "diagram0")
        let reused = coordinator.position(for: "diagram0", basePosition: base)
        assert(reused == base, "Released slot should be reusable for same filename")

        print("LayoutTests ✅")
    }
}
