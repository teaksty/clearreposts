import SwiftUI

struct SettingsView: View {
    @ObservedObject var cleaner: RepostCleaner
    let onLogout: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var tabSel = ""
    @State private var itemSel = ""
    @State private var btnSel = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text("Пауза между видео: \(cleaner.minDelay, specifier: "%.1f")–\(cleaner.maxDelay, specifier: "%.1f") с")
                            .font(.footnote)
                        Slider(value: $cleaner.minDelay, in: 0.5...10, step: 0.5)
                        Slider(value: $cleaner.maxDelay, in: 0.5...15, step: 0.5)
                    }
                } header: {
                    Text("Темп")
                } footer: {
                    Text("Слишком быстро — TikTok временно блокирует действия. Ниже 2 секунд опускать не советую.")
                }

                Section {
                    selectorEditor("Вкладка «Репосты»", text: $tabSel)
                    selectorEditor("Плитка видео", text: $itemSel)
                    selectorEditor("Кнопка репоста", text: $btnSel)
                } header: {
                    Text("Селекторы")
                } footer: {
                    Text("По одному CSS-селектору в строке, пробуются сверху вниз. Если TikTok сменит вёрстку — правится здесь, без пересборки приложения.")
                }

                Section {
                    Button("Сбросить селекторы") { fill(with: .default) }
                    Button("Выйти из аккаунта", role: .destructive) {
                        Task {
                            await WebRunner.logout()
                            dismiss()
                            onLogout()
                        }
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { save() }.bold()
                }
            }
            .onAppear { fill(with: cleaner.selectors) }
        }
    }

    private func selectorEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 76)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    private func fill(with cfg: SelectorConfig) {
        tabSel = cfg.repostTab.joined(separator: "\n")
        itemSel = cfg.videoItem.joined(separator: "\n")
        btnSel = cfg.repostButton.joined(separator: "\n")
    }

    private func save() {
        let cfg = SelectorConfig(
            repostTab: lines(tabSel),
            videoItem: lines(itemSel),
            repostButton: lines(btnSel)
        )
        cfg.save()
        cleaner.selectors = cfg
        dismiss()
    }

    private func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
