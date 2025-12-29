import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

/// Configuration for HTTP transport
public struct HTTPTransportConfiguration: Sendable {
  public let host: String
  public let port: Int
  public let path: String

  public init(host: String = "127.0.0.1", port: Int = 8080, path: String = "/") {
    self.host = host
    self.port = port
    self.path = path
  }

  public var url: URL {
    URL(string: "http://\(host):\(port)\(path)")!
  }
}

/// Transport implementation using HTTP for JSON-RPC communication
public actor HTTPTransport: Transport {
  public let mode: TransportMode
  public private(set) var isRunning: Bool = false

  private let config: HTTPTransportConfiguration
  private let logger: Logger
  private var messagesContinuation: AsyncStream<Data>.Continuation?
  private var _messages: AsyncStream<Data>?

  // Server mode
  private var eventLoopGroup: EventLoopGroup?
  private var serverChannel: Channel?

  // Client mode
  private var httpClient: HTTPClient?

  public var messages: AsyncStream<Data> {
    if let existing = _messages {
      return existing
    }
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    self.messagesContinuation = continuation
    self._messages = stream
    return stream
  }

  /// Initialize an HTTP transport
  /// - Parameters:
  ///   - mode: .server creates an HTTP server, .client sends HTTP requests
  ///   - config: HTTP configuration (host, port, path)
  ///   - logger: Optional logger instance
  public init(
    mode: TransportMode,
    config: HTTPTransportConfiguration = HTTPTransportConfiguration(),
    logger: Logger? = nil
  ) {
    self.mode = mode
    self.config = config
    self.logger = logger ?? Logger(label: "jsonrpc-proxy.http")
  }

  public func start() async throws {
    guard !isRunning else {
      throw TransportError.alreadyStarted
    }

    isRunning = true

    if mode == .server {
      try await startServer()
    } else {
      startClient()
    }

    logger.info("HTTPTransport started in \(mode) mode on \(config.host):\(config.port)")
  }

  public func stop() async throws {
    guard isRunning else { return }

    isRunning = false

    if mode == .server {
      try await serverChannel?.close()
      try await eventLoopGroup?.shutdownGracefully()
      serverChannel = nil
      eventLoopGroup = nil
    } else {
      try await httpClient?.shutdown()
      httpClient = nil
    }

    messagesContinuation?.finish()
    logger.info("HTTPTransport stopped")
  }

  public func send(_ data: Data) async throws {
    guard isRunning else {
      throw TransportError.notStarted
    }

    if mode == .client {
      try await sendHTTPRequest(data)
    } else {
      // In server mode, sending is handled via responses
      // For now, we just log - proper request/response matching would need more state
      logger.debug("Server mode send: \(data.count) bytes")
    }
  }

  // MARK: - Server Mode

  private func startServer() async throws {
    _ = messages  // Initialize messages stream

    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    self.eventLoopGroup = group

    let messageHandler = HTTPServerMessageHandler { [weak self] data in
      guard let self else { return }
      await self.handleIncomingMessage(data)
    }

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(.backlog, value: 256)
      .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(messageHandler)
        }
      }
      .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(.maxMessagesPerRead, value: 16)

    let channel = try await bootstrap.bind(host: config.host, port: config.port).get()
    self.serverChannel = channel
  }

  private func handleIncomingMessage(_ data: Data) {
    messagesContinuation?.yield(data)
    logger.debug("Received HTTP request: \(data.count) bytes")
  }

  // MARK: - Client Mode

  private func startClient() {
    httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
    _ = messages  // Initialize messages stream
  }

  private func sendHTTPRequest(_ data: Data) async throws {
    guard let client = httpClient else {
      throw TransportError.notStarted
    }

    var request = HTTPClientRequest(url: config.url.absoluteString)
    request.method = .POST
    request.headers.add(name: "Content-Type", value: "application/json")
    request.body = .bytes(ByteBuffer(data: data))

    let response = try await client.execute(request, timeout: .seconds(30))
    let body = try await response.body.collect(upTo: 10 * 1024 * 1024)  // 10MB max
    let responseData = Data(buffer: body)

    if !responseData.isEmpty {
      messagesContinuation?.yield(responseData)
      logger.debug("Received HTTP response: \(responseData.count) bytes")
    }
  }
}

// MARK: - HTTP Server Handler

private final class HTTPServerMessageHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let onMessage: @Sendable (Data) async -> Void
  private var requestBody = Data()

  init(onMessage: @escaping @Sendable (Data) async -> Void) {
    self.onMessage = onMessage
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let reqPart = unwrapInboundIn(data)

    switch reqPart {
    case .head:
      requestBody = Data()

    case .body(let buffer):
      var buf = buffer
      if let bytes = buf.readBytes(length: buf.readableBytes) {
        requestBody.append(contentsOf: bytes)
      }

    case .end:
      let body = requestBody
      let onMessage = self.onMessage

      // Process the request asynchronously
      Task {
        await onMessage(body)
      }

      // Send a simple acknowledgment response
      let responseBody = Data("{\"jsonrpc\":\"2.0\",\"result\":\"received\"}".utf8)

      var headers = HTTPHeaders()
      headers.add(name: "Content-Type", value: "application/json")
      headers.add(name: "Content-Length", value: String(responseBody.count))

      let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
      context.write(wrapOutboundOut(.head(head)), promise: nil)

      var buffer = context.channel.allocator.buffer(capacity: responseBody.count)
      buffer.writeBytes(responseBody)
      context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

      context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
  }
}
