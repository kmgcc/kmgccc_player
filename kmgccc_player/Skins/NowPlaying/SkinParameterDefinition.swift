import Foundation

struct SkinParameterDefinition: Identifiable, Codable {
    struct Choice: Identifiable, Codable, Hashable {
        let id: String
        let title: String
    }

    enum Control: Codable {
        case toggle
        case range(min: Double, max: Double, step: Double)
        case choice([Choice])

        private enum CodingKeys: String, CodingKey { case type, min, max, step, choices }
        private enum Kind: String, Codable { case toggle, range, choice }

        init(from decoder: any Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            switch try keys.decode(Kind.self, forKey: .type) {
            case .toggle: self = .toggle
            case .range:
                self = .range(min: try keys.decode(Double.self, forKey: .min),
                              max: try keys.decode(Double.self, forKey: .max),
                              step: try keys.decodeIfPresent(Double.self, forKey: .step) ?? 1)
            case .choice: self = .choice(try keys.decode([Choice].self, forKey: .choices))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var keys = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .toggle: try keys.encode(Kind.toggle, forKey: .type)
            case .range(let min, let max, let step):
                try keys.encode(Kind.range, forKey: .type)
                try keys.encode(min, forKey: .min)
                try keys.encode(max, forKey: .max)
                try keys.encode(step, forKey: .step)
            case .choice(let choices):
                try keys.encode(Kind.choice, forKey: .type)
                try keys.encode(choices, forKey: .choices)
            }
        }
    }

    let id: String
    let title: String
    let defaultValue: SkinParameterValue
    let control: Control
    var surfaces: Set<SkinSurface> = [.window, .fullscreen]
    var isUserVisible: Bool = false

    private enum CodingKeys: String, CodingKey { case id, title, defaultValue, control, surfaces, isUserVisible }
}

extension SkinParameterDefinition {
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        id = try keys.decode(String.self, forKey: .id)
        title = try keys.decode(String.self, forKey: .title)
        defaultValue = try keys.decode(SkinParameterValue.self, forKey: .defaultValue)
        control = try keys.decode(Control.self, forKey: .control)
        surfaces = try keys.decodeIfPresent(Set<SkinSurface>.self, forKey: .surfaces) ?? [.window, .fullscreen]
        isUserVisible = try keys.decodeIfPresent(Bool.self, forKey: .isUserVisible) ?? false
    }
}
