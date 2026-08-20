#!/usr/bin/env python3
"""
Массовое снятие репостов в TikTok через веб-сессию.

Работает в 4 режима:
  login  - открыть браузер и залогиниться руками (сессия сохранится)
  probe  - разведка: показать, какие data-e2e селекторы реально есть на странице
  sniff  - перехват сети: сними один репост руками, скрипт покажет эндпоинт
  run    - собрать все репосты и снять их пачкой

Профиль браузера лежит в .tt-profile/ — логин переживает перезапуски.
"""
import argparse
import asyncio
import json
import random
import sys
from datetime import datetime
from pathlib import Path

from playwright.async_api import async_playwright, TimeoutError as PWTimeout

# Windows-консоль по умолчанию не в UTF-8 — иначе русский вывод превращается в кракозябры.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

BASE = Path(__file__).resolve().parent
PROFILE_DIR = BASE / ".tt-profile"
STATE_FILE = BASE / "reposts.json"
LOG_FILE = BASE / "run.log"

# TikTok размечает вёрстку атрибутами data-e2e. Они относительно стабильны,
# но версии сайта отличаются — поэтому везде список кандидатов, а не один селектор.
SEL_REPOST_TAB = [
    '[data-e2e="repost-tab"]',
    '[data-e2e="user-repost"]',
    'p:has-text("Reposts")',
    'p:has-text("Репосты")',
]
# Строго user-repost-item и ничего больше. Подтверждено разведкой 21.08.2026.
# user-post-item — это СВОИ видео, div[data-e2e$="-item"] цепляет inbox-list-item
# из панели уведомлений. Любой из них по ошибке увёл бы скрипт не туда.
SEL_VIDEO_ITEM = [
    '[data-e2e="user-repost-item"] a[href*="/video/"]',
]
# TikTok показывает слайдер-пазл, когда заподозрит автоматизацию.
# Решает его только человек — скрипт лишь ждёт.
SEL_CAPTCHA = (
    '#captcha_container, .captcha_verify_container, [class*="captcha_verify"], '
    '#captcha-verify-image, .secsdk-captcha-drag-icon'
)
SEL_REPOST_BTN = [
    '[data-e2e="repost-icon"]',
    '[data-e2e="browse-repost"]',
    'button[aria-label*="epost" i]',
    'button[aria-label*="епост" i]',
]


def log(msg: str) -> None:
    line = f"[{datetime.now():%H:%M:%S}] {msg}"
    print(line, flush=True)
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


async def wait_if_captcha(page, poll: float = 3.0) -> bool:
    """Если появилась капча — ждём, пока её пройдут в окне браузера."""
    if not await page.locator(SEL_CAPTCHA).count():
        return False
    log("!!! TikTok показал капчу. Пройди её в окне браузера — жду.")
    log("    (в headless-режиме это невозможно: запускай без --headless)")
    while await page.locator(SEL_CAPTCHA).count():
        await asyncio.sleep(poll)
    log("Капча пройдена, продолжаю.")
    await page.wait_for_timeout(1500)
    return True


async def first_visible(page, selectors: list[str], timeout: int = 4000):
    """Вернуть первый селектор из списка, который реально виден на странице."""
    for sel in selectors:
        try:
            loc = page.locator(sel).first
            await loc.wait_for(state="visible", timeout=timeout)
            return loc, sel
        except PWTimeout:
            continue
    return None, None


async def launch(pw, headless: bool = False):
    return await pw.chromium.launch_persistent_context(
        user_data_dir=str(PROFILE_DIR),
        headless=headless,
        viewport={"width": 1280, "height": 900},
        args=["--disable-blink-features=AutomationControlled"],
    )


async def wait_for_enter(prompt: str) -> None:
    """Ждать Enter в консоли, не блокируя event loop."""
    await asyncio.get_event_loop().run_in_executor(None, input, prompt)


async def open_reposts_tab(page, username: str) -> None:
    """Открыть профиль и переключиться на вкладку с репостами."""
    url = f"https://www.tiktok.com/@{username.lstrip('@')}"
    log(f"Открываю {url}")
    await page.goto(url, wait_until="domcontentloaded")
    await page.wait_for_timeout(2500)
    await wait_if_captcha(page)

    tab, sel = await first_visible(page, SEL_REPOST_TAB, timeout=6000)
    if not tab:
        log("! Вкладка «Репосты» не найдена. Запусти режим probe и пришли вывод.")
        raise SystemExit(2)
    log(f"Вкладка найдена по селектору: {sel}")
    await tab.click()
    await page.wait_for_timeout(2500)


async def collect_reposts(page) -> list[str]:
    """Прокрутить ленту до конца и собрать ссылки на все репостнутые видео."""
    seen: list[str] = []
    stale_rounds = 0

    while stale_rounds < 3:
        hrefs = []
        for sel in SEL_VIDEO_ITEM:
            hrefs = await page.eval_on_selector_all(
                sel, "els => els.map(e => e.href)"
            )
            if hrefs:
                break

        before = len(seen)
        for h in hrefs:
            if h not in seen:
                seen.append(h)

        stale_rounds = stale_rounds + 1 if len(seen) == before else 0
        log(f"Собрано ссылок: {len(seen)}")

        await page.mouse.wheel(0, 3000)
        await page.wait_for_timeout(1800)

    return seen


async def remove_one(page, url: str, dry_run: bool) -> str:
    """Открыть видео и снять репост. Возвращает статус для лога."""
    await page.goto(url, wait_until="domcontentloaded")
    await page.wait_for_timeout(2000)
    if await wait_if_captcha(page):
        await page.wait_for_timeout(1000)

    btn, sel = await first_visible(page, SEL_REPOST_BTN, timeout=5000)
    if not btn:
        return "кнопка не найдена"

    label = (await btn.get_attribute("aria-label")) or (await btn.inner_text())
    if dry_run:
        return f"DRY-RUN, нашёл кнопку [{sel}] label={label!r}"

    await btn.click()
    await page.wait_for_timeout(1200)
    return f"снят (label был {label!r})"


async def cmd_login(args) -> None:
    async with async_playwright() as pw:
        ctx = await launch(pw)
        page = await ctx.new_page()
        await page.goto("https://www.tiktok.com/login")
        print("\n>>> Залогинься в открывшемся окне, потом нажми Enter здесь.\n")
        await wait_for_enter("")
        cookies = await ctx.cookies()
        names = {c["name"] for c in cookies}
        log(f"Куки сохранены. sessionid найден: {'sessionid' in names}")
        await ctx.close()


async def cmd_probe(args) -> None:
    """Разведка: вывалить все data-e2e атрибуты, чтобы уточнить селекторы."""
    async with async_playwright() as pw:
        ctx = await launch(pw)
        page = await ctx.new_page()
        url = f"https://www.tiktok.com/@{args.user.lstrip('@')}"
        await page.goto(url, wait_until="domcontentloaded")
        await page.wait_for_timeout(4000)

        attrs = await page.eval_on_selector_all(
            "[data-e2e]",
            "els => [...new Set(els.map(e => e.getAttribute('data-e2e')))]",
        )
        tabs = await page.eval_on_selector_all(
            "[role='tab'], [data-e2e$='-tab']",
            "els => els.map(e => ({t: e.innerText.trim(), e2e: e.getAttribute('data-e2e')}))",
        )
        print("\n=== data-e2e на странице профиля ===")
        print(json.dumps(sorted(a for a in attrs if a), ensure_ascii=False, indent=2))
        print("\n=== вкладки ===")
        print(json.dumps(tabs, ensure_ascii=False, indent=2))
        print("\nОкно оставлю открытым. Перейди на вкладку репостов, открой видео,")
        print("и нажми Enter — сниму data-e2e со страницы видео.\n")
        await wait_for_enter("")

        vattrs = await page.eval_on_selector_all(
            "[data-e2e]",
            "els => [...new Set(els.map(e => e.getAttribute('data-e2e')))]",
        )
        print("\n=== data-e2e на странице видео ===")
        print(json.dumps(sorted(a for a in vattrs if a), ensure_ascii=False, indent=2))
        await ctx.close()


async def cmd_sniff(args) -> None:
    """Перехват сети: сними один репост руками — увидим точный запрос."""
    async with async_playwright() as pw:
        ctx = await launch(pw)
        page = await ctx.new_page()

        async def on_request(req):
            if req.method in ("POST", "GET") and "/api/" in req.url:
                if any(k in req.url.lower() for k in ("repost", "digg", "commit", "favorite")):
                    log(f"--> {req.method} {req.url}")
                    if req.post_data:
                        log(f"    body: {req.post_data[:600]}")
                    hdrs = {k: v for k, v in req.headers.items()
                            if k.lower() in ("cookie", "x-secsdk-csrf-token", "content-type", "referer")}
                    log(f"    headers: {json.dumps(hdrs, ensure_ascii=False)[:800]}")

        page.on("request", on_request)
        await page.goto(f"https://www.tiktok.com/@{args.user.lstrip('@')}")
        print("\n>>> Зайди во вкладку «Репосты», сними ОДИН репост руками.")
        print(">>> Запрос появится здесь и в run.log. Потом нажми Enter.\n")
        await wait_for_enter("")
        await ctx.close()


async def cmd_run(args) -> None:
    async with async_playwright() as pw:
        ctx = await launch(pw)
        page = await ctx.new_page()

        if STATE_FILE.exists() and not args.refresh:
            urls = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            log(f"Беру сохранённый список: {len(urls)} шт. (--refresh чтобы пересобрать)")
        else:
            await open_reposts_tab(page, args.user)
            urls = await collect_reposts(page)
            STATE_FILE.write_text(json.dumps(urls, ensure_ascii=False, indent=2), encoding="utf-8")
            log(f"Список сохранён в {STATE_FILE.name}: {len(urls)} шт.")

        if args.limit:
            urls = urls[: args.limit]

        log(f"=== Обработка {len(urls)} видео, dry_run={args.dry_run} ===")
        done, failed = 0, 0
        for i, url in enumerate(urls, 1):
            try:
                status = await remove_one(page, url, args.dry_run)
                done += 1
            except Exception as e:
                status = f"ОШИБКА: {type(e).__name__}: {e}"
                failed += 1
            log(f"[{i}/{len(urls)}] {url.split('/')[-1]} — {status}")

            delay = random.uniform(args.min_delay, args.max_delay)
            await asyncio.sleep(delay)

        log(f"=== Готово. Обработано: {done}, ошибок: {failed} ===")
        await ctx.close()


DUMP_E2E = "els => [...new Set(els.map(e => e.getAttribute('data-e2e')))].filter(Boolean).sort()"

TAB_WORDS = ["Репосты", "Reposts", "Видео", "Videos",
             "Понравившиеся", "Liked", "Избранное", "Favorites"]

# Ищем вкладки по подписи: data-e2e у них на профиле отсутствует.
JS_TAB_CANDIDATES = """(words) => {
    const out = [];
    for (const e of document.querySelectorAll('*')) {
        const t = (e.textContent || '').trim();
        if (words.includes(t) && e.children.length <= 2) {
            out.push({
                tag: e.tagName,
                cls: (typeof e.className === 'string' ? e.className : '').slice(0, 90),
                e2e: e.getAttribute('data-e2e'),
                role: e.getAttribute('role'),
                text: t,
                parentCls: (e.parentElement && typeof e.parentElement.className === 'string'
                            ? e.parentElement.className : '').slice(0, 90)
            });
        }
    }
    return out;
}"""

JS_BUTTONS = """() => [...document.querySelectorAll('button, [role="button"], a')]
    .map(e => ({
        e2e: e.getAttribute('data-e2e'),
        label: e.getAttribute('aria-label'),
        text: (e.innerText || '').trim().slice(0, 28)
    }))
    .filter(x => x.e2e || x.label)"""


async def settle(page, shot: str | None = None, wait: int = 5000):
    """Дождаться прогрузки: пройти капчу, дать время сетке, при желании снять экран."""
    await page.wait_for_timeout(wait)
    await wait_if_captcha(page)
    await page.wait_for_timeout(2000)
    # Лёгкий скролл — ленивые сетки TikTok часто не рисуются без него.
    await page.mouse.wheel(0, 600)
    await page.wait_for_timeout(1500)
    if shot:
        await page.screenshot(path=str(BASE / shot))


async def cmd_autoprobe(args) -> None:
    """Разведка селекторов. Только чтение — ничего не удаляет."""
    if args.headless:
        log("! headless выключает возможность пройти капчу — профиль не откроется.")

    async with async_playwright() as pw:
        ctx = await launch(pw, headless=args.headless)
        page = await ctx.new_page()
        report = {}

        user = args.user.lstrip("@")
        if not user:
            await page.goto("https://www.tiktok.com/foryou", wait_until="domcontentloaded")
            await settle(page)
            user = await page.evaluate("""() => {
                const t = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
                if (!t) return '';
                try {
                    const d = JSON.parse(t.textContent);
                    const c = (d['__DEFAULT_SCOPE__']||{})['webapp.app-context']||{};
                    return (c.user && c.user.uniqueId) || '';
                } catch (e) { return ''; }
            }""")
            user = (user or "").lstrip("@")
        if not user:
            log("! Ник не определился — передай его аргументом: autoprobe @ник")
            await ctx.close()
            return
        report["username"] = user
        log(f"Аккаунт: @{user}")

        # --- Профиль ---
        await page.goto(f"https://www.tiktok.com/@{user}", wait_until="domcontentloaded")
        log("Жду прогрузки профиля (если появится капча — пройди её в окне)…")
        await settle(page, shot="shot_profile.png", wait=6000)

        report["profile_e2e"] = await page.eval_on_selector_all("[data-e2e]", DUMP_E2E)
        report["tab_candidates"] = await page.evaluate(JS_TAB_CANDIDATES, TAB_WORDS)
        log(f"Кандидатов вкладок по тексту: {len(report['tab_candidates'])}")
        for c in report["tab_candidates"]:
            log(f"   {c['text']!r}  tag={c['tag']} e2e={c['e2e']} cls={c['cls'][:40]}")

        # --- Клик по вкладке репостов ---
        clicked = None
        for word in ("Репосты", "Reposts"):
            loc = page.get_by_text(word, exact=True)
            if await loc.count():
                await loc.first.click()
                clicked = word
                break
        report["clicked_tab"] = clicked
        log(f"Клик по вкладке: {clicked}")
        await settle(page, shot="shot_reposts.png", wait=4000)

        # Дампы ПОСЛЕ прогрузки сетки — раньше я снимал их слишком рано.
        report["e2e_after_click"] = await page.eval_on_selector_all("[data-e2e]", DUMP_E2E)
        report["item_e2e"] = await page.eval_on_selector_all(
            "div[data-e2e]", "els => [...new Set(els.map(e => e.getAttribute('data-e2e')))]")
        counts = {}
        for sel in SEL_VIDEO_ITEM:
            counts[sel] = await page.locator(sel).count()
        report["item_counts"] = counts
        urls = await page.eval_on_selector_all(
            'a[href*="/video/"]', "els => [...new Set(els.map(e => e.href))]")
        report["all_video_links"] = urls[:40]
        log(f"Ссылок на видео на странице: {len(urls)}")

        # --- Страница видео ---
        if urls:
            await page.goto(urls[0], wait_until="domcontentloaded")
            await settle(page, shot="shot_video.png", wait=5000)
            report["video_e2e"] = await page.eval_on_selector_all("[data-e2e]", DUMP_E2E)
            report["video_buttons"] = await page.evaluate(JS_BUTTONS)
            log(f"Кнопок на странице видео: {len(report['video_buttons'])}")

        out = BASE / "probe_report.json"
        out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        log(f"Отчёт: {out.name} + скриншоты shot_*.png")
        await ctx.close()


# Снимок всего видимого и кликабельного — чтобы поймать разницу до/после открытия панели.
JS_SNAPSHOT = """() => {
    const vis = (e) => {
        const r = e.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
    };
    return [...document.querySelectorAll('[data-e2e], button, [role="button"], li, a, div')]
        .filter(vis)
        .map(e => ({
            e2e: e.getAttribute('data-e2e'),
            tag: e.tagName,
            label: e.getAttribute('aria-label'),
            text: (e.innerText || '').trim().slice(0, 40)
        }))
        .filter(x => (x.e2e || x.label) || (x.text && x.text.length < 40));
}"""

JS_TAG_DETAILS = """() => [...document.querySelectorAll('[data-e2e*="repost"]')].map(e => ({
    e2e: e.getAttribute('data-e2e'),
    tag: e.tagName,
    text: (e.innerText || '').trim().slice(0, 60),
    clickableParent: !!e.closest('button, [role="button"], a'),
    html: e.outerHTML.slice(0, 220)
}))"""


async def cmd_probevideo(args) -> None:
    """Найти управление снятием репоста на странице видео. Ничего не нажимает внутри панелей."""
    url = args.url
    if not url:
        rep = json.loads((BASE / "probe_report.json").read_text(encoding="utf-8"))
        links = rep.get("all_video_links") or []
        if not links:
            log("! Нет сохранённых ссылок — сначала autoprobe.")
            return
        url = links[0]

    async with async_playwright() as pw:
        ctx = await launch(pw, headless=False)
        page = await ctx.new_page()
        report = {"url": url}

        log(f"Открываю {url}")
        await page.goto(url, wait_until="domcontentloaded")
        await settle(page, shot="v_0_start.png", wait=5000)

        report["repost_elements"] = await page.evaluate(JS_TAG_DETAILS)
        log(f"Элементов с 'repost' в data-e2e: {len(report['repost_elements'])}")
        for e in report["repost_elements"]:
            log(f"   {e['e2e']} <{e['tag']}> кликабелен={e['clickableParent']} текст={e['text']!r}")

        before = await page.evaluate(JS_SNAPSHOT)
        key = lambda x: f"{x['e2e']}|{x['label']}|{x['text']}"
        seen = {key(x) for x in before}

        # Панель «Поделиться»: только открываем и читаем.
        for name, sel in (("share", '[data-e2e="share-icon"]'),
                          ("more", '[data-e2e="more-menu-icon"]')):
            loc = page.locator(sel).first
            if not await loc.count():
                log(f"{name}: элемент не найден")
                continue
            try:
                await loc.hover()
                await page.wait_for_timeout(1200)
                await loc.click()
            except Exception as e:
                log(f"{name}: клик не прошёл ({type(e).__name__})")
            await page.wait_for_timeout(2500)
            await page.screenshot(path=str(BASE / f"v_{name}.png"))

            after = await page.evaluate(JS_SNAPSHOT)
            fresh = [x for x in after if key(x) not in seen]
            for x in fresh:
                seen.add(key(x))
            report[f"new_after_{name}"] = fresh
            log(f"{name}: новых элементов {len(fresh)}")
            for x in fresh[:25]:
                blob = f"{x['e2e']} {x['label']} {x['text']}".lower()
                mark = " <<<" if any(w in blob for w in ("repost", "репост")) else ""
                log(f"   e2e={str(x['e2e']):20} text={x['text']!r}{mark}")
            await page.keyboard.press("Escape")
            await page.wait_for_timeout(1200)

        out = BASE / "probe_video.json"
        out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        log(f"Отчёт: {out.name} + скриншоты v_*.png")
        await ctx.close()


def main() -> None:
    p = argparse.ArgumentParser(description="Массовое снятие репостов TikTok")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("login", help="залогиниться руками, сохранить сессию")

    pr = sub.add_parser("probe", help="разведка селекторов")
    pr.add_argument("user", help="твой ник, например @nickname")

    sn = sub.add_parser("sniff", help="перехватить запрос снятия репоста")
    sn.add_argument("user", help="твой ник")

    rn = sub.add_parser("run", help="снять репосты пачкой")
    rn.add_argument("user", help="твой ник")
    rn.add_argument("--dry-run", action="store_true", help="ничего не удалять, только показать")
    rn.add_argument("--limit", type=int, default=0, help="обработать только N штук")
    rn.add_argument("--refresh", action="store_true", help="пересобрать список ссылок")
    rn.add_argument("--min-delay", type=float, default=2.5, help="мин. пауза между видео, сек")
    rn.add_argument("--max-delay", type=float, default=5.0, help="макс. пауза, сек")

    ap = sub.add_parser("autoprobe", help="разведка без участия человека (только чтение)")
    ap.add_argument("user", nargs="?", default="", help="ник; если не указан — определим сами")
    ap.add_argument("--headless", action="store_true", help="без окна браузера")

    pv = sub.add_parser("probevideo", help="найти кнопку снятия репоста на странице видео")
    pv.add_argument("url", nargs="?", default="", help="ссылка на видео; по умолчанию из probe_report.json")

    args = p.parse_args()
    handler = {"login": cmd_login, "probe": cmd_probe, "sniff": cmd_sniff,
               "run": cmd_run, "autoprobe": cmd_autoprobe,
               "probevideo": cmd_probevideo}[args.cmd]
    asyncio.run(handler(args))


if __name__ == "__main__":
    main()
