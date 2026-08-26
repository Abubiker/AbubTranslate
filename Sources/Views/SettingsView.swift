import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Languages") {
                Picker("First language:", selection: languageBinding(\.languageCodeA)) {
                    languageOptions
                }
                .pickerStyle(.menu)

                Picker("Second language:", selection: languageBinding(\.languageCodeB)) {
                    languageOptions
                }
                .pickerStyle(.menu)

                Text("The source language is detected automatically. Text in one of these two is translated into the other. A third language goes into whichever of the two matches your system language.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                HotkeyRecorder(title: "Translate:", slot: .translate) { _ in
                    model.applyHotKey(.translate)
                }
                HotkeyRecorder(title: "Speak translation:", slot: .speak) { _ in
                    model.applyHotKey(.speak)
                }
                Text("Shortcuts work in any keyboard layout and ignore Caps Lock. Translation uses the current selection, falling back to the clipboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if model.needsAccessibilityPermission {
                    accessibilityNotice
                }
            }

            Section("Cloud fallback") {
                Toggle(
                    "Use \(model.cloudProviderName) when Apple Translation cannot handle the pair",
                    isOn: cloudBinding
                )

                TextField("Email for a higher quota (optional):", text: emailBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.cloudFallbackEnabled)

                Text("Apple Translation supports a limited set of languages. For the rest the text is sent to an online service — it leaves your Mac. Everything else stays on device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Theme:", selection: $appearanceMode) {
                    Text("Automatic").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceMode) { _, _ in
                    model.applyAppearance()
                }
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        model.setLaunchAtLogin(newValue)
                    }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            launchAtLogin = model.isLaunchAtLoginEnabled
        }
    }

    private var accessibilityNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                String(localized: "Translating the selection needs Accessibility access"),
                systemImage: "hand.raised"
            )
            .font(.footnote)
            .foregroundStyle(.orange)

            Button("Open System Settings…") {
                model.requestAccessibilityPermission()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }

    private var cloudBinding: Binding<Bool> {
        Binding(get: { model.cloudFallbackEnabled }, set: { model.cloudFallbackEnabled = $0 })
    }

    private var emailBinding: Binding<String> {
        Binding(get: { model.cloudContactEmail }, set: { model.cloudContactEmail = $0 })
    }

    private var languageOptions: some View {
        ForEach(model.availableLanguageCodes, id: \.self) { code in
            Text(model.displayName(for: code)).tag(code)
        }
    }

    /// AppModel хранит языки в UserDefaults, а не в @AppStorage,
    /// поэтому Picker'ам нужен явный мост.
    private func languageBinding(_ keyPath: ReferenceWritableKeyPath<AppModel, String>) -> Binding<String> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0 }
        )
    }
}
