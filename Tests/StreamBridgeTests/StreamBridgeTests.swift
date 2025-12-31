import Foundation
import Testing

@testable import StreamProxy

@Suite("Transport Mode Tests")
struct TransportModeTests {
  @Test("Stdio transport initializes with correct mode")
  func testStdioTransportMode() async {
    let serverTransport = StdioTransport(mode: .server)
    let clientTransport = StdioTransport(mode: .client)

    let serverMode = await serverTransport.mode
    let clientMode = await clientTransport.mode

    #expect(serverMode == .server)
    #expect(clientMode == .client)
  }

  @Test("HTTP transport initializes with correct mode")
  func testHTTPTransportMode() async {
    let serverTransport = HTTPTransport(mode: .server)
    let clientTransport = HTTPTransport(mode: .client)

    let serverMode = await serverTransport.mode
    let clientMode = await clientTransport.mode

    #expect(serverMode == .server)
    #expect(clientMode == .client)
  }

  @Test("WebSocket transport initializes with correct mode")
  func testWebSocketTransportMode() async {
    let serverTransport = WebSocketTransport(mode: .server)
    let clientTransport = WebSocketTransport(mode: .client)

    let serverMode = await serverTransport.mode
    let clientMode = await clientTransport.mode

    #expect(serverMode == .server)
    #expect(clientMode == .client)
  }
}

@Suite("Configuration Tests")
struct ConfigurationTests {
  @Test("HTTP configuration creates correct URL")
  func testHTTPConfigURL() {
    let config = HTTPTransportConfiguration(
      host: "localhost", port: 8080, inPath: "/in", outPath: "/out")
    #expect(config.baseURL.absoluteString == "http://localhost:8080")
    #expect(config.inURL.absoluteString == "http://localhost:8080/in")
    #expect(config.outURL.absoluteString == "http://localhost:8080/out")
  }

  @Test("WebSocket configuration creates correct URL")
  func testWebSocketConfigURL() {
    let config = WebSocketTransportConfiguration(
      host: "localhost", port: 9000, path: "/ws", useTLS: false)
    #expect(config.url.absoluteString == "ws://localhost:9000/ws")
  }

  @Test("WebSocket configuration with TLS creates correct URL")
  func testWebSocketConfigTLSURL() {
    let config = WebSocketTransportConfiguration(
      host: "example.com", port: 443, path: "/ws", useTLS: true)
    #expect(config.url.absoluteString == "wss://example.com:443/ws")
  }

  @Test("TransportType factory methods")
  func testTransportTypeFactoryMethods() {
    let httpType = TransportType.http(host: "localhost", port: 3000)
    let wsType = TransportType.webSocket(host: "localhost", port: 8080, path: "/ws", useTLS: true)

    if case .http(let config) = httpType {
      #expect(config.host == "localhost")
      #expect(config.port == 3000)
      #expect(config.inPath == "/in")
      #expect(config.outPath == "/out")
    } else {
      Issue.record("Expected HTTP transport type")
    }

    if case .webSocket(let config) = wsType {
      #expect(config.host == "localhost")
      #expect(config.port == 8080)
      #expect(config.path == "/ws")
      #expect(config.useTLS == true)
    } else {
      Issue.record("Expected WebSocket transport type")
    }
  }
}

@Suite("Proxy Tests")
struct ProxyTests {
  @Test("Proxy initializes correctly with transport types")
  func testProxyInitialization() async {
    let proxy = Proxy(
      inboundType: .stdio,
      outboundType: .http(host: "localhost", port: 8080)
    )

    let isRunning = await proxy.isRunning
    #expect(isRunning == false)
  }

  @Test("Proxy initializes correctly with configuration")
  func testProxyConfigurationInitialization() async {
    let config = ProxyConfiguration(
      inbound: .stdio,
      outbound: .webSocket(host: "localhost", port: 9000, path: "/ws", useTLS: false)
    )
    let proxy = Proxy(configuration: config)

    let isRunning = await proxy.isRunning
    #expect(isRunning == false)
  }

  @Test("Bridge typealias works")
  func testBridgeTypealias() async {
    let bridge = Bridge(
      inboundType: .stdio,
      outboundType: .http(host: "localhost", port: 8080)
    )

    let isRunning = await bridge.isRunning
    #expect(isRunning == false)
  }
}
