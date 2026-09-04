import SwiftUI

/// Три живых шага первого запуска: язык цели → доступ → настоящее
/// выделение хоткеем. Отличие от «слайдов про фичи» — продукт сам
/// проверяет, что шаг выполнен (доступ выдан, выделение прочитано),
/// и последний шаг засчитывается только по настоящему успеху
/// (onboardingSelectionOK ставится из пути хоткея).
struct OnboardingView: View {
    var onComplete: () -> Void

    @Environment(AppModel.self) private var model
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DSTokens.xl) {
            HStack(spacing: DSTokens.xs) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == step ? 22 : 8, height: 4)
                }
                Spacer()
                Button("Skip") { onComplete() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            switch step {
            case 0: pairStep
            case 1: accessStep
            default: tryStep
            }

            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(step == 2 ? "Done" : "Continue") {
                    if step == 2 { onComplete() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DSTokens.xl)
        .frame(width: 420)
        .environment(\.locale, model.effectiveLocale)
        .preferredColorScheme(model.preferredColorScheme)
    }

    @ViewBuilder private var pairStep: some View {
        @Bindable var model = model
        // Автовыбор есть всегда — язык системы уже стоит в targetLanguageCode.
        // Но узкий список отсечкой prefix() терял текущий язык (на
        // google-списке «Русский» за 60-й позицией) — Picker рисовал пустое
        // поле, и автовыбор выглядел отсутствием выбора. Вставляем текущий.
        let current = model.targetLanguageCode
        let codes = model.targetAvailableCodes
        let list = Array(codes.prefix(80))
        let options = list.contains(current) ? list : [current] + list
        VStack(alignment: .leading, spacing: DSTokens.md) {
            Text("Translate into")
                .font(.system(size: 22, weight: .semibold))
            Text("Pick the language you read fastest. It is changeable in Settings anytime.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Picker("", selection: $model.targetLanguageCode) {
                ForEach(options, id: \.self) { code in
                    Text(model.displayName(for: code)).tag(code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var accessStep: some View {
        VStack(alignment: .leading, spacing: DSTokens.md) {
            Text("Accessibility access")
                .font(.system(size: 22, weight: .semibold))
            Text("Lets AbubTranslate read the selected text without touching your clipboard. Translation also works without it — via clipboard fallback.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Label {
                Text(model.needsAccessibilityPermission ? "Not granted yet" : "Granted")
            } icon: {
                Image(systemName: model.needsAccessibilityPermission
                      ? "circle"
                      : "checkmark.circle.fill")
                    .foregroundStyle(model.needsAccessibilityPermission ? Color.secondary : Color.green)
            }
            .font(.system(size: 13, weight: .medium))
            Button("Open System Settings…") {
                model.requestAccessibilityPermission()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var tryStep: some View {
        let hotkey = HotkeyBinding.load(slot: .translate).displayString
        return VStack(alignment: .leading, spacing: DSTokens.md) {
            Text("Try it right now")
                .font(.system(size: 22, weight: .semibold))
            Text("Select any word in any window — a browser, Notes, a chat — and press \(hotkey). AbubTranslate shows the panel itself.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if model.onboardingSelectionOK {
                Label("It works. Translation done.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Label {
                    Text("Waiting for your first selection…")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
        }
    }
}
