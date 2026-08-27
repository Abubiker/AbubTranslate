import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @State private var launchAtLogin = false
    // Движок, токен HuggingFace и почта MyMemory — единственные поля в этом
    // экране, которые НЕ применяются на лету: смена движка посреди набора
    // токена гоняла бы перевод по недописанному ключу. Черновик живёт здесь
    // и уходит в модель только по нажатию «Сохранить».
    @State private var hfToken: String = ""
    @State private var cloudEmail: String = ""
    @State private var engineMode: String = "apple"
    @State private var sourceLanguage: String = "auto"
    @State private var appLocaleRaw: String = "auto"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSTokens.xl) {
                pageHeader
                if hasCloudDraftChanges {
                    unsavedCloudBar
                }
                summaryGrid
                lanes
                systemCard
            }
            .padding(DSTokens.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: 900, minHeight: 640, idealHeight: 760, maxHeight: 860)
        .background(Color(NSColor.windowBackgroundColor))
        .environment(\.locale, model.effectiveLocale)
        .onAppear {
            launchAtLogin = model.isLaunchAtLoginEnabled
            resetCloudDraft()
            sourceLanguage = model.sourceLanguageCode ?? "auto"
            appLocaleRaw = model.appLocaleRaw
        }
        .onChange(of: sourceLanguage) { _, newValue in
            model.setSourceLanguageAndRetranslate(newValue == "auto" ? nil : newValue)
        }
    }

    /// Черновик движка/токена/почты не сохранён при закрытии окна — тихо
    /// пропадает, ровно как в любой форме за кнопкой «Сохранить». Ничего
    /// не коммитим за пользователя молча.
    private func resetCloudDraft() {
        engineMode = model.engineMode.rawValue
        hfToken = model.huggingFaceToken ?? ""
        cloudEmail = model.cloudContactEmail
    }

    private var hasCloudDraftChanges: Bool {
        engineMode != model.engineMode.rawValue
            || hfToken != (model.huggingFaceToken ?? "")
            || cloudEmail != model.cloudContactEmail
    }

    private func saveCloudDraft() {
        if let mode = EngineMode(rawValue: engineMode) ?? EngineMode.migrated(from: engineMode) {
            model.engineMode = mode
            engineMode = mode.rawValue
        }
        model.huggingFaceToken = hfToken
        model.cloudContactEmail = cloudEmail
    }

    // MARK: - Page header — отвечает "what is active"

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: DSTokens.sm) {
            Text("Settings")
                .pageTitleStyle()
            Text("Most changes apply immediately. Engine and credentials need Save.")
                .font(.system(size: DSTokens.bodySize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DSTokens.sm)
    }

    // MARK: - Unsaved cloud draft

    /// Появляется только когда в движке/токене/почте есть несохранённое —
    /// эти три поля единственные, где пользователь явно попросил Save
    /// вместо применения на лету: смена движка посреди набора токена
    /// не должна перезапускать перевод по недописанному ключу.
    private var unsavedCloudBar: some View {
        HStack(spacing: DSTokens.md) {
            Label("Unsaved changes", systemImage: "circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .imageScale(.small)

            Spacer(minLength: 0)

            Button("Discard") { resetCloudDraft() }
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button("Save") { saveCloudDraft() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, DSTokens.md)
        .padding(.vertical, DSTokens.sm)
        .background(
            RoundedRectangle(cornerRadius: DSTokens.radiusControl)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSTokens.radiusControl)
                .stroke(Color.orange.opacity(0.18), lineWidth: 0.5)
        )
    }

    // MARK: - Summary — current state

    private var summaryGrid: some View {
        // Реально применённое значение, а не черновик из Picker'а: сводка
        // отвечает «что активно сейчас», а движок за Save может отличаться
        // от того, что уже выбрано в форме, но ещё не подтверждено.
        let engine = model.engineMode
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: DSTokens.md), GridItem(.flexible(), spacing: DSTokens.md)], spacing: DSTokens.md) {
            summaryCard(
                overline: "Translating into",
                // Динамическое значение (имя языка) — не строковый литерал,
                // поэтому явно заворачиваем в LocalizedStringKey: без
                // подходящего ключа в .strings оно просто выводится как есть.
                title: LocalizedStringKey(model.displayName(for: model.targetLanguageCode)),
                subtitle: sourceLanguage == "auto" ? "Source: Auto-detect" : "Source: \(model.displayName(for: sourceLanguage))",
                icon: "arrow.right"
            )
            summaryCard(
                overline: "Engine",
                title: LocalizedStringKey(engine.displayName),
                // Выбранный режим ≠ то, что реально перевело последний раз:
                // HuggingFace без токена падает 401, и цепочка
                // молча уходит в MyMemory. Показываем правду, а не намерение —
                // иначе непонятно, почему выбран HF, а работает MyMemory.
                subtitle: engineActivitySubtitle(engine: engine),
                icon: engineIcon(for: engine)
            )
        }
    }

    /// Одна реализация для двух ширин: ViewThatFits в systemCard раньше
    /// держал дословную копию блока ради узкого/широкого варианта — правки
    /// приходилось вносить дважды, легко было забыть одну из копий.
    private func interfaceLanguagePicker(width: ClosedRange<CGFloat>?) -> some View {
        VStack(alignment: .leading, spacing: DSTokens.xs) {
            Text("Interface language").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Interface language", selection: $appLocaleRaw) {
                Text("Auto (System)").tag("auto")
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .modifier(OptionalWidthRange(range: width))
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: appLocaleRaw) { _, newValue in
                model.appLocaleRaw = newValue
                if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "AbubTranslateSettings" }) {
                    win.title = model.localizedString("AbubTranslate Settings")
                }
            }
        }
    }

    private func themePicker(width: ClosedRange<CGFloat>?) -> some View {
        VStack(alignment: .leading, spacing: DSTokens.xs) {
            Text("Theme").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Theme", selection: $appearanceMode) {
                Text("Automatic").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .modifier(OptionalWidthRange(range: width))
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: appearanceMode) { _, _ in
                model.applyAppearance()
            }
        }
    }

    private func engineActivitySubtitle(engine: EngineMode) -> LocalizedStringKey {
        guard let lastName = model.lastProviderName, model.lastUsedCloud else {
            return "\(model.targetAvailableCodes.count) languages"
        }
        let primaryName = engine.primaryProviderName
        if let primaryName, primaryName == lastName {
            return "Active: \(lastName)"
        }
        // Совпадает с основным именем режима — значит реально сработал он,
        // иначе это откат на запасной провайдер внутри той же цепочки.
        return "Fallback: \(lastName)"
    }

    private func engineIcon(for mode: EngineMode) -> String {
        switch mode {
        case .appleOnly, .appleMyMemory: return "apple.logo"
        case .hfCloud: return "cloud"
        }
    }

    /// LocalizedStringKey, а не String — иначе Text(String) выводится дословно
    /// мимо локализации. cardHeader ниже уже чинили от этой же ошибки,
    /// summaryCard тогда пропустили: обе сводные карточки оставались
    /// англоязычными на русской системе.
    private func summaryCard(overline: LocalizedStringKey, title: LocalizedStringKey, subtitle: LocalizedStringKey, icon: String) -> some View {
        HStack(alignment: .top, spacing: DSTokens.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(overline).overlineStyle()
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(DSTokens.md)
        .background(
            RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSTokens.radiusCard)
                .stroke(DSTokens.Colors.border, lineWidth: 0.5)
        )
        .shadow(color: DSTokens.Colors.shadowSoft.opacity(0.12), radius: 12, x: 0, y: 4)
    }

    // MARK: - Lanes — primary + supporting

    private var lanes: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DSTokens.lgPlus) {
                VStack(spacing: DSTokens.lgPlus) {
                    languagesCard
                    shortcutsCard
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(spacing: DSTokens.lgPlus) {
                    engineCard
                    contextualCard
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(spacing: DSTokens.lgPlus) {
                languagesCard
                engineCard
                contextualCard
                shortcutsCard
            }
        }
    }

    @ViewBuilder
    private var contextualCard: some View {
        if engineMode == EngineMode.appleMyMemory.rawValue {
            myMemoryCard
        } else if engineMode == EngineMode.hfCloud.rawValue {
            hfCard
        }
    }

    // MARK: - Cards

    private var languagesCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Languages", title: "Target & source", icon: "globe", description: "Source is detected automatically unless fixed.")

            Grid(alignment: .leading, horizontalSpacing: DSTokens.md, verticalSpacing: DSTokens.sm) {
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Translate into").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Picker("", selection: targetBinding) {
                            ForEach(targetOptions(for: model.targetLanguageCode), id: \.self) { code in
                                Text(model.displayName(for: code)).tag(code)
                            }
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source language").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Picker("", selection: $sourceLanguage) {
                            Text("Auto-detect").tag("auto")
                            ForEach(sourceOptions, id: \.self) { code in
                                Text(model.displayName(for: code)).tag(code)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }

            Divider().opacity(0.5)
            let count = model.targetAvailableCodes.count
            Text("\(count) languages available in the current engine.")
                .footnoteMuted()
        }
        .cardSurface()
    }

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Engine", title: "Translation engine", icon: "cpu", description: nil)

            // Черновик: contextualCard ниже следует за ним сразу (чтобы можно
            // было настроить поля нового режима до сохранения), а вот сам
            // model.engineMode меняется только в saveCloudDraft().
            Picker("Engine", selection: $engineMode) {
                ForEach(EngineMode.pickerCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            // mode.description уже даёт одну сухую строку — второй, более
            // длинный пересказ того же самого был чистым дублированием
            // (и вдобавок устарел: там всё ещё говорилось, что HuggingFace
            // работает без ключа).
            if let mode = EngineMode(rawValue: engineMode) ?? EngineMode.migrated(from: engineMode) {
                Text(mode.description)
                    .footnoteMuted()
            }
        }
        .cardSurface()
    }

    private var myMemoryCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Cloud", title: "MyMemory", icon: "envelope", description: nil)
            TextField("Email", text: $cloudEmail, prompt: Text("optional"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            Text("No key needed. 5k words/day, 50k with email.")
                .footnoteMuted()
        }
        .cardSurface()
    }

    private func providerLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var hfCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Cloud", title: "HuggingFace", icon: "cloud", description: nil)

            SecureField("HuggingFace token", text: $hfToken, prompt: Text("hf_…"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            Text("Anonymous access is blocked. Get one at huggingface.co/settings/tokens")
                .footnoteMuted()

            Divider().opacity(0.5)

            // Автоматический запасной вариант — не часть выбора пользователя,
            // поэтому оформлен отдельным блоком, а не второй колонкой рядом
            // с HuggingFace: без LibreTranslate тут больше не пара, а один
            // провайдер плюс его фолбэк.
            VStack(alignment: .leading, spacing: DSTokens.xs) {
                providerLabel("MyMemory — fallback")
                TextField("Email", text: $cloudEmail, prompt: Text("optional"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                Text("Automatic fallback if HuggingFace has no token or fails.")
                    .footnoteMuted()
            }
        }
        .cardSurface()
    }

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Shortcuts", title: "Keyboard", icon: "keyboard", description: nil)

            VStack(alignment: .leading, spacing: DSTokens.sm) {
                HotkeyRecorder(title: "Translate:", slot: .translate) { _ in
                    model.applyHotKey(.translate)
                }
                HotkeyRecorder(title: "Speak translation:", slot: .speak) { _ in
                    model.applyHotKey(.speak)
                }
            }

            Text("Any keyboard layout. Uses the current selection, or the clipboard.")
                .footnoteMuted()

            if model.needsAccessibilityPermission {
                accessibilityNotice
            }
        }
        .cardSurface()
    }

    private var systemCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "System", title: "Interface & system", icon: "paintbrush", description: nil)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DSTokens.xl) {
                    interfaceLanguagePicker(width: 220...300)
                    themePicker(width: 180...260)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: DSTokens.md) {
                    interfaceLanguagePicker(width: nil)
                    themePicker(width: nil)
                }
            }
            HStack(alignment: .top, spacing: DSTokens.xl) {
                VStack(alignment: .leading, spacing: DSTokens.xs) {
                    Text("Startup").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .font(.system(size: 13, weight: .medium))
                        .onChange(of: launchAtLogin) { _, newValue in
                            model.setLaunchAtLogin(newValue)
                        }
                        .tint(.accentColor)
                }
                Spacer(minLength: 0)
            }
            Text("Auto follows the system language.")
                .footnoteMuted()
        }
        .cardSurface()
    }

    // MARK: - Helpers

    /// LocalizedStringKey, а не String: Text(String) выводится дословно и
    /// мимо локализации — из-за этого шапки карточек оставались английскими.
    private func cardHeader(
        overline: LocalizedStringKey,
        title: LocalizedStringKey,
        icon: String,
        description: LocalizedStringKey?
    ) -> some View {
        VStack(alignment: .leading, spacing: DSTokens.xs) {
            HStack(spacing: DSTokens.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(overline)
                    .overlineStyle()
            }
            Text(title)
                .sectionTitleStyle()
            if let description {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceOptions: [String] {
        var codes = model.sourceAvailableCodes
        if let src = model.sourceLanguageCode, !codes.contains(src) {
            codes.append(src)
        }
        return codes.sorted { model.displayName(for: $0) < model.displayName(for: $1) }
    }

    private func targetOptions(for current: String) -> [String] {
        var codes = model.targetAvailableCodes
        if !codes.contains(current) {
            codes.append(current)
        }
        return codes.sorted { model.displayName(for: $0) < model.displayName(for: $1) }
    }

    private var accessibilityNotice: some View {
        VStack(alignment: .leading, spacing: DSTokens.sm) {
            Label(
                String(localized: "Translating the selection needs Accessibility access"),
                systemImage: "hand.raised.fill"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)

            Button("Open System Settings…") {
                model.requestAccessibilityPermission()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(DSTokens.md)
        .background(
            RoundedRectangle(cornerRadius: DSTokens.radiusControl)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSTokens.radiusControl)
                .stroke(Color.orange.opacity(0.18), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var targetBinding: Binding<String> {
        Binding(
            get: { model.targetLanguageCode },
            set: { model.retarget(to: Locale.Language(identifier: $0)) }
        )
    }

    private func languageBinding(_ keyPath: ReferenceWritableKeyPath<AppModel, String>) -> Binding<String> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0 }
        )
    }
}
