import SwiftUI

struct CleanerView: View {
    let onLogout: () -> Void

    @StateObject private var cleaner = RepostCleaner()
    @State private var showSettings = false
    @State private var showWebView = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            List {
                if cleaner.needsCaptcha { captchaSection }
                statusSection
                actionsSection
                if !cleaner.reposts.isEmpty { repostsSection }
                if !cleaner.results.isEmpty { resultsSection }
                if !cleaner.diagnostics.isEmpty { diagnosticsSection }
                webViewSection
            }
            .navigationTitle("Репосты")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(cleaner: cleaner, onLogout: onLogout)
            }
            .alert("Снять отмеченные репосты?", isPresented: $confirmDelete) {
                Button("Отмена", role: .cancel) {}
                Button("Снять \(cleaner.selected.count)", role: .destructive) {
                    Task { await cleaner.removeAll(dryRun: false) }
                }
            } message: {
                Text("Действие необратимо: вернуть репосты можно будет только вручную.")
            }
        }
    }

    /// TikTok периодически требует пройти слайдер-пазл. Автоматика его не решает —
    /// показываем WebView и отдаём управление человеку.
    private var captchaSection: some View {
        Section {
            Label("Нужна проверка", systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            Text("TikTok показал капчу. Разверни WebView ниже, проведи ползунок пальцем, затем нажми «Продолжить».")
                .font(.footnote)
            Button("Продолжить") {
                cleaner.captchaResolved()
                showWebView = false
            }
            .buttonStyle(.borderedProminent)
        }
        .onAppear { showWebView = true }
    }

    private var statusSection: some View {
        Section {
            // Автоопределение ломается на медленной сети и в симуляторе,
            // поэтому даём вписать ник руками.
            HStack {
                Text("@").foregroundStyle(.secondary)
                TextField("ник (если не определился сам)", text: $cleaner.manualUsername)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(cleaner.isBusy)
            }
            if !cleaner.username.isEmpty {
                LabeledContent("Аккаунт", value: "@\(cleaner.username)")
            }
            Text(cleaner.status)
                .font(.callout)
                .foregroundStyle(.secondary)
            if cleaner.phase == .removing {
                ProgressView(value: cleaner.progress) {
                    Text("\(cleaner.processed) из \(cleaner.reposts.count)")
                        .font(.caption)
                }
            } else if cleaner.phase == .scanning {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await cleaner.scan() }
            } label: {
                Label("Найти репосты", systemImage: "magnifyingglass")
            }
            .disabled(cleaner.isBusy)

            Button {
                Task { await cleaner.removeAll(dryRun: true) }
            } label: {
                Label("Проверка без удаления", systemImage: "eye")
            }
            .disabled(cleaner.isBusy || cleaner.reposts.isEmpty)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Снять репосты: \(cleaner.selected.count)", systemImage: "trash")
            }
            .disabled(cleaner.isBusy || cleaner.selected.isEmpty)

            if cleaner.isBusy {
                Button(role: .cancel) { cleaner.stop() } label: {
                    Label("Остановить", systemImage: "stop.circle")
                }
            }
        } footer: {
            Text("Сначала «Проверка» — она открывает те же страницы, но ничего не нажимает. Если кнопка находится, можно снимать.")
        }
    }

    private var repostsSection: some View {
        Section {
            ForEach(cleaner.reposts) { r in
                Button {
                    cleaner.toggle(r)
                } label: {
                    HStack(spacing: 10) {
                        cover(r)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.displayName)
                                .font(.subheadline).bold()
                                .lineLimit(1)
                            if !r.desc.isEmpty {
                                Text(r.desc).font(.caption)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            if r.createTime > 0 {
                                Text(r.date, format: .dateTime.year().month().day())
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Image(systemName: cleaner.selected.contains(r.videoID)
                              ? "checkmark.square.fill" : "square")
                            .foregroundStyle(cleaner.selected.contains(r.videoID)
                                             ? Color.accentColor : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(cleaner.isBusy)
            }
        } header: {
            HStack {
                Text("Репосты (\(cleaner.selected.count) из \(cleaner.reposts.count))")
                Spacer()
                Button(cleaner.selected.count == cleaner.reposts.count ? "Снять все" : "Выбрать все") {
                    cleaner.selectAll(cleaner.selected.count != cleaner.reposts.count)
                }
                .font(.caption)
                .disabled(cleaner.isBusy)
            }
        }
    }

    /// Превью с CDN TikTok. Может не отдаться из-за проверки Referer —
    /// тогда остаётся заглушка, а строка всё равно читается по тексту.
    @ViewBuilder
    private func cover(_ r: Repost) -> some View {
        if let u = URL(string: r.coverURL), !r.coverURL.isEmpty {
            AsyncImage(url: u) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 44, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 44, height: 58)
                .overlay(Image(systemName: "play.fill").foregroundStyle(.secondary))
        }
    }

    private var resultsSection: some View {
        Section("Результат (\(cleaner.results.count))") {
            ForEach(cleaner.results) { r in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: r.outcome))
                        .foregroundStyle(color(for: r.outcome))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.repost.displayName.isEmpty ? r.repost.videoID : r.repost.displayName)
                            .font(.subheadline)
                        Text(r.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    /// Когда селектор не сработал — показываем, что реально есть на странице.
    /// Это заменяет ручную «разведку» через компьютер.
    private var diagnosticsSection: some View {
        Section("Диагностика: data-e2e на странице") {
            Text(cleaner.diagnostics.joined(separator: "\n"))
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var webViewSection: some View {
        Section {
            Toggle("Показать рабочий WebView", isOn: $showWebView)
            // WebView обязан быть в иерархии, иначе JS засыпает. Когда он скрыт —
            // держим его крошечным и прозрачным, но живым.
            WebViewHost(webView: cleaner.runner.webView)
                .frame(height: showWebView ? 320 : 1)
                .opacity(showWebView ? 1 : 0.01)
                .allowsHitTesting(showWebView)
        }
    }

    private func icon(for o: RemovalOutcome) -> String {
        switch o {
        case .removed: return "checkmark.circle.fill"
        case .buttonNotFound: return "questionmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .captcha: return "exclamationmark.shield.fill"
        }
    }

    private func color(for o: RemovalOutcome) -> Color {
        switch o {
        case .removed: return .green
        case .buttonNotFound: return .orange
        case .failed: return .red
        case .captcha: return .orange
        }
    }
}
