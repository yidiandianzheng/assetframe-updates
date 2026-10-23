import Foundation
@preconcurrency import Network
import Darwin

/// One bounded newline-delimited request per connection, on loopback only.
/// All state and command dispatch belong to the main actor; no second DB writer.
@MainActor
final class LocalCLITransport {
    static let maximumRequestBytes = 65_536
    private let directory: URL
    private let handler: @MainActor (CLIRequest) async -> CLIResponse
    private let token = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var lease: Int32 = -1
    private var connections: [UUID: NWConnection] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private(set) var endpoint: CLIEndpoint?
    var onStateChange: (@MainActor (String?) -> Void)?
    var endpointURL: URL { directory.appendingPathComponent("endpoint.json") }

    init(directory: URL, handler: @escaping @MainActor (CLIRequest) async -> CLIResponse) {
        self.directory = directory; self.handler = handler
    }

    func start() throws {
        guard listener == nil else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR else { throw CLIError(code: "unsafe_endpoint", message: "CLI目录必须是当前用户拥有的真实目录") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fd = Darwin.open(directory.appendingPathComponent("server.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CLIError(code: "endpoint_lock", message: "无法打开CLI运行锁") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw CLIError(code: "already_running", message: "此数据根已有CLI服务运行")
        }
        lease = fd
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let next = try NWListener(using: parameters, on: .any)
            listener = next
            next.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.listener === next else { return }
                    switch state {
                    case .ready:
                        do {
                            guard let port = next.port else { throw CLIError(code: "missing_port", message: "CLI端口尚未分配") }
                            let endpoint = CLIEndpoint(port: port.rawValue, pid: getpid(), token: self.token)
                            try JSONEncoder().encode(endpoint).write(to: self.endpointURL, options: .atomic)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.endpointURL.path)
                            self.endpoint = endpoint; self.onStateChange?(nil)
                        } catch { self.stop(); self.onStateChange?(error.localizedDescription) }
                    case .failed(let error): self.stop(); self.onStateChange?(error.localizedDescription)
                    default: break
                    }
                }
            }
            next.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            next.start(queue: .main)
        } catch { stop(); throw error }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for task in timeouts.values { task.cancel() }; timeouts.removeAll()
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        if let data = try? Data(contentsOf: endpointURL),
           let saved = try? JSONDecoder().decode(CLIEndpoint.self, from: data), saved.token == token {
            try? FileManager.default.removeItem(at: endpointURL)
        }
        endpoint = nil
        if lease >= 0 { flock(lease, LOCK_UN); Darwin.close(lease); lease = -1 }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        timeouts[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.finish(id)
        }
        receive(id, accumulated: Data())
    }

    private func receive(_ id: UUID, accumulated: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connections[id] != nil else { return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                if buffer.count > Self.maximumRequestBytes {
                    self.send(.failure("request_too_large", "请求超过64KB"), to: id); return
                }
                if let newline = buffer.firstIndex(of: 10) {
                    // Pipelining/trailing payload is never executed.
                    guard buffer[(newline + 1)...].allSatisfy({ $0 == 10 || $0 == 13 || $0 == 32 }) else {
                        self.send(.failure("invalid_request", "每次连接只支持一个请求"), to: id); return
                    }
                    self.dispatch(Data(buffer[..<newline]), id: id)
                } else if complete || error != nil {
                    self.send(.failure("invalid_request", "请求必须以换行结束"), to: id)
                } else { self.receive(id, accumulated: buffer) }
            }
        }
    }

    private func dispatch(_ data: Data, id: UUID) {
        guard let request = try? JSONDecoder().decode(CLIRequest.self, from: data) else {
            send(.failure("invalid_request", "请求必须是有效JSON协议对象"), to: id); return
        }
        guard request.token == token else { send(.failure(request.id, "unauthorized", "CLI连接凭据无效"), to: id); return }
        guard request.protocolVersion == 1 else { send(.failure(request.id, "unsupported_protocol", "仅支持协议版本1"), to: id); return }
        guard !request.id.isEmpty, request.id.utf8.count <= 128 else {
            send(.failure("invalid_request", "请求ID无效"), to: id); return
        }
        timeouts[id]?.cancel()
        timeouts[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.finish(id)
        }
        Task { [weak self] in
            guard let self else { return }
            let response = await handler(request)
            send(response, to: id)
        }
    }

    private func send(_ response: CLIResponse, to id: UUID) {
        guard let connection = connections[id], var data = try? JSONEncoder().encode(response) else { finish(id); return }
        data.append(10)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish(id) }
        })
    }
    private func finish(_ id: UUID) {
        timeouts.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}
