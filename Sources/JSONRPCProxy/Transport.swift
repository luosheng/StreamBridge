import Foundation

// MARK: - Transport Protocol

/// Defines the mode in which a transport operates
public enum TransportMode: Sendable {
  /// Server mode: listens for incoming connections/data
  case server
  /// Client mode: connects to a remote endpoint
  case client
}

/// Errors that can occur during transport operations
public enum TransportError: Error, Sendable {
  case notStarted
  case alreadyStarted
  case connectionFailed(String)
  case sendFailed(String)
  case invalidMessage(String)
  case timeout
  case closed
}

/// Protocol defining a JSON-RPC transport mechanism
public protocol Transport: Actor {
  /// The mode this transport is operating in
  var mode: TransportMode { get }

  /// Whether the transport is currently running
  var isRunning: Bool { get }

  /// Start the transport
  func start() async throws

  /// Stop the transport
  func stop() async throws

  /// Send data through the transport
  func send(_ data: Data) async throws

  /// Stream of incoming messages
  var messages: AsyncStream<Data> { get }
}

// MARK: - Message Framing

/// Utilities for JSON-RPC message framing (Content-Length based)
public enum MessageFraming {
  /// Frame a message with Content-Length header
  public static func frame(_ data: Data) -> Data {
    let header = "Content-Length: \(data.count)\r\n\r\n"
    var framedData = Data(header.utf8)
    framedData.append(data)
    return framedData
  }

  /// Parse Content-Length header from data
  /// Returns the content length and the position after the header
  public static func parseHeader(_ data: Data) -> (contentLength: Int, headerEnd: Int)? {
    guard let string = String(data: data, encoding: .utf8) else {
      return nil
    }

    guard let headerEndRange = string.range(of: "\r\n\r\n") else {
      return nil
    }

    let headerPart = String(string[..<headerEndRange.lowerBound])
    let lines = headerPart.split(separator: "\r\n")

    for line in lines {
      let parts = line.split(separator: ":", maxSplits: 1)
      if parts.count == 2 {
        let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        if key == "content-length", let length = Int(value) {
          let headerEnd = string.distance(from: string.startIndex, to: headerEndRange.upperBound)
          return (length, headerEnd)
        }
      }
    }

    return nil
  }
}
