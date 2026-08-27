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

    var body: some View {
        VStack(spacing: DSTokens.lg) {
            sourceCard
            actionRow
            resultCard
            controls
        }
        .padding(DSTokens.lg)
        .frame(minWidth: 360, idealWidth: Self.width, maxWidth: Self.width)
        .fixedSize(horizontal: true, vertical: false)
        .environment(\.locale, model.effectiveLocale)
        .animation(.smooth(duration: 0.22), value: model.status)
        .animation(.smooth(duration: 0.2), value: model.translatedText)
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

    // MARK: - Языковые меню

    /// Меню целевого языка — живёт в шапке карточки «Перевод»,
    /// чтобы подпись и контрол читались как одно целое.
    private var targetLanguageMenu: some View {
        let code = model.targetLanguageCode
        let codes = model.targetAvailableCodes
        let all = codes.contains(code) ? codes : ([code] + codes)
        return Menu {
            ForEach(all, id: \.self) { option in
                Button(model.displayName(for: option)) { model.retarget(to: Locale.Language(identifier: option)) }
            }
        } label: {
            languagePill(title: model.displayName(for: code))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Text("Translate into this language"))
    }

    private var sourceLanguageMenu: some View {
        let all: [String] = {
            var list = model.sourceAvailableCodes
            if let cur = model.sourceLanguageCode, !list.contains(cur) {
                list.insert(cur, at: 0)
            }
            return list
        }()
        return Menu {
            Button("Auto-detect") { model.sourceLanguageCode = nil }
            Divider()
            ForEach(all, id: \.self) { option in
                Button(model.displayName(for: option)) { model.sourceLanguageCode = option }
            }
        } label: {
            let title = model.sourceLanguageCode.map { model.displayName(for: $0) } ?? String(localized: "Auto-detect")
            languagePill(title: title, isAuto: model.sourceLanguageCode == nil)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // Три пилюли ниже отличались только размером/цветом текста и наличием
    // иконки, а Capsule-фон с обводкой повторяли дословно — один хелпер,
    // три тонких обёртки с прежними параметрами, поведение не изменилось.
    private func pill(
        _ title: String,
        systemImage: String? = nil,
        size: CGFloat,
        weight: Font.Weight = .medium,
        primary: Bool = false,
        muted: Bool = false
    ) -> some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.system(size: size, weight: weight))
        .foregroundStyle(primary ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, primary ? 10 : 7)
        .padding(.vertical, primary ? 5 : 3)
        .background(Capsule().fill(muted ? DSTokens.Colors.bgCard.opacity(0.6) : Color.primary.opacity(0.06)))
        .overlay(Capsule().stroke(DSTokens.Colors.border, lineWidth: 0.5))
    }

    private func languagePill(title: String, isAuto: Bool = false) -> some View {
        pill(title, size: DSTokens.labelSize, primary: true, muted: isAuto)
    }

    private func smallCapsule(_ text: String) -> some View {
        pill(text, size: DSTokens.metaSize)
    }

    private func providerCapsule(name: String) -> some View {
        pill(name, systemImage: "cloud", size: 11)
    }

    // MARK: - Карточка оригинала

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.sm) {
            HStack(spacing: DSTokens.sm) {
                cardTitle("Original", systemImage: "doc.text")
                Spacer(minLength: DSTokens.sm)
                sourceLanguageMenu
                    .help(Text("Source language — Auto-detect or fixed", comment: "Panel source menu help"))
                if let detected = model.detectedLanguage {
                    smallCapsule(model.languageName(detected))
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { model.sourceText },
                    set: { model.sourceTextEdited($0) }
                ))
                .font(.system(size: DSTokens.bodyLargeSize))
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .padding(DSTokens.md)
                .background(panelCardBackground)

                if model.sourceText.isEmpty {
                    Text("Paste text here — it translates automatically. Or select text anywhere and press the shortcut.")
                        .font(.system(size: DSTokens.bodySize))
                        .foregroundStyle(.tertiary)
                        .lineSpacing(2)
                        .padding(.horizontal, DSTokens.lg)
                        .padding(.vertical, DSTokens.lg + 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 72, maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Кнопка перевода — единственный primary на панель

    /// Своп — вторичная утилита слева, «Перевести» — единственный primary.
    /// Раньше своп стоял между языковыми пилюлями и спорил с кнопкой за внимание.
    private var actionRow: some View {
        HStack(spacing: DSTokens.sm) {
            Button {
                model.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 22)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canSwap)
            .help(Text("Swap source and target"))
            .accessibilityLabel(Text("Swap source and target"))

            translateButton
        }
    }

    private var translateButton: some View {
        Button {
            model.translate(text: model.sourceText)
        } label: {
            Label("Translate", systemImage: "arrow.left.arrow.right")
                .font(.system(size: DSTokens.bodySize, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .hoverLift()
        .accessibilityLabel(Text("Translate"))
        .accessibilityHint(Text("Translate original text"))
        .disabled(model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.defaultAction)
        .opacity(model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.6 : 1)
    }

    // MARK: - Карточка перевода

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.sm) {
            HStack(spacing: DSTokens.sm) {
                cardTitle("Translation", systemImage: "character.bubble")
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                }
                Spacer(minLength: DSTokens.sm)
                if model.lastUsedCloud, !model.translatedText.isEmpty {
                    providerCapsule(name: model.lastProviderName ?? model.cloudProviderName)
                }
                targetLanguageMenu
            }

            ZStack(alignment: .topLeading) {
                panelCardBackground
                resultContent
                    .padding(DSTokens.md)
            }
            .frame(minHeight: 72, maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        switch model.status {
        case .failed(let message):
            VStack(alignment: .leading, spacing: DSTokens.sm) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: DSTokens.labelSize, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

        case .sameLanguage(let detected, let suggestion):
            VStack(alignment: .leading, spacing: DSTokens.sm) {
                Label(
                    String(localized: "Text is already in \(model.languageName(detected))"),
                    systemImage: "text.badge.checkmark"
                )
                .font(.system(size: DSTokens.labelSize, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let suggestion {
                    Button {
                        model.retarget(to: suggestion)
                    } label: {
                        Text("Translate into \(model.languageName(suggestion))")
                            .font(.system(size: DSTokens.labelSize, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

        case .preparing:
            statusRow(icon: "arrow.down.circle", text: "Downloading the language pack…")

        case .workingCloud:
            statusRow(icon: "cloud", text: String(localized: "Translating via \(model.cloudProviderName)…"))

        case .working:
            statusRow(icon: "ellipsis", text: "Translating…")

        case .idle, .done:
            if model.translatedText.isEmpty {
                Text("The translation will appear here")
                    .font(.system(size: DSTokens.bodySize))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    Text(model.translatedText)
                        .font(.system(size: DSTokens.bodySize))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func statusRow(icon: String, text: String) -> some View {
        HStack(spacing: DSTokens.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
            Label(text, systemImage: icon)
                .font(.system(size: DSTokens.bodySize))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Нижние контролы — secondary zone muted

    private var controls: some View {
        HStack(spacing: DSTokens.sm) {
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
            // Шестерёнка переехала сюда из шапки: наверху она одна держала
            // целую строку ради одной кнопки.
            controlButton(systemImage: "gearshape", help: "Settings", enabled: true) {
                model.showSettings?()
            }
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
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(Text(help))
        .focusEffectDisabled(false)
    }

    // MARK: - Общие элементы

    private var panelCardBackground: some View {
        RoundedRectangle(cornerRadius: DSTokens.radiusCard)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                    .stroke(DSTokens.Colors.border, lineWidth: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                    .stroke(DSTokens.Colors.highlight, lineWidth: 0.5)
                    .opacity(0.5)
            )
    }

    private func cardTitle(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: DSTokens.labelSize, weight: .medium))
            .tracking(0.2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .accessibilityAddTraits(.isHeader)
    }
}
