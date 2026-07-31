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

public struct OctorynResumableEvent: Sendable {
  public let id: String?
  public let event: StreamEvent

  public init(id: String? = nil, event: StreamEvent) {
    self.id = id
    self.event = event
  }
}

public typealias OctorynChatTransport = @Sendable (
  _ messages: [ChatMessage],
  _ model: String,
  _ resumeFrom: String?
) async throws -> AsyncThrowingStream<OctorynResumableEvent, Error>

@MainActor
@Observable
public final class OctorynChat {
  public private(set) var messages: [OctorynUIMessage] = []
  public private(set) var isStreaming = false
  public private(set) var error: String?
  public private(set) var lastEventID: String?
  public private(set) var canResume = false

  private let model: String
  private let transport: OctorynChatTransport
  private var streamTask: Task<Void, Never>?
  private var pendingAssistantIndex: Int?

  public init(client: OctorynClient, model: String) {
    self.transport = { messages, model, resumeFrom in
      if resumeFrom != nil {
        throw OctorynError.invalidRequest(
          "URLSessionTransport does not expose resumable event IDs; provide OctorynChatTransport"
        )
      }
      let source = try await client.streamText(.init(model: model, messages: messages))
      return AsyncThrowingStream { continuation in
        let task = Task {
          do {
            for try await event in source {
              continuation.yield(.init(event: event))
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
    self.model = model
  }

  public init(model: String, transport: @escaping OctorynChatTransport) {
    self.model = model
    self.transport = transport
  }

  public func send(_ prompt: String) {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isStreaming else { return }

    messages.append(.init(role: .user, text: trimmed))
    messages.append(.init(role: .assistant, text: ""))
    let assistantIndex = messages.endIndex - 1
    lastEventID = nil
    canResume = false
    startStream(assistantIndex: assistantIndex, resumeFrom: nil)
  }

  public func edit(messageID: UUID, text: String) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty,
      let index = messages.firstIndex(where: { $0.id == messageID && $0.role == .user })
    else { return }
    stop()
    messages[index].text = value
    messages.removeSubrange((index + 1)..<messages.endIndex)
    messages.append(.init(role: .assistant, text: ""))
    lastEventID = nil
    canResume = false
    startStream(assistantIndex: messages.endIndex - 1, resumeFrom: nil)
  }

  public func regenerate(messageID: UUID? = nil) {
    let target = messageID.flatMap { id in
      messages.firstIndex(where: { $0.id == id && $0.role == .assistant })
    } ?? messages.indices.reversed().first(where: { messages[$0].role == .assistant })
    guard let assistantIndex = target,
      messages[..<assistantIndex].lastIndex(where: { $0.role == .user }) != nil
    else { return }
    stop()
    messages.removeSubrange(assistantIndex..<messages.endIndex)
    messages.append(.init(role: .assistant, text: ""))
    lastEventID = nil
    canResume = false
    startStream(assistantIndex: messages.endIndex - 1, resumeFrom: nil)
  }

  public func resume() {
    guard canResume, let assistantIndex = pendingAssistantIndex,
      let resumeFrom = lastEventID, !isStreaming
    else { return }
    startStream(assistantIndex: assistantIndex, resumeFrom: resumeFrom)
  }

  private func startStream(assistantIndex: Int, resumeFrom: String?) {
    pendingAssistantIndex = assistantIndex
    isStreaming = true
    error = nil

    streamTask = Task {
      do {
        let history = messages.dropLast().map {
          ChatMessage(role: $0.role.rawValue, content: $0.text)
        }
        let stream = try await transport(history, model, resumeFrom)
        for try await item in stream {
          if let id = item.id { lastEventID = id }
          apply(item.event, to: assistantIndex)
        }
        canResume = false
        pendingAssistantIndex = nil
      } catch is CancellationError {
        // User-initiated cancellation is an expected terminal state.
      } catch {
        self.error = error.localizedDescription
        canResume = lastEventID != nil
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
    lastEventID = nil
    canResume = false
    pendingAssistantIndex = nil
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
