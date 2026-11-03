import SwiftUI
import UsageKit

struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.orderedSnapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(model.orderedSnapshots) { snapshot in
                                AccountCard(snapshot: snapshot, now: context.date)
                                if snapshot.id != model.orderedSnapshots.last?.id { Divider() }
                            }
                        }
                        .padding(14)
                    }
                }
                .frame(maxHeight: 560)
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Token Tracker").font(.headline)
            Spacer()
            if let lastRefresh = model.lastRefresh {
                Text(lastRefresh, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Last refreshed")
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                    .animation(model.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: model.isRefreshing)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("Refresh now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
            Text("No accounts yet").font(.headline)
            Text("Add your Claude and ChatGPT accounts in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Account…") { showSettings() }
        }
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { showSettings() }
                .keyboardShortcut(",")
            Spacer()
            if let syncError = model.syncError {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.orange)
                    .help("iCloud sync failed: \(syncError)")
            }
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}
