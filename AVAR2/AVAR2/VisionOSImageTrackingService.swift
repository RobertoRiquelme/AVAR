import Foundation
import SwiftUI

#if os(visionOS)
import ARKit
import RealityKit
import CoreGraphics

@MainActor
final class VisionOSImageTrackingService: ObservableObject {
    private let session = ARKitSession()
    private var provider: ImageTrackingProvider?

    // Client callback
    var onMarkerPose: ((String, SIMD3<Float>, simd_quatf) -> Void)?

    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var lastMarkerId: String? = nil
    @Published var lastUpdateDate: Date? = nil

    func start() async {
        guard ImageTrackingProvider.isSupported else {
            errorMessage = "ImageTrackingProvider is not supported on this device."
            return
        }

        // Build a checkerboard marker CGImage at runtime (no external asset required)
        var images: [ARKit.ReferenceImage] = []
        if let cg = Self.generateCheckerboard(size: 1024, grid: 9) {
            // physicalSize in meters (15 cm)
            let ref = ARKit.ReferenceImage(cgimage: cg, physicalSize: CGSize(width: 0.15, height: 0.15))
            images.append(ref)
        }

        provider = ImageTrackingProvider(referenceImages: images)
        guard provider != nil else {
            errorMessage = "Failed to create ImageTrackingProvider (no reference images)."
            return
        }

        do {
            if let provider { try await session.run([provider]) }
            isRunning = true
            Task { [weak self] in
                guard let self, let provider = self.provider else { return }
                for await update in provider.anchorUpdates {
                    switch update.event {
                    case .added, .updated:
                        let anchor = update.anchor
                        let M = anchor.originFromAnchorTransform
                        let pos = SIMD3<Float>(M.columns.3.x, M.columns.3.y, M.columns.3.z)
                        let rot = simd_quatf(M)
                        let name = Self.extractName(from: anchor)
                        self.lastMarkerId = name
                        self.lastUpdateDate = Date()
                        self.onMarkerPose?(name, pos, rot)
                    case .removed:
                        break
                    }
                }
            }
        } catch {
            errorMessage = "Image tracking error: \(error.localizedDescription)"
            isRunning = false
        }
    }

    private static func extractName(from anchor: Any) -> String {
        // Try to pull a `name` from likely properties using reflection; fallback to "marker"
        let mirror = Mirror(reflecting: anchor)
        for child in mirror.children {
            if child.label == "name", let n = child.value as? String, !n.isEmpty { return n }
            if child.label == "referenceImage" {
                let m2 = Mirror(reflecting: child.value)
                for c2 in m2.children {
                    if c2.label == "name", let n = c2.value as? String, !n.isEmpty { return n }
                }
            }
        }
        return "marker"
    }

    private static func generateCheckerboard(size: Int, grid: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Background white
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // Black border
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(CGFloat(size) * 0.01) // 1% border
        ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(size)-1, height: CGFloat(size)-1))

        // Draw checkerboard pattern inside
        let cell = CGFloat(size) / CGFloat(grid)
        // Fill entire inside with black first
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // Overlay white cells in alternating pattern
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for i in 0..<grid {
            for j in 0..<grid {
                // Classic checker: (i + j) % 2 == 1 is white
                if ((i + j) % 2) == 1 {
                    let x = CGFloat(j) * cell
                    let y = CGFloat(i) * cell
                    ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                }
            }
        }

        return ctx.makeImage()
    }
}
#endif
