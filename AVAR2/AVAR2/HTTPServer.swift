import Foundation
import Network

#if canImport(Darwin)
import Darwin
#endif

// MARK: - DateFormatter Extension
extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - Network Utilities
extension HTTPServer {
    /// Get the device's local IP address
    private func getLocalIPAddress() -> String {
        var address: String?
        
        // Get list of all interfaces on the local machine:
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "localhost" }
        guard let firstAddr = ifaddr else { return "localhost" }
        
        // For each interface ...
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            var addr = ptr.pointee.ifa_addr.pointee
            
            // Check for running IPv4, IPv6 interfaces. Skip the loopback interface.
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) || addr.sa_family == UInt8(AF_INET6) {
                    
                    // Convert interface address to a human readable string:
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if (getnameinfo(&addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST) == 0) {
                        address = String(cString: hostname)
                        
                        // Prefer IPv4 over IPv6, and non-loopback addresses
                        if addr.sa_family == UInt8(AF_INET) && address != "127.0.0.1" {
                            break
                        }
                    }
                }
            }
        }
        
        freeifaddrs(ifaddr)
        return address ?? "localhost"
    }
}

class HTTPServer: ObservableObject {
    @Published var isRunning = false
    @Published var serverURL = ""
    @Published var lastReceivedJSON = ""
    @Published var serverStatus = "Stopped"
    @Published var serverLogs: [String] = []
    
    private var listener: NWListener?
    private let port: UInt16 = 8081
    private let queue = DispatchQueue(label: "HTTPServer")
    private let maxLogs = 50 // Limit log entries to prevent memory issues
    
    var onJSONReceived: ((ScriptOutput) -> Void)?
    
    /// Add a log entry to both console and UI logs
    private func log(_ message: String) {
        print(message)
        DispatchQueue.main.async {
            let timestamp = DateFormatter.logFormatter.string(from: Date())
            let logEntry = "[\(timestamp)] \(message)"
            self.serverLogs.append(logEntry)
            
            // Limit log size
            if self.serverLogs.count > self.maxLogs {
                self.serverLogs.removeFirst(self.serverLogs.count - self.maxLogs)
            }
        }
    }
    
    func start() {
        guard !isRunning else { return }
        
        do {
            let tcpOptions = NWProtocolTCP.Options()
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.allowLocalEndpointReuse = true
            parameters.acceptLocalOnly = false // accept connections from other devices on the LAN
            parameters.includePeerToPeer = true // allow direct peer-to-peer transports if available
            
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        let deviceIP = self?.getLocalIPAddress() ?? "localhost"
                        self?.serverURL = "http://\(deviceIP):\(self?.port ?? 8081)/avar"
                        self?.serverStatus = "Running on \(deviceIP):\(self?.port ?? 8081)"
                        self?.log("🌐 HTTP Server started on \(deviceIP):\(self?.port ?? 8081)")
                    case .failed(let error):
                        self?.isRunning = false
                        self?.serverStatus = "Failed: \(error.localizedDescription)"
                        self?.log("❌ HTTP Server failed: \(error.localizedDescription)")
                    case .cancelled:
                        self?.isRunning = false
                        self?.serverURL = ""
                        self?.serverStatus = "Stopped"
                        self?.log("🛑 HTTP Server stopped")
                    default:
                        break
                    }
                }
            }
            
            listener?.start(queue: queue)
            
        } catch {
            DispatchQueue.main.async {
                self.serverStatus = "Error: \(error.localizedDescription)"
            }
            log("❌ Failed to start HTTP server: \(error.localizedDescription)")
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.serverURL = ""
            self.serverStatus = "Stopped"
        }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                self.receiveRequest(connection)
            } else if case .failed(let error) = state {
                self.log("❌ Connection failed: \(error.localizedDescription)")
                connection.cancel()
            }
        }
        
        connection.start(queue: queue)
    }
    
    private func receiveRequest(_ connection: NWConnection, accumulatedData: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                self.log("❌ Receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            var buffer = accumulatedData
            if let chunk = data, !chunk.isEmpty {
                buffer.append(chunk)
            }

            let maxRequestSize = 5 * 1024 * 1024
            if buffer.count > maxRequestSize {
                self.log("⚠️ Request exceeded maximum allowed size (\(maxRequestSize) bytes)")
                self.sendResponse(connection: connection, statusCode: 400, body: "Request too large")
                return
            }

            let headerDelimiter = Data("\r\n\r\n".utf8)
            if let headerRange = buffer.range(of: headerDelimiter) {
                let headerData = buffer[..<headerRange.lowerBound]
                let bodyStartIndex = headerRange.upperBound

                let headerString = String(decoding: headerData, as: UTF8.self)

                self.log("🧾 Request headers:\n\(headerString)")
                let contentLength = self.parseContentLength(from: headerString)
                self.log("📏 Expecting body of \(contentLength) bytes")
                let totalNeeded = bodyStartIndex + contentLength

                if buffer.count < totalNeeded {
                    if isComplete {
                        self.log("❌ Connection closed before full body received")
                        self.sendResponse(connection: connection, statusCode: 400, body: "Incomplete request body")
                    } else {
                        self.receiveRequest(connection, accumulatedData: buffer)
                    }
                    return
                }

                let requestData = buffer.prefix(totalNeeded)
                let requestString = String(decoding: requestData, as: UTF8.self)
                self.log("📥 Received request: \(requestString.prefix(200))...")
                self.processHTTPRequest(requestString, connection: connection)
            } else {
                if isComplete {
                    self.log("❌ Connection closed before headers received")
                    self.sendResponse(connection: connection, statusCode: 400, body: "Invalid request format")
                } else {
                    self.receiveRequest(connection, accumulatedData: buffer)
                }
            }
        }
    }

    private func parseContentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                return Int(value) ?? 0
            }
        }
        return 0
    }
    
    private func processHTTPRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            log("❌ Empty request received")
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }

        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 3 else {
            log("❌ Malformed request line: \(firstLine)")
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        
        let method = components[0]
        let path = components[1]
        
        if method == "POST" && path == "/avar" {
            handleDiagramPost(request: request, connection: connection)
        } else if method == "GET" && path == "/" {
            handleGetRoot(connection: connection)
        } else if method == "GET" && path == "/avar" {
            handleGetAvar(connection: connection)
        } else if method == "OPTIONS" {
            handleOptions(connection: connection)
        } else {
            sendResponse(connection: connection, statusCode: 404, body: "Not Found")
        }
    }
    
    private func handleOptions(connection: NWConnection) {
        let response = """
        HTTP/1.1 200 OK\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        Content-Length: 0\r
        \r
        
        """
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.log("❌ Send error: \(error.localizedDescription)")
            }
            connection.cancel()
        })
    }
    
    private func handleGetRoot(connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>AVAR2 Diagram Server</title>
        </head>
        <body>
            <h1>AVAR2 Diagram Server</h1>
            <p>POST JSON diagrams to <a href="/avar">/avar</a> endpoint</p>
            <p>Expected format: {"elements": [...]} or {"RTelements": [...]}</p>
        </body>
        </html>
        """
        
        sendResponse(connection: connection, statusCode: 200, body: html, contentType: "text/html")
    }
    
    private func handleGetAvar(connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>AVAR2 - Send Diagram</title>
        </head>
        <body>
            <h1>AVAR2 Diagram Endpoint</h1>
            <p>Send POST request with JSON diagram data to this endpoint</p>
            <p>Expected format: {"elements": [...]} or {"RTelements": [...]}</p>
            <h2>Example:</h2>
            <pre>
            curl -X POST http://\(getLocalIPAddress()):8081/avar \\
                -H "Content-Type: application/json" \\
                -d '{"id": "diagram1", "elements": [{"id": "1", "type": "node", "shape": "Box", "position": [0,0,0]}]}'
            </pre>
            <p><strong>Note:</strong> You can now include an "id" field at the root level to update existing diagrams.</p>
        </body>
        </html>
        """
        
        sendResponse(connection: connection, statusCode: 200, body: html, contentType: "text/html")
    }
    
    private func handleDiagramPost(request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        
        guard let emptyLineIndex = lines.firstIndex(of: ""),
              emptyLineIndex + 1 < lines.count else {
            sendResponse(connection: connection, statusCode: 400, body: "Invalid request format")
            return
        }
        
        let bodyLines = lines[(emptyLineIndex + 1)...]
        let rawBody = bodyLines.joined(separator: "\r\n")
        
        // Clean the JSON body by removing formatting whitespace and fixing various quote escaping
        var cleanedBody = rawBody
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle different forms of escaped quotes
        cleanedBody = cleanedBody
            .replacingOccurrences(of: "\\\"", with: "\"")  // Standard escaped quotes
            .replacingOccurrences(of: "\u{005C}\u{0022}", with: "\"")  // Unicode escaped quotes
        
        // If the entire JSON is wrapped in quotes, remove them
        if cleanedBody.hasPrefix("\"") && cleanedBody.hasSuffix("\"") && cleanedBody.count > 1 {
            cleanedBody = String(cleanedBody.dropFirst().dropLast())
            // After unwrapping, clean escaped quotes again
            cleanedBody = cleanedBody.replacingOccurrences(of: "\\\"", with: "\"")
        }
        
        log("📥 Raw body length: \(rawBody.count)")
        log("🧹 Cleaned JSON: \(cleanedBody.prefix(200))...")
        
        // Test if it's valid JSON first
        do {
            _ = try JSONSerialization.jsonObject(with: cleanedBody.data(using: .utf8) ?? Data())
            log("✅ JSON syntax is valid")
        } catch {
            log("❌ Invalid JSON syntax: \(error.localizedDescription)")
            
            // Try additional cleaning for common issues
            var extraCleanedBody = cleanedBody
                .replacingOccurrences(of: "\\\\", with: "\\")  // Fix double backslashes
                .replacingOccurrences(of: "\\/", with: "/")    // Fix escaped forward slashes
                .replacingOccurrences(of: "\\n", with: "")     // Remove literal \n strings
                .replacingOccurrences(of: "\\t", with: "")     // Remove literal \t strings
                .replacingOccurrences(of: "\\r", with: "")     // Remove literal \r strings
            
            log("🔧 Extra cleaned JSON: \(extraCleanedBody.prefix(200))...")
            cleanedBody = extraCleanedBody
        }
        
        guard let jsonData = cleanedBody.data(using: .utf8) else {
            sendResponse(connection: connection, statusCode: 400, body: "Invalid JSON data")
            return
        }
        
        do {
            let scriptOutput = try JSONDecoder().decode(ScriptOutput.self, from: jsonData)
            
            DispatchQueue.main.async {
                self.lastReceivedJSON = cleanedBody
                self.onJSONReceived?(scriptOutput)
            }
            
            sendResponse(connection: connection, statusCode: 200, body: "\"done\"", contentType: "application/json")
            log("✅ Successfully parsed and processed diagram with \(scriptOutput.elements.count) elements")
            
        } catch let decodingError as DecodingError {
            let errorMessage = "JSON decoding error: \(decodingError.localizedDescription)"
            log("❌ \(errorMessage)")
            
            // Provide more specific error details
            switch decodingError {
            case .keyNotFound(let key, let context):
                log("🔑 Missing key: \(key.stringValue) at \(context.codingPath)")
            case .typeMismatch(let type, let context):
                log("🔄 Type mismatch: expected \(type) at \(context.codingPath)")
            case .valueNotFound(let type, let context):
                log("❓ Value not found: \(type) at \(context.codingPath)")
            case .dataCorrupted(let context):
                log("💥 Data corrupted at: \(context.codingPath)")
            @unknown default:
                log("🤷 Unknown decoding error")
            }
            
            sendResponse(connection: connection, statusCode: 400, body: "Invalid JSON format: \(errorMessage)")
        } catch {
            log("❌ JSON parsing error: \(error.localizedDescription)")
            sendResponse(connection: connection, statusCode: 400, body: "Invalid JSON format: \(error.localizedDescription)")
        }
    }
    
    private func sendResponse(connection: NWConnection, statusCode: Int, body: String, contentType: String = "text/plain") {
        let statusText = HTTPServer.statusText(for: statusCode)
        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r
        \(body)
        """
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.log("❌ Send error: \(error.localizedDescription)")
            }
            connection.cancel()
        })
    }
    
    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
