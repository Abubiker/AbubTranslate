import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @State private var launchAtLogin = false
    // Движок и ключи облачных движков — единственные поля в этом экране,
    // которые НЕ применяются на лету: смена движка посреди набора ключа
    // гоняла бы перевод по недописанным данным. Черновик живёт здесь
    // и уходит в модель только по нажатию «Сохранить».
    @State private var cloudEmail: String = ""
    @State private var azureKey: String = ""
    @State private var azureRegion: String = ""
    @State private var googleKey: String = ""
    @State private var deepLKey: String = ""
    @State private var openAIBaseURL: String = ""
    @State private var openAIKey: String = ""
    @State private var openAIModel: String = ""
    @State private var engineMode: String = "apple"
    // Снимок последнего сохранённого состояния — сравнение hasCloudDraftChanges
    // идёт против ЭТИХ @State, не против model.*. model.engineMode/
    // cloudContactEmail и т.п. — вычисляемые свойства поверх
    // UserDefaults/Keychain, @Observable их не отслеживает: запись в них не
    // помечает вьюху грязной. Если единственное реальное изменение — почта,
    // а движок остался тем же (String присвоение самому себе SwiftUI не
    // считает изменением), вьюха не перерисовывалась вообще — и полоса
    // «Сохранить» висела вечно, хотя запись в UserDefaults уже прошла.
    @State private var savedEngineMode: String = "apple"
    @State private var savedCloudEmail: String = ""
    @State private var savedAzureKey: String = ""
    @State private var savedAzureRegion: String = ""
    @State private var savedGoogleKey: String = ""
    @State private var savedDeepLKey: String = ""
    @State private var savedOpenAIBaseURL: String = ""
    @State private var savedOpenAIKey: String = ""
    @State private var savedOpenAIModel: String = ""
    @State private var sourceLanguage: String = "auto"
    @State private var appLocaleRaw: String = "en"
    @State private var deepLUsageText: String?
    @State private var deepLUsageLoading = false
    @State private var openAICheckText: String?
    @State private var openAICheckLoading = false
    @State private var openAICheckSuccess = false

    var body: some View {
        ScrollView {
            // Один вертикальный поток, порядок фиксированный: движок решает,
            // какие языки и облачные поля вообще актуальны, поэтому он
            // всегда первый — колонки вразнобой раньше не давали такой
            // гарантии порядка чтения.
            // Зазор между карточками и внешние поля уменьшены — почти
            // слитный блок вместо просторных воздушных промежутков, но
            // разделение всё ещё читается (не 0).
            VStack(alignment: .leading, spacing: DSTokens.md) {
                pageHeader
                if hasCloudDraftChanges {
                    unsavedCloudBar
                }
                engineCard
                languagesCard
                contextualCard
                shortcutsCard
                systemCard
            }
            .padding(DSTokens.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 680, minHeight: 640, idealHeight: 780, maxHeight: 900)
        .background {
            if #available(macOS 26.0, *) {
                SettingsBackground()
            } else {
                Color(NSColor.windowBackgroundColor)
            }
        }
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
        cloudEmail = model.cloudContactEmail
        azureKey = model.azureKey ?? ""
        azureRegion = model.azureRegion ?? ""
        googleKey = model.googleKey ?? ""
        deepLKey = model.deepLKey ?? ""
        openAIBaseURL = model.openAIBaseURL ?? ""
        openAIKey = model.openAIKey ?? ""
        openAIModel = model.openAIModel ?? ""
        savedEngineMode = engineMode
        savedCloudEmail = cloudEmail
        savedAzureKey = azureKey
        savedAzureRegion = azureRegion
        savedGoogleKey = googleKey
        savedDeepLKey = deepLKey
        savedOpenAIBaseURL = openAIBaseURL
        savedOpenAIKey = openAIKey
        savedOpenAIModel = openAIModel
    }

    private var hasCloudDraftChanges: Bool {
        engineMode != savedEngineMode
            || cloudEmail != savedCloudEmail
            || azureKey != savedAzureKey
            || azureRegion != savedAzureRegion
            || googleKey != savedGoogleKey
            || deepLKey != savedDeepLKey
            || openAIBaseURL != savedOpenAIBaseURL
            || openAIKey != savedOpenAIKey
            || openAIModel != savedOpenAIModel
    }

    private func saveCloudDraft() {
        if let mode = EngineMode(rawValue: engineMode) ?? EngineMode.migrated(from: engineMode) {
            model.engineMode = mode
            engineMode = mode.rawValue
        }
        model.cloudContactEmail = cloudEmail
        model.azureKey = azureKey
        model.azureRegion = azureRegion
        model.googleKey = googleKey
        model.deepLKey = deepLKey
        model.openAIBaseURL = openAIBaseURL
        model.openAIKey = openAIKey
        model.openAIModel = openAIModel
        savedEngineMode = engineMode
        savedCloudEmail = cloudEmail
        savedAzureKey = azureKey
        savedAzureRegion = azureRegion
        savedGoogleKey = googleKey
        savedDeepLKey = deepLKey
        savedOpenAIBaseURL = openAIBaseURL
        savedOpenAIKey = openAIKey
        savedOpenAIModel = openAIModel
    }

    private func checkDeepLUsage() async {
        deepLUsageLoading = true
        defer { deepLUsageLoading = false }
        do {
            let (count, limit) = try await DeepLProvider().checkUsage()
            deepLUsageText = model.localizedString("Used %lld of %lld characters.", count, limit)
        } catch {
            deepLUsageText = error.localizedDescription
        }
    }

    private func checkOpenAIConnection() async {
        openAICheckLoading = true
        defer { openAICheckLoading = false }
        do {
            let (code, _) = try await OpenAICompatibleProvider().checkConnection()
            openAICheckText = "200 success — \(code)"
            openAICheckSuccess = true
        } catch {
            // показать код + текст ошибки
            openAICheckText = error.localizedDescription
            openAICheckSuccess = false
        }
    }

    // MARK: - Page header — отвечает "what is active"

    private var pageHeader: some View {
        Text("Settings")
            .pageTitleStyle()
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

    /// Что реально перевело последний раз — раньше жило в отдельной сводной
    /// плашке над карточками, теперь одна строка внутри engineCard: та же
    /// правда (движок мог тихо откатиться на MyMemory), без дублирующего
    /// блока сверху.
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

    @ViewBuilder
    private var contextualCard: some View {
        if engineMode == EngineMode.appleMyMemory.rawValue {
            myMemoryCard
        } else if engineMode == EngineMode.azureCloud.rawValue {
            azureCard
        } else if engineMode == EngineMode.googleCloud.rawValue {
            googleCard
        } else if engineMode == EngineMode.deepLCloud.rawValue {
            deepLCard
        } else if engineMode == EngineMode.openAICompatible.rawValue {
            openAICard
        }
    }

    // MARK: - Cards

    private var languagesCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Languages", title: nil, icon: "globe", description: "Source is detected automatically unless fixed.")

            Grid(alignment: .leading, horizontalSpacing: DSTokens.md, verticalSpacing: DSTokens.sm) {
                GridRow {
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Translate into").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Picker("", selection: targetBinding) {
                            ForEach(targetOptions(for: model.targetLanguageCode), id: \.self) { code in
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
            cardHeader(overline: "Engine", title: nil, icon: "cpu", description: nil)

            // Черновик: contextualCard ниже следует за ним сразу (чтобы можно
            // было настроить поля нового режима до сохранения), а вот сам
            // model.engineMode меняется только в saveCloudDraft().
            Picker("Engine", selection: $engineMode) {
                ForEach(EngineMode.pickerCases, id: \.rawValue) { mode in
                    Text(model.localizedString(mode.displayNameKey)).tag(mode.rawValue)
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
                Text(model.localizedString(mode.descriptionKey))
                    .footnoteMuted()
            }

            // Реально применённый движок (model.engineMode), не черновик из
            // Picker'а выше: показывает, что сработало в последний раз —
            // облачный движок без ключа падает и цепочка тихо уходит в
            // MyMemory, эта строка не даёт этому остаться незамеченным.
            Text(engineActivitySubtitle(engine: model.engineMode))
                .font(.system(size: DSTokens.metaSize, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .cardSurface()
    }

    private var myMemoryCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Cloud", title: "MyMemory", icon: "envelope", description: nil)
            TextField("Email", text: $cloudEmail, prompt: Text("optional"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            Text("No key needed. 5k characters/day, 50k with any email — no signup.")
                .footnoteMuted()
        }
        .cardSurface()
    }

    private func providerLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var azureCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Cloud", title: "Azure Translator", icon: "cloud", description: nil)

            SecureField("Azure key", text: $azureKey, prompt: Text("subscription key"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            TextField("Azure region", text: $azureRegion, prompt: Text("e.g. westeurope — optional for global resources"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: DSTokens.xs) {
                providerLabel("MyMemory — fallback")
                TextField("Email", text: $cloudEmail, prompt: Text("optional"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                Text("Automatic fallback if Azure has no key or fails.")
                    .footnoteMuted()
            }
        }
        .cardSurface()
    }

    private var googleCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Cloud", title: "Google Translate", icon: "cloud", description: nil)

            SecureField("Google key", text: $googleKey, prompt: Text("API key"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: DSTokens.xs) {
                providerLabel("MyMemory — fallback")
                TextField("Email", text: $cloudEmail, prompt: Text("optional"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                Text("Automatic fallback if Google has no key or fails.")
                    .footnoteMuted()
            }
        }
        .cardSurface()
    }

    private var deepLCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Cloud", title: "DeepL", icon: "cloud", description: nil)

            SecureField("DeepL key", text: $deepLKey, prompt: Text("API key"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            HStack(spacing: DSTokens.sm) {
                Button {
                    Task { await checkDeepLUsage() }
                } label: {
                    if deepLUsageLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check usage")
                    }
                }
                .disabled(deepLUsageLoading || savedDeepLKey.isEmpty)
                if let deepLUsageText {
                    Text(deepLUsageText).footnoteMuted()
                }
            }
            // Проверяет СОХРАНЁННЫЙ ключ (Keychain через DeepLProvider), не
            // черновик в поле выше — как и перевод, использует только то,
            // что реально прошло через «Сохранить».
            if savedDeepLKey.isEmpty {
                Text("Save a key first to check usage.")
                    .footnoteMuted()
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: DSTokens.xs) {
                providerLabel("MyMemory — fallback")
                TextField("Email", text: $cloudEmail, prompt: Text("optional"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                Text("Automatic fallback if DeepL has no key or fails.")
                    .footnoteMuted()
            }
        }
        .cardSurface()
    }

    private var openAICard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Cloud", title: "OpenAI-compatible", icon: "cloud", description: nil)

            TextField("Base URL", text: $openAIBaseURL, prompt: Text("https://api.openai.com/v1"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .autocorrectionDisabled()
                .textContentType(.URL)

            SecureField("API key", text: $openAIKey, prompt: Text("sk-..."))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            TextField("Model", text: $openAIModel, prompt: Text("gpt-4o-mini"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()

            HStack(spacing: DSTokens.sm) {
                Button {
                    Task { await checkOpenAIConnection() }
                } label: {
                    if openAICheckLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(openAICheckLoading || savedOpenAIBaseURL.isEmpty || savedOpenAIKey.isEmpty || savedOpenAIModel.isEmpty)
                if let openAICheckText {
                    Text(openAICheckText)
                        .font(.system(size: 12))
                        .foregroundStyle(openAICheckSuccess ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }
            }
            if savedOpenAIBaseURL.isEmpty || savedOpenAIKey.isEmpty || savedOpenAIModel.isEmpty {
                Text("Save base URL, key and model first to check connection.")
                    .footnoteMuted()
            } else {
                Text("Test sends Hello en→ru with fixed prompt. Success is 200.")
                    .footnoteMuted()
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: DSTokens.xs) {
                providerLabel("MyMemory — fallback")
                TextField("Email", text: $cloudEmail, prompt: Text("optional"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                Text("Automatic fallback if OpenAI has no key or fails.")
                    .footnoteMuted()
            }
        }
        .cardSurface()
    }

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "Shortcuts", title: nil, icon: "keyboard", description: nil)

            VStack(alignment: .leading, spacing: DSTokens.sm) {
                HotkeyRecorder(title: "Translate:", slot: .translate) { _ in
                    model.applyHotKey(.translate)
                }
                HotkeyRecorder(title: "Speak translation:", slot: .speak) { _ in
                    model.applyHotKey(.speak)
                }
            }

            if model.needsAccessibilityPermission {
                accessibilityNotice
            }
        }
        .cardSurface()
    }

    /// Строчный список в стиле System Settings.app: подпись слева, control
    /// справа, тонкий разделитель между пунктами — вместо прежней плотной
    /// карточки с сегментированными контролами вперемешку.
    private var systemCard: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            cardHeader(overline: "System", title: nil, icon: "paintbrush", description: nil)

            VStack(spacing: 0) {
                settingsRow(label: "Theme") {
                    Picker("Theme", selection: $appearanceMode) {
                        Text("Automatic").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: appearanceMode) { _, _ in
                        model.applyAppearance()
                    }
                }
                Divider().opacity(0.5)
                settingsRow(label: "Interface language") {
                    Picker("Interface language", selection: $appLocaleRaw) {
                        ForEach(AppModel.InterfaceLanguage.allCases, id: \.rawValue) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: appLocaleRaw) { _, newValue in
                        model.appLocaleRaw = newValue
                        if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "AbubTranslateSettings" }) {
                            win.title = model.localizedString("AbubTranslate Settings")
                        }
                    }
                }
                Divider().opacity(0.5)
                settingsRow(label: "Launch at login") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.accentColor)
                        .onChange(of: launchAtLogin) { _, newValue in
                            model.setLaunchAtLogin(newValue)
                        }
                }
            }
        }
        .cardSurface()
    }

    /// Один пункт строчного списка: подпись слева, control справа выровнен
    /// по правому краю — тот же паттерн, что в системных Настройках macOS.
    private func settingsRow<Content: View>(
        label: LocalizedStringKey,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: DSTokens.labelSize, weight: .regular))
            Spacer(minLength: DSTokens.lg)
            control()
        }
        .padding(.vertical, DSTokens.xs)
    }

    // MARK: - Helpers

    /// LocalizedStringKey, а не String: Text(String) выводится дословно и
    /// мимо локализации — из-за этого шапки карточек оставались английскими.
    ///
    /// title опционален: у части карточек (движок/языки/хоткеи/система)
    /// он почти дословно повторял overline — чистый дубль, убран. Там, где
    /// title называет что-то конкретное (провайдер облака — DeepL/Azure/
    /// Google/MyMemory), передаём его как раньше.
    private func cardHeader(
        overline: LocalizedStringKey,
        title: LocalizedStringKey?,
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
            if let title {
                Text(title)
                    .sectionTitleStyle()
            }
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
        return codes.sorted { model.englishDisplayName(for: $0) < model.englishDisplayName(for: $1) }
    }

    private func targetOptions(for current: String) -> [String] {
        var codes = model.targetAvailableCodes
        if !codes.contains(current) {
            codes.append(current)
        }
        return codes.sorted { model.englishDisplayName(for: $0) < model.englishDisplayName(for: $1) }
    }

    private var accessibilityNotice: some View {
        VStack(alignment: .leading, spacing: DSTokens.sm) {
            Label(
                model.localizedString("Translating the selection needs Accessibility access"),
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
