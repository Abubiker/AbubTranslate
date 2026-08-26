import Foundation
import ServiceManagement

/// Автозапуск при входе. Вынесено из точки входа приложения, чтобы
/// SettingsView можно было собрать и проверить без @main.
extension AppModel {
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("AbubTranslate launch-at-login error: \(error)")
        }
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
    }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
