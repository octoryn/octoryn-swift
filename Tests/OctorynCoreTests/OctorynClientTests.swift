import Foundation
import XCTest

@testable import OctorynCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private final class MockTransport: OctorynTransport, @unchecked Sendable {
  var response: TransportResponse
  var streamResponse: TransportStream?
  private(set) var request: URLRequest?

  init(response: TransportResponse) {
    self.response = response
  }

  func send(_ request: URLRequest) async throws -> TransportResponse {
    self.request = request
    return response
  }

  func stream(_ request: URLRequest) async throws -> TransportStream {
    self.request = request
    return try XCTUnwrap(streamResponse)
  }
}

final class OctorynClientTests: XCTestCase {
  func testGenerateTextNormalizesToolsAndGovernance() async throws {
    let data = try fixture("chat-completion", extension: "json")
    let transport = MockTransport(
      response: .init(
        status: 200,
        headers: [
          "x-octoryn-run-id": "run_swift",
          "x-octoryn-region": "au-sydney",
        ],
        body: data
      ))
    let client = try OctorynClient(apiKey: "test", transport: transport)

    let result = try await client.generateText(
      .init(
        model: "policy/frontier",
        prompt: "Weather?"
      ))

    XCTAssertEqual(result.text, "Governed answer")
    XCTAssertEqual(result.toolCalls.first?.name, "getWeather")
    XCTAssertEqual(result.octoryn.runID, "run_swift")
    XCTAssertEqual(result.octoryn.region, "au-sydney")
    XCTAssertEqual(transport.request?.url?.path, "/v1/chat/completions")
    XCTAssertEqual(
      try result.toolCalls.first?.decodeInput(),
      .object(["city": .string("Sydney")])
    )
  }

  func testCustomBaseURLWithoutTrailingSlashPreservesVersionPath() async throws {
    let transport = MockTransport(
      response: .init(
        status: 200,
        headers: [:],
        body: Data("{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}".utf8)
      ))
    let client = try OctorynClient(
      apiKey: "test",
      baseURL: try XCTUnwrap(URL(string: "https://router.test/v1")),
      transport: transport
    )

    _ = try await client.generateText(.init(model: "policy/frontier", prompt: "Hi"))

    XCTAssertEqual(transport.request?.url?.absoluteString, "https://router.test/v1/chat/completions")
  }

  func testStreamingReassemblesSplitToolCalls() async throws {
    let body = String(decoding: try fixture("chat-stream", extension: "sse"), as: UTF8.self)
    let lines = AsyncThrowingStream<String, Error> { continuation in
      for line in body.components(separatedBy: .newlines) {
        continuation.yield(line)
      }
      continuation.finish()
    }
    let transport = MockTransport(response: .init(status: 200, headers: [:], body: Data()))
    transport.streamResponse = .init(
      status: 200,
      headers: ["x-octoryn-upstream": "anthropic"],
      lines: lines
    )
    let client = try OctorynClient(apiKey: "test", transport: transport)

    let stream = try await client.streamText(.init(model: "policy/frontier", prompt: "Hi"))
    var text = ""
    var call: ToolCall?
    var upstream: String?
    for try await event in stream {
      switch event {
      case .textDelta(let fragment): text += fragment
      case .toolCall(let value): call = value
      case .finish(_, let governance): upstream = governance.upstream
      default: break
      }
    }

    XCTAssertEqual(text, "Octoryn")
    XCTAssertEqual(call?.name, "getWeather")
    XCTAssertEqual(try call?.decodeInput(), .object(["city": .string("Sydney")]))
    XCTAssertEqual(upstream, "anthropic")
  }

  func testStructuredOutputValidatesAndDecodes() async throws {
    struct Risk: Codable, Equatable, Sendable {
      let risk: String
      let score: Double
    }
    let response = """
      {"choices":[{"message":{"content":"{\\"risk\\":\\"low\\",\\"score\\":7}"},"finish_reason":"stop"}]}
      """
    let transport = MockTransport(
      response: .init(
        status: 200,
        headers: [:],
        body: Data(response.utf8)
      ))
    let client = try OctorynClient(apiKey: "test", transport: transport)
    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "risk": .object(["type": .string("string")]),
        "score": .object(["type": .string("number")]),
      ]),
      "required": .array([.string("risk"), .string("score")]),
      "additionalProperties": .bool(false),
    ])

    let result = try await client.generateObject(
      Risk.self,
      request: .init(model: "policy/risk", prompt: "Assess"),
      schema: schema
    )

    XCTAssertEqual(result.object, Risk(risk: "low", score: 7))
  }

  func testRejectsInvalidPromptCombinationLocally() async throws {
    let transport = MockTransport(response: .init(status: 200, headers: [:], body: Data()))
    let client = try OctorynClient(apiKey: "test", transport: transport)

    do {
      _ = try await client.generateText(
        .init(
          model: "policy/frontier",
          prompt: "one",
          messages: [.init(role: "user", content: "two")]
        ))
      XCTFail("Expected local validation error")
    } catch OctorynError.invalidRequest {
      XCTAssertNil(transport.request)
    }
  }

  private func fixture(_ name: String, extension: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: `extension`, subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
  }
}
