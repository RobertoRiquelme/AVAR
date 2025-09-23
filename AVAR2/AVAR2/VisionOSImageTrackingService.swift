import Foundation
import SwiftUI

#if os(visionOS)
import ARKit
import RealityKit
import CoreGraphics
import ImageIO

@MainActor
final class VisionOSImageTrackingService: ObservableObject {
    private let session = ARKitSession()
    private var provider: ImageTrackingProvider?
    private let markerAssetName = "marker"
    private let markerPhysicalSize: CGFloat = 0.15

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

        guard let cg = Self.loadMarkerCGImage(named: markerAssetName) else {
            errorMessage = "Missing marker image asset '\(markerAssetName).png' in bundle."
            return
        }

        var markerReference = ARKit.ReferenceImage(
            cgimage: cg,
            physicalSize: CGSize(width: markerPhysicalSize, height: markerPhysicalSize)
        )
        markerReference.name = markerAssetName

        provider = ImageTrackingProvider(referenceImages: [markerReference])
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

    private static func loadMarkerCGImage(named name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
#endif
