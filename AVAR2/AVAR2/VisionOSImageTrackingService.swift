import Foundation
import SwiftUI

#if os(visionOS)
import ARKit
import RealityKit
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class VisionOSImageTrackingService: ObservableObject {
    private let session = ARKitSession()
    private var provider: ImageTrackingProvider?
    private let markerAssetName = "marker"
    private static let defaultMarkerPhysicalSize: CGFloat = 0.15

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

        let referenceImages = Self.loadReferenceImages(targetName: markerAssetName)
        if referenceImages.isEmpty {
            print("🛑 VisionOSImageTrackingService: no reference images loaded for marker '\(markerAssetName)'")
        } else {
            let names = referenceImages.compactMap { $0.name ?? "<unnamed>" }
            let sizes = referenceImages.map { $0.physicalSize }
            print("📷 VisionOSImageTrackingService: loaded \(referenceImages.count) reference image(s): names=\(names) sizes=\(sizes)")
        }
        guard !referenceImages.isEmpty else {
            errorMessage = "Missing marker image asset '\(markerAssetName)' in bundle resources."
            return
        }
        provider = ImageTrackingProvider(referenceImages: referenceImages)
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

    private static func loadReferenceImages(targetName: String) -> [ARKit.ReferenceImage] {
        if let fromCatalog = loadReferenceImagesFromCatalog(targetName: targetName), !fromCatalog.isEmpty {
            return fromCatalog
        }

        if let fallback = loadReferenceImageFromFallbacks(names: [targetName, "AVAR2_Marker_A", "AVAR2_Marker_B"]) {
            return [fallback]
        }

        return []
    }

    private static func loadReferenceImagesFromCatalog(targetName: String) -> [ARKit.ReferenceImage]? {
        do {
            let images = try ARKit.ReferenceImage.loadReferenceImages(inGroupNamed: "AR Resources", bundle: .main)
            if images.isEmpty { return [] }

            let matching = images.filter { $0.name == targetName }
            if !matching.isEmpty { return matching }
            print("ℹ️ VisionOSImageTrackingService: catalog returned \(images.count) image(s); no exact match for '\(targetName)', using full set")
            return images
        } catch {
            print("🛑 VisionOSImageTrackingService: failed to load reference images from catalog: \(error)")
            return nil
        }
    }

    private static func loadReferenceImageFromFallbacks(names: [String]) -> ARKit.ReferenceImage? {
        for candidate in names {
            if let image = loadLoosePNG(named: candidate) {
                let size = CGSize(width: Self.defaultMarkerPhysicalSize, height: Self.defaultMarkerPhysicalSize)
                var ref = ARKit.ReferenceImage(cgimage: image, physicalSize: size)
                ref.name = candidate
                print("📦 VisionOSImageTrackingService: using fallback PNG '\(candidate)' with size \(size)")
                return ref
            }
#if canImport(UIKit)
            if let uiImage = UIImage(named: candidate), let cgImage = uiImage.cgImage {
                let size = CGSize(width: Self.defaultMarkerPhysicalSize, height: Self.defaultMarkerPhysicalSize)
                var ref = ARKit.ReferenceImage(cgimage: cgImage, physicalSize: size)
                ref.name = candidate
                print("📦 VisionOSImageTrackingService: using fallback UIImage '\(candidate)' with size \(size)")
                return ref
            }
#endif
        }
        return nil
    }

    private static func loadLoosePNG(named name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
#endif
