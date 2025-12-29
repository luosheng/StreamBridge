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

/// Protocol defining a transport mechanism for streaming data
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

  /// Stream of incoming data
  var messages: AsyncStream<Data> { get }
}
