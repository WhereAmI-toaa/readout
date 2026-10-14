import SwiftUI

@main
struct ReadoutApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.reader)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
        }
    }
}
