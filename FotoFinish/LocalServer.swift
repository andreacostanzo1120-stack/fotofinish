import Foundation
import Network
import Security

// MARK: - Richiesta / risposta HTTP minimali

struct WebRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    var json: [String: Any] {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
    }

    /// Estrae una richiesta completa dal buffer (e la rimuove). Nil se i dati non sono ancora completi.
    static func parse(_ buf: inout Data) -> WebRequest? {
        guard let sep = buf.range(of: Data([13, 10, 13, 10])) else { return nil }
        let headData = buf.subdata(in: 0..<sep.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else {
            buf.removeAll()
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else {
            buf.removeAll()
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard buf.count - bodyStart >= length else { return nil }
        let body = length > 0 ? buf.subdata(in: bodyStart..<(bodyStart + length)) : Data()
        buf.removeSubrange(0..<(bodyStart + length))

        let target = String(parts[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return WebRequest(method: String(parts[0]).uppercased(),
                          path: comps?.path ?? target,
                          query: query,
                          headers: headers,
                          body: body)
    }
}

struct WebResponse {
    var status = 200
    var contentType = "application/json; charset=utf-8"
    var body = Data()

    static func json(_ s: String) -> WebResponse {
        WebResponse(status: 200, contentType: "application/json; charset=utf-8", body: Data(s.utf8))
    }

    static func html(_ d: Data) -> WebResponse {
        WebResponse(status: 200, contentType: "text/html; charset=utf-8", body: d)
    }

    static func text(_ s: String, status: Int) -> WebResponse {
        WebResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(s.utf8))
    }

    func serialized() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

// MARK: - Server

enum ServerError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

final class LocalServer {
    typealias Handler = (WebRequest) -> WebResponse

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fotofinish.server", qos: .userInteractive)
    private let handler: Handler
    let port: UInt16
    var onState: ((String) -> Void)?

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    static func loadIdentity() throws -> SecIdentity {
        guard let url = Bundle.main.url(forResource: "server", withExtension: "p12"),
              let data = try? Data(contentsOf: url) else {
            throw ServerError.message("File server.p12 mancante nell’app")
        }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: "fotofinish"] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let ref = first[kSecImportItemIdentity as String] else {
            throw ServerError.message("Certificato non valido (codice \(status))")
        }
        return ref as! SecIdentity
    }

    func start() throws {
        let identity = try LocalServer.loadIdentity()
        guard let secIdentity = sec_identity_create(identity) else {
            throw ServerError.message("Impossibile usare il certificato")
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.message("Porta non valida")
        }
        let l = try NWListener(using: params, on: nwPort)
        l.service = NWListener.Service(name: "FotoFinish", type: "_fotofinish._tcp")
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onState?("Server attivo sulla porta \(self?.port ?? 0)")
            case .failed(let error):
                self?.onState?("Server fermo: \(error.localizedDescription)")
            case .waiting(let error):
                self?.onState?("Server in attesa: \(error.localizedDescription)")
            default:
                break
            }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                conn.cancel()
                return
            }
            var buf = buffer
            if let d = data {
                buf.append(d)
            }
            while let req = WebRequest.parse(&buf) {
                let resp = self.handler(req)
                conn.send(content: resp.serialized(), completion: .contentProcessed({ _ in }))
            }
            if error != nil || isComplete || buf.count > 8_000_000 {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }
}

// MARK: - Registro dei telefoni collegati (thread-safe)

final class Hub {
    private let lock = NSLock()
    private var armed = false
    private var run = 0
    private var gates: [Int: GateInfo] = [:]
    private var nextId = 1

    func setArmed(_ a: Bool, run r: Int) {
        lock.lock()
        armed = a
        run = r
        lock.unlock()
    }

    func state() -> (armed: Bool, run: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (armed, run)
    }

    func register(name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextId
        nextId += 1
        gates[id] = GateInfo(id: id, name: name, lastSeen: HostClock.now(), rtt: 0)
        return id
    }

    func isKnown(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gates[id] != nil
    }

    func touch(_ id: Int) {
        lock.lock()
        if var g = gates[id] {
            g.lastSeen = HostClock.now()
            gates[id] = g
        }
        lock.unlock()
    }

    func setRTT(_ id: Int, _ rtt: Double) {
        lock.lock()
        if var g = gates[id] {
            g.rtt = rtt
            gates[id] = g
        }
        lock.unlock()
    }

    func active(now: Double) -> [GateInfo] {
        lock.lock()
        defer { lock.unlock() }
        gates = gates.filter { now - $0.value.lastSeen < 120 }
        return gates.values.filter { now - $0.lastSeen < 4 }.sorted { $0.id < $1.id }
    }
}

// MARK: - Indirizzi di rete

enum NetInfo {
    static func ipv4() -> [(name: String, ip: String)] {
        var result: [(name: String, ip: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let r = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if r == 0 {
                    result.append((name: name, ip: String(cString: host)))
                }
            }
            ptr = ifa.ifa_next
        }
        return result
    }

    static func urls(port: Int) -> [String] {
        let all = ipv4().filter { !$0.ip.hasPrefix("169.254") && $0.ip != "127.0.0.1" }
        var ips: [String] = []
        for item in all where item.name.hasPrefix("bridge") { ips.append(item.ip) }
        for item in all where item.name.hasPrefix("en") { ips.append(item.ip) }
        return ips.map { "https://\($0):\(port)" }
    }
}
