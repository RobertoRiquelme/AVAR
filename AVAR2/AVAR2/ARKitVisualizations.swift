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
        classification.color
    }

    var classificationDisplayName: String {
        switch classification {
        case .wall: return "Wall"
        case .floor: return "Floor"
        case .ceiling: return "Ceiling"
        case .table: return "Table"
        case .door: return "Door"
        case .seat: return "Seat"
        case .window: return "Window"
        case .undetermined: return "Undetermined"
        case .notAvailable: return "Not Available"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }
}

extension PlaneAnchor.Classification {
    var color: UIColor {
        switch self {
        case .wall:
            return UIColor.blue.withAlphaComponent(0.65)
        case .floor:
            return UIColor.red.withAlphaComponent(0.65)
        case .ceiling:
            return UIColor.green.withAlphaComponent(0.65)
        case .table:
            return UIColor.yellow.withAlphaComponent(0.65)
        case .door:
            return UIColor.brown.withAlphaComponent(0.65)
        case .seat:
            return UIColor.systemPink.withAlphaComponent(0.65)
        case .window:
            return UIColor.orange.withAlphaComponent(0.65)
        case .undetermined:
            return UIColor.lightGray.withAlphaComponent(0.65)
        case .notAvailable:
            return UIColor.gray.withAlphaComponent(0.65)
        case .unknown:
            return UIColor.black.withAlphaComponent(0.65)
        @unknown default:
            return UIColor.purple
        }
    }
}
#endif



