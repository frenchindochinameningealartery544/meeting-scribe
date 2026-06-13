import SwiftUI

/// On-screen live caption bar, following broadcast subtitle conventions
/// (BBC / Netflix / Section 508): at most two centre-aligned lines, ~37–42
/// characters each, on a translucent box for contrast.
///
/// Live text streams in token-by-token, so instead of reflowing a sliding tail
/// (which makes the whole caption jump) it is greedily wrapped into fixed lines
/// on word boundaries. Greedy wrapping keeps earlier lines stable as text grows,
/// and showing only the last two lines gives a readable "roll-up" effect — the
/// format the BBC recommends for live captioning.
struct CaptionsOverlay: View {
    @Environment(AppState.self) private var appState

    /// BBC uses 37, Netflix 42; kept conservative so each wrapped line reliably
    /// fits one visual row at the caption font.
    private static let maxCharsPerLine = 38

    var body: some View {
        VStack {
            Spacer()
            bar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 10)
    }

    /// The full current text: the in-progress turn, else the last finalized line.
    private var fullText: String {
        if !appState.liveInProgress.isEmpty { return appState.liveInProgress }
        if let last = appState.liveCaptions.last { return last.translated }
        switch appState.liveStatus {
        case .connecting: return "Connecting…"
        case .live:       return "Listening…"
        case .closed(let error): return error == nil ? "" : "Translation error"
        }
    }

    /// The last three wrapped lines, joined with explicit breaks.
    private var displayText: String {
        Self.wrap(fullText, maxChars: Self.maxCharsPerLine)
            .suffix(3)
            .joined(separator: "\n")
    }

    @ViewBuilder
    private var bar: some View {
        if displayText.isEmpty {
            EmptyView()
        } else {
            Text(displayText)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.7), radius: 1, y: 1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.85))
                )
                .frame(maxWidth: 760)
        }
    }

    /// Greedy word-wrap into lines of at most `maxChars`. Stable under growth:
    /// appending text never changes the breaks of earlier lines.
    private static func wrap(_ text: String, maxChars: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for token in text.split(separator: " ", omittingEmptySubsequences: true) {
            var word = String(token)
            // Hard-wrap a single word longer than a line.
            while word.count > maxChars {
                if !current.isEmpty { lines.append(current); current = "" }
                lines.append(String(word.prefix(maxChars)))
                word = String(word.dropFirst(maxChars))
            }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= maxChars {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
