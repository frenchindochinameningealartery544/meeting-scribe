import SwiftUI

/// Live subtitles shown during recording — the original spoken text, transcribed
/// in real time. Auto-scrolls to the newest line.
struct LiveTranslatePanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                captions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble.fill")
                .foregroundStyle(Theme.accent)
            Text("Live subtitles")
                .font(.headline)
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch appState.liveStatus {
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case .live:
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("Live").font(.caption).foregroundStyle(.secondary)
            }
        case .closed(let error):
            HStack(spacing: 6) {
                Circle().fill(error == nil ? Color.secondary : Color.red).frame(width: 7, height: 7)
                Text(error == nil ? "Idle" : "Error")
                    .font(.caption)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .help(error ?? "")
            }
        }
    }

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if appState.liveCaptions.isEmpty && appState.liveInProgress.isEmpty {
                        Text("Waiting for speech…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    }
                    ForEach(appState.liveCaptions) { caption in
                        captionRow(text: caption.original, live: false)
                            .id(caption.id)
                    }
                    if !appState.liveInProgress.isEmpty {
                        captionRow(text: appState.liveInProgress, live: true)
                            .id("inProgress")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 140, maxHeight: 280)
            .onChange(of: appState.liveCaptions.count) { _, _ in
                withAnimation { proxy.scrollTo("inProgress", anchor: .bottom) }
                if let last = appState.liveCaptions.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: appState.liveInProgress) { _, _ in
                withAnimation { proxy.scrollTo("inProgress", anchor: .bottom) }
            }
        }
    }

    private func captionRow(text: String, live: Bool) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(live ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
