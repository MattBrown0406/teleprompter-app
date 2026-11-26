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
    var onFontSizeChange: (CGFloat) -> Void

    @State private var dragStartOffset: CGFloat?
    @State private var pinchStartSize: CGFloat?

    private static let placeholder = "Tap Scripts to write or paste what you want to say. It will scroll here, just below the camera, so your eyes stay on the lens."

    var body: some View {
        GeometryReader { geo in
            // Where the line you're reading sits, as a share of the box height.
            let readingLine = max(fontSize * 1.2, geo.size.height * 0.18)

            ZStack(alignment: .top) {
                Text(text.isEmpty ? Self.placeholder : text)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .lineSpacing(fontSize * 0.28)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .foregroundStyle(text.isEmpty ? Color.white.opacity(0.55) : .white)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .frame(width: max(0, geo.size.width - 32), alignment: centered ? .center : .leading)
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
                        .init(color: .black, location: 0.08),
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
                        if dragStartOffset == nil { dragStartOffset = engine.offset }
                        let target = (dragStartOffset ?? 0) - value.translation.height
                        engine.offset = min(max(0, target), engine.maxOffset)
                    }
                    .onEnded { _ in dragStartOffset = nil }
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
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Script")
        .accessibilityValue(text)
        .accessibilityHint("Double tap to start or pause scrolling.")
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
