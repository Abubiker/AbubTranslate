import SwiftUI
import NaturalLanguage
import UniformTypeIdentifiers
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
        .background {
            if #available(macOS 26.0, *) {
                LiquidGlassBackground(lighterDark: true)
            }
        }
        .environment(\.locale, model.effectiveLocale)
        .preferredColorScheme(model.preferredColorScheme)
        .animation(.smooth(duration: 0.22), value: model.status)
        .animation(.smooth(duration: 0.2), value: model.translatedText)
        // Картинка, брошенная на панель = OCR-перевод без единого
        // разрешения: пиксели уже на диске, Vision читает их локально.
        .onDrop(of: [UTType.fileURL, UTType.png, UTType.tiff], isTargeted: nil) { providers, _ in
            guard let provider = providers.first else { return false }
            Task { @MainActor in
                var data: Data?
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) {
                    let url: URL?
                    switch item {
                    case let u as URL: url = u
                    case let u as NSURL: url = u as URL
                    case let d as Data:
                        if let u = URL(dataRepresentation: d, relativeTo: nil) {
                            url = u
                        } else {
                            var stale = false
                            url = try? URL(resolvingBookmarkData: d, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
                        }
                    default: url = nil
                    }
                    if let url, let candidate = try? Data(contentsOf: url),
                       ImageOCRManager.isImageData(candidate) {
                        data = candidate
                    }
                }
                if data == nil {
                    for type in [UTType.png, UTType.tiff] {
                        if let raw = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? Data,
                           ImageOCRManager.isImageData(raw) { data = raw; break }
                    }
                }
                if let data { model.recognize(data) }
            }
            return true
        }
        .translationTask(model.translationConfig) { session in
            let text = model.takePendingText()
            guard !text.isEmpty else { return }
            do {
                var parts: [String] = []
                for piece in TextChunker.pieces(text, limit: Self.sessionChunkLimit(for: text)) {
                    try Task.checkCancellation()
                    let response = try await session.translate(piece.text)
                    parts.append(response.targetText + piece.trailing)
                }
                model.finishTranslation(parts.joined())
            } catch is CancellationError {
                return
            } catch {
                // Пока статус .preparing — пакет докачивается, падение
                // сессии в этот момент штатное; перезапуск сделает watchdog.
                if model.status == .preparing { return }
                model.failTranslation(error.localizedDescription)
            }
        }
    }

    /// Apple-движок не ругается и молча режет ответ примерно на 800 символах
    /// (замерено: вход 1600 → ровно 800 на выходе, вход 100000 → 409).
    /// Лимит на источник берётся с запасом под «раз expanding» языковые пары;
    /// плотные письменности (CJK/хангыль) разжимаются сильнее — для них лимит меньше.
    private static func sessionChunkLimit(for text: String) -> Int {
        let dense = text.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)   // CJK-иероглифы
                || (0x3040...0x30FF).contains($0.value) // кана
                || (0xAC00...0xD7AF).contains($0.value) // хангыль-слоги
        }
        return dense ? 200 : 400
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
                Button {
                    model.retarget(to: Locale.Language(identifier: option))
                } label: {
                    HStack {
                        Text(model.displayName(for: option))
                        if code == option { Image(systemName: "checkmark") }
                    }
                }
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
        let selected = model.sourceLanguageCode ?? "auto"
        return Menu {
            Button {
                model.sourceLanguageCode = nil
            } label: {
                HStack {
                    Text(model.localizedString("Auto-detect"))
                    if selected == "auto" { Image(systemName: "checkmark") }
                }
            }
            Divider()
            ForEach(all, id: \.self) { option in
                Button {
                    model.sourceLanguageCode = option
                } label: {
                    HStack {
                        Text(model.displayName(for: option))
                        if selected == option { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            languagePill(title: sourcePillTitle, isAuto: model.sourceLanguageCode == nil)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sourcePillTitle: String {
        if let code = model.sourceLanguageCode {
            return model.displayName(for: code)
        }
        if let det = model.detectedLanguage, let c = det.languageCode?.identifier {
            return "\(model.localizedString("Auto-detect")) (\(model.displayName(for: c)))"
        }
        return model.localizedString("Auto-detect")
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
                if let detected = model.detectedLanguage,
                   let src = model.sourceLanguage,
                   src.languageCode?.identifier != detected.languageCode?.identifier {
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
                if !model.translatedText.isEmpty, let meta = resultMetaText {
                    providerCapsule(name: meta)
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
        switch model.status {        case .failed(let message):
            VStack(alignment: .leading, spacing: DSTokens.sm) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: DSTokens.labelSize, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                // Провал Apple-движка по паре — не тупик: одно нажатие
                // включает Apple+MyMemory и повторяет этот же текст.
                if model.canOfferFallbackEngine {
                    Button {
                        model.enableMyMemoryAndRetranslate()
                    } label: {
                        Text("Translate via MyMemory")
                            .font(.system(size: DSTokens.labelSize, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

        case .sameLanguage(let detected, let suggestion):
            VStack(alignment: .leading, spacing: DSTokens.sm) {
                Label(
                    model.localizedString("Text is already in %@", model.languageName(detected)),
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
            statusRow(icon: "arrow.down.circle", text: model.localizedString("Downloading the language pack…"))

        case .workingCloud:
            statusRow(icon: "cloud", text: model.localizedString("Translating via %@…", model.cloudProviderName))

        case .working:
            statusRow(icon: "ellipsis", text: model.localizedString("Translating…"))

        case .idle, .done:
            if model.translatedText.isEmpty {
                Text("The translation will appear here")
                    .font(.system(size: DSTokens.bodySize))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: DSTokens.sm) {
                    ScrollView {
                        Text(model.translatedText)
                            // Одиночное слово крупнее — карточка, а не
                            // простыня: определения из системных словарей
                            // wave 2 (Dictionary Services мёртв в публичном
                            // SDK, LLM-определение требует облака).
                            .font(.system(size: wordMode != nil ? DSTokens.bodyLargeSize : DSTokens.bodySize))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    /// Источник — одно слово (не фраза)? По нему включается словарный
    /// layout;tokenizer NaturalLanguage отсекает «word.word» и мусор.
    private var wordMode: String? {
        let t = model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 24, !t.contains(" "), !t.contains("\n") else { return nil }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = t
        return tokenizer.tokens(for: t.startIndex..<t.endIndex).count == 1 ? t : nil
    }

    /// Чип над переводом: чем и за сколько получен результат — «cache»,
    /// облачный провайдер с таймингом или «на устройстве».
    private var resultMetaText: String? {
        if model.lastUsedCache { return model.localizedString("From cache") }
        let seconds: String? = model.lastElapsed.map {
            String(format: "%.1fs", Double($0.components.seconds) + Double($0.components.attoseconds) * 1e-18)
        }
        if model.lastUsedCloud {
            let name = model.lastProviderName ?? model.cloudProviderName
            return seconds.map { "\(name) · \($0)" } ?? name
        }
        let device = model.localizedString("on-device")
        return seconds.map { "\(device) · \($0)" } ?? device
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
                systemImage: model.copiedFlash ? "checkmark.circle.fill" : "doc.on.doc",
                help: "Copy translation",
                enabled: !model.translatedText.isEmpty
            ) {
                model.copyResult()
            }
            .overlay(alignment: .top) {
                if model.copiedFlash {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(5)
                        .background(Capsule().fill(DSTokens.Colors.bgCard))
                        .overlay(Capsule().stroke(DSTokens.Colors.border, lineWidth: 0.5))
                        .offset(y: -22)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.snappy(duration: 0.2), value: model.copiedFlash)
            controlButton(
                systemImage: "xmark.circle",
                help: "Clear",
                enabled: !model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                model.clearAll()
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
            controlButton(
                systemImage: "arrow.turn.down.left",
                help: "Replace selection in place",
                enabled: !model.translatedText.isEmpty
            ) {
                model.replaceInPlace()
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
