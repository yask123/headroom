// The drop-down: one section per provider, the week's headroom up top.

import AppKit
import SwiftUI

struct PanelView: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Left this week")
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 4)
            ProviderSection(provider: .claude)
            Hairline().padding(.horizontal, 20)
            ProviderSection(provider: .codex)
            Hairline()
            Footer()
        }
    }
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
}

// MARK: Provider

private struct ProviderSection: View {
    @Environment(Store.self) private var store
    let provider: Provider

    private var state: ProviderState { store[provider] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                if let snap = state.snapshot, let weekly = snap.weekly {
                    Headline(window: weekly, tint: provider.tint)
                    if !snap.others.isEmpty {
                        VStack(spacing: 7) {
                            ForEach(snap.others) { MinorRow(window: $0, weekly: weekly, tint: provider.tint) }
                        }
                        .padding(.top, 14)
                    }
                    if let error = state.error { Note(text: error).padding(.top, 10) }
                } else if state.needsSignIn {
                    if provider == .claude { ConnectClaude() } else {
                        Note(text: "Sign in to Codex on this Mac and it shows up here.")
                            .padding(.top, 10)
                    }
                } else if let error = state.error {
                    Note(text: error).padding(.top, 10)
                } else {
                    Placeholder()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var header: some View {
        HStack(spacing: 7) {
            ProviderMark(provider: provider).frame(width: 14, height: 14)
            Text(provider.name).font(.system(size: 13, weight: .semibold))
            if let plan = state.snapshot?.plan {
                Text(plan)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(.primary.opacity(0.07), in: .capsule)
            }
            Spacer(minLength: 8)
            if let reset = state.snapshot?.weekly?.resetsAt {
                Text("Resets \(Dur.reset(reset))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The big number, the bar, and how the week is going.
private struct Headline: View {
    let window: Window
    let tint: Color

    var body: some View {
        let pct = Int((window.left * 100).rounded())
        let timeLeft = window.timeLeft()
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(pct)")
                    .font(.system(size: 44, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(pct)))
                Text("%")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
                Text("left")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                Spacer()
            }
            .foregroundStyle(window.left < 0.1 ? Color.low : .primary)
            .padding(.top, 6)

            UsageBar(left: window.left, timeLeft: timeLeft, tint: tint)
                .frame(height: 6)
                .padding(.top, 8)

            HStack {
                Text(pace(timeLeft))
                Spacer()
                if let r = window.resetsAt { Text("\(Dur.span(r.timeIntervalSinceNow)) to go") }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.top, 9)
        }
        .animation(.smooth(duration: 0.5), value: pct)
    }

    /// Compares what's left with how much of the week is left.
    private func pace(_ timeLeft: Double?) -> String {
        if window.left <= 0.001 { return "Out until the reset" }
        guard let t = timeLeft else { return "" }
        let days = t * (window.length ?? 0) / 86400
        let perDay = days >= 1 ? " · \(Int((window.left * 100 / days).rounded()))% a day" : ""
        if window.left > t + 0.08 { return "Room to spare" + perDay }
        if window.left < t - 0.08 { return "Running hot" + perDay }
        return "On pace" + perDay
    }
}

struct UsageBar: View {
    let left: Double
    let timeLeft: Double?
    let tint: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let color = left < 0.1 ? Color.low : tint
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: left > 0 ? max(h, w * left) : 0)
                if let t = timeLeft {
                    // Where the bar would end if you spent evenly through the week.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.primary.opacity(0.55))
                        .frame(width: 1.5, height: h + 6)
                        .offset(x: min(max(0, w * t - 0.75), w - 1.5))
                        .help("Even pace")
                }
            }
        }
        .animation(.smooth(duration: 0.5), value: left)
    }
}

private struct MinorRow: View {
    let window: Window
    let weekly: Window
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label).foregroundStyle(.secondary)
            if let r = window.resetsAt, abs(r.timeIntervalSince(weekly.resetsAt ?? .distantPast)) > 120 {
                Text("· \(Dur.span(r.timeIntervalSinceNow))").foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            UsageBar(left: window.left, timeLeft: nil, tint: tint)
                .frame(width: 64, height: 4)
            Text("\(Int((window.left * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 11.5))
        .monospacedDigit()
    }
}

private struct ConnectClaude: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.connecting
                 ? "Finish signing in in your browser — this updates on its own."
                 : "Sign in once with your Claude account to see your weekly limit.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(store.connecting ? "Waiting for browser…" : "Connect Claude") { store.connectClaude() }
                    .buttonStyle(.glass)
                    .disabled(store.connecting)
                if store.connecting {
                    Button("Cancel") { store.cancelConnect() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if let error = store.claude.error { Note(text: error) }
        }
        .padding(.top, 12)
    }
}

private struct Note: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Placeholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.06)).frame(width: 110, height: 36)
            Capsule().fill(.primary.opacity(0.06)).frame(height: 6)
        }
        .padding(.top, 10)
    }
}

// MARK: Footer

private struct Footer: View {
    @Environment(Store.self) private var store
    @State private var spin = 0.0

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(updated).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                withAnimation(.smooth(duration: 0.6)) { spin += 360 }
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").rotationEffect(.degrees(spin))
            }
            .help("Refresh")
            Menu {
                Toggle("Show percentages in menu bar", isOn: $store.showNumbers)
                Toggle("Open at login", isOn: $store.openAtLogin)
                Divider()
                if store.claude.snapshot != nil || ClaudeAuth.shared.isSignedIn {
                    Button("Sign out of Claude") { store.disconnectClaude() }
                }
                Button("Quit Headroom") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var updated: String {
        guard let d = store.lastFetched else { return store.claude.loading || store.codex.loading ? "Updating…" : " " }
        let s = Date.now.timeIntervalSince(d)
        return s < 60 ? "Updated just now" : "Updated \(Dur.span(s)) ago"
    }
}
