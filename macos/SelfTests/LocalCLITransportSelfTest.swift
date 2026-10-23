import Foundation
import Darwin

private enum TestFailure: Error { case failed(String) }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw TestFailure.failed(message) }
}

private func exchange(port: UInt16, data: Data, fragmented: Bool = false) throws -> CLIResponse {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TestFailure.failed("socket") }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 8, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { throw TestFailure.failed("connect") }
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let length = fragmented ? min(7, buffer.count - offset) : buffer.count - offset
            let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), length, 0)
            guard count > 0 else { throw TestFailure.failed("send") }
            offset += count
        }
    }
    var received = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while !received.contains(10) {
        let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
        guard count > 0 else { throw TestFailure.failed("recv") }
        received.append(contentsOf: buffer.prefix(count))
    }
    return try JSONDecoder().decode(CLIResponse.self, from: received.prefix { $0 != 10 })
}

private func wire(token: String, version: Int = 1) throws -> Data {
            var data = try JSONEncoder().encode(CLIRequest(protocolVersion: version, id: "test", token: token, command: "status", arguments: [:]))
            data.append(10); return data
        }

@main
struct LocalCLITransportSelfTest {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assetframe-cli-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var executions = 0
        let server = LocalCLITransport(directory: root) { request in
            executions += 1
            return CLIResponse(id: request.id, ok: true, result: .string(request.command))
        }
        try server.start()
        defer { server.stop() }
        for _ in 0..<100 where server.endpoint == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard let endpoint = server.endpoint else { throw TestFailure.failed("ready") }
        let attrs = try FileManager.default.attributesOfItem(atPath: server.endpointURL.path)
        try require((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private endpoint")
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: root.path)
        try require((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "private directory")
        try require(endpoint.host == "127.0.0.1", "loopback only")
        let other = LocalCLITransport(directory: root) { _ in .failure("unexpected", "unexpected") }
        do { try other.start(); throw TestFailure.failed("second server acquired lock") }
        catch let error as CLIError { try require(error.code == "already_running", "lock isolation") }
        let denied = try await Task.detached { try exchange(port: endpoint.port, data: wire(token: "wrong")) }.value
        try require(denied.error?.code == "unauthorized" && executions == 0, "no unauthenticated execution")
        let version = try await Task.detached { try exchange(port: endpoint.port, data: wire(token: endpoint.token, version: 2)) }.value
        try require(version.error?.code == "unsupported_protocol" && executions == 0, "version gate")
        let malformed = try await Task.detached { try exchange(port: endpoint.port, data: Data("{broken}\n".utf8)) }.value
        try require(malformed.error?.code == "invalid_request" && executions == 0, "malformed JSON")
        let oversized = try await Task.detached { try exchange(port: endpoint.port, data: Data(repeating: 65, count: 65537) + Data([10])) }.value
        try require(oversized.error?.code == "request_too_large" && executions == 0, "bounded input")
        let good = try await Task.detached { try exchange(port: endpoint.port, data: wire(token: endpoint.token), fragmented: true) }.value
        try require(good.ok && good.id == "test" && executions == 1, "fragmented request")
        let pipelined = try await Task.detached { try exchange(port: endpoint.port, data: wire(token: endpoint.token) + wire(token: endpoint.token)) }.value
        try require(pipelined.error?.code == "invalid_request" && executions == 1, "no pipelining")
        // Incomplete requests must release a connection slot after the deadline.
        let incomplete = await Task.detached { () -> Bool in
            do { _ = try exchange(port: endpoint.port, data: Data("{".utf8)); return false }
            catch { return true }
        }.value
        try require(incomplete, "incomplete request timeout")
        let recovered = try await Task.detached { try exchange(port: endpoint.port, data: wire(token: endpoint.token)) }.value
        try require(recovered.ok && executions == 2, "accept after timeout")
        server.stop()
        try require(!FileManager.default.fileExists(atPath: server.endpointURL.path), "remove owned discovery endpoint")
        try other.start()
        for _ in 0..<100 where other.endpoint == nil { try await Task.sleep(for: .milliseconds(20)) }
        try require(other.endpoint != nil, "restart after lease release")
        other.stop()
        print("LocalCLITransportSelfTest passed: loopback, private discovery, lock, auth, protocol, malformed/oversized/fragmented input, pipeline rejection, timeout recovery and endpoint cleanup")
    }
}
