#if os(visionOS)
import ARKit
import Foundation
import simd
import QuartzCore

// MARK: - Legacy Shared Space Coordinator
//
// ⚠️ DEPRECATED for most use cases in visionOS 26+
//
// This coordinator uses SharedCoordinateSpaceProvider which requires:
// - Enterprise/managed entitlement from Apple
// - Custom networking layer (MultipeerConnectivity, etc.)
//
// For most apps, use the NEW approach instead:
// - SharePlay + SystemCoordinator (for session management)
// - WorldAnchor(sharedWithNearbyParticipants: true) (for spatial alignment)
//
// See: SharedWorldAnchorManager.swift for the recommended visionOS 26+ approach
//
// This class is kept for enterprise use cases that need custom networking
// without FaceTime/SharePlay dependency.

@available(visionOS 26.0, *)
@MainActor
final class VisionOSSharedSpaceCoordinator {
    private var session: ARKitSession?
    private var worldTracking: WorldTrackingProvider?
    private var sharedProvider: SharedCoordinateSpaceProvider?
    
    private var coordinateTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var deviceAnchorTask: Task<Void, Never>?

    var onCoordinateData: ((SharedCoordinateSpaceMessage) -> Void)?
    var onSharingEnabledChanged: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var latestDeviceTransform: simd_float4x4 = matrix_identity_float4x4

    func start() async {
        guard SharedCoordinateSpaceProvider.isSupported, WorldTrackingProvider.isSupported else {
            print("⚠️ Shared coordinate space not supported on this device")
            return
        }

        makeFreshSession()
        
        guard let session, let worldTracking, let sharedProvider else { return }
        
        do {
            try await session.run([worldTracking, sharedProvider])
            
            coordinateTask?.cancel()
            coordinateTask = Task { [weak self] in
                await self?.pumpCoordinateSpaceData()
            }
            
            eventTask?.cancel()
            eventTask = Task { [weak self] in
                await self?.monitorEvents()
            }
            
            deviceAnchorTask?.cancel()
            deviceAnchorTask = Task { [weak self] in
                await self?.trackDeviceAnchor()
            }
            
            print("🌐 Shared coordinate space provider started")
        } catch {
            onError?(error)
            print("❌ Failed to start shared coordinate space provider: \(error)")
        }
    }

    func stop() {
        coordinateTask?.cancel(); coordinateTask = nil
        eventTask?.cancel();      eventTask = nil
        deviceAnchorTask?.cancel(); deviceAnchorTask = nil
        
        session?.stop()
        session = nil
        worldTracking = nil
        sharedProvider = nil
        
        print("🌐 Shared coordinate space provider stopped")
    }

    // If your API for push is async, make this `async` and call with `await`.
    func pushCoordinateData(_ message: SharedCoordinateSpaceMessage) {
        guard let provider = sharedProvider else {
            print("⚠️ SharedCoordinateSpaceProvider not active; dropping payload")
            return
        }
        guard let coordinateData = SharedCoordinateSpaceProvider.CoordinateSpaceData(data: message.payload) else {
            print("⚠️ Ignoring invalid coordinate space payload")
            return
        }
        provider.push(data: coordinateData)
    }

    private func pumpCoordinateSpaceData() async {
        while !Task.isCancelled {
            guard let provider = sharedProvider else {
                // Provider was torn down (e.g., stop()); back off and try again until task is cancelled.
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            if let data = provider.nextCoordinateSpaceData {
                let message = SharedCoordinateSpaceMessage(
                    payload: data.data,
                    recipientIdentifiers: data.recipientIdentifiers
                )
                onCoordinateData?(message)
            } else {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func monitorEvents() async {
        // We must unwrap before iterating; optional AsyncSequence doesn't conform to AsyncSequence.
        guard let provider = sharedProvider else { return }
        for await event in provider.eventUpdates {
            switch event {
            case .sharingEnabled:
                onSharingEnabledChanged?(true)
            case .sharingDisabled:
                onSharingEnabledChanged?(false)
            case .connectedParticipantIdentifiers(let participants):
                print("👥 Shared coordinate participants: \(participants)")
            }
        }
    }

    private func trackDeviceAnchor() async {
        while !Task.isCancelled {
            if let worldTracking,
               let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                latestDeviceTransform = anchor.originFromAnchorTransform
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }
    
    private func makeFreshSession() {
        // Create brand-new instances each start; stopped providers cannot be re-run.
        session = ARKitSession()
        worldTracking = WorldTrackingProvider()
        sharedProvider = SharedCoordinateSpaceProvider()
    }
}
#endif
