import Foundation

private let cLogger: @convention(c) (UnsafePointer<CChar>?) -> Void = { msg in
    guard let msg else { return }
    sharedConsole.log(String(cString: msg))
}

func installConsoleLogger() {
    set_console_logger(cLogger)
}

func pingServer() {
    guard let url = URL(string: "http://192.168.1.50:8080/ping") else { return }

    URLSession.shared.dataTask(with: url) { data, response, error in
        if let error {
            sharedConsole.log("GET error: \(error.localizedDescription)")
            return
        }

        if let http = response as? HTTPURLResponse {
            sharedConsole.log("GET status: \(http.statusCode)")
        } else {
            sharedConsole.log("GET ok")
        }

        if let data, let body = String(data: data, encoding: .utf8) {
            sharedConsole.log("GET body: \(body)")
        }
    }.resume()
}
