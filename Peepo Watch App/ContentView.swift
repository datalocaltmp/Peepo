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
            // Outline (4 directions – efficient for watchOS)
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
    private enum RunMode {
        case kernStuff
        case fuzz
    }

    @State private var showConsole = false
    @State private var runMode: RunMode = .kernStuff

    var body: some View {
        ZStack {
            // Background image from Assets: background.png
            Image("background")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            if showConsole {
                ConsoleView(console: sharedConsole)
                    .onAppear {
                        installConsoleLogger()
                        DispatchQueue.global(qos: .userInitiated).async {
                            switch runMode {
                            case .kernStuff:
                                kern_stuff()

                            case .fuzz:
                                // Start the exerciser/fuzzer (C file)
                                // Tweak these as needed for watch performance:
                                // durationSeconds: 30, workerCount: 2, stepsPerWorker: 8000
                                let seed = exerciser_seed_from_time()
                                exerciser_start(seed, 3600, 8, 8000)
                            }
                        }
                    }
                    // Slight dark overlay so console text stays readable
                    .background(Color.black.opacity(0.25))
                    .ignoresSafeArea()
            } else {
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

                    Spacer()

                    // Bottom buttons
                    VStack(spacing: 10) {
                        Button {
                            runMode = .kernStuff
                            showConsole = true
                        } label: {
                            OutlinedText(
                                text: "KERNEL FUN",
                                font: .headline,
                                textColor: .white,
                                outlineColor: .black,
                                outlineWidth: 1
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderless)
                        .tint(.black.opacity(0.50))

                        Button {
                            runMode = .fuzz
                            showConsole = true
                        } label: {
                            OutlinedText(
                                text: "KERN FUZZ",
                                font: .headline,
                                textColor: .white,
                                outlineColor: .black,
                                outlineWidth: 1
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderless)
                        .tint(.black.opacity(0.50))
                    }
                    .padding(.bottom, 20)
                }
                .padding(.horizontal, 10)
            }
        }
    }
}

#Preview {
    ContentView()
}
