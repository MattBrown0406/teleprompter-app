import SwiftUI

/// The scrolling script, drawn over the camera near the lens.
///
/// Tap to pause or play, drag to scroll by hand, pinch to change the text size.
struct TeleprompterView: View {
    @ObservedObject var engine: PrompterEngine
    let text: String
    let fontSize: CGFloat
    let mirrored: Bool
    let centered: Bool
    let backgroundOpacity: Double
    /// Where the line to read sits, as a share of the box height. Nil uses the usual spot near the top.
    var readingLineFraction: CGFloat? = nil
    var onFontSizeChange: (CGFloat) -> Void

    @State private var dragStartOffset: CGFloat?
    @State private var pinchStartSize: CGFloat?
    @State private var textHeight: CGFloat = 0

    private static let placeholder = "Tap Scripts to write or paste what you want to say. It will scroll here, just below the camera, so your eyes stay on the lens."

    private func readingLine(in height: CGFloat) -> CGFloat {
        if let fraction = readingLineFraction {
            return max(fontSize * 0.25 + 4, height * fraction)
        }
        return max(fontSize * 1.2, height * 0.18)
    }

    var body: some View {
        GeometryReader { geo in
            let readingLine = readingLine(in: geo.size.height)
            let textWidth = max(0, geo.size.width - 32)
            // Fade the edges, but never over the reading line.
            let topFade = min(0.08, (readingLine * 0.5) / max(geo.size.height, 1))

            ZStack(alignment: .top) {
                ScriptText(
                    text: text.isEmpty ? Self.placeholder : text,
                    isPlaceholder: text.isEmpty,
                    readUpTo: engine.followsVoice ? splitIndex : nil,
                    fontSize: fontSize,
                    centered: centered
                )
                .equatable()
                .frame(width: textWidth, alignment: centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { textGeo in
                        Color.clear.preference(key: ScriptHeightKey.self, value: textGeo.size.height)
                    }
                )
                .padding(.top, readingLine)
                .offset(y: -engine.offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: topFade),
                        .init(color: .black, location: 0.82),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay(alignment: .topLeading) {
                // Marker for the line to read.
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .offset(x: 4, y: readingLine + fontSize * 0.35)
            }
            .background(Color.black.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 16))
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .contentShape(Rectangle())
            .onTapGesture { engine.toggle() }
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        if dragStartOffset == nil {
                            dragStartOffset = engine.offset
                            engine.isDragging = true
                        }
                        let target = (dragStartOffset ?? 0) - value.translation.height
                        engine.offset = min(max(0, target), engine.maxOffset)
                    }
                    .onEnded { _ in
                        dragStartOffset = nil
                        engine.didScrollByHand()
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchStartSize == nil { pinchStartSize = fontSize }
                        onFontSizeChange((pinchStartSize ?? fontSize) * value.magnification)
                    }
                    .onEnded { _ in pinchStartSize = nil }
            )
            .onPreferenceChange(ScriptHeightKey.self) { height in
                // Stop once the last line has passed the reading line.
                engine.maxOffset = max(0, height - fontSize)
                textHeight = height
            }
            .onChange(of: LayoutInput(text: text, fontSize: fontSize, width: textWidth, centered: centered, height: textHeight), initial: true) { _, input in
                engine.setScript(input.text)
                guard input.height > 0, input.width > 0, !input.text.isEmpty else { return }
                engine.setWordOffsets(ScriptLayout.wordOffsets(
                    text: input.text, words: engine.words, width: input.width,
                    fontSize: input.fontSize, centered: input.centered, renderedHeight: input.height))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Script")
        .accessibilityValue(text)
        .accessibilityHint("Double tap to start or pause scrolling.")
    }

    /// Where the already-read part of the script ends.
    private var splitIndex: String.Index? {
        let index = engine.spokenIndex
        guard !text.isEmpty, index > 0 else { return nil }
        let words = engine.words
        guard index < words.count else { return text.endIndex }
        return words[index].start
    }

    private struct LayoutInput: Equatable {
        let text: String
        let fontSize: CGFloat
        let width: CGFloat
        let centered: Bool
        let height: CGFloat
    }
}

/// The script text. Its own view so it only redraws when the words or the read point change,
/// not on every scroll frame.
private struct ScriptText: View, Equatable {
    let text: String
    let isPlaceholder: Bool
    let readUpTo: String.Index?
    let fontSize: CGFloat
    let centered: Bool

    var body: some View {
        styled
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .lineSpacing(fontSize * 0.28)
            .multilineTextAlignment(centered ? .center : .leading)
            .foregroundStyle(isPlaceholder ? Color.white.opacity(0.55) : .white)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }

    private var styled: Text {
        guard let split = readUpTo, split > text.startIndex, split <= text.endIndex else { return Text(text) }
        // Words already said are dimmer, so your eye lands on what comes next.
        return Text(text[..<split]).foregroundStyle(Color.white.opacity(0.42)) + Text(text[split...])
    }
}

/// Works out where each word sits in the laid-out script, using the same font and spacing
/// as `ScriptText`, so voice following can put the word you're on at the reading line.
enum ScriptLayout {
    /// Scroll offset for each word (and one more for the end of the script).
    /// Moves through each line in proportion to the words said on it, so the scroll is smooth.
    static func wordOffsets(text: String, words: [ScriptWord], width: CGFloat, fontSize: CGFloat,
                            centered: Bool, renderedHeight: CGFloat) -> [CGFloat] {
        guard !words.isEmpty else { return [] }
        var font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        if let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: rounded, size: fontSize)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.28
        paragraph.alignment = centered ? .center : .natural
        let storage = NSTextStorage(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        let measured = layout.usedRect(for: container).height
        // SwiftUI and TextKit can differ by a hair per line; stretch to the real height so it doesn't add up.
        let scale = measured > 0 ? renderedHeight / measured : 1

        // Line rect for each word.
        let lines: [CGRect] = words.map { word in
            let glyph = layout.glyphIndexForCharacter(at: min(word.range.location, max(0, storage.length - 1)))
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        var offsets = [CGFloat](repeating: 0, count: words.count + 1)
        var start = 0
        while start < words.count {
            var end = start
            while end + 1 < words.count && lines[end + 1].minY == lines[start].minY { end += 1 }
            let line = lines[start]
            let count = CGFloat(end - start + 1)
            for i in start...end {
                offsets[i] = (line.minY + line.height * CGFloat(i - start) / count) * scale
            }
            start = end + 1
        }
        offsets[words.count] = (lines[words.count - 1].maxY) * scale
        return offsets
    }
}

private struct ScriptHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Big 3, 2, 1 before recording.
struct CountdownOverlay: View {
    let value: Int
    var body: some View {
        Text("\(value)")
            .font(.system(size: 160, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 12)
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: value)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.25))
            .allowsHitTesting(false)
    }
}
