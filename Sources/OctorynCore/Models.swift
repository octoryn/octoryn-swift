import Foundation

public struct ChatMessage: Codable, Equatable, Sendable {
  public let role: String
  public let content: String

  public init(role: String, content: String) {
    self.role = role
    self.content = content
  }
}

public struct ToolDefinition: Encodable, Equatable, Sendable {
  public struct Function: Encodable, Equatable, Sendable {
    public let name: String
    public let description: String?
    public let parameters: JSONValue

    public init(name: String, description: String? = nil, parameters: JSONValue) {
      self.name = name
      self.description = description
      self.parameters = parameters
    }
  }

  public let type = "function"
  public let function: Function

  public init(name: String, description: String? = nil, parameters: JSONValue) {
    self.function = Function(name: name, description: description, parameters: parameters)
  }
}

public struct TextRequest: Sendable {
  public let model: String
  public let prompt: String?
  public let messages: [ChatMessage]?
  public let system: String?
  public let temperature: Double?
  public let maxOutputTokens: Int?
  public let tools: [ToolDefinition]?
  public let metadata: [String: String]?

  public init(
    model: String,
    prompt: String? = nil,
    messages: [ChatMessage]? = nil,
    system: String? = nil,
    temperature: Double? = nil,
    maxOutputTokens: Int? = nil,
    tools: [ToolDefinition]? = nil,
    metadata: [String: String]? = nil
  ) {
    self.model = model
    self.prompt = prompt
    self.messages = messages
    self.system = system
    self.temperature = temperature
    self.maxOutputTokens = maxOutputTokens
    self.tools = tools
    self.metadata = metadata
  }
}

public struct ToolCall: Equatable, Sendable {
  public let id: String
  public let name: String
  public let arguments: String
  public let type: String

  public func decodeInput() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))
  }
}

public struct GovernanceMetadata: Equatable, Sendable {
  public let runID: String?
  public let upstream: String?
  public let byok: String?
  public let region: String?
  public let route: String?
  public let policyDecision: String?
  public let evidenceHash: String?
  public let estimatedCost: Double?

  public init(
    runID: String? = nil,
    upstream: String? = nil,
    byok: String? = nil,
    region: String? = nil,
    route: String? = nil,
    policyDecision: String? = nil,
    evidenceHash: String? = nil,
    estimatedCost: Double? = nil
  ) {
    self.runID = runID
    self.upstream = upstream
    self.byok = byok
    self.region = region
    self.route = route
    self.policyDecision = policyDecision
    self.evidenceHash = evidenceHash
    self.estimatedCost = estimatedCost
  }
}

public struct TextResult: Sendable {
  public let text: String
  public let toolCalls: [ToolCall]
  public let finishReason: String?
  public let usage: JSONValue?
  public let octoryn: GovernanceMetadata
  public let rawResponse: JSONValue?
}

public struct ObjectResult<Value: Decodable & Sendable>: Sendable {
  public let object: Value
  public let result: TextResult
}

public enum StreamEvent: Sendable {
  case start(GovernanceMetadata)
  case textDelta(String)
  case reasoningDelta(String)
  case toolCallStart(index: Int)
  case toolCallDelta(index: Int, fragment: String)
  case toolCall(ToolCall)
  case usage(JSONValue)
  case finish(reason: String?, governance: GovernanceMetadata)
  case providerEvent(JSONValue)
  case error(String)
}
