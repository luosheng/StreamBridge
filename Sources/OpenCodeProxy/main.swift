import Foundation
import Logging
import StreamBridge

/// OpenCode ACP Proxy
///
/// A transparent stdio proxy that forwards stdin to "opencode acp"
/// and returns stdout/stderr back.

@main
struct OpenCodeProxy {
  static let enableLogging = ProcessInfo.processInfo.environment["DEBUG"] != nil

  static func log(_ message: String) {
    if enableLogging {
      fputs("[proxy] \(message)\n", stderr)
    }
  }

  static func main() async throws {
    log("Starting OpenCode ACP Proxy...")

    // Launch the subprocess
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["opencode", "acp"]
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
      log("Process started with PID: \(process.processIdentifier)")
    } catch {
      fputs("[proxy] Failed to start process: \(error)\n", stderr)
      exit(1)
    }

    // Forward parent stdin -> subprocess stdin
    let stdinTask = Task.detached {
      let inputHandle = FileHandle.standardInput
      let outputHandle = stdinPipe.fileHandleForWriting

      while true {
        let data = inputHandle.availableData
        if data.isEmpty {
          Self.log("stdin EOF")
          try? outputHandle.close()
          break
        }
        Self.log("stdin received \(data.count) bytes")
        try? outputHandle.write(contentsOf: data)
      }
    }

    // Forward subprocess stdout -> parent stdout
    let stdoutTask = Task.detached {
      let inputHandle = stdoutPipe.fileHandleForReading

      while true {
        let data = inputHandle.availableData
        if data.isEmpty {
          Self.log("subprocess stdout EOF")
          break
        }
        Self.log("subprocess stdout: \(data.count) bytes")
        FileHandle.standardOutput.write(data)
      }
    }

    // Forward subprocess stderr -> parent stderr
    let stderrTask = Task.detached {
      let inputHandle = stderrPipe.fileHandleForReading

      while true {
        let data = inputHandle.availableData
        if data.isEmpty {
          Self.log("subprocess stderr EOF")
          break
        }
        Self.log("subprocess stderr: \(data.count) bytes")
        if let text = String(data: data, encoding: .utf8) {
          Self.log("stderr content: \(text)")
        }
        FileHandle.standardError.write(data)
      }
    }

    // Wait for process to exit
    process.waitUntilExit()
    log("Process exited with code: \(process.terminationStatus)")

    stdinTask.cancel()
    stdoutTask.cancel()
    stderrTask.cancel()

    exit(process.terminationStatus)
  }
}
