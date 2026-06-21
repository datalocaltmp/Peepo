import Foundation

private let cLogger: @convention(c) (UnsafePointer<CChar>?) -> Void = { msg in
    guard let msg else { return }
    // C log messages carry a trailing newline; strip it so it doesn't render as
    // an extra blank line in the console.
    let s = String(cString: msg).trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
    DispatchQueue.main.async { sharedConsole.log(s) }
}

func installConsoleLogger() {
    set_console_logger(cLogger)
}
