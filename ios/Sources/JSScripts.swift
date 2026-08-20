import Foundation

/// JS, исполняемый внутри страницы TikTok. Тела функций для callAsyncJavaScript:
/// именованные аргументы приходят как готовые переменные, результат — JSON-строка.
enum JS {

    /// Общие хелперы, подклеиваются в начало каждого скрипта.
    private static let prelude = """
    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    const diag = () => [...new Set(
        [...document.querySelectorAll('[data-e2e]')].map(e => e.getAttribute('data-e2e'))
    )].filter(Boolean).sort();
    // TikTok подсовывает слайдер-пазл, когда заподозрит автоматизацию.
    // Решать его должен человек — мы только сообщаем наверх.
    const captcha = () => !!document.querySelector(
        '#captcha_container, .captcha_verify_container, [class*="captcha_verify"], '
        + '#captcha-verify-image, .secsdk-captcha-drag-icon'
    );
    const pick = (selectors) => {
        for (const s of selectors) {
            const el = document.querySelector(s);
            if (el) return { el, sel: s };
        }
        return null;
    };
    """

    /// Кто залогинен. Основной источник — JSON гидратации, который TikTok
    /// кладёт в <script id="__UNIVERSAL_DATA_FOR_REHYDRATION__">.
    static let whoami = prelude + """
    try {
        if (captcha()) return JSON.stringify({ ok: false, error: 'captcha' });
        const tag = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
        if (tag) {
            const data = JSON.parse(tag.textContent);
            const scope = data['__DEFAULT_SCOPE__'] || {};
            const ctx = scope['webapp.app-context'] || {};
            const uid = (ctx.user && ctx.user.uniqueId) || '';
            if (uid) return JSON.stringify({ ok: true, username: uid, via: 'rehydration' });
        }
        // Запасной путь — ссылка «профиль» в шапке.
        const link = document.querySelector('[data-e2e="nav-profile"], a[href^="/@"]');
        if (link) {
            // Без регулярки: обратный слеш в литерале Swift ломает сборку,
            // а разбор ссылки вида /@nickname прекрасно делается срезами.
            const href = link.getAttribute('href') || '';
            if (href.charAt(0) === '/' && href.charAt(1) === '@') {
                const nick = href.slice(2).split('/')[0].split('?')[0];
                if (nick) return JSON.stringify({ ok: true, username: nick, via: 'nav-link' });
            }
        }
        return JSON.stringify({ ok: false, error: 'username-not-found', e2e: diag() });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e), e2e: diag() });
    }
    """

    /// Переключиться на вкладку репостов, домотать до конца, собрать ссылки.
    static let collectReposts = prelude + """
    try {
        if (captcha()) return JSON.stringify({ ok: false, error: 'captcha' });
        let tab = pick(tabSelectors);
        if (!tab) {
            const cands = [...document.querySelectorAll('[role="tab"], p, span, button, div')];
            const hit = cands.find(e => {
                const t = (e.textContent || '').trim();
                return t.length < 20 && tabTexts.some(x => t === x);
            });
            if (hit) tab = { el: hit, sel: 'text-fallback' };
        }
        if (!tab) return JSON.stringify({ ok: false, error: 'tab-not-found', e2e: diag() });

        tab.el.click();
        await sleep(2500);
        if (captcha()) return JSON.stringify({ ok: false, error: 'captcha' });

        const seen = new Set();
        let stale = 0;
        while (stale < 3 && seen.size < maxItems) {
            let found = [];
            for (const s of itemSelectors) {
                const els = [...document.querySelectorAll(s)];
                if (els.length) { found = els; break; }
            }
            const before = seen.size;
            for (const a of found) {
                if (a.href && a.href.indexOf('/video/') !== -1) seen.add(a.href);
            }
            stale = (seen.size === before) ? stale + 1 : 0;
            window.scrollTo(0, document.body.scrollHeight);
            await sleep(1800);
        }
        return JSON.stringify({ ok: true, urls: [...seen], tabSelector: tab.sel });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e), e2e: diag() });
    }
    """

    /// Снять репост на открытой странице видео.
    static let removeRepost = prelude + """
    try {
        await sleep(1200);
        if (captcha()) return JSON.stringify({ ok: false, error: 'captcha' });
        const hit = pick(btnSelectors);
        if (!hit) return JSON.stringify({ ok: false, error: 'button-not-found', e2e: diag() });

        const label = hit.el.getAttribute('aria-label') || (hit.el.textContent || '').trim();
        // Сам data-e2e часто висит на иконке внутри кнопки — кликать надо по кнопке.
        const target = hit.el.closest('button, [role="button"]') || hit.el;
        if (dryRun) {
            return JSON.stringify({ ok: true, dryRun: true, selector: hit.sel, label });
        }
        target.click();
        await sleep(900);
        return JSON.stringify({ ok: true, selector: hit.sel, label });
    } catch (e) {
        return JSON.stringify({ ok: false, error: String(e), e2e: diag() });
    }
    """
    /// Ставится при загрузке каждой страницы. Оборачивает fetch и XHR, чтобы
    /// ловить ответы /api/repost/item_list/. Запрос делает сама страница —
    /// она же подписывает его X-Bogus/X-Gnarly/msToken, которые снаружи не получить.
    static let feedHook = """
    (function () {
        if (window.__ctHooked) return;
        window.__ctHooked = true;
        const MARK = 'repost/item_list';
        const send = (text) => {
            try {
                window.webkit.messageHandlers.repostFeed.postMessage(text);
            } catch (e) {}
        };

        const origFetch = window.fetch;
        window.fetch = function (...args) {
            const p = origFetch.apply(this, args);
            try {
                const req = args[0];
                const url = (typeof req === 'string') ? req : (req && req.url) || '';
                if (url.indexOf(MARK) !== -1) {
                    p.then(res => { res.clone().text().then(send).catch(() => {}); })
                     .catch(() => {});
                }
            } catch (e) {}
            return p;
        };

        const origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function (method, url, ...rest) {
            this.__ctUrl = url;
            return origOpen.call(this, method, url, ...rest);
        };
        const origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function (...args) {
            this.addEventListener('load', () => {
                try {
                    if ((this.__ctUrl || '').indexOf(MARK) !== -1) send(this.responseText);
                } catch (e) {}
            });
            return origSend.apply(this, args);
        };
    })();
    """

    /// Прокрутка вкладки репостов: подгружает следующую порцию, чтобы страница
    /// сама сходила за ней и перехват увидел ответ.
    static let scrollStep = prelude + """
    if (captcha()) return JSON.stringify({ ok: false, error: 'captcha' });
    const before = document.querySelectorAll(itemSelector).length;
    window.scrollTo(0, document.body.scrollHeight);
    await sleep(2200);
    const after = document.querySelectorAll(itemSelector).length;
    return JSON.stringify({ ok: true, before, after, grew: after > before });
    """

}

// MARK: - Разбор ответов

struct JSWhoami: Decodable {
    let ok: Bool
    let username: String?
    let error: String?
    let e2e: [String]?
}

struct JSCollect: Decodable {
    let ok: Bool
    let urls: [String]?
    let error: String?
    let e2e: [String]?
    let tabSelector: String?
}

struct JSScroll: Decodable {
    let ok: Bool
    let before: Int?
    let after: Int?
    let grew: Bool?
    let error: String?
}

struct JSRemove: Decodable {
    let ok: Bool
    let selector: String?
    let label: String?
    let error: String?
    let e2e: [String]?
}
