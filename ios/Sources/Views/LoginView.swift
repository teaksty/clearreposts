import SwiftUI
import WebKit

/// Вход в TikTok обычной веб-формой. Пароль живёт только внутри WebView
/// и в куках системного хранилища — приложение его не видит и не хранит.
struct LoginView: View {
    let onLoggedIn: () -> Void

    @StateObject private var model = LoginModel()

    var body: some View {
        NavigationStack {
            WebViewHost(webView: model.runner.webView)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Вход в TikTok")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Я вошёл") { Task { await model.check(onLoggedIn) } }
                    }
                }
                .overlay(alignment: .bottom) {
                    if let note = model.note {
                        Text(note)
                            .font(.footnote)
                            .padding(10)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.bottom, 24)
                    }
                }
        }
        .task { await model.start(onLoggedIn) }
    }
}

@MainActor
final class LoginModel: ObservableObject {
    let runner = WebRunner()
    @Published var note: String?

    private var poller: Task<Void, Never>?

    func start(_ onLoggedIn: @escaping () -> Void) async {
        try? await runner.load("https://www.tiktok.com/login")
        // Логин может завершиться редиректом, QR-кодом или подтверждением —
        // проще периодически проверять куку, чем угадывать все сценарии.
        poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if await WebRunner.isLoggedIn() {
                    poller?.cancel()
                    onLoggedIn()
                    return
                }
            }
        }
    }

    func check(_ onLoggedIn: @escaping () -> Void) async {
        if await WebRunner.isLoggedIn() {
            onLoggedIn()
        } else {
            note = "Сессия ещё не появилась — заверши вход и попробуй снова"
        }
    }

    deinit { poller?.cancel() }
}
