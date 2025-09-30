//
//  DiagramLayoutCoordinator.swift
//  AVAR2
//
//  Created to manage spatial placement of diagrams around the user.
//

import Foundation
import simd

struct DiagramLayoutCoordinator {
    struct Slot: Hashable {
        let x: Int
        let z: Int

        func offset(spacing: Float) -> SIMD3<Float> {
            SIMD3<Float>(Float(x) * spacing, 0, Float(z) * spacing)
        }
    }

    private var occupiedSlots: Set<Slot> = []
    private var filenameToSlot: [String: Slot] = [:]
    private var searchCache: [Int: [Slot]] = [:]

    private let spacing: Float
    private let skipBehindUser: Bool
    private let maxSearchRadius: Int

    init(spacing: Float = 0.9, skipBehindUser: Bool = true, maxSearchRadius: Int = 20) {
        self.spacing = spacing
        self.skipBehindUser = skipBehindUser
        self.maxSearchRadius = maxSearchRadius
    }

    mutating func position(for filename: String, basePosition: SIMD3<Float>) -> SIMD3<Float> {
        if let slot = filenameToSlot[filename] {
            occupiedSlots.insert(slot)
            return basePosition + slot.offset(spacing: spacing)
        }

        let slot = findNextAvailableSlot()
        occupiedSlots.insert(slot)
        filenameToSlot[filename] = slot
        return basePosition + slot.offset(spacing: spacing)
    }

    mutating func release(filename: String) {
        guard let slot = filenameToSlot.removeValue(forKey: filename) else { return }
        occupiedSlots.remove(slot)
    }

    mutating func reset() {
        occupiedSlots.removeAll()
        filenameToSlot.removeAll()
    }

    func slot(for filename: String) -> Slot? {
        filenameToSlot[filename]
    }

    var occupancyCount: Int { occupiedSlots.count }
    var storedFilenameCount: Int { filenameToSlot.count }

    // MARK: - Private helpers

    private mutating func findNextAvailableSlot() -> Slot {
        let fallbackSlot = Slot(x: 0, z: -(maxSearchRadius + 1))

        for radius in 0...maxSearchRadius {
            let candidates = slots(for: radius)
            for slot in candidates where isSlotAllowed(slot) && !occupiedSlots.contains(slot) {
                return slot
            }
        }

        // Hard stop reached: return a deterministic fallback slot
        if !occupiedSlots.contains(fallbackSlot) {
            return fallbackSlot
        }

        // As a final safety, place further forward until we find open space
        var z = fallbackSlot.z - 1
        while true {
            let dynamicSlot = Slot(x: 0, z: z)
            if !occupiedSlots.contains(dynamicSlot) {
                return dynamicSlot
            }
            z -= 1
        }
    }

    private mutating func slots(for radius: Int) -> [Slot] {
        if let cached = searchCache[radius] {
            return cached
        }

        var result: [Slot] = []
        if radius == 0 {
            result = [Slot(x: 0, z: 0)]
        } else {
            for zAbs in 0...radius {
                let z = -zAbs
                for x in (-radius)...radius {
                    if max(abs(x), zAbs) == radius {
                        result.append(Slot(x: x, z: z))
                    }
                }
            }
        }
        searchCache[radius] = result
        return result
    }

    private func isSlotAllowed(_ slot: Slot) -> Bool {
        guard skipBehindUser else { return true }
        return slot.z <= 0
    }
}
