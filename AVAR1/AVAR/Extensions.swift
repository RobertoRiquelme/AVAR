//
//  Extensions.swift
//  AVAR
//
//  Created by Roberto Riquelme on 22-04-25.
//

// Extensions.swift
import UIKit

extension String {
    var colorFromHex: UIColor? {
        var hexSanitized = self.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexSanitized.hasPrefix("#") {
            hexSanitized.removeFirst()
        }

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let red = CGFloat((rgb & 0xFF0000) >> 16) / 255
        let green = CGFloat((rgb & 0x00FF00) >> 8) / 255
        let blue = CGFloat(rgb & 0x0000FF) / 255

        return UIColor(red: red, green: green, blue: blue, alpha: 1.0)
    }
}
