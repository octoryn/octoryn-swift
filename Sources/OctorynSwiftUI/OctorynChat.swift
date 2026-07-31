import Foundation
import Observation
import OctorynCore

public struct OctorynUIMessage: Identifiable, Equatable, Sendable {
  public enum Role: String, Sendable {
    case user
    case assistant
    case system
  }

  public let id: UUID
  public let role: Role
  public var text: String
  public var reasoning: String
  public var toolCalls: [ToolCall]
  public var governance: GovernanceMetadata?

  public init(
    id: UUID = UUID(),
    role: Role,
    text: String,
    reasoning: String = "",
    toolCalls: [ToolCall] = [],
    governance: GovernanceMetadata? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.reasoning = reasoning
    self.toolCalls = toolCalls
    self.governance = governance
  }
}

@MainActor
@Observable
public final class OctorynChat {
  public private(set) var messages: [OctorynUIMessage] = []
  public private(set) var isStreaming = false
  public private(set) var error: String?

  private let client: OctorynClient
  private let model: String
  private var streamTask: Task<Void, Never>?

  public init(client: OctorynClient, model: String) {
    self.client = client
    self.model = model
  }

  public func send(_ prompt: String) {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isStreaming else { return }

    messages.append(.init(role: .user, text: trimmed))
    messages.append(.init(role: .assistant, text: ""))
    let assistantIndex = messages.endIndex - 1
    isStreaming = true
    error = nil

    streamTask = Task {
      do {
        let history = messages.dropLast().map {
          ChatMessage(role: $0.role.rawValue, content: $0.text)
        }
        let stream = try await client.streamText(
          .init(model: model, messages: history)
        )
        for try await event in stream {
          apply(event, to: assistantIndex)
        }
      } catch is CancellationError {
        // User-initiated cancellation is an expected terminal state.
      } catch {
        self.error = error.localizedDescription
      }
      isStreaming = false
    }
  }

  public func stop() {
    streamTask?.cancel()
    streamTask = nil
    isStreaming = false
  }

  public func reset() {
    stop()
    messages.removeAll()
    error = nil
  }

  private func apply(_ event: StreamEvent, to index: Int) {
    guard messages.indices.contains(index) else { return }
    switch event {
    case .start(let governance):
      messages[index].governance = governance
    case .textDelta(let text):
      messages[index].text += text
    case .reasoningDelta(let text):
      messages[index].reasoning += text
    case .toolCall(let call):
      messages[index].toolCalls.append(call)
    case .finish(_, let governance):
      messages[index].governance = governance
    case .error(let message):
      error = message
    case .toolCallStart, .toolCallDelta, .usage, .providerEvent:
      break
    }
  }
}
