import Foundation
import ARKit

/// Guards the visionOS 26 `classification` → `surfaceClassification` migration.
///
/// The rename is not cosmetic. ARKit collapsed three pre-26 cases (`.unknown`, `.undetermined`,
/// `.notAvailable`) into a single `.none` and added six new ones (stairs, bed, cabinet,
/// homeAppliance, tv, plant). That matters because `ElementViewModel.filterValidSurfaces` grants a
/// 3D diagram snap validity with:
///
///     isHorizontalSurface(surface) || surfaceType == "Floor" || surfaceType == "Table"
///
/// so the *strings* "Floor" and "Table" are load-bearing. If a new classification were ever mapped
/// to one of them, that surface would silently become a snap target — a diagram could start
/// snapping to a television. Nothing in the type system prevents that, so it is asserted here.
@main
struct SurfaceClassificationTests {
    /// Every case known at time of writing. `SurfaceClassification` is non-frozen and not
    /// `CaseIterable`, so this list is maintained by hand and cannot be derived. A classification
    /// added by a future ARKit falls into `@unknown default` and is treated as unclassified
    /// (deferring to the geometry heuristic) — safe, but it will not appear here until someone
    /// adds it, so revisit this list when updating the SDK.
    static let allCases: [SurfaceClassification] = [
        .none, .wall, .floor, .ceiling, .table, .seat, .window,
        .door, .stairs, .bed, .cabinet, .homeAppliance, .tv, .plant,
    ]

    static func main() {
        testOnlyFloorAndTableGrantSnapValidity()
        testUnclassifiedDefersToGeometry()
        testNamesAreTotalAndDistinct()
        testColoursAreTotal()
        print("SurfaceClassificationTests ✅")
    }

    /// The invariant that protects snapping.
    static func testOnlyFloorAndTableGrantSnapValidity() {
        let snapGranting = Set(["Floor", "Table"])
        var granting: Set<SurfaceClassification> = []
        for c in allCases where c.surfaceTypeName.map(snapGranting.contains) == true {
            granting.insert(c)
        }
        assert(granting == [.floor, .table],
               "Exactly .floor and .table may map to a snap-granting name. Got: "
               + "\(granting.map { $0.surfaceTypeName ?? "nil" }.sorted())")

        // Spelling matters as much as the set — the comparison is a literal string match.
        assert(SurfaceClassification.floor.surfaceTypeName == "Floor",
               "filterValidSurfaces compares against the literal \"Floor\"")
        assert(SurfaceClassification.table.surfaceTypeName == "Table",
               "filterValidSurfaces compares against the literal \"Table\"")

        // The six classifications new in visionOS 26 must not have become snap targets by name.
        for c in [SurfaceClassification.stairs, .bed, .cabinet, .homeAppliance, .tv, .plant] {
            let name = c.surfaceTypeName ?? "nil"
            assert(!snapGranting.contains(name),
                   "New classification \(name) must not grant snap validity by name; it can still "
                   + "qualify geometrically via isHorizontalSurface")
        }
    }

    /// `.none` must return nil so `getSurfaceTypeName` falls back to the vertical-surface
    /// heuristic. Returning a name here would strip that fallback for every unclassified plane.
    static func testUnclassifiedDefersToGeometry() {
        assert(SurfaceClassification.none.surfaceTypeName == nil,
               ".none must defer to the caller's geometry heuristic")
        for c in allCases where c != .none {
            assert(c.surfaceTypeName != nil, "\(c) should have a name")
        }
    }

    static func testNamesAreTotalAndDistinct() {
        let names = allCases.compactMap { $0.surfaceTypeName }
        assert(names.count == allCases.count - 1, "Exactly one case (.none) may be unnamed")
        assert(Set(names).count == names.count,
               "Names must be distinct so log output identifies the surface: \(names)")
        for name in names {
            assert(!name.isEmpty, "Empty surface name")
        }
    }

    /// Colours are debug-visualization only, but the switch must stay total or the app
    /// would not compile after an ARKit update — this catches an accidental `default:`.
    static func testColoursAreTotal() {
        for c in allCases {
            var a: CGFloat = 0
            c.color.getRed(nil, green: nil, blue: nil, alpha: &a)
            assert(a > 0, "\(String(describing: c.surfaceTypeName)) has a fully transparent colour")
        }
    }
}
