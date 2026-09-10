import Foundation
import RealityKit
import simd

/// End-to-end check over every bundled diagram in `AVAR2/Resources`.
///
/// The app ships 37 example diagrams spanning four decoder formats and a dozen shape vocabularies.
/// Nothing previously exercised them: a decoder change, a renamed shape key or a degenerate extent
/// could break a specific example and only surface when someone happened to open that file in a
/// headset. This walks all of them through the real path — decode, normalize, and build a mesh and
/// material for every single element — so that breakage fails a test run instead.
///
/// It also covers the largest examples (~2000 elements), which makes it the only automated signal
/// on load cost.
@main
struct ResourceIntegrityTests {
    static func main() {
        let dir = resourcesDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasSuffix(".txt") }.sorted() ?? []

        guard !files.isEmpty else {
            fatalError("No .txt resources found at \(dir) — set AVAR2_RESOURCES to the Resources directory")
        }

        var totalElements = 0
        var timings: [(name: String, seconds: Double, count: Int)] = []

        for file in files {
            let name = (file as NSString).deletingPathExtension
            let url = URL(fileURLWithPath: dir).appendingPathComponent(file)

            guard let data = try? Data(contentsOf: url) else {
                fatalError("\(name): could not be read")
            }

            let output: ScriptOutput
            do {
                output = try JSONDecoder().decode(ScriptOutput.self, from: data)
            } catch {
                fatalError("\(name): failed to decode — \(error)")
            }

            assert(!output.elements.isEmpty, "\(name): decoded to zero elements")

            // Every bundled diagram must classify as 2D or 3D deterministically; `is2D` drives
            // normalization, Y sign and handle placement, so an unstable value here would render
            // the same file differently on two devices.
            let reDecoded = try! JSONDecoder().decode(ScriptOutput.self, from: data)
            assert(reDecoded.is2D == output.is2D, "\(name): is2D is not deterministic")
            assert(reDecoded.elements.count == output.elements.count,
                   "\(name): element count is not deterministic")

            let normalization = NormalizationContext(elements: output.elements, is2D: output.is2D)
            assert(normalization.globalRange > 0,
                   "\(name): globalRange is \(normalization.globalRange); it divides extents, so a "
                   + "non-positive value yields NaN/inf geometry")

            // Build real geometry for every element. This is where a degenerate extent, an
            // unhandled shape key or a bad mesh descriptor would trap.
            let started = Date()
            for (index, element) in output.elements.enumerated() {
                let built = element.meshAndMaterial(normalization: normalization)
                // Touching the result forces the mesh to actually be realized.
                let bounds = built.mesh.bounds
                assert(bounds.extents.x.isFinite && bounds.extents.y.isFinite && bounds.extents.z.isFinite,
                       "\(name)[\(index)] (type=\(element.type)): produced non-finite mesh bounds")
            }
            let elapsed = Date().timeIntervalSince(started)

            totalElements += output.elements.count
            timings.append((name, elapsed, output.elements.count))
        }

        // Surface the cost leaders. Mesh generation is cached by geometry, so a diagram that is
        // slow relative to its element count usually means a builder is bypassing `MeshCache`
        // and re-tessellating identical shapes — which is what made a 360-circle diagram the
        // slowest of all 37, at 30ms per element.
        print("ResourceIntegrityTests ✅ (\(files.count) diagrams, \(totalElements) elements)")
        print("  slowest:")
        for t in timings.sorted(by: { $0.seconds > $1.seconds }).prefix(5) {
            let perElement = t.count > 0 ? t.seconds / Double(t.count) * 1000 : 0
            print("    " + t.name.padding(toLength: 30, withPad: " ", startingAt: 0)
                  + String(format: "%6.2fs  %5d elems  %5.2f ms/elem", t.seconds, t.count, perElement))
        }
    }

    /// Resources live in the source tree, not a bundle — these suites are plain executables.
    static func resourcesDirectory() -> String {
        if let override = ProcessInfo.processInfo.environment["AVAR2_RESOURCES"] { return override }
        // Default to the checkout this file lives in.
        return URL(fileURLWithPath: #filePath)          // .../AVAR2/Tests/ResourceIntegrityTests.swift
            .deletingLastPathComponent()                 // .../AVAR2/Tests
            .deletingLastPathComponent()                 // .../AVAR2
            .appendingPathComponent("AVAR2/Resources")
            .path
    }
}
