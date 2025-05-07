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

struct ScriptOutput: Codable {
    let elements: [ElementDTO]

    private enum CodingKeys: String, CodingKey {
        case elements
        case RTelements
    }

    // -- your custom decoder --
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let els = try? container.decode([ElementDTO].self, forKey: .elements) {
            self.elements = els
        } else {
            self.elements = try container.decode([ElementDTO].self, forKey: .RTelements)
        }
    }

    // -- now add this to satisfy Encodable --
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // choose whichever key you prefer when re-encoding;
        // here we re-emit under "elements":
        try container.encode(elements, forKey: .elements)
    }
}

/// One “node” or “shape” in your visualization.
struct ElementDTO: Codable {
    let shape: ShapeDTO?        // e.g. Box, Line, Sphere, etc.
    let position: [Double]?     // 2D or 3D coordinates
    let color: [Double]?        // RGBA, etc.
    let id: String              // always exposed as String
    let type: String            // e.g. "camera", "RTelement", etc.
    let fromId: String?         // for edges: source element ID
    let toId: String?           // for edges: destination element ID

    private enum CodingKeys: String, CodingKey {
        case shape, position, color, id, type
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

        // Decode id as Int or String
        if let intID = try? c.decode(Int.self, forKey: .id) {
            self.id = String(intID)
        } else if let strID = try? c.decode(String.self, forKey: .id) {
            self.id = strID
        } else {
            self.id = ""
        }

        self.type = try c.decode(String.self, forKey: .type)
        // Decode from_id as Int or String
        if let fromInt = try? c.decode(Int.self, forKey: .fromId) {
            self.fromId = String(fromInt)
        } else {
            self.fromId = try c.decodeIfPresent(String.self, forKey: .fromId)
        }
        // Decode to_id as Int or String
        if let toInt = try? c.decode(Int.self, forKey: .toId) {
            self.toId = String(toInt)
        } else {
            self.toId = try c.decodeIfPresent(String.self, forKey: .toId)
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
}
