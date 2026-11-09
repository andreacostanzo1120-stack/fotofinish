import SwiftUI

@main
struct FotoFinishApp: App {
    @StateObject private var engine = RaceEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(engine.store)
                .environmentObject(engine.settings)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    engine.startServices()
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var e: RaceEngine
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView(selection: $e.selectedTab) {
            RaceView()
                .tabItem { Label("Gara", systemImage: "stopwatch") }
                .tag(0)
            SessionsView()
                .tabItem { Label("Allenamento", systemImage: "list.bullet.rectangle") }
                .tag(1)
            HistoryView()
                .tabItem { Label("Storico", systemImage: "chart.xyaxis.line") }
                .tag(2)
            MoreView()
                .tabItem { Label("Altro", systemImage: "ellipsis.circle") }
                .tag(3)
        }
        .preferredColorScheme(settings.colorScheme)
        .dynamicTypeSize(settings.typeRange)
    }
}
