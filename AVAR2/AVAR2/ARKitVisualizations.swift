//
//  ARKitVisualizations.swift
//  AVAR2
//
//  Created by Roberto Riquelme on 04-07-25.
//

import ARKit
import SwiftUI

#if os(visionOS)
// Surface visualization helpers used by plane visualizations
extension PlaneAnchor {
    var classificationColor: UIColor {
        surfaceClassification.color
    }

    var classificationDisplayName: String {
        surfaceClassification.surfaceTypeName ?? "Unclassified"
    }
}

extension SurfaceClassification {
    /// Human-readable name, or `nil` when ARKit has not classified the surface.
    ///
    /// ⚠️ **"Floor" and "Table" are load-bearing.** `ElementViewModel.filterValidSurfaces` grants a
    /// 3D diagram snap validity via `surfaceType == "Floor" || surfaceType == "Table"`, so adding
    /// either string to another case silently turns that surface into a snap target. The six
    /// classifications added in visionOS 26 (stairs, bed, cabinet, homeAppliance, tv, plant)
    /// therefore return their own names: they can still qualify *geometrically* through
    /// `isHorizontalSurface`, exactly as they did before when they fell to `@unknown default`.
    /// `Tests/SurfaceClassificationTests.swift` pins this.
    ///
    /// `nil` for `.none` so the caller can apply its vertical-surface heuristic. `.none` replaces
    /// the pre-26 trio `.unknown` / `.undetermined` / `.notAvailable`, which ARKit has collapsed
    /// into a single case.
    var surfaceTypeName: String? {
        switch self {
        case .none: return nil
        case .wall: return "Wall"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        case .table: return "Table"
        case .door: return "Door"
        case .seat: return "Seat"
        case .window: return "Window"
        case .stairs: return "Stairs"
        case .bed: return "Bed"
        case .cabinet: return "Cabinet"
        case .homeAppliance: return "Appliance"
        case .tv: return "TV"
        case .plant: return "Plant"
        // Non-frozen enum: ARKit may add classifications. Treat anything new as unclassified so
        // it falls back to the geometry heuristic — the safe default, and crucially never
        // "Floor"/"Table", so a future case cannot silently become a snap target.
        @unknown default: return nil
        }
    }
}

extension SurfaceClassification {
    /// Debug visualization colour. Display only — nothing branches on it.
    var color: UIColor {
        switch self {
        case .wall: return UIColor.blue.withAlphaComponent(0.65)
        case .floor: return UIColor.red.withAlphaComponent(0.65)
        case .ceiling: return UIColor.green.withAlphaComponent(0.65)
        case .table: return UIColor.yellow.withAlphaComponent(0.65)
        case .door: return UIColor.brown.withAlphaComponent(0.65)
        case .seat: return UIColor.systemPink.withAlphaComponent(0.65)
        case .window: return UIColor.orange.withAlphaComponent(0.65)
        case .stairs: return UIColor.systemTeal.withAlphaComponent(0.65)
        case .bed: return UIColor.systemIndigo.withAlphaComponent(0.65)
        case .cabinet: return UIColor.systemBrown.withAlphaComponent(0.65)
        case .homeAppliance: return UIColor.systemCyan.withAlphaComponent(0.65)
        case .tv: return UIColor.systemPurple.withAlphaComponent(0.65)
        case .plant: return UIColor.systemGreen.withAlphaComponent(0.65)
        // Merges the pre-26 .undetermined / .notAvailable / .unknown, which used three
        // near-indistinguishable greys anyway.
        case .none: return UIColor.gray.withAlphaComponent(0.65)
        @unknown default: return UIColor.purple.withAlphaComponent(0.65)
        }
    }
}
#endif



