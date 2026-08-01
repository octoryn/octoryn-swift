import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct OctorynClient: Sendable {
  private let apiKey: String
  private let baseURL: URL
  private let transport: any OctorynTransport

  public init(
    apiKey: String,
    baseURL: URL = URL(string: "https://api.octoryn.dev/v1/")!,
    transport: any OctorynTransport = URLSessionTransport()
  ) throws {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OctorynError.invalidRequest("Octoryn API key is required")
    }
    self.apiKey = apiKey
    self.baseURL = Self.directoryURL(baseURL)
    self.transport = transport
  }

  private static func directoryURL(_ url: URL) -> URL {
    guard !url.absoluteString.hasSuffix("/") else { return url }
    return URL(string: url.absoluteString + "/") ?? url
  }

  public func generateText(_ input: TextRequest) async throws -> TextResult {
    let request = try makeRequest(payload: payload(input, stream: false))
    let response = try await transport.send(request)
    try ensureSuccess(response.status, headers: response.headers, body: response.body)
    return try normalize(response.body, governance: governance(response.headers))
  }

  public func generateObject<Value: Decodable & Sendable>(
    _ type: Value.Type,
    request input: TextRequest,
    schema: JSONValue,
    schemaName: String = "response",
    schemaDescription: String? = nil
  ) async throws -> ObjectResult<Value> {
    var body = try payload(input, stream: false)
    body["response_format"] = .object([
      "type": .string("json_schema"),
      "json_schema": .object([
        "name": .string(schemaName),
        "description": schemaDescription.map(JSONValue.string) ?? .null,
        "strict": .bool(true),
        "schema": schema,
      ]),
    ])
    let response = try await transport.send(makeRequest(payload: body))
    try ensureSuccess(response.status, headers: response.headers, body: response.body)
    let result = try normalize(response.body, governance: governance(response.headers))
    let raw = Data(result.text.utf8)
    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: raw)
    } catch {
      throw OctorynError.structuredOutput(
        rawOutput: result.text,
        validationErrors: ["$: invalid JSON"]
      )
    }
    let errors = SchemaValidator.validate(value, schema: schema)
    guard errors.isEmpty else {
      throw OctorynError.structuredOutput(rawOutput: result.text, validationErrors: errors)
    }
    do {
      return ObjectResult(object: try JSONDecoder().decode(type, from: raw), result: result)
    } catch {
      throw OctorynError.structuredOutput(
        rawOutput: result.text,
        validationErrors: ["$: cannot decode requested Swift type: \(error)"]
      )
    }
  }

  public func streamText(_ input: TextRequest) async throws -> AsyncThrowingStream<
    StreamEvent, Error
  > {
    let request = try makeRequest(payload: payload(input, stream: true))
    let response = try await transport.stream(request)
    try ensureSuccess(response.status, headers: response.headers, body: Data())
    let evidence = governance(response.headers)
    return AsyncThrowingStream { continuation in
      let task = Task {
        let parser = SSEParser(governance: evidence)
        continuation.yield(.start(evidence))
        do {
          for try await line in response.lines {
            try Task.checkCancellation()
            for event in try await parser.consume(line: line) {
              continuation.yield(event)
            }
          }
          for event in try await parser.finish() {
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.yield(.error(error.localizedDescription))
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func payload(_ input: TextRequest, stream: Bool) throws -> [String: JSONValue] {
    guard !input.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OctorynError.invalidRequest("model is required")
    }
    guard (input.prompt == nil) != (input.messages == nil) else {
      throw OctorynError.invalidRequest("pass exactly one of prompt or messages")
    }
    var messages = input.messages ?? []
    if let system = input.system {
      messages.insert(ChatMessage(role: "system", content: system), at: 0)
    }
    if let prompt = input.prompt {
      messages.append(ChatMessage(role: "user", content: prompt))
    }
    var body: [String: JSONValue] = [
      "model": .string(input.model),
      "messages": .array(
        messages.map {
          .object(["role": .string($0.role), "content": .string($0.content)])
        }),
      "stream": .bool(stream),
    ]
    if let temperature = input.temperature { body["temperature"] = .number(temperature) }
    if let limit = input.maxOutputTokens { body["max_tokens"] = .number(Double(limit)) }
    if let metadata = input.metadata {
      body["metadata"] = .object(metadata.mapValues(JSONValue.string))
    }
    if let tools = input.tools {
      body["tools"] = .array(
        tools.map {
          .object([
            "type": .string("function"),
            "function": .object([
              "name": .string($0.function.name),
              "description": $0.function.description.map(JSONValue.string) ?? .null,
              "parameters": $0.function.parameters,
            ]),
          ])
        })
    }
    return body
  }

  private func makeRequest(payload: [String: JSONValue]) throws -> URLRequest {
    guard let url = URL(string: "chat/completions", relativeTo: baseURL)?.absoluteURL else {
      throw OctorynError.invalidRequest("invalid Octoryn base URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("octoryn-swift/0.2.1", forHTTPHeaderField: "User-Agent")
    request.setValue("swift/0.2.1", forHTTPHeaderField: "X-Octoryn-Sdk")
    request.httpBody = try JSONEncoder().encode(JSONValue.object(payload))
    return request
  }

  private func normalize(_ data: Data, governance: GovernanceMetadata) throws -> TextResult {
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case .object(let response) = root,
      case .array(let choices) = response["choices"],
      case .object(let choice) = choices.first,
      case .object(let message) = choice["message"]
    else {
      throw OctorynError.invalidResponse("Octoryn response contained no choices")
    }
    let text = Self.text(message["content"])
    let calls = Self.toolCalls(message["tool_calls"])
    let reason = choice["finish_reason"]?.string
    return TextResult(
      text: text,
      toolCalls: calls,
      finishReason: reason,
      usage: response["usage"],
      octoryn: governance,
      rawResponse: root
    )
  }

  private static func text(_ value: JSONValue?) -> String {
    switch value {
    case .string(let text):
      text
    case .array(let parts):
      parts.compactMap { part in
        guard case .object(let object) = part,
          object["type"] == .string("text")
        else { return nil }
        return object["text"]?.string
      }.joined()
    default:
      ""
    }
  }

  private static func toolCalls(_ value: JSONValue?) -> [ToolCall] {
    guard case .array(let calls) = value else { return [] }
    return calls.compactMap { call in
      guard case .object(let object) = call,
        case .object(let function) = object["function"]
      else { return nil }
      return ToolCall(
        id: object["id"]?.string ?? "",
        name: function["name"]?.string ?? "",
        arguments: function["arguments"]?.string ?? "{}",
        type: object["type"]?.string ?? "function"
      )
    }
  }

  private func ensureSuccess(
    _ status: Int,
    headers: [String: String],
    body: Data
  ) throws {
    guard !(200...299).contains(status) else { return }
    let root = try? JSONDecoder().decode(JSONValue.self, from: body)
    let error = root?.object?["error"]?.object
    throw OctorynError.api(
      status: status,
      code: error?["code"]?.string,
      message: error?["message"]?.string ?? "Octoryn request failed",
      requestID: headers["x-request-id"],
      retryAfter: headers["retry-after"].flatMap(Int.init)
    )
  }

  private func governance(_ headers: [String: String]) -> GovernanceMetadata {
    GovernanceMetadata(
      runID: headers["x-octoryn-run-id"],
      upstream: headers["x-octoryn-upstream"],
      byok: headers["x-octoryn-byok"],
      region: headers["x-octoryn-region"],
      route: headers["x-octoryn-route"],
      policyDecision: headers["x-octoryn-policy-decision"],
      evidenceHash: headers["x-octoryn-evidence-hash"],
      estimatedCost: headers["x-octoryn-estimated-cost"].flatMap(Double.init)
    )
  }
}

extension JSONValue {
  fileprivate var object: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  fileprivate var string: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
}
