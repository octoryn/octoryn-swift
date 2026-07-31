import OctorynCore
import XCTest

@testable import OctorynSwiftUI

@MainActor
final class OctorynChatTests: XCTestCase {
  func testInitialStateIsIdle() throws {
    let client = try OctorynClient(apiKey: "test")
    let chat = OctorynChat(client: client, model: "policy/frontier")

    XCTAssertTrue(chat.messages.isEmpty)
    XCTAssertFalse(chat.isStreaming)
    XCTAssertNil(chat.error)
  }

  func testResumesCustomTransportFromLastEventID() async throws {
    let recorder = ResumableRecorder()
    let chat = OctorynChat(model: "policy/frontier") { messages, _, resumeFrom in
      await recorder.stream(messages: messages, resumeFrom: resumeFrom)
    }

    chat.send("Hello")
    await waitUntil { chat.canResume }
    XCTAssertEqual(chat.messages.last?.text, "Octo")
    XCTAssertEqual(chat.lastEventID, "evt_1")

    chat.resume()
    await waitUntil { !chat.isStreaming }
    XCTAssertEqual(chat.messages.last?.text, "Octoryn")
    XCTAssertFalse(chat.canResume)
    let resumeValues = await recorder.resumeValues()
    XCTAssertEqual(resumeValues, [nil, "evt_1"])
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<100 where !condition() {
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
  }
}

private enum TestDisconnect: Error {
  case connectionLost
}

private actor ResumableRecorder {
  private var resumes: [String?] = []

  func stream(
    messages: [ChatMessage],
    resumeFrom: String?
  ) -> AsyncThrowingStream<OctorynResumableEvent, Error> {
    resumes.append(resumeFrom)
    return AsyncThrowingStream { continuation in
      if resumeFrom == nil {
        continuation.yield(.init(id: "evt_1", event: .textDelta("Octo")))
        continuation.finish(throwing: TestDisconnect.connectionLost)
      } else {
        continuation.yield(.init(id: "evt_2", event: .textDelta("ryn")))
        continuation.yield(
          .init(id: "evt_3", event: .finish(reason: "stop", governance: .init(
            runID: "run_swift_resume",
            upstream: nil,
            byok: nil,
            region: "au-sydney",
            route: nil,
            policyDecision: nil,
            evidenceHash: nil,
            estimatedCost: nil
          )))
        )
        continuation.finish()
      }
    }
  }

  func resumeValues() -> [String?] { resumes }
}
