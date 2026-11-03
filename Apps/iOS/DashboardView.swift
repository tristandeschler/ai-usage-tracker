import SwiftUI
import UsageKit

struct DashboardView: View {
    @Environment(CompanionModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let error = model.error {
                        Label(error, systemImage: "icloud.slash")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 16))
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        GlassEffectContainer(spacing: 14) {
                            VStack(spacing: 14) {
                                ForEach(model.snapshots) { snapshot in
                                    VStack(alignment: .leading, spacing: 6) {
                                        AccountGlassCard(snapshot: snapshot, now: context.date)
                                        Text("Updated \(snapshot.fetchedAt.formatted(.relative(presentation: .named)))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.leading, 14)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .background(backdrop)
            .overlay {
                if model.snapshots.isEmpty && !model.isLoading {
                    ContentUnavailableView(
                        "Nothing synced yet",
                        systemImage: "menubar.dock.rectangle",
                        description: Text("Turn on “Sync to iPhone via iCloud” in Token Tracker on your Mac, signed in to the same Apple Account.")
                    )
                }
            }
            .navigationTitle("Token Tracker")
            .refreshable { await model.refresh() }
            .task { await model.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refresh() } }
            }
        }
    }

    /// Soft provider-colored wash so the glass cards have something to refract.
    private var backdrop: some View {
        ZStack {
            Color(.systemGroupedBackground)
            RadialGradient(colors: [UsageStyle.providerColor(.anthropic).opacity(0.25), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [UsageStyle.providerColor(.openai).opacity(0.2), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}
