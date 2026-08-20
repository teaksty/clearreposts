import SwiftUI

@main
struct ClearRepostsApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @State private var loggedIn: Bool? = nil

    var body: some View {
        Group {
            switch loggedIn {
            case nil:
                ProgressView("Проверяю сессию…")
            case .some(false):
                LoginView { loggedIn = true }
            case .some(true):
                CleanerView(onLogout: { loggedIn = false })
            }
        }
        .task { loggedIn = await WebRunner.isLoggedIn() }
    }
}
