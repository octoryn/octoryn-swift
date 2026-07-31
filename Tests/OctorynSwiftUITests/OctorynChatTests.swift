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
}
