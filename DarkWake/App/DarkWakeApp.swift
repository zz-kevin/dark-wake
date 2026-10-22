import SwiftUI

@main
struct DarkWakeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(.cyan)
                .task { model.restart() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            MapScreen()
                .tabItem { Label("Picture", systemImage: "map") }
                .tag(Tab.map)
            AlertsScreen()
                .tabItem { Label("Alerts", systemImage: "exclamationmark.triangle") }
                .badge(model.openAlertCount)
                .tag(Tab.alerts)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}
