// The unix-socket transport of the `bmem mcp` (proxy) <-> `bmem daemon` pair.
// Protocol: one JSON line per request {"tool","args","project","limit"},
// the reply is one line {"text","isError"}.
// Blocking I/O on the global GCD queue and a dedicated accept thread — the
// Swift Concurrency cooperative pool is not blocked (see the dispatchMain grab-bag).
import Foundation
import CoreFoundation
import MCP

// MARK: - Value <-> JSON

func toValue(_ any: Any) -> Value {
    if any is NSNull { return .null }
    if let n = any as? NSNumber {
        let cf = n as CFNumber
        if CFGetTypeID(cf) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
        if CFNumberIsFloatType(cf) { return .double(n.doubleValue) }
        return .int(n.intValue)
    }
    if let s = any as? String { return .string(s) }
    if let a = any as? [Any] { return .array(a.map(toValue)) }
    if let o = any as? [String: Any] { return .object(o.mapValues(toValue)) }
    return .string(String(describing: any))
}

func fromValue(_ v: Value) -> Any {
    switch v {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .data(_, let d): return d.base64EncodedString()
    case .array(let a): return a.map(fromValue)
    case .object(let o): return o.mapValues(fromValue)
    }
}

// MARK: - Socket helpers

private func makeUnixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        // _ = — silences the warning 'Result of call to withUnsafeBytes is unused'
        // (memcpy returns UnsafeMutableRawPointer).
        bytes.withUnsafeBytes { src in
            _ = memcpy(raw.baseAddress!, src.baseAddress!, bytes.count)
        }
        raw[bytes.count] = 0
    }
    return addr
}

func socketAlive(_ path: String) -> Bool {
    guard let fd = connectUnix(path, timeoutMs: 500) else { return false }
    close(fd)
    return true
}

func connectUnix(_ path: String, timeoutMs: Int) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    guard var addr = makeUnixAddress(path) else { close(fd); return nil }
    let r = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if r != 0 { close(fd); return nil }
    return fd
}

// MARK: - Client (bmem mcp in proxy mode)

func daemonCall(_ path: String, payload: [String: Any], timeoutMs: Int = 60_000) -> (String, Bool)? {
    guard let fd = connectUnix(path, timeoutMs: timeoutMs) else { return nil }
    defer { close(fd) }
    guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    data.append(0x0A)
    let wrote: Bool = data.withUnsafeBytes { raw in
        guard var ptr = raw.baseAddress else { return false }
        var left = raw.count
        while left > 0 {
            let n = write(fd, ptr, left)
            if n <= 0 { return false }
            ptr += n; left -= n
        }
        return true
    }
    guard wrote else { return nil }
    var buf = Data()
    let tmp = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 1)
    defer { tmp.deallocate() }
    while true {
        let n = read(fd, tmp, 65536)
        if n <= 0 { return nil }
        buf.append(contentsOf: UnsafeRawBufferPointer(start: tmp, count: n))
        if buf.last == 0x0A { break }
        if buf.count > 32_000_000 { return nil }
    }
    guard let obj = try? JSONSerialization.jsonObject(with: buf) as? [String: Any],
          let text = obj["text"] as? String else { return nil }
    return (text, obj["isError"] as? Bool ?? false)
}

// MARK: - Server (bmem daemon)

struct SocketRequest: Sendable {
    let tool: String
    let args: [String: Value]
    let project: String
    let limit: Int
}

final class ResponseBox: @unchecked Sendable {
    var value = "{\"error\":\"INTERNAL\",\"detail\":\"handler not run\"}"
}

/// Returns false if a daemon is already alive (flock taken) or bind failed.
func startSocketServer(path: String,
                       handler: @escaping @Sendable (SocketRequest) async -> String) -> Bool {
    // Daemon uniqueness: flock on the lock file. The second instance exits immediately
    // WITHOUT unlinking the first one's socket — the main race of auto-spawning two MCP sessions.
    let lockPath = path + ".lock"
    let lockFd = open(lockPath, O_RDWR | O_CREAT, 0o600)
    guard lockFd >= 0, flock(lockFd, LOCK_EX | LOCK_NB) == 0 else { return false }
    if socketAlive(path) { return false }
    unlink(path)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    guard var addr = makeUnixAddress(path) else { close(fd); return false }
    let bound = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(fd, 32) == 0 else { close(fd); return false }
    chmod(path, 0o600)

    let queue = DispatchQueue(label: "bmem.sockets", attributes: .concurrent)
    let acceptThread = Thread {
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                break
            }
            queue.async {
                defer { close(cfd) }
                var buf = Data()
                let tmp = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 1)
                defer { tmp.deallocate() }
                while true {
                    let n = read(cfd, tmp, 65536)
                    if n <= 0 { break }
                    buf.append(contentsOf: UnsafeRawBufferPointer(start: tmp, count: n))
                    while let nl = buf.firstIndex(of: 0x0A) {
                        let line = buf.subdata(in: buf.startIndex..<nl)
                        buf.removeSubrange(buf.startIndex...nl)
                        var resp = "{\"error\":\"BAD_JSON\"}"
                        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                           let tool = obj["tool"] as? String {
                            let argsDict = obj["args"] as? [String: Any] ?? [:]
                            let req = SocketRequest(
                                tool: tool,
                                args: argsDict.mapValues(toValue),
                                project: obj["project"] as? String ?? "hermes",
                                limit: obj["limit"] as? Int ?? 10)
                            let sem = DispatchSemaphore(value: 0)
                            let box = ResponseBox()
                            Task {
                                box.value = await handler(req)
                                sem.signal()
                            }
                            sem.wait()
                            resp = box.value
                        }
                        var outBytes = Array(resp.utf8)
                        outBytes.append(0x0A)
                        outBytes.withUnsafeBufferPointer { rb in
                            guard var ptr = rb.baseAddress else { return }
                            var left = rb.count
                            while left > 0 {
                                let w = write(cfd, ptr, left)
                                if w <= 0 { return }
                                ptr += w; left -= w
                            }
                        }
                    }
                }
            }
        }
    }
    acceptThread.name = "bmem.accept"
    acceptThread.start()
    return true
}
