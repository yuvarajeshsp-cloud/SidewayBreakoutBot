import Foundation
import Network

enum BridgeServerError: Error {
    case invalidPort
}

/// A tiny hand-rolled HTTP/1.1 server (POST /webhook, GET / health check) built
/// directly on Network.framework -- no third-party dependencies, so opening
/// this package in Xcode never needs to fetch anything to build it.
///
/// Deliberately NOT built on Foundation's URLSession/GCD-mixed-with-a-GUI-
/// framework pattern that caused the Python/Tkinter version's threading
/// issue: NWListener's callback queue and SwiftUI's main queue are properly
/// separate here, with UI updates explicitly dispatched to the main queue.
final class BridgeServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "SidewayBreakoutBot.bridge.server")

    var onEvent: ((SignalRecord) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var getSecret: () -> String = { "changeme" }
    var getPendingDir: () -> String = { "" }

    func start(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw BridgeServerError.invalidPort
        }
        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStatus?("Running on port \(port)", true)
            case .failed(let error):
                self?.onStatus?("Failed to start on port \(port): \(error)", false)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let data = data, !data.isEmpty {
                buf.append(data)
            }

            if let headerRange = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: buf.startIndex..<headerRange.lowerBound)
                let headerStr = String(data: headerData, encoding: .utf8) ?? ""
                let lines = headerStr.components(separatedBy: "\r\n")
                let requestLine = lines.first ?? ""
                var contentLength = 0
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, parts[0].lowercased() == "content-length" {
                        contentLength = Int(parts[1]) ?? 0
                    }
                }
                let bodySoFar = buf.subdata(in: headerRange.upperBound..<buf.endIndex)
                if bodySoFar.count >= contentLength {
                    self.process(requestLine: requestLine, body: Data(bodySoFar.prefix(contentLength)), connection: connection)
                    return
                } else if isComplete || error != nil {
                    self.process(requestLine: requestLine, body: bodySoFar, connection: connection)
                    return
                }
            } else if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buf)
        }
    }

    // MARK: - Request handling

    private func process(requestLine: String, body: Data, connection: NWConnection) {
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""

        if method == "GET", path == "/" {
            respond(connection, status: "200 OK", json: ["status": "ok", "pending_dir": getPendingDir()])
            return
        }
        guard method == "POST", path == "/webhook" else {
            respond(connection, status: "404 Not Found", json: ["status": "not found"])
            return
        }

        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            // This indicator also fires plain-text alerts (breakout detected, TP hit
            // notifications, etc.) through the same "any alert() call" webhook -- those
            // aren't meant for MT5, so just log and ignore rather than error.
            emit(obj: nil, status: "ignored (not JSON)")
            respond(connection, status: "200 OK", json: ["status": "ignored", "reason": "not JSON"])
            return
        }

        guard (obj["secret"] as? String) == getSecret() else {
            emit(obj: obj, status: "rejected (bad secret)")
            respond(connection, status: "401 Unauthorized", json: ["status": "rejected", "reason": "bad secret"])
            return
        }

        let action = obj["action"] as? String ?? ""
        guard ["OPEN", "MODIFY_SL", "CLOSE"].contains(action) else {
            emit(obj: obj, status: "ignored (unknown action)")
            respond(connection, status: "200 OK", json: ["status": "ignored", "reason": "unknown action"])
            return
        }

        guard let groupId = obj["group_id"] as? String, !groupId.isEmpty else {
            emit(obj: obj, status: "ignored (no group_id)")
            respond(connection, status: "200 OK", json: ["status": "ignored", "reason": "missing group_id"])
            return
        }

        do {
            try writeSignalFile(obj)
            emit(obj: obj, status: "queued")
            respond(connection, status: "200 OK", json: ["status": "queued"])
        } catch {
            respond(connection, status: "500 Internal Server Error", json: ["status": "error", "reason": "\(error)"])
        }
    }

    private func emit(obj: [String: Any]?, status: String) {
        let p = obj ?? [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let record = SignalRecord(
            time: formatter.string(from: Date()),
            action: p["action"] as? String ?? "",
            groupId: p["group_id"] as? String ?? "",
            leg: stringify(p["leg"]),
            symbol: p["symbol"] as? String ?? "",
            dir: p["dir"] as? String ?? "",
            entry: stringify(p["entry"]),
            sl: stringify(p["sl"]),
            tp: stringify(p["tp"]),
            status: status
        )
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(record)
        }
    }

    private func stringify(_ v: Any?) -> String {
        if let n = v as? NSNumber { return n.stringValue }
        if let s = v as? String { return s }
        return ""
    }

    private func writeSignalFile(_ payload: [String: Any]) throws {
        let dir = getPendingDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        let fname = "\(Int(Date().timeIntervalSince1970 * 1000))_\(String(UUID().uuidString.prefix(8))).json"
        let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
        let finalURL = dirURL.appendingPathComponent(fname)
        let tmpURL = dirURL.appendingPathComponent(".tmp_\(UUID().uuidString)")
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: tmpURL)
        try FileManager.default.moveItem(at: tmpURL, to: finalURL) // atomic rename on the same volume
    }

    private func respond(_ connection: NWConnection, status: String, json: [String: Any]) {
        let bodyData = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var full = Data(head.utf8)
        full.append(bodyData)
        connection.send(content: full, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
}
