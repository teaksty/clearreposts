import Foundation
import WebKit

/// Тонкая async-обёртка над WKWebView: навигация и JS с await и таймаутами.
@MainActor
final class WebRunner: NSObject, WKNavigationDelegate {

    /// Десктопный UA. Без него TikTok отдаёт мобильную вёрстку с другими
    /// data-e2e и баннером «Open in app», через который не пробиться.
    static let desktopUA = """
    Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 \
    (KHTML, like Gecko) Version/17.4 Safari/605.1.15
    """

    enum WebError: LocalizedError {
        case timeout
        case navigationFailed(String)

        var errorDescription: String? {
            switch self {
            case .timeout: return "Страница не загрузилась за отведённое время"
            case .navigationFailed(let m): return "Ошибка навигации: \(m)"
            }
        }
    }

    let webView: WKWebView
    /// Сюда прилетает сырой JSON каждого ответа /api/repost/item_list/.
    var onFeedJSON: (@MainActor (String) -> Void)?

    private var navContinuation: CheckedContinuation<Void, Error>?
    private var watchdog: Task<Void, Never>?

    override init() {
        let cfg = WKWebViewConfiguration()
        // .default() — общее хранилище с окном логина, поэтому сессия видна здесь.
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: JS.feedHook,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        cfg.userContentController = controller
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
            configuration: cfg
        )
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = Self.desktopUA
        // Слабый посредник: контроллер держит обработчик сильно,
        // а прямая ссылка на self замкнула бы цикл удержания.
        controller.add(ScriptProxy(self), name: "repostFeed")
    }

    fileprivate func handleFeed(_ text: String) {
        onFeedJSON?(text)
    }

    // MARK: - Навигация

    func load(_ urlString: String, timeout: TimeInterval = 30) async throws {
        guard let url = URL(string: urlString) else {
            throw WebError.navigationFailed("некорректный URL: \(urlString)")
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            navContinuation = c
            startWatchdog(timeout)
            webView.load(URLRequest(url: url))
        }
    }

    private func startWatchdog(_ timeout: TimeInterval) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.finishNavigation(.failure(WebError.timeout))
        }
    }

    /// Единая точка выхода — гарантирует, что continuation резюмится ровно один раз.
    private func finishNavigation(_ result: Result<Void, Error>) {
        watchdog?.cancel()
        watchdog = nil
        guard let c = navContinuation else { return }
        navContinuation = nil
        c.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(WebError.navigationFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finishNavigation(.failure(WebError.navigationFailed(error.localizedDescription)))
    }

    // MARK: - JS

    /// Выполнить асинхронный JS и получить результат. Тело может использовать await.
    @discardableResult
    func eval(_ source: String, args: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            source,
            arguments: args,
            in: nil,
            contentWorld: .page
        )
    }

    func evalJSON<T: Decodable>(_ source: String, args: [String: Any] = [:], as type: T.Type) async throws -> T {
        let raw = try await eval(source, args: args)
        let str = (raw as? String) ?? "null"
        let data = Data(str.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Сессия

    /// Залогинен ли пользователь — проверяем наличие sessionid среди кук TikTok.
    static func isLoggedIn() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.contains {
            $0.name == "sessionid" && $0.domain.contains("tiktok.com") && !$0.value.isEmpty
        }
    }

    static func logout() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        for r in records where r.displayName.contains("tiktok") {
            await store.removeData(ofTypes: types, for: [r])
        }
    }
}


/// Разрывает цикл WKUserContentController -> обработчик -> WebRunner.
private final class ScriptProxy: NSObject, WKScriptMessageHandler {
    weak var owner: WebRunner?
    init(_ owner: WebRunner) { self.owner = owner }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        Task { @MainActor in self.owner?.handleFeed(text) }
    }
}
