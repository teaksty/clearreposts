import Foundation
import SwiftUI

@MainActor
final class RepostCleaner: ObservableObject {

    enum Phase: Equatable {
        case idle, scanning, ready, removing, finished
        /// TikTok показал капчу — ждём, пока человек её пройдёт.
        case blocked
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status: String = "Готов к работе"
    @Published private(set) var username: String = ""
    @Published private(set) var reposts: [Repost] = []
    @Published private(set) var results: [RemovalResult] = []
    @Published private(set) var processed: Int = 0
    /// Список data-e2e со страницы — показываем, когда селектор не сработал.
    @Published private(set) var diagnostics: [String] = []
    /// Поднимается, когда нужна ручная проверка. Вью по нему раскрывает WebView.
    @Published private(set) var needsCaptcha = false
    /// Что отмечено к снятию. По умолчанию — всё найденное.
    @Published var selected: Set<String> = []

    /// Копится из перехваченных ответов item_list, ключ — id видео.
    private var harvested: [String: Repost] = [:]

    // Паузы между видео. @AppStorage работает только во вью, поэтому руками.
    @Published var minDelay: Double = RepostCleaner.stored("minDelay", 2.5) {
        didSet { UserDefaults.standard.set(minDelay, forKey: "minDelay") }
    }
    @Published var maxDelay: Double = RepostCleaner.stored("maxDelay", 5.0) {
        didSet { UserDefaults.standard.set(maxDelay, forKey: "maxDelay") }
    }

    private static func stored(_ key: String, _ fallback: Double) -> Double {
        (UserDefaults.standard.object(forKey: key) as? Double) ?? fallback
    }

    let runner = WebRunner()
    var selectors = SelectorConfig.load()

    private var cancelRequested = false

    var progress: Double {
        let total = max(queue.count, 1)
        return phase == .removing ? Double(processed) / Double(total) : 0
    }

    var isBusy: Bool { phase == .scanning || phase == .removing }

    /// Вызывается из UI после того, как человек прошёл проверку.
    func captchaResolved() {
        needsCaptcha = false
        status = "Проверка пройдена. Можно продолжать."
        phase = reposts.isEmpty ? .idle : .ready
    }

    private func blockOnCaptcha() {
        needsCaptcha = true
        phase = .blocked
        status = "TikTok просит пройти проверку. Открой WebView ниже, проведи ползунок и продолжи."
    }

    func stop() {
        cancelRequested = true
        status = "Останавливаюсь после текущего видео…"
    }

    // MARK: - Поиск репостов

    func scan() async {
        phase = .scanning
        cancelRequested = false
        diagnostics = []
        results = []
        processed = 0

        harvested = [:]
        selected = []
        // Страница сама сходит за списком — мы читаем её ответ.
        runner.onFeedJSON = { [weak self] text in
            guard let self else { return }
            guard let data = text.data(using: .utf8),
                  let feed = try? JSONDecoder().decode(TikTokFeed.self, from: data),
                  let items = feed.itemList else { return }
            for item in items {
                let r = Repost(item: item)
                self.harvested[r.videoID] = r
            }
            self.status = "Найдено репостов: \(self.harvested.count)…"
        }

        do {
            status = "Определяю аккаунт…"
            try await runner.load("https://www.tiktok.com/foryou")
            try await Task.sleep(nanoseconds: 2_000_000_000)

            let who = try await runner.evalJSON(JS.whoami, as: JSWhoami.self)
            guard who.ok, let name = who.username, !name.isEmpty else {
                if who.error == "captcha" { blockOnCaptcha(); return }
                diagnostics = who.e2e ?? []
                fail("Не удалось определить аккаунт (\(who.error ?? "?")). Проверь, что вход выполнен.")
                return
            }
            username = name
            status = "Аккаунт: @\(name). Открываю профиль…"

            try await runner.load("https://www.tiktok.com/@\(name)")
            try await Task.sleep(nanoseconds: 2_500_000_000)

            status = "Собираю репосты (листаю ленту)…"
            let collected = try await runner.evalJSON(
                JS.collectReposts,
                args: [
                    "tabSelectors": selectors.repostTab,
                    "itemSelectors": selectors.videoItem,
                    "tabTexts": SelectorConfig.tabTextFallbacks,
                    "maxItems": 3000,
                ],
                as: JSCollect.self
            )

            guard collected.ok, let urls = collected.urls else {
                if collected.error == "captcha" { blockOnCaptcha(); return }
                diagnostics = collected.e2e ?? []
                fail("Не нашёл вкладку репостов (\(collected.error ?? "?")). Смотри диагностику ниже.")
                return
            }

            // Перехват даёт превью, автора и дату; ссылки из DOM — только id.
            // Берём перехваченное, а недостающее дополняем ссылками.
            var merged = harvested
            for u in urls {
                let r = Repost(url: u)
                if merged[r.videoID] == nil { merged[r.videoID] = r }
            }
            reposts = merged.values.sorted { $0.createTime > $1.createTime }
            selected = Set(reposts.map(\.videoID))

            phase = .ready
            status = reposts.isEmpty
                ? "Репостов не найдено — либо их нет, либо сменились селекторы."
                : "Найдено репостов: \(reposts.count) (с метаданными: \(harvested.count))"

        } catch {
            fail("Сбой при сканировании: \(error.localizedDescription)")
        }
    }

    // MARK: - Снятие

    var queue: [Repost] { reposts.filter { selected.contains($0.videoID) } }

    func toggle(_ r: Repost) {
        if selected.contains(r.videoID) { selected.remove(r.videoID) }
        else { selected.insert(r.videoID) }
    }

    func selectAll(_ on: Bool) {
        selected = on ? Set(reposts.map(\.videoID)) : []
    }

    func removeAll(dryRun: Bool) async {
        let targets = queue
        guard !targets.isEmpty else { return }
        phase = .removing
        cancelRequested = false
        results = []
        processed = 0

        for (i, repost) in targets.enumerated() {
            if cancelRequested {
                status = "Остановлено на \(i) из \(targets.count)"
                break
            }
            status = "\(dryRun ? "Проверка" : "Снимаю") \(i + 1) из \(targets.count)…"
            let result = await removeOne(repost, dryRun: dryRun)
            results.append(result)
            processed = i + 1

            if result.outcome == .captcha {
                blockOnCaptcha()
                return
            }

            // Пауза вразнобой — ровный интервал ловит rate-limit заметно быстрее.
            if i < targets.count - 1 {
                let pause = Double.random(in: min(minDelay, maxDelay)...max(minDelay, maxDelay))
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }

        phase = .finished
        let goneIDs = Set(results.filter { $0.outcome == .removed }.map { $0.repost.videoID })
        if !dryRun && !goneIDs.isEmpty {
            reposts.removeAll { goneIDs.contains($0.videoID) }
            selected.subtract(goneIDs)
        }
        let removed = results.filter { $0.outcome == .removed }.count
        let problems = results.count - removed
        status = dryRun
            ? "Проверка завершена: кнопка найдена у \(removed) из \(results.count)"
            : "Готово. Снято: \(removed), с ошибками: \(problems)"
    }

    private func removeOne(_ repost: Repost, dryRun: Bool) async -> RemovalResult {
        do {
            try await runner.load(repost.url)
            let r = try await runner.evalJSON(
                JS.removeRepost,
                args: ["btnSelectors": selectors.repostButton, "dryRun": dryRun],
                as: JSRemove.self
            )
            if r.ok {
                return RemovalResult(
                    repost: repost,
                    outcome: .removed,
                    detail: "\(r.selector ?? "?") · \(r.label ?? "")"
                )
            }
            if r.error == "captcha" {
                return RemovalResult(repost: repost, outcome: .captcha, detail: "нужна ручная проверка")
            }
            if let e2e = r.e2e, diagnostics.isEmpty { diagnostics = e2e }
            return RemovalResult(
                repost: repost,
                outcome: .buttonNotFound,
                detail: r.error ?? "кнопка не найдена"
            )
        } catch {
            return RemovalResult(
                repost: repost,
                outcome: .failed,
                detail: error.localizedDescription
            )
        }
    }

    private func fail(_ message: String) {
        status = message
        phase = .idle
    }
}
