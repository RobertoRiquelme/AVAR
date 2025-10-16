import Foundation

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

    private enum CodingKeys: String, CodingKey {
        case elements
        case RTelements
        case id
    }

    // -- your custom decoder --
    init(from decoder: Decoder) throws {
        // Try to decode as a direct array first (new format)
        if let directElements = try? decoder.singleValueContainer().decode([ElementDTO].self) {
            self.elements = directElements
            self.is2D = false // Default for direct array format
            self.id = nil // No root-level ID in direct array format
            return
        }
        
        // Fall back to object format (old format)
        let container = try decoder.container(keyedBy: CodingKeys.self)
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

    private enum CodingKeys: String, CodingKey {
        case shape, position, color, id, type, interactions, extent, model
        case fromId = "from_id", toId = "to_id"
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
        // Decode from_id as String (primary) or convert from Int
        if let fromString = try? c.decode(String.self, forKey: .fromId) {
            self.fromId = fromString
        } else if let fromInt = try? c.decode(Int.self, forKey: .fromId) {
            self.fromId = String(fromInt)
        } else {
            self.fromId = nil
        }
        
        // Decode to_id as String (primary) or convert from Int
        if let toString = try? c.decode(String.self, forKey: .toId) {
            self.toId = toString
        } else if let toInt = try? c.decode(Int.self, forKey: .toId) {
            self.toId = String(toInt)
        } else {
            self.toId = nil
        }
    }
}

/// The nested “shape” object (optional).
struct ShapeDTO: Codable {
    let shapeDescription: String?
    let extent: [Double]?   // e.g. [width, height, depth]
    let text: String?       // any label
    let color: [Double]?    // sometimes color appears here
    let id: String?         // some shapes carry their own id

    private enum CodingKeys: String, CodingKey {
        case shapeDescription, extent, text, color, id
    }
    
    // Custom initializer for string fallback
    init(shapeDescription: String) {
        self.shapeDescription = shapeDescription
        self.extent = nil
        self.text = nil
        self.color = nil
        self.id = nil
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
        
        // Decode id as String (primary) or convert from Int, or leave nil (same logic as ElementDTO)
        if let strID = try? container.decode(String.self, forKey: .id) {
            self.id = strID
        } else if let intID = try? container.decode(Int.self, forKey: .id) {
            self.id = String(intID)
        } else {
            self.id = nil
        }
    }
    
}
