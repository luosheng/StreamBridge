// The Swift Programming Language
// https://docs.swift.org/swift-book

// MARK: - Public API Exports

// Core Types
@_exported import struct Foundation.Data
@_exported import struct Foundation.URL

// Transport Protocol & Types
public typealias JSONRPCTransport = Transport
public typealias JSONRPCTransportMode = TransportMode
public typealias JSONRPCTransportError = TransportError

// Re-export main types for convenience
// Users can import JSONRPCProxy and access:
// - Proxy
// - ProxyConfiguration
// - TransportType
// - StdioTransport
// - HTTPTransport
// - HTTPTransportConfiguration
// - WebSocketTransport
// - WebSocketTransportConfiguration
// - MessageFraming
