#if os(visionOS)
import ARKit
import Foundation
import simd
import QuartzCore

@available(visionOS 26.0, *)
@MainActor
final class VisionOSSharedSpaceCoordinator {
    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let sharedProvider = SharedCoordinateSpaceProvider()
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

        do {
            try await session.run([worldTracking, sharedProvider])
            coordinateTask?.cancel()
            coordinateTask = Task { [weak self] in await self?.pumpCoordinateSpaceData() }
            eventTask?.cancel()
            eventTask = Task { [weak self] in await self?.monitorEvents() }
            deviceAnchorTask?.cancel()
            deviceAnchorTask = Task { [weak self] in await self?.trackDeviceAnchor() }
            print("🌐 Shared coordinate space provider started")
        } catch {
            onError?(error)
            print("❌ Failed to start shared coordinate space provider: \(error)")
        }
    }

    func stop() {
        coordinateTask?.cancel()
        eventTask?.cancel()
        deviceAnchorTask?.cancel()
        coordinateTask = nil
        eventTask = nil
        deviceAnchorTask = nil
        session.stop()
        print("🌐 Shared coordinate space provider stopped")
    }

    func pushCoordinateData(_ message: SharedCoordinateSpaceMessage) {
        guard let coordinateData = SharedCoordinateSpaceProvider.CoordinateSpaceData(data: message.payload) else {
            print("⚠️ Ignoring invalid coordinate space payload")
            return
        }
        sharedProvider.push(data: coordinateData)
    }

    private func pumpCoordinateSpaceData() async {
        while !Task.isCancelled {
            if let data = sharedProvider.nextCoordinateSpaceData {
                let message = SharedCoordinateSpaceMessage(payload: data.data,
                                                            recipientIdentifiers: data.recipientIdentifiers)
                onCoordinateData?(message)
            } else {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func monitorEvents() async {
        for await event in sharedProvider.eventUpdates {
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
            if let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                latestDeviceTransform = anchor.originFromAnchorTransform
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }
}
#endif
