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
    let position: [Double]?     // 2D or 3D coordinates
    let color: [Double]?        // RGBA, etc.
    let id: Int                 // numeric ID
    let type: String            // e.g. "camera", "RTelement", etc.
    let fromId: Int?            // for edges: source element ID
    let toId: Int?              // for edges: destination element ID
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
        if let shapeDTO = try? c.decode(ShapeDTO.self, forKey: .shape) {
            self.shape = shapeDTO
        } else if let shapeString = try? c.decode(String.self, forKey: .shape) {
            self.shape = ShapeDTO(shapeDescription: shapeString)
        } else {
            self.shape = nil
        }

        self.position = try c.decodeIfPresent([Double].self, forKey: .position)
        self.color    = try c.decodeIfPresent([Double].self, forKey: .color)
        self.interactions = try c.decodeIfPresent([String].self, forKey: .interactions)
        self.extent = try c.decodeIfPresent([Double].self, forKey: .extent)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)

        // Decode id as Int (primary) or convert from String/Double
        if let intID = try? c.decode(Int.self, forKey: .id) {
            self.id = intID
        } else if let doubleID = try? c.decode(Double.self, forKey: .id) {
            self.id = Int(doubleID)
        } else if let strID = try? c.decode(String.self, forKey: .id), let intFromString = Int(strID) {
            self.id = intFromString
        } else {
            // If id is completely missing or invalid, generate one
            self.id = Int.random(in: 100000...999999)
        }

        // Try to decode type, fall back to model, or use default
        if let typeValue = try? c.decode(String.self, forKey: .type) {
            self.type = typeValue
        } else if let modelValue = try? c.decode(String.self, forKey: .model) {
            self.type = modelValue
        } else {
            self.type = "element" // default type
        }
        // Decode from_id as Int (primary) or convert from String
        if let fromInt = try? c.decode(Int.self, forKey: .fromId) {
            self.fromId = fromInt
        } else if let fromString = try? c.decode(String.self, forKey: .fromId), let intFromString = Int(fromString) {
            self.fromId = intFromString
        } else {
            self.fromId = nil
        }
        
        // Decode to_id as Int (primary) or convert from String
        if let toInt = try? c.decode(Int.self, forKey: .toId) {
            self.toId = toInt
        } else if let toString = try? c.decode(String.self, forKey: .toId), let intFromString = Int(toString) {
            self.toId = intFromString
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
    let id: Int?            // some shapes carry their own id

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
}
