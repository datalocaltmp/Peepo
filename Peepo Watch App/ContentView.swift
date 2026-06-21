//
//  ContentView.swift
//  Peepo Watch App
//

import SwiftUI

// MARK: - Outlined Text Helper

struct OutlinedText: View {
    let text: String
    let font: Font
    let textColor: Color
    let outlineColor: Color
    let outlineWidth: CGFloat

    var body: some View {
        ZStack {
            // Outline (4 directions - efficient for watchOS)
            Text(text).font(font).foregroundColor(outlineColor).offset(x:  outlineWidth, y:  0)
            Text(text).font(font).foregroundColor(outlineColor).offset(x: -outlineWidth, y:  0)
            Text(text).font(font).foregroundColor(outlineColor).offset(x:  0, y:  outlineWidth)
            Text(text).font(font).foregroundColor(outlineColor).offset(x:  0, y: -outlineWidth)

            // Main text
            Text(text)
                .font(font)
                .foregroundColor(textColor)
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    private static let buildTag = "A003"

    @State private var showConsole = false
    @State private var dswWon = false
    @State private var showProcList = false
    @State private var showDumps = false
    @State private var deleteMsg: String? = nil
    @StateObject private var workoutManager = WorkoutManager()

    private let dswPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Delete all dump files (*.bin) from the app's Documents to free space.
    private func deleteDumps() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var n = 0
        if let files = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "bin" {
                if (try? FileManager.default.removeItem(at: f)) != nil { n += 1 }
            }
        }
        return "deleted \(n) dump\(n == 1 ? "" : "s")"
    }

    var body: some View {
        ZStack {
            // Background image from Assets: background.png
            Image("background")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            if dswWon {
                PostWinView(showProcList: $showProcList, console: sharedConsole)
            } else if showConsole {
                ZStack {
                    Color.black.ignoresSafeArea()

                    VStack(spacing: 0) {
                        // Header row is outside the ScrollView so taps always register
                        HStack {
                            Button {
                                darksword_cancel()
                                sharedConsole.clear()
                                showConsole = false
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.headline)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                            .background(.black.opacity(0.45))
                            .clipShape(Circle())
                            Spacer()
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 2)

                        ConsoleView(console: sharedConsole)
                            .onAppear {
                                installConsoleLogger()
                                workoutManager.startBreathingWorkout()
                                // darksword uses pthread_exit via FAILURE() so needs a real
                                // pthread, not a GCD worker - pthread_exit on a GCD thread
                                // corrupts the thread pool and breaks UI event handling
                                Thread.detachNewThread { darksword_run() }
                            }
                            .onDisappear {
                                workoutManager.stopWorkout()
                            }
                    }
                }
            } else {
                GeometryReader { geo in
                    VStack {
                        // Top label
                        OutlinedText(
                            text: "@datalocaltmp",
                            font: .headline,
                            textColor: .white,
                            outlineColor: .black,
                            outlineWidth: 1
                        )
                        .padding(.top, 12)
                        OutlinedText(
                            text: "build \(Self.buildTag)",
                            font: .system(size: 9, weight: .light, design: .monospaced),
                            textColor: .white.opacity(0.7),
                            outlineColor: .black,
                            outlineWidth: 1
                        )

                        Button { showDumps = true } label: {
                            Text("📄 list dumps")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.blue.opacity(0.95))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.45))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)

                        Button { deleteMsg = deleteDumps() } label: {
                            Text(deleteMsg ?? "🗑 delete dumps")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.red.opacity(0.9))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.45))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)

                        Spacer()

                        // Only one button: run the exploit.
                        Button {
                            showConsole = true
                        } label: {
                            OutlinedText(
                                text: "DATASWORD",
                                font: .headline,
                                textColor: .white,
                                outlineColor: .black,
                                outlineWidth: 1
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.white.opacity(0.35), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6)
                        // 25% of the screen height as padding below the button.
                        .padding(.bottom, geo.size.height * 0.25)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 10)
                }
            }
        }
        .onReceive(dswPoll) { _ in
            dswWon = (darksword_succeeded() != 0)
        }
        .fullScreenCover(isPresented: $showProcList) {
            ProcessListView { showProcList = false }
        }
        .fullScreenCover(isPresented: $showDumps) {
            DumpListView { showDumps = false }
        }
    }
}

// MARK: - Dump file listing

struct DumpListView: View {
    let onClose: () -> Void
    struct Item: Identifiable { let id = UUID(); let name: String; let size: Int }
    @State private var items: [Item] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("dumps (\(items.count))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).padding(6)
                    }
                    .buttonStyle(.plain)
                    .background(.red.opacity(0.35))
                    .clipShape(Circle())
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)

                if items.isEmpty {
                    Spacer()
                    Text("no dumps").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                } else {
                    List(items) { it in
                        HStack(spacing: 6) {
                            Text(it.name).font(.system(size: 9, design: .monospaced)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(fmt(it.size)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func fmt(_ b: Int) -> String {
        if b >= 1 << 20 { return String(format: "%.1fMB", Double(b) / Double(1 << 20)) }
        if b >= 1 << 10 { return "\(b >> 10)KB" }
        return "\(b)B"
    }

    private func load() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var out: [Item] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.fileSizeKey]) {
            for f in files where f.pathExtension == "bin" {
                let sz = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                out.append(Item(name: f.lastPathComponent, size: sz))
            }
        }
        items = out.sorted { $0.name < $1.name }
    }
}

// MARK: - Post-WIN dump menu

struct PostWinView: View {
    @Binding var showProcList: Bool
    let console: ConsoleBuffer

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Console fills the screen; DUMP PROCESS floats centered over the logs.
            ConsoleView(console: console)
                .padding(.horizontal, 8)

            Button {
                showProcList = true
            } label: {
                Text("PROCESS DUMP")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(.green.opacity(0.92))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.6), radius: 4)
        }
    }
}

// MARK: - Process List (post-exploit)

struct ProcessListView: View {
    @State private var procs: [ProcRow] = []
    @State private var loading = true
    let onClose: () -> Void

    struct ProcRow: Identifiable {
        let id = UUID()
        let pid: Int32
        let name: String
        let proc: UInt64
    }
    @State private var probed: String? = nil
    @State private var hexPath: String? = nil
    @State private var showHex = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "chevron.left").font(.headline).padding(6)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(loading ? "…" : "\(procs.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)

            if loading {
                Spacer()
                ProgressView()
                Spacer()
            } else if procs.isEmpty {
                Spacer()
                Text("no processes\n(sandbox restricted?)")
                    .multilineTextAlignment(.center)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                if let probed = probed {
                    Text(probed)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.green)
                        .lineLimit(2)
                        .padding(.horizontal, 6)
                }
                if hexPath != nil {
                    Button { showHex = true } label: {
                        Text("VIEW HEX ▸")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .background(.blue.opacity(0.30))
                    .clipShape(Capsule())
                    .padding(.horizontal, 6)
                }
                List(procs) { p in
                    Button {
                        let proc = p.proc, pid = p.pid, name = p.name
                        probed = "dumping \(name) (pid \(pid))…"
                        DispatchQueue.global(qos: .userInitiated).async {
                            peepo_dump_process(proc, name)
                            DispatchQueue.main.async {
                                probed = "dumped \(name) (pid \(pid))"
                                if let cp = peepo_last_dump_path() { hexPath = String(cString: cp) }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(p.name)
                                .font(.system(size: 10))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear(perform: load)
        .fullScreenCover(isPresented: $showHex) {
            HexView(path: hexPath ?? "") { showHex = false }
        }
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let maxN = 1024
            var buf = [ds_proc_info_t](repeating: ds_proc_info_t(), count: maxN)
            let n = peepo_list_processes(&buf, Int32(maxN))
            var rows: [ProcRow] = []
            if n > 0 {
                for i in 0..<Int(n) {
                    let nm = withUnsafePointer(to: buf[i].name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                    }
                    rows.append(ProcRow(pid: buf[i].pid, name: nm, proc: buf[i].proc))
                }
            }
            DispatchQueue.main.async {
                procs = rows
                loading = false
            }
        }
    }
}

// MARK: - On-watch hex viewer (xxd-style)

struct HexView: View {
    let path: String
    let onClose: () -> Void
    @State private var rows: [String] = []
    @State private var header = ""

    private static let chunk = 64 * 1024   // show first 64KB

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text(header)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).padding(6)
                    }
                    .buttonStyle(.plain)
                    .background(.red.opacity(0.35))
                    .clipShape(Circle())
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows.indices, id: \.self) { i in
                            Text(rows[i])
                                .font(.system(size: 6, weight: .regular, design: .monospaced))
                                .foregroundColor(.green.opacity(0.95))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(.horizontal, 3)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            rows = ["(can't open file)", path]; return
        }
        let data = fh.readData(ofLength: Self.chunk)
        let total = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? data.count
        fh.closeFile()

        let bytes = [UInt8](data)
        var out: [String] = []
        out.reserveCapacity(bytes.count / 8 + 1)
        var i = 0
        while i < bytes.count {
            let end = min(i + 8, bytes.count)
            var hex = ""
            var asc = ""
            for j in i..<end {
                let b = bytes[j]
                hex += String(format: "%02x ", b)
                asc += (b >= 32 && b < 127) ? String(UnicodeScalar(b)) : "."
            }
            while hex.count < 24 { hex += " " }   // pad short final row
            out.append(String(format: "%06x %@ %@", i, hex, asc))
            i += 8
        }
        rows = out
        let name = (path as NSString).lastPathComponent
        header = "\(name)  \(total)B  (first \(min(Self.chunk, total) >> 10)K)"
    }
}

#Preview {
    ContentView()
}
