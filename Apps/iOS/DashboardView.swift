import SwiftUI
import UsageKit

struct DashboardView: View {
    @Environment(CompanionModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                if let error = model.error {
                    Label(error, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ForEach(model.snapshots) { snapshot in
                        Section {
                            AccountCard(snapshot: snapshot, now: context.date)
                                .padding(.vertical, 4)
                        } footer: {
                            Text("Updated \(snapshot.fetchedAt.formatted(.relative(presentation: .named)))")
                        }
                    }
                }
            }
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
}
