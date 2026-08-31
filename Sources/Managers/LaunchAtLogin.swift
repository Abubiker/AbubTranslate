import Foundation
import ServiceManagement

/// Автозапуск при входе. Вынесено из точки входа приложения, чтобы
/// SettingsView можно было собрать и проверить без @main.
extension AppModel {
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "launchAtLogin")
            } else {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(false, forKey: "launchAtLogin")
            }
        } catch {
            NSLog("AbubTranslate launch-at-login error: \(error)")
            // Не пишем в UserDefaults при ошибке — иначе UI покажет включено, а система выключена
            // Синхронизируем с реальным статусом
            let actual = SMAppService.mainApp.status == .enabled
            UserDefaults.standard.set(actual, forKey: "launchAtLogin")
        }
    }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
