//
//  SessionOriginLogic.swift
//  AVAR2
//
//  Pure logic behind session-origin establishment.
//
//  Extracted from `CollaborativeSessionManager` and `SharedWorldAnchorManager` because both
//  pieces were previously welded to live objects (a `GroupSession`'s participant list, an
//  `ARKitSession`'s world-tracking provider) and therefore could not be tested at all — despite
//  being exactly the logic whose failure produced the original misalignment bug. Owner election
//  in particular has to be *provably* convergent: if two devices disagree, alignment silently
//  breaks in a way that is very expensive to observe on hardware.
//

import Foundation
import simd

// MARK: - Owner election

/// Decides which participant creates the session-origin anchor.
enum SessionOriginElection {
    /// Returns the id of the participant that should create the anchor.
    ///
    /// The rule is "lowest UUID string wins", applied to the *same* input on every device, so all
    /// participants independently compute the same answer. This replaced
    /// `activeParticipants.first == localParticipant`, where `activeParticipants` is an unordered
    /// `Set` — that gave a different answer per device and could flip mid-session, and it gated
    /// both anchor creation and (via `isHost`) whether remote diagrams rendered at all.
    ///
    /// - Parameter participantIDs: all active participants, in any order.
    /// - Returns: the elected owner, or `nil` when there are no participants.
    static func owner(participantIDs: [UUID]) -> UUID? {
        participantIDs.min { $0.uuidString < $1.uuidString }
    }

    /// Whether `localID` is the elected owner.
    ///
    /// Requires the local participant to actually be in the list; a device that does not yet see
    /// itself in `activeParticipants` must not claim ownership.
    static func isOwner(localID: UUID?, participantIDs: [UUID]) -> Bool {
        guard let localID, participantIDs.contains(localID) else { return false }
        return owner(participantIDs: participantIDs) == localID
    }

    /// Whether a peer's announced origin should replace one we created ourselves.
    ///
    /// A device briefly sees only itself while joining, so it can elect itself and create an
    /// anchor before a lower-UUID peer appears. Both devices then hold different origins. This
    /// tie-break resolves that from either side without further messages: the anchor owned by the
    /// lower participant UUID wins.
    ///
    /// - Returns: `true` if we should drop our anchor and adopt theirs.
    static func shouldYield(toOwner remoteOwnerID: UUID, localOwnerID: UUID) -> Bool {
        remoteOwnerID.uuidString < localOwnerID.uuidString
    }
}

// MARK: - Gravity-aligned pose

/// Builds the transform used for the session-origin anchor.
enum GravityAlignedPose {
    /// A pose `distance` metres in front of `deviceTransform`, with a **yaw-only** basis.
    ///
    /// Yaw-only is deliberate. Using the device's full rotation would bake the creator's head
    /// tilt into the shared frame, so every diagram on every participant would inherit that tilt
    /// and surface snapping would fight the anchor basis. The original code was worse: it set a
    /// translation with an *identity* rotation while the receiver multiplied by the matrix as
    /// though it carried a real basis.
    ///
    /// ## Basis convention
    ///
    /// The yaw rotation maps **+Z onto the creator's facing direction** — so the anchor's +Z points
    /// away from the creator and its −Z points back at them. Note this is the *opposite* of the
    /// usual ARKit/RealityKit "−Z is forward" convention; do not assume −Z-forward when reading
    /// this transform.
    ///
    /// The absolute yaw is functionally invisible: both participants resolve the same physical
    /// anchor, and diagram poses are expressed relative to it, so any consistent convention works.
    /// It is stated here only so a future reader does not silently assume the other one.
    /// `SessionOriginTests.testPoseIsPlacedForwardAtDistance` pins it.
    ///
    /// - Parameters:
    ///   - deviceTransform: `originFromAnchorTransform` of the device anchor.
    ///   - distance: metres forward from the device.
    /// - Returns: a rigid, unit-scale, gravity-aligned transform.
    static func inFrontOf(deviceTransform: simd_float4x4, distance: Float) -> simd_float4x4 {
        let eye = SIMD3<Float>(deviceTransform.columns.3.x,
                               deviceTransform.columns.3.y,
                               deviceTransform.columns.3.z)
        // -Z is forward in ARKit/RealityKit convention.
        let forward = SIMD3<Float>(-deviceTransform.columns.2.x,
                                   -deviceTransform.columns.2.y,
                                   -deviceTransform.columns.2.z)

        // Project onto the horizontal plane. Falls back to -Z when the user is looking straight
        // up or down, where the horizontal projection degenerates to (near) zero length.
        let horizontal = SIMD3<Float>(forward.x, 0, forward.z)
        let flat = simd_length(horizontal) > 1e-4
            ? simd_normalize(horizontal)
            : SIMD3<Float>(0, 0, -1)

        var transform = simd_float4x4(simd_quatf(angle: atan2(flat.x, flat.z), axis: [0, 1, 0]))
        let position = eye + flat * distance
        transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return transform
    }
}
