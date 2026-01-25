import Foundation

final class ConsoleBuffer: ObservableObject {
    @Published var lines: [String] = []
    private let lock = NSLock()

    func log(_ s: String) {
        lock.lock()
        lines.append(s)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}

let sharedConsole = ConsoleBuffer()
