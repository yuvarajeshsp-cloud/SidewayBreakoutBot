import Foundation
import Combine
import AppKit

final class BridgeModel: ObservableObject {
    @Published var secret: String = "changeme"
    @Published var port: String = "5000"
    @Published var pendingDir: String = ""
    @Published var status: String = "Starting..."
    @Published var statusOK: Bool = true
    @Published var records: [SignalRecord] = []

    private let server = BridgeServer()
    private let configURL: URL
    private let csvURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SidewayBreakoutBotBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("config.json")
        csvURL = dir.appendingPathComponent("signal_log.csv")

        loadConfig()
        if pendingDir.isEmpty {
            pendingDir = BridgeModel.defaultPendingDir()
        }
        ensureCSVHeader()
        startServer()
    }

    /// MT5 for Mac runs the real Windows terminal under Wine, so its "Common
    /// Files" folder lives inside that Wine bottle, not a normal Mac path.
    /// This is a best-guess default for MetaQuotes' own official Mac
    /// installer -- if your broker uses a different wrapper, open MT5 ->
    /// File -> Open Data Folder, then look for a sibling "Common" folder and
    /// paste its "pending" subfolder path into the field below instead.
    static func defaultPendingDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/MetaTrader 5/drive_c/users/\(NSUserName())/AppData/Roaming/MetaQuotes/Terminal/Common/Files/SidewayBreakoutBot/pending"
    }

    func startServer() {
        server.getSecret = { [weak self] in self?.secret ?? "changeme" }
        server.getPendingDir = { [weak self] in self?.pendingDir ?? "" }
        server.onEvent = { [weak self] record in
            self?.addRecord(record)
        }
        server.onStatus = { [weak self] message, ok in
            DispatchQueue.main.async {
                self?.status = ok ? "\(message)  |  pending: \(self?.pendingDir ?? "")" : message
                self?.statusOK = ok
            }
        }
        do {
            try server.start(port: UInt16(port) ?? 5000)
        } catch {
            status = "Failed to start: \(error)"
            statusOK = false
        }
        saveConfig()
    }

    func restartServer() {
        server.stop()
        startServer()
    }

    func applySecret() {
        // The server reads `secret` live via the getSecret closure above, so
        // this takes effect on the very next request -- no restart needed.
        saveConfig()
    }

    private func addRecord(_ record: SignalRecord) {
        records.insert(record, at: 0)
        if records.count > 500 {
            records.removeLast(records.count - 500)
        }
        appendCSV(record)
    }

    func clearTable() {
        records.removeAll()
    }

    // MARK: - Config persistence

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        secret = obj["secret"] as? String ?? secret
        if let p = obj["port"] as? Int { port = String(p) }
        pendingDir = obj["pending_dir"] as? String ?? ""
    }

    func saveConfig() {
        let obj: [String: Any] = ["secret": secret, "port": Int(port) ?? 5000, "pending_dir": pendingDir]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? data.write(to: configURL)
        }
    }

    // MARK: - CSV audit log

    private func ensureCSVHeader() {
        if !FileManager.default.fileExists(atPath: csvURL.path) {
            let header = "time,action,group_id,leg,symbol,dir,entry,sl,tp,status\n"
            try? header.write(to: csvURL, atomically: true, encoding: .utf8)
        }
    }

    private func appendCSV(_ r: SignalRecord) {
        let line = [r.time, r.action, r.groupId, r.leg, r.symbol, r.dir, r.entry, r.sl, r.tp, r.status]
            .map(csvEscape)
            .joined(separator: ",") + "\n"
        guard let lineData = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: csvURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(lineData)
        }
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    // MARK: - UI actions

    func sendTestSignal() {
        let payload: [String: Any] = [
            "v": 1, "action": "OPEN", "secret": secret,
            "group_id": "MANUAL_TEST_\(Int(Date().timeIntervalSince1970))",
            "leg": 1, "legs_total": 1, "symbol": "TESTSYMBOL", "dir": "BUY",
            "entry": 1.0, "sl": 0.99, "tp": 1.02,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "http://127.0.0.1:\(port)/webhook") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }

    func openPendingFolder() {
        try? FileManager.default.createDirectory(atPath: pendingDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: pendingDir))
    }

    func openLogFile() {
        ensureCSVHeader()
        NSWorkspace.shared.open(csvURL)
    }
}
