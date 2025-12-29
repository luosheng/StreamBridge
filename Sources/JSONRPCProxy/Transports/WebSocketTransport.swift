import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import WebSocketKit

/// Configuration for WebSocket transport
public struct WebSocketTransportConfiguration: Sendable {
  public let host: String
  public let port: Int
  public let path: String
  public let useTLS: Bool

  public init(
    host: String = "127.0.0.1", port: Int = 8080, path: String = "/", useTLS: Bool = false
  ) {
    self.host = host
    self.port = port
    self.path = path
    self.useTLS = useTLS
  }

  public var url: URL {
    let scheme = useTLS ? "wss" : "ws"
    return URL(string: "\(scheme)://\(host):\(port)\(path)")!
  }
}

/// Transport implementation using WebSocket for JSON-RPC communication
public actor WebSocketTransport: Transport {
  public let mode: TransportMode
  public private(set) var isRunning: Bool = false

  private let config: WebSocketTransportConfiguration
  private let logger: Logger
  private var messagesContinuation: AsyncStream<Data>.Continuation?
  private var _messages: AsyncStream<Data>?

  // Server mode
  private var eventLoopGroup: EventLoopGroup?
  private var serverChannel: Channel?
  private var connectedClients: [WebSocket] = []

  // Client mode
  private var clientWebSocket: WebSocket?
  private var clientEventLoopGroup: EventLoopGroup?

  public var messages: AsyncStream<Data> {
    if let existing = _messages {
      return existing
    }
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    self.messagesContinuation = continuation
    self._messages = stream
    return stream
  }

  /// Initialize a WebSocket transport
  /// - Parameters:
  ///   - mode: .server creates a WebSocket server, .client connects to a WebSocket server
  ///   - config: WebSocket configuration
  ///   - logger: Optional logger instance
  public init(
    mode: TransportMode,
    config: WebSocketTransportConfiguration = WebSocketTransportConfiguration(),
    logger: Logger? = nil
  ) {
    self.mode = mode
    self.config = config
    self.logger = logger ?? Logger(label: "jsonrpc-proxy.websocket")
  }

  public func start() async throws {
    guard !isRunning else {
      throw TransportError.alreadyStarted
    }

    isRunning = true
    _ = messages  // Initialize messages stream

    if mode == .server {
      try await startServer()
    } else {
      try await startClient()
    }

    logger.info("WebSocketTransport started in \(mode) mode on \(config.host):\(config.port)")
  }

  public func stop() async throws {
    guard isRunning else { return }

    isRunning = false

    if mode == .server {
      for client in connectedClients {
        try await client.close()
      }
      connectedClients.removeAll()
      try await serverChannel?.close()
      try await eventLoopGroup?.shutdownGracefully()
      serverChannel = nil
      eventLoopGroup = nil
    } else {
      try await clientWebSocket?.close()
      try await clientEventLoopGroup?.shutdownGracefully()
      clientWebSocket = nil
      clientEventLoopGroup = nil
    }

    messagesContinuation?.finish()
    logger.info("WebSocketTransport stopped")
  }

  public func send(_ data: Data) async throws {
    guard isRunning else {
      throw TransportError.notStarted
    }

    if mode == .client {
      guard let ws = clientWebSocket else {
        throw TransportError.notStarted
      }
      try await ws.send(Array(data))
    } else {
      // Server mode: broadcast to all connected clients
      for client in connectedClients {
        try await client.send(Array(data))
      }
    }

    logger.debug("Sent \(data.count) bytes via WebSocket")
  }

  /// Send to a specific client (server mode only)
  public func send(_ data: Data, to client: WebSocket) async throws {
    guard mode == .server else {
      throw TransportError.sendFailed("send(to:) is only available in server mode")
    }
    try await client.send(Array(data))
  }

  // MARK: - Server Mode

  private func startServer() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    self.eventLoopGroup = group

    // Use WebSocketKit with NIO upgrader

    let upgrader = NIOWebSocketServerUpgrader(
      shouldUpgrade: { channel, head in
        channel.eventLoop.makeSucceededFuture(HTTPHeaders())
      },
      upgradePipelineHandler: { channel, _ in
        WebSocket.server(on: channel) { [weak self] ws in
          guard let self else { return }
          Task {
            await self.handleNewClient(ws)
          }
        }
      }
    )

    let httpHandler = WebSocketHTTPHandler()

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(.backlog, value: 256)
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
          upgraders: [upgrader],
          completionHandler: { _ in }
        )
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgradeConfig)
          .flatMap {
            channel.pipeline.addHandler(httpHandler)
          }
      }
      .childChannelOption(.socketOption(.so_reuseaddr), value: 1)

    let channel = try await bootstrap.bind(host: config.host, port: config.port).get()
    self.serverChannel = channel
  }

  private func handleNewClient(_ ws: WebSocket) {
    connectedClients.append(ws)
    logger.info("New WebSocket client connected. Total clients: \(connectedClients.count)")

    ws.onBinary { [weak self] _, buffer in
      guard let self else { return }
      let data = Data(buffer.readableBytesView)
      Task {
        await self.handleIncomingMessage(data)
      }
    }

    ws.onText { [weak self] _, text in
      guard let self else { return }
      let data = Data(text.utf8)
      Task {
        await self.handleIncomingMessage(data)
      }
    }

    ws.onClose.whenComplete { [weak self] _ in
      guard let self else { return }
      Task {
        await self.removeClient(ws)
      }
    }
  }

  private func removeClient(_ ws: WebSocket) {
    connectedClients.removeAll { $0 === ws }
    logger.info("WebSocket client disconnected. Total clients: \(connectedClients.count)")
  }

  // MARK: - Client Mode

  private func startClient() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    self.clientEventLoopGroup = group

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      WebSocket.connect(to: config.url.absoluteString, on: group) { [weak self] ws in
        guard let self else {
          continuation.resume()
          return
        }
        Task {
          await self.handleClientConnection(ws)
          continuation.resume()
        }
      }.whenFailure { error in
        continuation.resume(throwing: error)
      }
    }
  }

  private func handleClientConnection(_ ws: WebSocket) {
    self.clientWebSocket = ws

    ws.onBinary { [weak self] _, buffer in
      guard let self else { return }
      let data = Data(buffer.readableBytesView)
      Task {
        await self.handleIncomingMessage(data)
      }
    }

    ws.onText { [weak self] _, text in
      guard let self else { return }
      let data = Data(text.utf8)
      Task {
        await self.handleIncomingMessage(data)
      }
    }

    ws.onClose.whenComplete { [weak self] _ in
      guard let self else { return }
      Task {
        await self.handleClientDisconnection()
      }
    }
  }

  private func handleClientDisconnection() {
    clientWebSocket = nil
    logger.info("WebSocket client disconnected from server")
  }

  // MARK: - Common

  private func handleIncomingMessage(_ data: Data) {
    messagesContinuation?.yield(data)
    logger.debug("Received \(data.count) bytes via WebSocket")
  }
}

// MARK: - HTTP Handler for WebSocket Upgrade

private final class WebSocketHTTPHandler: ChannelInboundHandler, RemovableChannelHandler,
  @unchecked Sendable
{
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    // Handle non-upgrade HTTP requests by returning 400
    let reqPart = unwrapInboundIn(data)

    if case .end = reqPart {
      var headers = HTTPHeaders()
      headers.add(name: "Content-Length", value: "0")
      let head = HTTPResponseHead(version: .http1_1, status: .badRequest, headers: headers)
      context.write(wrapOutboundOut(.head(head)), promise: nil)
      context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
  }
}
