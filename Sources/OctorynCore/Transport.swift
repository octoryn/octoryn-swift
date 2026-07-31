import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct TransportResponse: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data
}

public struct TransportStream: Sendable {
  public let status: Int
  public let headers: [String: String]
  public let lines: AsyncThrowingStream<String, Error>
}

public protocol OctorynTransport: Sendable {
  func send(_ request: URLRequest) async throws -> TransportResponse
  func stream(_ request: URLRequest) async throws -> TransportStream
}

public struct URLSessionTransport: OctorynTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func send(_ request: URLRequest) async throws -> TransportResponse {
    let (data, response) = try await session.data(for: request)
    let http = try Self.http(response)
    return TransportResponse(
      status: http.statusCode,
      headers: Self.headers(http),
      body: data
    )
  }

  public func stream(_ request: URLRequest) async throws -> TransportStream {
    let (bytes, response) = try await session.bytes(for: request)
    let http = try Self.http(response)
    let lines = AsyncThrowingStream<String, Error> { continuation in
      let task = Task {
        do {
          for try await line in bytes.lines {
            try Task.checkCancellation()
            continuation.yield(line)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return TransportStream(
      status: http.statusCode,
      headers: Self.headers(http),
      lines: lines
    )
  }

  private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse else {
      throw OctorynError.invalidResponse("Octoryn returned a non-HTTP response")
    }
    return response
  }

  private static func headers(_ response: HTTPURLResponse) -> [String: String] {
    response.allHeaderFields.reduce(into: [:]) { result, pair in
      result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
    }
  }
}
