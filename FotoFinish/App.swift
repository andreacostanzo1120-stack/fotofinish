import SwiftUI

@main
struct FotoFinishApp: App {
    @StateObject private var engine = RaceEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(engine.store)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    engine.startServices()
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            RaceView()
                .tabItem { Label("Gara", systemImage: "stopwatch") }
            ResultsView()
                .tabItem { Label("Risultati", systemImage: "list.bullet") }
            StatsView()
                .tabItem { Label("Statistiche", systemImage: "chart.xyaxis.line") }
            ConnectView()
                .tabItem { Label("Collega", systemImage: "qrcode") }
        }
    }
}
