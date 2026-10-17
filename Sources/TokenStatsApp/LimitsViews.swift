import AppKit
import ServiceManagement
import SwiftUI

/// The menu bar icon: a gauge plus how much is left on whichever plan is closest to its limit.
struct MenuBarLabel: View {
    @ObservedObject var store: LimitsStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.67percent")
            if let tightest = store.tightest {
                Text("\(Int(tightest.window.remainingPercent.rounded()))%").monospacedDigit()
            }
        }
        .accessibilityLabel("Token Stats plan limits")
        .task { store.start() }
    }
}

/// The panel that drops down from the menu bar.
struct MenuBarPanel: View {
    @ObservedObject var store: LimitsStore
    let openDashboard: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Plan limits").font(.headline)
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if let lastRefresh = store.lastRefresh {
                    Text("Updated \(lastRefresh.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh limits")
            }

            if let notice = store.notice {
                Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            if store.accounts.isEmpty {
                Text(store.isRefreshing ? "Checking your plans…" : "No signed-in plans found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                // A plain stack: a ScrollView has no height of its own and collapses inside the menu.
                VStack(spacing: 2) {
                    ForEach(store.accounts) { AccountGlanceRow(account: $0) }
                }
            }

            Divider()
            CLIUpdatesRow(updater: CLIUpdater.shared)
            Divider()
            HStack {
                Button("Open Token Stats", action: openDashboard)
                Spacer()
                Menu("Add account") {
                    Button("Codex account…") { store.addAccount(.codex) }
                    Button("Claude account…") { store.addAccount(.claude) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HStack {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { store.refreshIfStale() }
    }
}

/// Daily updates for Claude Code, Codex, Grok and Muse.
struct CLIUpdatesRow: View {
    @ObservedObject var updater: CLIUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Toggle("Update CLIs daily", isOn: $updater.isEnabled).toggleStyle(.checkbox)
                Spacer()
                if updater.isUpdating {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Update now") { updater.updateNow() }
                        .buttonStyle(.borderless)
                }
            }
            .font(.callout)
            if let lastRun = updater.lastRun, !updater.results.isEmpty {
                Text("Last run \(lastRun.formatted(.relative(presentation: .named))): "
                    + updater.results.map(\.summary).joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Full output is in \(updater.logURL.path)")
            }
        }
    }
}

/// One line per account in the menu: who it is, then the percentage left on its main limits.
struct AccountGlanceRow: View {
    let account: LimitAccount

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: account.provider.symbol)
                .foregroundStyle(account.provider.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.email ?? account.source)
                    .font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Text([account.provider.rawValue, account.plan].compactMap { $0 }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let error = account.error, account.windows.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
            ForEach(account.glanceWindows) { GlanceGauge(window: $0, color: account.provider.color) }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        .help(account.windows.map { "\($0.title): \(Int($0.remainingPercent.rounded()))% left \(LimitFormat.resetText($0.resetsAt))" }.joined(separator: "\n"))
    }
}

private struct GlanceGauge: View {
    let window: LimitWindow
    let color: Color

    private var tint: Color {
        switch window.remainingPercent {
        case ..<10: return .red
        case ..<25: return .orange
        default: return color
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(Int(window.remainingPercent.rounded()))%")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(tint).frame(width: proxy.size.width * window.remainingPercent / 100)
                }
            }
            .frame(width: 44, height: 4)
            Text(window.shortTitle).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 48, alignment: .trailing)
    }
}

struct LimitAccountCard: View {
    let account: LimitAccount
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: 7) {
                Image(systemName: account.provider.symbol)
                    .foregroundStyle(account.provider.color)
                    .frame(width: 16)
                Text(account.provider.rawValue).fontWeight(.semibold)
                if let plan = account.plan {
                    Text(plan)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(account.provider.color.opacity(0.18)))
                }
                Spacer()
                Text(account.displayName)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let error = account.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(account.windows) { LimitBar(window: $0, color: account.provider.color, compact: compact) }
            if !account.notes.isEmpty {
                Text(account.notes.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 10 : 16)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 15, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

struct LimitBar: View {
    let window: LimitWindow
    let color: Color
    var compact = false

    private var barColor: Color {
        switch window.remainingPercent {
        case ..<10: return .red
        case ..<25: return .orange
        default: return color
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title).font(compact ? .caption : .callout)
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .font((compact ? Font.caption : .callout).weight(.semibold).monospacedDigit())
                    .foregroundStyle(barColor)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(barColor)
                        .frame(width: proxy.size.width * window.remainingPercent / 100)
                }
            }
            .frame(height: compact ? 5 : 7)
            let footer = [window.detail, window.resetsAt.map { LimitFormat.resetText($0) }].compactMap { $0 }
            if !footer.isEmpty {
                Text(footer.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// The plan limits block at the top of the dashboard window.
struct PlanLimitsSection: View {
    @ObservedObject var store: LimitsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Plan limits").font(.title3.weight(.semibold))
                Spacer()
                Menu("Add account") {
                    Button("Codex account…") { store.addAccount(.codex) }
                    Button("Claude account…") { store.addAccount(.claude) }
                }
                .fixedSize()
                Button { store.refresh() } label: {
                    if store.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.bordered)
                .help("Refresh limits")
            }
            if let notice = store.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if store.accounts.isEmpty {
                Text(store.isRefreshing ? "Checking your plans…" : "No signed-in plans found.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(store.accounts) { LimitAccountCard(account: $0) }
                }
            }
        }
        .task { store.start() }
        .onAppear { store.refreshIfStale() }
    }
}

#if DEBUG
/// `token-stats-swift --render-limits <dir>` (debug builds only) saves the menu panel and the
/// dashboard's limits section as PNGs, for PR screenshots without touching the screen.
enum LimitsSnapshot {
    @MainActor static func renderIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--render-limits", arguments.count > 1 else { return }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        _ = NSApplication.shared
        Task { @MainActor in
            let store = LimitsStore.shared
            store.refresh()
            while store.isRefreshing { try? await Task.sleep(for: .milliseconds(100)) }
            save(MenuBarPanel(store: store) {}, size: NSSize(width: 360, height: 400), to: directory.appendingPathComponent("menu.png"))
            save(PlanLimitsSection(store: store).padding(24).frame(width: 1040).background(Color(red: 0.045, green: 0.052, blue: 0.065)),
                 size: NSSize(width: 1040, height: 230), to: directory.appendingPathComponent("dashboard-limits.png"), dark: true)
            exit(0)
        }
        RunLoop.main.run()
    }

    @MainActor private static func save<V: View>(_ view: V, size: NSSize, to url: URL, dark: Bool = false) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
