import SwiftUI

struct ConsoleView: View {
    @ObservedObject var console: ConsoleBuffer
    @State private var autoScroll = true

    // Fixed font size; lines wrap. Wrapped continuation lines get a hanging indent
    // via NSParagraphStyle.headIndent (the first line stays at the margin).
    private static func formatted(_ s: String) -> AttributedString {
        let para = NSMutableParagraphStyle()
        para.firstLineHeadIndent = 0
        para.headIndent = 12
        para.lineBreakMode = .byCharWrapping
        let ns = NSAttributedString(string: s, attributes: [.paragraphStyle: para])
        return AttributedString(ns)
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(console.lines.indices, id: \.self) { i in
                            Text(Self.formatted(console.lines[i]))
                                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color.green.opacity(0.95))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Color.clear.frame(height: 1).id("BOTTOM")
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
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
