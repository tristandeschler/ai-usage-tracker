import SwiftUI
import UsageKit

struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var renaming: AccountConfig?

    var body: some View {
        VStack(spacing: 12) {
            header
            if model.orderedSnapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        GlassEffectContainer(spacing: 10) {
                            VStack(spacing: 10) {
                                ForEach(model.orderedSnapshots) { snapshot in
                                    AccountGlassCard(
                                        snapshot: snapshot,
                                        now: context.date,
                                        isActive: model.settings.menuBarMode == .activeAccount
                                            && snapshot.id == model.activeAccountID
                                    )
                                    .contextMenu { cardMenu(for: snapshot.id) }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 600)
                .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(12)
        .frame(width: 360)
        .renameAccountAlert($renaming)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Token Tracker").font(.title3.weight(.semibold))
                Group {
                    if model.limitedCount > 0 {
                        Text("\(model.limitedCount) account\(model.limitedCount == 1 ? "" : "s") limited")
                            .foregroundStyle(.red)
                    } else if let lastRefresh = model.lastRefresh {
                        Text("Updated \(lastRefresh.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("Loading…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: model.isRefreshing)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .keyboardShortcut("r")
            .help("Refresh now")
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No accounts yet").font(.headline)
            Text("Add your Claude and ChatGPT accounts to start tracking limits.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Account…") { showSettings() }
                .buttonStyle(.glassProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: UsageStyle.cardCornerRadius))
    }

    private var footer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    showSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",")

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private func cardMenu(for id: UUID) -> some View {
        if let account = model.accounts.first(where: { $0.id == id }) {
            Button("Rename…") { renaming = account }
            Button("Hide from Menu") {
                var updated = account
                updated.isEnabled = false
                model.update(updated)
            }
        }
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}
