import Foundation

/// Одно репостнутое видео. Метаданные приходят из /api/repost/item_list/,
/// который страница запрашивает сама — мы лишь читаем её ответ.
struct Repost: Identifiable, Hashable, Codable {
    let videoID: String
    let authorHandle: String
    let authorName: String
    let desc: String
    let coverURL: String
    let createTime: Int

    var id: String { videoID }
    var url: String { "https://www.tiktok.com/@\(authorHandle)/video/\(videoID)" }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(createTime)) }
    var displayName: String { authorName.isEmpty ? authorHandle : authorName }

    init(item: TikTokItem) {
        videoID = item.id
        authorHandle = item.author?.uniqueId ?? ""
        authorName = item.author?.nickname ?? ""
        desc = item.desc ?? ""
        coverURL = item.video?.cover ?? ""
        createTime = item.createTime ?? 0
    }

    /// Запасной путь: есть только ссылка (сбор через DOM, без метаданных).
    init(url: String) {
        let parts = URL(string: url)?.pathComponents ?? []
        videoID = parts.last ?? url
        authorHandle = String((parts.first { $0.hasPrefix("@") } ?? "").dropFirst())
        authorName = ""
        desc = ""
        coverURL = ""
        createTime = 0
    }
}

// MARK: - Форма ответа /api/repost/item_list/

struct TikTokFeed: Decodable {
    let itemList: [TikTokItem]?
    let hasMore: Bool?
}

struct TikTokItem: Decodable {
    let id: String
    let desc: String?
    let createTime: Int?
    let author: TikTokAuthor?
    let video: TikTokVideo?
}

struct TikTokAuthor: Decodable {
    let uniqueId: String?
    let nickname: String?
}

struct TikTokVideo: Decodable {
    let cover: String?
}

enum RemovalOutcome: String, Codable {
    case removed          // кнопка нажата, репост снят
    case buttonNotFound   // не нашли кнопку — скорее всего сменились селекторы
    case failed           // навигация или JS упали
    case captcha          // TikTok показал проверку: нужен человек
}

struct RemovalResult: Identifiable, Codable {
    var id: String { repost.videoID }
    let repost: Repost
    let outcome: RemovalOutcome
    let detail: String
}

/// Селекторы вынесены в настройки: TikTok регулярно меняет вёрстку,
/// и чинить это должно быть можно без пересборки приложения.
struct SelectorConfig: Codable, Equatable {
    var repostTab: [String]
    var videoItem: [String]
    var repostButton: [String]

    static let `default` = SelectorConfig(
        // repost-tab подтверждён на живом профиле.
        repostTab: [
            "[data-e2e=\"repost-tab\"]",
        ],
        // Только user-repost-item: user-post-item — свои видео,
        // а div[data-e2e$="-item"] ловит ещё и уведомления.
        videoItem: [
            "[data-e2e=\"user-repost-item\"] a[href*=\"/video/\"]",
        ],
        // repost-action-tag найден на живой странице видео: div 30x24,
        // cursor:pointer, обработчик на самом элементе, не на <button>.
        repostButton: [
            "[data-e2e=\"repost-action-tag\"]",
            "[data-e2e=\"repost-icon\"]",
            "button[aria-label*=\"epost\" i]",
        ]
    )

    /// Текст вкладки ищем ещё и по подписи — на случай, если data-e2e отсутствует.
    static let tabTextFallbacks = ["Reposts", "Репосты", "Repost"]
}

extension SelectorConfig {
    private static let key = "selectorConfig"

    static func load() -> SelectorConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cfg = try? JSONDecoder().decode(SelectorConfig.self, from: data)
        else { return .default }
        return cfg
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
