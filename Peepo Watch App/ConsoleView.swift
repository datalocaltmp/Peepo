import SwiftUI

struct ConsoleView: View {
    @ObservedObject var console: ConsoleBuffer
    @State private var autoScroll = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(console.lines.indices, id: \.self) { i in
                            Text(console.lines[i])
                                .font(.system(size: 8, weight: .light, design: .monospaced))
                                .foregroundStyle(Color.green.opacity(0.95))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Color.clear.frame(height: 1).id("BOTTOM")
                    }
                    .padding(8)
                }
                .onChange(of: console.lines.count) { _, _ in
                    guard autoScroll else { return }
                    DispatchQueue.main.async {
                        withAnimation(.linear(duration: 0.12)) {
                            proxy.scrollTo("BOTTOM", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}
