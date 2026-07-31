#if os(visionOS)
import ARKit
import Foundation
import simd
import RealityKit
import QuartzCore

/// Manages shared world anchors for co-located collaboration.
///
/// Uses `WorldAnchor(originFromAnchorTransform:sharedWithNearbyParticipants:)` so nearby Vision
/// Pro devices in the same SharePlay session resolve the *same physical point*. Each device
/// reads that anchor's transform in **its own** ARKit origin, which is why the transform must
/// never be transmitted — see the invariant in `CollaborativeSessionManager`.
///
/// Note: shared anchors are not persisted; their lifetime is the SharePlay session.
///
/// No availability gate: the app's deployment target is already visionOS 26.0.
@MainActor
final class SharedWorldAnchorManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isRunning = false
    @Published private(set) var sharingAvailable = false
    @Published private(set) var sharedAnchors: [UUID: WorldAnchor] = [:]
    @Published private(set) var lastError: String?

    // MARK: - Callbacks

    /// Called when a shared anchor is added or updated (from any participant)
    var onAnchorUpdated: ((WorldAnchor) -> Void)?

    /// Called when a shared anchor is removed
    var onAnchorRemoved: ((UUID) -> Void)?

    /// Called when sharing availability changes
    var onSharingAvailabilityChanged: ((Bool) -> Void)?

    // MARK: - Private Properties

    private var session: ARKitSession?
    private var worldTrackingProvider: WorldTrackingProvider?

    private var anchorUpdateTask: Task<Void, Never>?
    private var sharingAvailabilityTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        print("🌍 SharedWorldAnchorManager initialized")
    }

    deinit {
        // Cancel tasks in deinit - stop() is @MainActor so we can't call it directly
        anchorUpdateTask?.cancel()
        sharingAvailabilityTask?.cancel()
    }

    // MARK: - Public API

    /// Start the ARKit session with world tracking for shared anchors
    func start() async {
        guard !isRunning else {
            print("⚠️ SharedWorldAnchorManager already running")
            return
        }

        guard WorldTrackingProvider.isSupported else {
            lastError = "World tracking not supported on this device"
            print("❌ \(lastError!)")
            return
        }

        // Create fresh session and provider
        session = ARKitSession()
        worldTrackingProvider = WorldTrackingProvider()

        guard let session = session, let provider = worldTrackingProvider else {
            lastError = "Failed to create ARKit session"
            return
        }

        do {
            try await session.run([provider])
            isRunning = true
            print("✅ SharedWorldAnchorManager started")

            // Start observing anchor updates
            anchorUpdateTask?.cancel()
            anchorUpdateTask = Task { [weak self] in
                await self?.observeAnchorUpdates()
            }

            // Start observing sharing availability
            sharingAvailabilityTask?.cancel()
            sharingAvailabilityTask = Task { [weak self] in
                await self?.observeSharingAvailability()
            }

        } catch {
            lastError = "Failed to start ARKit session: \(error.localizedDescription)"
            print("❌ \(lastError!)")
        }
    }

    /// Stop the ARKit session
    func stop() {
        anchorUpdateTask?.cancel()
        anchorUpdateTask = nil

        sharingAvailabilityTask?.cancel()
        sharingAvailabilityTask = nil

        session?.stop()
        session = nil
        worldTrackingProvider = nil

        sharedAnchors.removeAll()
        isRunning = false
        sharingAvailable = false

        print("🛑 SharedWorldAnchorManager stopped")
    }

    /// Create a shared world anchor at the specified transform
    /// This anchor will be visible to all nearby SharePlay participants
    func createSharedAnchor(at transform: simd_float4x4) async throws -> WorldAnchor {
        guard let provider = worldTrackingProvider else {
            throw SharedAnchorError.notRunning
        }

        guard sharingAvailable else {
            throw SharedAnchorError.sharingNotAvailable
        }

        let anchor = WorldAnchor(
            originFromAnchorTransform: transform,
            sharedWithNearbyParticipants: true
        )

        try await provider.addAnchor(anchor)

        print("📍 Created shared world anchor: \(anchor.id)")
        return anchor
    }

    /// Create a shared anchor in front of the user, with a **yaw-only, gravity-aligned** basis.
    ///
    /// Yaw-only on purpose. Using the full device rotation would bake the creator's head tilt
    /// into the shared frame, so every diagram on every device would inherit that tilt and
    /// surface snapping would fight the anchor basis. The previous version was worse still: it
    /// set translation with an *identity* rotation, while the receiver multiplied by the matrix
    /// as though it carried a real basis.
    func createSharedAnchorInFrontOfUser(distance: Float = 1.0) async throws -> WorldAnchor {
        guard let provider = worldTrackingProvider else {
            throw SharedAnchorError.notRunning
        }

        guard let deviceAnchor = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            throw SharedAnchorError.deviceAnchorUnavailable
        }

        let anchorTransform = GravityAlignedPose.inFrontOf(
            deviceTransform: deviceAnchor.originFromAnchorTransform,
            distance: distance
        )
        return try await createSharedAnchor(at: anchorTransform)
    }

    /// Remove a shared anchor
    func removeAnchor(_ anchorID: UUID) async throws {
        guard let provider = worldTrackingProvider else {
            throw SharedAnchorError.notRunning
        }

        guard let anchor = sharedAnchors[anchorID] else {
            throw SharedAnchorError.anchorNotFound
        }

        try await provider.removeAnchor(anchor)
        print("🗑️ Removed shared anchor: \(anchorID)")
    }

    /// Get the current device transform
    func getDeviceTransform() -> simd_float4x4? {
        guard let provider = worldTrackingProvider else { return nil }
        return provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform
    }

    // MARK: - Private Methods

    private func observeAnchorUpdates() async {
        guard let provider = worldTrackingProvider else { return }

        for await update in provider.anchorUpdates {
            let anchor = update.anchor

            // Only track anchors that are shared with nearby participants
            guard anchor.isSharedWithNearbyParticipants else { continue }

            switch update.event {
            case .added:
                sharedAnchors[anchor.id] = anchor
                onAnchorUpdated?(anchor)
                print("➕ Shared anchor added: \(anchor.id) (tracked: \(anchor.isTracked))")

            case .updated:
                sharedAnchors[anchor.id] = anchor
                onAnchorUpdated?(anchor)
                // Don't spam logs for frequent updates

            case .removed:
                sharedAnchors.removeValue(forKey: anchor.id)
                onAnchorRemoved?(anchor.id)
                print("➖ Shared anchor removed: \(anchor.id)")
            }
        }
    }

    private func observeSharingAvailability() async {
        guard let provider = worldTrackingProvider else { return }

        for await availability in provider.worldAnchorSharingAvailability {
            let wasAvailable = sharingAvailable
            sharingAvailable = (availability == .available)

            if sharingAvailable != wasAvailable {
                onSharingAvailabilityChanged?(sharingAvailable)
                print("🔄 Sharing availability changed: \(sharingAvailable ? "available" : "unavailable")")
            }
        }
    }
}

// MARK: - Errors

enum SharedAnchorError: LocalizedError {
    case notRunning
    case sharingNotAvailable
    case deviceAnchorUnavailable
    case anchorNotFound

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "SharedWorldAnchorManager is not running"
        case .sharingNotAvailable:
            return "World anchor sharing is not available. Ensure SharePlay is active with nearby participants."
        case .deviceAnchorUnavailable:
            return "Could not get device position"
        case .anchorNotFound:
            return "Anchor not found"
        }
    }
}

#endif
