// OpenAI-compatible /v1/embeddings inside the daemon (goal A from the
// «Foundation Apple — summary» note): the same engine that serves internal
// search — no second python server.
//
// Contract:
// - POST /v1/embeddings {model, input: string|[string]} →
//   {"object":"list","data":[{"object":"embedding","index":i,"embedding":[...]},...],
//    "model":<name echo>, "model_version":<backend name>, "usage":{...}};
// - GET /v1/models -> a list with the active backend name and its dimension;
// - the model name in the request is accepted as-is and echoed back: the
//   transport must not fail because a client config carries another name.
//
// Since 1.1.1 the default backend is EmbeddingGemma-2 CoreML (768-dim vectors),
// the outward name is "embeddinggemma-2"; BMEM_EMBED_BACKEND=qwen rolls back to
// Qwen3-CoreAI (1024-dim), name "qwen3-embedding-0.6b". External consumers
// beware: the vector space and dimension changed — rebuild your own index
// (old qwen vectors are incompatible with the new ones).
//
// ONE lane goes outward — Embedder.embedRaw without prompt prefixes
// (internal search distinguishes query/document, an external store builds its
// index and queries one way — the same way the python encode did). Vectors
// are L2-normalized by the engine itself.
//
// Style as in Socket.swift: blocking I/O on GCD queues + a dedicated accept
// thread; the Swift Concurrency cooperative pool is not blocked. Limits:
// request body <= 4 MB, socket timeouts 15 s, Connection: close.
import Foundation
import BMemCore

// Name/dimension follow the active backend (the same BMEM_EMBED_BACKEND
// semantics as Embedder.prefersGemma — default gemma).
private let useGemmaBackend = (ProcessInfo.processInfo.environment["BMEM_EMBED_BACKEND"] ?? "").lowercased() != "qwen"
let embedModelName = useGemmaBackend ? "embeddinggemma-2" : "qwen3-embedding-0.6b"
let embedModelDim = useGemmaBackend ? 768 : 1024

private let embedHttpQueue = DispatchQueue(label: "bmem.embed.http", attributes: .concurrent)

func startEmbedServer(port: UInt16, engine: Engine, state: ControlState) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { close(fd); return false }
    guard listen(fd, 64) == 0 else { close(fd); return false }
    Thread.detachNewThread {
        while true {
            var peer = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &peer) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &len)
                }
            }
            if cfd < 0 { usleep(200_000); continue }
            embedHttpQueue.async { handleEmbedRequest(fd: cfd, engine: engine, state: state) }
        }
    }
    return true
}

// MARK: - HTTP/1.1, exactly as much as a local endpoint needs

private let crlfPair = Data([13, 10, 13, 10])

private func readRequest(_ fd: Int32) -> (method: String, path: String, body: Data)? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 16384)
    var headerEnd: Int? = nil
    var contentLength = 0
    while true {
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 { break }
        data.append(contentsOf: buf[0..<n])
        if let he = headerEnd {
            if data.count - he >= contentLength { break }
        } else if let r = data.range(of: crlfPair) {
            guard let header = String(data: data.subdata(in: 0..<r.lowerBound), encoding: .utf8) else { return nil }
            for line in header.components(separatedBy: "\r\n").dropFirst() {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    contentLength = Int(lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            headerEnd = r.upperBound
            if data.count - r.upperBound >= contentLength { break }
        }
        if data.count > 4_194_304 { return nil }
    }
    guard let he = headerEnd else { return nil }
    guard let header = String(data: data.subdata(in: 0..<he - 4), encoding: .utf8) else { return nil }
    let parts = header.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
    guard parts.count >= 2 else { return nil }
    let body = data.count > he ? data.subdata(in: he..<data.endIndex) : Data()
    return (String(parts[0]), String(parts[1]), body)
}

private func jsonData(_ obj: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
}

private func respond(_ fd: Int32, status: Int, json: Data) {
    let statusText: String
    switch status {
    case 200: statusText = "OK"
    case 400: statusText = "Bad Request"
    case 404: statusText = "Not Found"
    case 501: statusText = "Not Implemented"
    default: statusText = "Internal Server Error"
    }
    var out = Data("HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
    out.append(json)
    out.withUnsafeBytes { raw in
        var sent = 0
        let base = raw.baseAddress!
        while sent < out.count {
            let n = send(fd, base.advanced(by: sent), out.count - sent, 0)
            if n <= 0 { break }
            sent += n
        }
    }
}

private func handleEmbedRequest(fd: Int32, engine: Engine, state: ControlState) {
    // Daemon lifecycle fix: the HTTP transport joins the drain during graceful shutdown
    // (gracefulExit waits for the counter to hit zero before exit).
    inflight.begin()
    defer { inflight.end() }
    var tv = timeval(tv_sec: 15, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    defer { close(fd) }
    guard let req = readRequest(fd) else { return }
    // UI-1 control API: routes may arrive with a query string (/v1/search?q=...),
    // so we match on the path before '?' and delegate into ControlAPI.
    let cleanPath = req.path.components(separatedBy: "?").first ?? req.path
    if controlRoutes.contains(cleanPath) {
        // Semaphore pattern (like /v1/embeddings below): block the GCD thread,
        // do not hold the cooperative pool.
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: ControlResponse?
        Task {
            out = await handleControlRequest(method: req.method, path: cleanPath,
                                             query: parseQueryString(req.path),
                                             body: req.body, engine: engine, state: state)
            sem.signal()
        }
        sem.wait()
        let r = out ?? ControlResponse(status: 500, json: ["error": "control handler lost"])
        respond(fd, status: r.status, json: jsonData(r.json))
        return
    }
    switch (req.method, req.path) {
    case ("GET", "/v1/models"), ("GET", "/models"):
        respond(fd, status: 200, json: jsonData([
            "object": "list",
            "data": [["id": embedModelName, "object": "model", "owned_by": "bmem", "dimension": embedModelDim]],
        ]))
    case ("POST", "/v1/embeddings"), ("POST", "/embeddings"):
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let rawInput = obj["input"] else {
            respond(fd, status: 400, json: jsonData(["error": ["message": "missing input", "type": "invalid_request_error"]]))
            return
        }
        var inputs: [String] = []
        if let s = rawInput as? String { inputs = [s] }
        else if let arr = rawInput as? [Any] { inputs = arr.compactMap { $0 as? String } }
        inputs = inputs.filter { !$0.isEmpty }
        let model = (obj["model"] as? String) ?? embedModelName
        if inputs.isEmpty {
            respond(fd, status: 200, json: jsonData(["object": "list", "data": [], "model": model, "model_version": embedModelName]))
            return
        }
        // Semaphore pattern: block the GCD thread, not the cooperative pool (see Socket.swift).
        let sem = DispatchSemaphore(value: 0)
        // nonisolated(unsafe): access to the variables is strictly Task->signal->wait,
        // the semaphore provides happens-before; Swift 6 would reject a mutable capture otherwise.
        nonisolated(unsafe) var vectors: [[Float]] = []
        nonisolated(unsafe) var failure: String? = nil
        Task {
            do {
                for text in inputs {
                    let v = try await engine.embedRaw(text)
                    vectors.append(v)
                }
            } catch {
                failure = "\(error)"
            }
            sem.signal()
        }
        sem.wait()
        if let failure {
            respond(fd, status: 500, json: jsonData(["error": ["message": failure, "type": "server_error"]]))
        } else {
            let data = vectors.enumerated().map { (i, v) in
                ["object": "embedding", "index": i, "embedding": v.map { Double($0) }]
            }
            respond(fd, status: 200, json: jsonData([
                "object": "list", "data": data, "model": model, "model_version": embedModelName,
                "usage": ["prompt_tokens": 0, "total_tokens": 0],
            ]))
        }
    default:
        respond(fd, status: 404, json: jsonData(["error": ["message": "not found: \(req.path)", "type": "invalid_request_error"]]))
    }
}
