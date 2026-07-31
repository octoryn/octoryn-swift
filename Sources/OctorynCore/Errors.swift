import Foundation

public enum OctorynError: Error, LocalizedError, Sendable {
  case invalidRequest(String)
  case invalidResponse(String)
  case api(status: Int, code: String?, message: String, requestID: String?, retryAfter: Int?)
  case structuredOutput(rawOutput: String, validationErrors: [String])
  case incompleteStream

  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let message), .invalidResponse(let message):
      message
    case .api(_, _, let message, _, _):
      message
    case .structuredOutput:
      "Octoryn structured output failed validation"
    case .incompleteStream:
      "Octoryn stream ended before [DONE]"
    }
  }
}
