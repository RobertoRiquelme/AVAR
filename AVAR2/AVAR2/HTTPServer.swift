import Foundation
import Network

class HTTPServer: ObservableObject {
    @Published var isRunning = false
    @Published var serverURL = ""
    @Published var lastReceivedJSON = ""
    @Published var serverStatus = "Stopped"
    
    private var listener: NWListener?
    private let port: UInt16 = 8080
    private let queue = DispatchQueue(label: "HTTPServer")
    
    var onJSONReceived: ((ScriptOutput) -> Void)?
    
    func start() {
        guard !isRunning else { return }
        
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.serverURL = "http://localhost:\(self?.port ?? 8080)/avar"
                        self?.serverStatus = "Running on port \(self?.port ?? 8080)"
                        print("🌐 HTTP Server started on port \(self?.port ?? 8080)")
                    case .failed(let error):
                        self?.isRunning = false
                        self?.serverStatus = "Failed: \(error.localizedDescription)"
                        print("❌ HTTP Server failed: \(error)")
                    case .cancelled:
                        self?.isRunning = false
                        self?.serverURL = ""
                        self?.serverStatus = "Stopped"
                        print("🛑 HTTP Server stopped")
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
            print("❌ Failed to start HTTP server: \(error)")
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
                print("❌ Connection failed: \(error)")
                connection.cancel()
            }
        }
        
        connection.start(queue: queue)
    }
    
    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            if let error = error {
                print("❌ Receive error: \(error)")
                connection.cancel()
                return
            }
            
            guard let data = data, !data.isEmpty else {
                connection.cancel()
                return
            }
            
            let requestString = String(data: data, encoding: .utf8) ?? ""
            print("📥 Received request: \(requestString.prefix(200))...")
            
            self?.processHTTPRequest(requestString, connection: connection)
        }
    }
    
    private func processHTTPRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        
        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 3 else {
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
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error {
                print("❌ Send error: \(error)")
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
            curl -X POST http://localhost:8080/avar \\
                -H "Content-Type: application/json" \\
                -d '{"elements": [{"id": "1", "type": "node", "shape": "Box", "position": [0,0,0]}]}'
            </pre>
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
        let body = bodyLines.joined(separator: "\r\n")
        
        guard let jsonData = body.data(using: .utf8) else {
            sendResponse(connection: connection, statusCode: 400, body: "Invalid JSON data")
            return
        }
        
        do {
            let scriptOutput = try JSONDecoder().decode(ScriptOutput.self, from: jsonData)
            
            DispatchQueue.main.async {
                self.lastReceivedJSON = body
                self.onJSONReceived?(scriptOutput)
            }
            
            sendResponse(connection: connection, statusCode: 200, body: "Diagram received successfully")
            print("✅ Successfully parsed and processed diagram with \(scriptOutput.elements.count) elements")
            
        } catch {
            print("❌ JSON parsing error: \(error)")
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
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error {
                print("❌ Send error: \(error)")
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
