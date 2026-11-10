import Foundation
import Network
import Observation

@MainActor @Observable
final class PoachChromeBridge {
    static let shared = PoachChromeBridge()
    private static let preference = "chromePairingCode"
    private var listener: NWListener?
    private(set) var errorMessage: String?
    private var incoming: PoachBrowserEvidence?
    @ObservationIgnored private var incomingExpiry: Task<Void, Never>?
    private var latest: PoachBrowserEvidence?
    private(set) var revision = 0
    private var receivedAt: Date?
    private var code = UserDefaults.standard.string(forKey: preference)

    func pairingCode() -> String {
        let value = code ?? UUID().uuidString
        code = value
        UserDefaults.standard.set(value, forKey: Self.preference)
        startIfPaired()
        return value
    }

    func startIfPaired() {
        guard code != nil, listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 47831)
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed = state else { return }
                Task { @MainActor in
                    self?.listener?.cancel()
                    self?.listener = nil
                    self?.errorMessage = "Poach couldn’t start the local Chrome connection."
                }
            }
            self.listener = listener
            errorMessage = nil
            listener.start(queue: .main)
        } catch {
            errorMessage = "Poach couldn’t start the local Chrome connection."
        }
    }

    func evidence(for recording: ClosedRange<Int>) -> PoachBrowserEvidence? {
        guard let receivedAt, Date().timeIntervalSince(receivedAt) < 180 else { return nil }
        return latest?.aligned(to: recording)
    }

    func isReceiving(for recording: ClosedRange<Int>) -> Bool {
        return incoming?.aligned(to: recording) != nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { connection.cancel() }
        }
        receive(connection, buffer: Data(), timeout: timeout)
    }

    private func receive(_ connection: NWConnection, buffer: Data, timeout: Task<Void, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, error == nil else { timeout.cancel(); connection.cancel(); return }
                var request = buffer
                if let data { request.append(data) }
                if let status = self.handle(request) {
                    timeout.cancel()
                    let response = Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                } else if complete {
                    timeout.cancel()
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: request, timeout: timeout)
                }
            }
        }
    }

    private func handle(_ request: Data) -> String? {
        let separator = Data([13, 10, 13, 10])
        guard request.count <= PoachBrowserEvidence.byteLimit + 4096 else { return "413 Payload Too Large" }
        guard let boundary = request.range(of: separator) else {
            return request.count < 4096 ? nil : "400 Bad Request"
        }
        guard boundary.lowerBound < 4096,
              let header = String(data: request[..<boundary.lowerBound], encoding: .utf8) else {
            return "400 Bad Request"
        }
        let lines = header.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let delimiter = line.firstIndex(of: ":") else { return "400 Bad Request" }
            let name = line[..<delimiter].lowercased()
            guard headers[name] == nil else { return "400 Bad Request" }
            headers[name] = line[line.index(after: delimiter)...].trimmingCharacters(in: .whitespaces)
        }
        guard let code, headers["authorization"] == "Bearer \(code)" else { return "401 Unauthorized" }
        if lines.first == "GET /v1/pair HTTP/1.1" { return "204 No Content" }
        guard lines.first == "POST /v1/capture HTTP/1.1",
              headers["content-type"] == "application/json",
              let length = headers["content-length"].flatMap(Int.init),
              (1...PoachBrowserEvidence.byteLimit).contains(length) else { return "400 Bad Request" }
        let body = request[boundary.upperBound...]
        guard body.count >= length else { return nil }
        guard body.count == length, let evidence = try? PoachBrowserEvidence.decode(Data(body)) else {
            return "422 Unprocessable Content"
        }
        incomingExpiry?.cancel()
        if headers["x-poach-final"] == "1" {
            latest = evidence
            receivedAt = Date()
            incoming = nil
            incomingExpiry = nil
        } else {
            incoming = evidence
            incomingExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                self?.incoming = nil
                self?.incomingExpiry = nil
                self?.revision += 1
            }
        }
        revision += 1
        return "204 No Content"
    }
}
