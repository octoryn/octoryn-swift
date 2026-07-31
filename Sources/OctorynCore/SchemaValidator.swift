import Foundation

enum SchemaValidator {
  static func validate(_ value: JSONValue, schema: JSONValue, path: String = "$") -> [String] {
    guard case .object(let definition) = schema else {
      return ["\(path): schema must be an object"]
    }
    var errors = validateType(value, expected: definition["type"], path: path)
    if case .array(let allowed) = definition["enum"], !allowed.contains(value) {
      errors.append("\(path): value is not in enum")
    }
    if case .object(let object) = value {
      errors += validateObject(object, definition: definition, path: path)
    }
    if case .array(let values) = value, let itemSchema = definition["items"] {
      for (index, item) in values.enumerated() {
        errors += validate(item, schema: itemSchema, path: "\(path)[\(index)]")
      }
    }
    return errors
  }

  private static func validateType(
    _ value: JSONValue,
    expected: JSONValue?,
    path: String
  ) -> [String] {
    guard case .string(let type) = expected else { return [] }
    let valid =
      switch (type, value) {
      case ("object", .object), ("array", .array), ("string", .string),
        ("number", .number), ("integer", .number), ("boolean", .bool),
        ("null", .null):
        true
      default:
        false
      }
    return valid ? [] : ["\(path): expected \(type)"]
  }

  private static func validateObject(
    _ object: [String: JSONValue],
    definition: [String: JSONValue],
    path: String
  ) -> [String] {
    var errors: [String] = []
    if case .array(let required) = definition["required"] {
      for case .string(let name) in required where object[name] == nil {
        errors.append("\(path).\(name): required")
      }
    }
    if case .object(let properties) = definition["properties"] {
      for (name, value) in object {
        if let propertySchema = properties[name] {
          errors += validate(value, schema: propertySchema, path: "\(path).\(name)")
        } else if definition["additionalProperties"] == .bool(false) {
          errors.append("\(path).\(name): additional property is not allowed")
        }
      }
    }
    return errors
  }
}
