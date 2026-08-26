import SwiftUI
@preconcurrency import Translation

/// Кнопки в стиле Liquid Glass на macOS 26+, с фолбэком на старых системах.
private struct GlassCompat: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    fileprivate func glassCompat(prominent: Bool = false) -> some View {
        modifier(GlassCompat(prominent: prominent))
    }
}

struct PanelView: View {
    /// Ширина панели — нужна и AppDelegate для якоря поповера.
    static let width: CGFloat = 440

    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 14) {
            header
            sourceCard
            translateButton
            resultCard
            controls
        }
        .padding(16)
        .frame(width: Self.width)
        .animation(.smooth(duration: 0.25), value: model.status)
        .translationTask(model.translationConfig) { session in
            let text = model.takePendingText()
            guard !text.isEmpty else { return }
            do {
                let response = try await session.translate(text)
                model.finishTranslation(response.targetText)
            } catch is CancellationError {
                model.resetStatus()
            } catch {
                model.failTranslation(error.localizedDescription)
            }
        }
    }

    // MARK: - Шапка: пара языков + своп + настройки

    private var header: some View {
        HStack(spacing: 8) {
            languageMenu(code: model.languageCodeA) { model.languageCodeA = $0 }

            Button {
                model.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Swap languages"))

            languageMenu(code: model.languageCodeB) { model.languageCodeB = $0 }

            Spacer()

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .glassCompat()
            .controlSize(.small)
            .help(Text("Settings"))
        }
    }

    private func languageMenu(code: String, onPick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(model.availableLanguageCodes, id: \.self) { option in
                Button(model.displayName(for: option)) { onPick(option) }
            }
        } label: {
            languagePill(title: model.displayName(for: code))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func languagePill(title: String) -> some View {
        Text(title)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: - Карточка оригинала

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                cardTitle("Original", systemImage: "doc.text")
                if let detected = model.detectedLanguage {
                    // Иначе непонятно, что язык вообще определился: в шапке
                    // висит пара A⇄B, и она может не совпадать с оригиналом.
                    Text(model.languageName(detected))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { model.sourceText },
                    set: { model.sourceText = $0 }
                ))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(cardBackground)

                if model.sourceText.isEmpty {
                    Text("Select text and press the shortcut, or type here")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 60, maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Кнопка перевода

    private var translateButton: some View {
        Button {
            model.translate(text: model.sourceText)
        } label: {
            Label("Translate", systemImage: "arrow.left.arrow.right")
                .frame(maxWidth: .infinity)
        }
        .glassCompat(prominent: true)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: - Карточка перевода

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                cardTitle("Translation", systemImage: "character.bubble")
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ZStack(alignment: .topLeading) {
                cardBackground
                resultContent
                    .padding(10)
            }
            .frame(minHeight: 60, maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        switch model.status {
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .topLeading)

        case .preparing:
            Label("Downloading the language pack…", systemImage: "arrow.down.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .topLeading)

        case .working:
            Text("Translating…")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .topLeading)

        case .idle, .done:
            if model.translatedText.isEmpty {
                Text("The translation will appear here")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    Text(model.translatedText)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Нижние контролы

    private var controls: some View {
        HStack(spacing: 14) {
            controlButton(
                systemImage: "doc.on.doc",
                help: "Copy translation",
                enabled: !model.translatedText.isEmpty
            ) {
                model.copyResult()
            }
            controlButton(
                systemImage: model.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2",
                help: "Speak translation",
                enabled: model.canSpeak && !model.isSpeaking
            ) {
                model.speakLastTranslation()
            }
            controlButton(systemImage: "stop.fill", help: "Stop", enabled: model.isSpeaking) {
                model.stopSpeech()
            }
            Spacer()
            Text(verbatim: "AbubTranslate")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
    }

    private func controlButton(
        systemImage: String,
        help: LocalizedStringKey,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 20, height: 20)
        }
        .glassCompat()
        .disabled(!enabled)
        .help(help)
    }

    // MARK: - Общие элементы

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }

    private func cardTitle(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}
