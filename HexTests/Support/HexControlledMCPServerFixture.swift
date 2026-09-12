import Darwin
import Foundation
import HexMCP

/// Real loopback HTTP and stdio protocol fixtures; never reads the user's environment or credentials.
@MainActor
final class HexControlledMCPServerFixture {
  static let token = "hex-controlled-fixture-token"
  let root: URL
  private let process = Process()
  private var state: [String: String] = ["mode": "ready", "tool": "echo"]

  init() throws {
    // Foundation can retain /var as a symlinked alias; the private store requires every ancestor
    // to be literal. Use the same realpath boundary as the persistence integration fixtures.
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    let succeeded = resolved.withUnsafeMutableBufferPointer { buffer in
      FileManager.default.temporaryDirectory.path.withCString {
        Darwin.realpath($0, buffer.baseAddress) != nil
      }
    }
    guard succeeded else { throw FixtureError.temporaryDirectoryUnavailable }
    let bytes = resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    root = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
      .appendingPathComponent("HexControlledMCP-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    try Self.httpProgram.write(
      to: root.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    try writeState()
  }

  func start() async throws -> URL {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [root.appendingPathComponent("server.py").path, root.path]
    process.environment = ["PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let portURL = root.appendingPathComponent("port")
    for _ in 0..<500 {
      if let text = try? String(contentsOf: portURL, encoding: .utf8),
        let port = Int(text), let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")
      {
        return endpoint
      }
      guard process.isRunning else { throw FixtureError.serverExited }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.serverDidNotStart
  }

  func update(mode: String = "ready", tool: String = "echo") throws {
    state = ["mode": mode, "tool": tool]
    try writeState()
  }

  func events() throws -> [[String: String]] {
    let url = root.appendingPathComponent("events.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode([String: String].self, from: Data($0.utf8))
    }
  }

  func waitForCalls(_ count: Int) async throws {
    for _ in 0..<500 {
      if try events().filter({ $0["method"] == "tools/call" }).count >= count { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw FixtureError.callDidNotArrive
  }

  func stopServer() {
    guard process.isRunning else { return }
    process.terminate()
    process.waitUntilExit()
  }

  func cleanup() {
    stopServer()
    try? FileManager.default.removeItem(at: root)
  }

  static func stdioConfiguration(serverID: String = "local") throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
      serverID: serverID, executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
      arguments: [stdioProgram], workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"], requestTimeoutMilliseconds: 2_000,
      shutdownGraceMilliseconds: 50, maximumMessageBytes: 16 * 1_024)
  }

  static let stdioProgram = #"""
    {
      id = $0
      if (!match(id, /"id":[0-9]+/)) next
      id = substr(id, RSTART + 5, RLENGTH - 5)
      if (index($0, "\"method\":\"initialize\""))
        result = "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"Controlled stdio\",\"version\":\"1\"}}"
      else if (index($0, "\"method\":\"tools/list\""))
        result = "{\"tools\":[{\"name\":\"echo\",\"inputSchema\":{\"type\":\"object\"}}]}"
      else if (index($0, "\"method\":\"tools/call\""))
        result = "{\"content\":[{\"type\":\"text\",\"text\":\"stdio receipt\"}],\"structuredContent\":{\"receipt\":\"stdio\"},\"isError\":false}"
      else next
      print "{\"jsonrpc\":\"2.0\",\"id\":" id ",\"result\":" result "}"
      fflush()
    }
    """#

  private func writeState() throws {
    try JSONEncoder().encode(state).write(
      to: root.appendingPathComponent("state.json"), options: .atomic)
  }

  private enum FixtureError: Error {
    case serverExited, serverDidNotStart, callDidNotArrive, temporaryDirectoryUnavailable
  }

  private static let httpProgram = #"""
    import http.server, json, os, sys, threading, time, uuid
    root = sys.argv[1]
    lock = threading.Lock()
    sessions = set()
    ping_replied = threading.Event()
    def state():
        with open(os.path.join(root, 'state.json')) as source:
            return json.load(source)
    def record(method, authorized, session='', operation='', protocol=''):
        event = dict(method=method, authorized=str(authorized), session=session,
                     operation=operation, protocol=protocol)
        with lock:
            with open(os.path.join(root, 'events.jsonl'), 'a') as destination:
                destination.write(json.dumps(event) + '\n')
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def send(self, status, body=b'', session=None, content_type='application/json'):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            if session: self.send_header('MCP-Session-Id', session)
            self.end_headers()
            if body:
                try: self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError): pass
        def do_DELETE(self):
            session = self.headers.get('MCP-Session-Id', '')
            authorized = self.headers.get('Authorization') == 'Bearer hex-controlled-fixture-token'
            record('DELETE', authorized, session)
            with lock: sessions.discard(session)
            self.send(204)
        def do_POST(self):
            current = state()
            message = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            method = message.get('method', '')
            session = self.headers.get('MCP-Session-Id', '')
            authorized = self.headers.get('Authorization') == 'Bearer hex-controlled-fixture-token'
            operation = str(message.get('params', {}).get('arguments', {}).get('operation', ''))
            record(method, authorized, session, operation,
                   self.headers.get('MCP-Protocol-Version', ''))
            if not authorized or current['mode'] == 'revoked':
                self.send(401); return
            if method == 'initialize':
                session = str(uuid.uuid4())
                with lock: sessions.add(session)
                result = dict(protocolVersion='2025-11-25', capabilities=dict(tools={}),
                              serverInfo=dict(name='Controlled HTTP', version='1'))
            else:
                with lock: valid_session = session in sessions
                if not valid_session: self.send(404); return
                if not method and message.get('id') == 'server-ping' and 'result' in message:
                    ping_replied.set()
                    self.send(202); return
                if method == 'notifications/initialized': self.send(202); return
                if method == 'tools/list':
                    tool = dict(name=current['tool'], inputSchema=dict(type='object'))
                    result = dict(tools=[tool, tool] if current['mode'] == 'malformed' else [tool])
                elif method == 'tools/call':
                    if current['mode'] == 'drop_call':
                        self.close_connection = True; return
                    deadline = time.monotonic() + 5
                    while state()['mode'] == 'hold_call' and time.monotonic() < deadline:
                        time.sleep(.01)
                    result = dict(content=[dict(type='text', text='http receipt ' + operation)],
                                  structuredContent=dict(receipt=operation, session=session), isError=False)
                else: self.send(400); return
            response = json.dumps(dict(jsonrpc='2.0', id=message['id'], result=result)).encode()
            if method == 'tools/list':
                final_event = b'data: ' + response + b'\n\n'
                if current['mode'] == 'keepalive_until_timeout':
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        try:
                            self.wfile.write(b': keepalive\n\n')
                            self.wfile.flush()
                        except (BrokenPipeError, ConnectionResetError): break
                        time.sleep(.05)
                elif current['mode'] == 'ping_gate':
                    ping = b'data: {"jsonrpc":"2.0","id":"server-ping","method":"ping"}\n\n'
                    ping_replied.clear()
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    self.wfile.write(ping)
                    self.wfile.flush()
                    if not ping_replied.wait(3):
                        self.close_connection = True; return
                    try:
                        self.wfile.write(final_event)
                        self.wfile.flush()
                        time.sleep(3)
                    except (BrokenPipeError, ConnectionResetError): pass
                else:
                    self.send(200, b': keepalive\n\n' + final_event,
                              content_type='text/event-stream')
            elif method == 'tools/call' and current['mode'] == 'json_trailing_garbage':
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(response)
                self.wfile.flush()
                time.sleep(.1)
                try: self.wfile.write(b'not-json')
                except (BrokenPipeError, ConnectionResetError): pass
            else: self.send(200, response, session if method == 'initialize' else None)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    with open(os.path.join(root, 'port'), 'w') as destination:
        destination.write(str(server.server_port))
    server.serve_forever(poll_interval=.02)
    """#
}
