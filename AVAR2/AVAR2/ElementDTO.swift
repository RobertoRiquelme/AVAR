import Foundation
import simd

// USE: 
// let decoder = JSONDecoder()
// let fileURL = Bundle.main.url(forResource: "2D Tree Layout", withExtension: "json")!
// let data = try Data(contentsOf: fileURL)
// let output = try decoder.decode(ScriptOutput.self, from: data)

// now output.elements is an array of ElementDTO,
// each with optional shape, position, color, etc.

/// Top‐level DTO that can decode either
/// { "elements": [...] } or { "RTelements": [...] }.
/// Now also supports an optional root-level "id" for diagram identification.

struct ScriptOutput: Codable {
    let elements: [ElementDTO]
    /// True if decoded from the "RTelements" key (i.e. a 2D/RT graph)
    let is2D: Bool
    /// Optional diagram ID for tracking/updating diagrams
    let id: Int?
    /// Shared position from collaborative session (used by clients to place diagram at host's position)
    var sharedPosition: SIMD3<Float>?
    /// Shared orientation from collaborative session
    var sharedOrientation: simd_quatf?
    /// Shared scale from collaborative session
    var sharedScale: Float?

    private enum CodingKeys: String, CodingKey {
        case elements
        case RTelements
        case nodes
        case edges
        case id
        case type
        case sharedPosition
        case sharedOrientation
        case sharedScale
    }

    // -- your custom decoder --
    init(from decoder: Decoder) throws {
        // Try to decode as a direct array first (new format)
        if let directElements = try? decoder.singleValueContainer().decode([ElementDTO].self) {
            self.elements = directElements
            self.is2D = false // Default for direct array format
            self.id = nil // No root-level ID in direct array format
            self.sharedPosition = nil
            self.sharedOrientation = nil
            self.sharedScale = nil
            return
        }

        // Fall back to object format (old format)
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Check for nodes/edges format (AVAR-SquareNodes.txt, AVAR-Ruler.txt)
        if let nodes = try? container.decode([ElementDTO].self, forKey: .nodes) {
            let edges = (try? container.decode([ElementDTO].self, forKey: .edges)) ?? []

            // Flatten any composite nodes
            let flattenedNodes = Self.flattenComposites(nodes)

            // Merge nodes and edges
            self.elements = flattenedNodes + edges
            self.is2D = true // RS formats are 2D

            // Decode optional root-level id
            if let intID = try? container.decode(Int.self, forKey: .id) {
                self.id = intID
            } else if let doubleID = try? container.decode(Double.self, forKey: .id) {
                self.id = Int(doubleID)
            } else if let strID = try? container.decode(String.self, forKey: .id), let intFromString = Int(strID) {
                self.id = intFromString
            } else {
                self.id = nil
            }

            // Decode shared position/orientation/scale (from collaborative session)
            self.sharedPosition = Self.decodeSharedPosition(from: container)
            self.sharedOrientation = Self.decodeSharedOrientation(from: container)
            self.sharedScale = try? container.decode(Float.self, forKey: .sharedScale)
            return
        }

        // Check for elements format (current and AVAR-RedGreen.txt)
        if let els = try? container.decode([ElementDTO].self, forKey: .elements) {
            self.elements = els
            self.is2D = false
        } else {
            self.elements = try container.decode([ElementDTO].self, forKey: .RTelements)
            self.is2D = true
        }

        // Decode optional root-level id (Int, Double, or String)
        if let intID = try? container.decode(Int.self, forKey: .id) {
            self.id = intID
        } else if let doubleID = try? container.decode(Double.self, forKey: .id) {
            self.id = Int(doubleID)
        } else if let strID = try? container.decode(String.self, forKey: .id), let intFromString = Int(strID) {
            self.id = intFromString
        } else {
            self.id = nil
        }

        // Decode shared position/orientation/scale (from collaborative session)
        self.sharedPosition = Self.decodeSharedPosition(from: container)
        self.sharedOrientation = Self.decodeSharedOrientation(from: container)
        self.sharedScale = try? container.decode(Float.self, forKey: .sharedScale)
    }

    /// Decode shared position from a dictionary with x, y, z keys
    private static func decodeSharedPosition(from container: KeyedDecodingContainer<CodingKeys>) -> SIMD3<Float>? {
        guard let posDict = try? container.decode([String: Float].self, forKey: .sharedPosition) else {
            return nil
        }
        guard let x = posDict["x"], let y = posDict["y"], let z = posDict["z"] else {
            return nil
        }
        return SIMD3<Float>(x, y, z)
    }

    /// Decode shared orientation from a dictionary with x, y, z, w keys
    private static func decodeSharedOrientation(from container: KeyedDecodingContainer<CodingKeys>) -> simd_quatf? {
        guard let orientDict = try? container.decode([String: Float].self, forKey: .sharedOrientation) else {
            return nil
        }
        guard let x = orientDict["x"], let y = orientDict["y"], let z = orientDict["z"], let w = orientDict["w"] else {
            return nil
        }
        return simd_quatf(ix: x, iy: y, iz: z, r: w)
    }

    // Helper function to flatten composite nodes
    private static func flattenComposites(_ nodes: [ElementDTO]) -> [ElementDTO] {
        var flattened: [ElementDTO] = []

        for node in nodes {
            // Check if this is a composite node (RSComposite type with nested nodes)
            if node.type.contains("Composite"), let childNodes = node.childNodes {
                // Offset child positions by the composite's position
                let compositePos = node.position ?? [0, 0]
                for var child in childNodes {
                    if var childPos = child.position {
                        // Add composite offset to child position
                        for i in 0..<min(childPos.count, compositePos.count) {
                            childPos[i] += compositePos[i]
                        }
                        child.position = childPos
                    }
                    flattened.append(child)
                }
            } else {
                // Regular node, add as-is
                flattened.append(node)
            }
        }

        return flattened
    }

    // -- now add this to satisfy Encodable --
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // choose whichever key you prefer when re-encoding;
        // here we re-emit under "elements":
        try container.encode(elements, forKey: .elements)
        try container.encodeIfPresent(id, forKey: .id)
    }
}

/// One "node" or "shape" in your visualization.
struct ElementDTO: Codable {
    let shape: ShapeDTO?        // e.g. Box, Line, Sphere, etc.
    var position: [Double]?     // 2D or 3D coordinates
    let color: [Double]?        // RGBA, etc.
    let id: String?             // optional ID (can be string or numeric)
    let type: String            // e.g. "camera", "RTelement", etc.
    let fromId: String?         // for edges: source element ID
    let toId: String?           // for edges: destination element ID
    let interactions: [String]? // defines interactions for elements
    let extent: [Double]?       // element-level extent/size
    let model: String?          // alternative to type field
    let childNodes: [ElementDTO]? // for RSComposite: nested nodes
    let childEdges: [ElementDTO]? // for RSComposite: nested edges
    let markerEnd: MarkerDTO?   // for RSArrowedLine: arrow marker
    let points: [[Double]]?     // for lines and polygons
    let borderColor: [Double]?  // border/stroke color
    let borderWidth: Double?    // border/stroke width
    let text: String?           // element-level text (for RSLabel)

    private enum CodingKeys: String, CodingKey {
        case shape, position, color, id, type, interactions, extent, model
        case fromId = "from_id", toId = "to_id"
        case childNodes = "nodes", childEdges = "edges"
        case markerEnd, points, borderColor, borderWidth, text
        case from, to  // Alternative names for fromId/toId in RS formats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Try decoding shape as ShapeDTO or fallback to string and wrap
        let rawId = try? c.decode(String.self, forKey: .id)
        print("🔧 Processing element with ID: '\(rawId ?? "nil")'")
        
        do {
            let shapeDTO = try c.decode(ShapeDTO.self, forKey: .shape)
            print("✅ Successfully decoded ShapeDTO, shapeDescription: '\(shapeDTO.shapeDescription ?? "nil")'")
            self.shape = shapeDTO
        } catch {
            print("❌ ShapeDTO decoding failed with error: \(error)")
            if let shapeString = try? c.decode(String.self, forKey: .shape) {
                print("✅ Decoded shape as string '\(shapeString)'")
                self.shape = ShapeDTO(shapeDescription: shapeString)
            } else {
                print("🚨 No shape found for element - checking if shape key exists in JSON")
                let hasShapeKey = c.contains(.shape)
                print("   Shape key exists: \(hasShapeKey)")
                self.shape = nil
            }
        }

        self.position = try c.decodeIfPresent([Double].self, forKey: .position)
        self.color    = try c.decodeIfPresent([Double].self, forKey: .color)
        self.interactions = try c.decodeIfPresent([String].self, forKey: .interactions)
        self.extent = try c.decodeIfPresent([Double].self, forKey: .extent)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.childNodes = try c.decodeIfPresent([ElementDTO].self, forKey: .childNodes)
        self.childEdges = try c.decodeIfPresent([ElementDTO].self, forKey: .childEdges)
        self.markerEnd = try c.decodeIfPresent(MarkerDTO.self, forKey: .markerEnd)
        self.points = try c.decodeIfPresent([[Double]].self, forKey: .points)
        self.borderColor = try c.decodeIfPresent([Double].self, forKey: .borderColor)
        self.borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)

        // Decode id as String (primary) or convert from Int/Double to String
        if let strID = try? c.decode(String.self, forKey: .id) {
            self.id = strID
        } else if let intID = try? c.decode(Int.self, forKey: .id) {
            self.id = String(intID)
        } else if let doubleID = try? c.decode(Double.self, forKey: .id) {
            self.id = String(Int(doubleID))
        } else {
            // No ID provided - leave as nil for new format compatibility
            self.id = nil
        }

        // Try to decode type, fall back to model, or use default
        if let typeValue = try? c.decode(String.self, forKey: .type) {
            self.type = typeValue
        } else if let modelValue = try? c.decode(String.self, forKey: .model) {
            self.type = modelValue
        } else {
            self.type = "element" // default type
        }
        // Decode from_id/from as String (primary) or convert from Int
        if let fromString = try? c.decode(String.self, forKey: .fromId) {
            self.fromId = fromString
        } else if let fromInt = try? c.decode(Int.self, forKey: .fromId) {
            self.fromId = String(fromInt)
        } else if let fromString = try? c.decode(String.self, forKey: .from) {
            self.fromId = fromString
        } else if let fromInt = try? c.decode(Int.self, forKey: .from) {
            self.fromId = String(fromInt)
        } else {
            self.fromId = nil
        }

        // Decode to_id/to as String (primary) or convert from Int
        if let toString = try? c.decode(String.self, forKey: .toId) {
            self.toId = toString
        } else if let toInt = try? c.decode(Int.self, forKey: .toId) {
            self.toId = String(toInt)
        } else if let toString = try? c.decode(String.self, forKey: .to) {
            self.toId = toString
        } else if let toInt = try? c.decode(Int.self, forKey: .to) {
            self.toId = String(toInt)
        } else {
            self.toId = nil
        }
    }

    // Encodable conformance
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(shape, forKey: .shape)
        try container.encodeIfPresent(position, forKey: .position)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(fromId, forKey: .fromId)
        try container.encodeIfPresent(toId, forKey: .toId)
        try container.encodeIfPresent(interactions, forKey: .interactions)
        try container.encodeIfPresent(extent, forKey: .extent)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(childNodes, forKey: .childNodes)
        try container.encodeIfPresent(childEdges, forKey: .childEdges)
        try container.encodeIfPresent(markerEnd, forKey: .markerEnd)
        try container.encodeIfPresent(points, forKey: .points)
        try container.encodeIfPresent(borderColor, forKey: .borderColor)
        try container.encodeIfPresent(borderWidth, forKey: .borderWidth)
        try container.encodeIfPresent(text, forKey: .text)
    }
}

/// The nested "shape" object (optional).
struct ShapeDTO: Codable {
    let shapeDescription: String?
    let extent: [Double]?   // e.g. [width, height, depth]
    let text: String?       // any label
    let color: [Double]?    // sometimes color appears here
    let id: String?         // some shapes carry their own id
    let radius: Double?     // optional radius for cylinders/edges
    let points: [[Double]]? // polygon points
    let borderColor: [Double]?  // border/stroke color
    let borderWidth: Double?    // border/stroke width
    let position: [Double]?     // shape-level position

    private enum CodingKeys: String, CodingKey {
        case shapeDescription, extent, text, color, id, radius
        case points, borderColor, borderWidth, position
    }
    
    // Custom initializer for string fallback
    init(shapeDescription: String) {
        self.shapeDescription = shapeDescription
        self.extent = nil
        self.text = nil
        self.color = nil
        self.id = nil
        self.radius = nil
        self.points = nil
        self.borderColor = nil
        self.borderWidth = nil
        self.position = nil
    }
    
    // Custom decoder to debug shape parsing
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        print("🔍 ShapeDTO decoder - available keys: \(container.allKeys)")
        
        self.shapeDescription = try container.decodeIfPresent(String.self, forKey: .shapeDescription)
        print("   shapeDescription: '\(self.shapeDescription ?? "nil")'")
        
        self.extent = try container.decodeIfPresent([Double].self, forKey: .extent)
        print("   extent: \(self.extent ?? [])")
        
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.color = try container.decodeIfPresent([Double].self, forKey: .color)
        self.radius = try container.decodeIfPresent(Double.self, forKey: .radius)
        self.points = try container.decodeIfPresent([[Double]].self, forKey: .points)
        self.borderColor = try container.decodeIfPresent([Double].self, forKey: .borderColor)
        self.borderWidth = try container.decodeIfPresent(Double.self, forKey: .borderWidth)
        self.position = try container.decodeIfPresent([Double].self, forKey: .position)

        // Decode id as String (primary) or convert from Int, or leave nil (same logic as ElementDTO)
        if let strID = try? container.decode(String.self, forKey: .id) {
            self.id = strID
        } else if let intID = try? container.decode(Int.self, forKey: .id) {
            self.id = String(intID)
        } else {
            self.id = nil
        }
    }

    // Encodable conformance
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(shapeDescription, forKey: .shapeDescription)
        try container.encodeIfPresent(extent, forKey: .extent)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(radius, forKey: .radius)
        try container.encodeIfPresent(points, forKey: .points)
        try container.encodeIfPresent(borderColor, forKey: .borderColor)
        try container.encodeIfPresent(borderWidth, forKey: .borderWidth)
        try container.encodeIfPresent(position, forKey: .position)
    }
}

/// Marker DTO for arrow ends (markerEnd property in RSArrowedLine)
struct MarkerDTO: Codable {
    let shape: ShapeDTO?
    let offset: Double?
    let offsetRatio: Double?
    let id: String?

    private enum CodingKeys: String, CodingKey {
        case shape, offset, offsetRatio, id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.shape = try container.decodeIfPresent(ShapeDTO.self, forKey: .shape)
        self.offset = try container.decodeIfPresent(Double.self, forKey: .offset)
        self.offsetRatio = try container.decodeIfPresent(Double.self, forKey: .offsetRatio)

        // Decode id as String (primary) or convert from Int
        if let strID = try? container.decode(String.self, forKey: .id) {
            self.id = strID
        } else if let intID = try? container.decode(Int.self, forKey: .id) {
            self.id = String(intID)
        } else {
            self.id = nil
        }
    }

    // Encodable conformance
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(shape, forKey: .shape)
        try container.encodeIfPresent(offset, forKey: .offset)
        try container.encodeIfPresent(offsetRatio, forKey: .offsetRatio)
        try container.encodeIfPresent(id, forKey: .id)
    }
}

