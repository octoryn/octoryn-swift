import Foundation

private struct ToolBuilder {
  var id = ""
  var type = "function"
  var name = ""
  var arguments = ""
}

actor SSEParser {
  private let governance: GovernanceMetadata
  private var dataLines: [String] = []
  private var text = ""
  private var tools: [Int: ToolBuilder] = [:]
  private var finishReason: String?
  private var done = false

  init(governance: GovernanceMetadata) {
    self.governance = governance
  }

  func consume(line: String) throws -> [StreamEvent] {
    if line.isEmpty {
      return try processEvent()
    }
    if line.hasPrefix("data:") {
      dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
    }
    return []
  }

  func finish() throws -> [StreamEvent] {
    var events = try processEvent()
    guard done else { throw OctorynError.incompleteStream }
    for (_, builder) in tools.sorted(by: { $0.key < $1.key }) {
      events.append(
        .toolCall(
          ToolCall(
            id: builder.id,
            name: builder.name,
            arguments: builder.arguments,
            type: builder.type
          )))
    }
    events.append(.finish(reason: finishReason, governance: governance))
    return events
  }

  private func processEvent() throws -> [StreamEvent] {
    guard !dataLines.isEmpty else { return [] }
    let payload = dataLines.joined(separator: "\n")
    dataLines.removeAll(keepingCapacity: true)
    if payload == "[DONE]" {
      done = true
      return []
    }
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
    guard case .object(let chunk) = value else { return [.providerEvent(value)] }
    var events: [StreamEvent] = []
    var recognized = false
    if let usage = chunk["usage"] {
      events.append(.usage(usage))
      recognized = true
    }
    if case .array(let choices) = chunk["choices"] {
      for choiceValue in choices {
        guard case .object(let choice) = choiceValue else { continue }
        if let reason = choice["finish_reason"]?.string {
          finishReason = reason
        }
        if case .object(let delta) = choice["delta"] {
          recognized = apply(delta: delta, events: &events) || recognized
        }
      }
    }
    if !recognized { events.append(.providerEvent(value)) }
    return events
  }

  private func apply(delta: [String: JSONValue], events: inout [StreamEvent]) -> Bool {
    var recognized = false
    if let fragment = delta["content"]?.string {
      text += fragment
      events.append(.textDelta(fragment))
      recognized = true
    }
    if let reasoning = delta["reasoning"]?.string ?? delta["reasoning_content"]?.string {
      events.append(.reasoningDelta(reasoning))
      recognized = true
    }
    if case .array(let parts) = delta["tool_calls"] {
      for part in parts {
        apply(toolPart: part, events: &events)
        recognized = true
      }
    }
    return recognized
  }

  private func apply(toolPart: JSONValue, events: inout [StreamEvent]) {
    guard case .object(let part) = toolPart else { return }
    let index = part["index"]?.integer ?? 0
    let starting = tools[index] == nil
    var builder = tools[index] ?? ToolBuilder()
    if let id = part["id"]?.string { builder.id = id }
    if let type = part["type"]?.string { builder.type = type }
    if case .object(let function) = part["function"] {
      builder.name += function["name"]?.string ?? ""
      let arguments = function["arguments"]?.string ?? ""
      builder.arguments += arguments
      if starting { events.append(.toolCallStart(index: index)) }
      events.append(.toolCallDelta(index: index, fragment: arguments))
    }
    tools[index] = builder
  }
}

extension JSONValue {
  fileprivate var string: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  fileprivate var integer: Int? {
    guard case .number(let value) = self else { return nil }
    return Int(value)
  }
}
