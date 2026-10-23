import Foundation

/// Versioned JSON values keep the transport independent of library/UI models.
indirect enum CLIValue: Codable, Sendable {
    case object([String: CLIValue]), array([CLIValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: CLIValue].self) { self = .object(v) }
        else { self = .array(try c.decode([CLIValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    static func encoded<T: Encodable>(_ value: T) throws -> CLIValue {
        try JSONDecoder().decode(CLIValue.self, from: JSONEncoder().encode(value))
    }
    static func optional(_ value: String?) -> CLIValue { value.map(Self.string) ?? .null }
}

struct CLIRequest: Codable, Sendable {
    var protocolVersion: Int
    var id: String
    var token: String
    var command: String
    var arguments: [String: String]
}

struct CLIError: Error, Codable, Sendable {
    var code: String
    var message: String
}

struct CLIResponse: Codable, Sendable {
    var protocolVersion = 1
    var id: String
    var ok: Bool
    var result: CLIValue?
    var error: CLIError?
    static func failure(_ code: String, _ message: String) -> Self {
        failure("", code, message)
    }
    static func failure(_ id: String, _ code: String, _ message: String) -> Self {
        Self(id: id, ok: false, error: CLIError(code: code, message: message))
    }
}

struct CLIEndpoint: Codable, Sendable {
    var protocolVersion = 1
    var host = "127.0.0.1"
    var port: UInt16
    var pid: Int32
    var token: String
}
