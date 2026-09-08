import Foundation

/// Сравнение версий релизов: "1.1.3", "v1.1.3", "1.1.3-beta2".
///
/// Отдельным файлом и без зависимостей намеренно: так `Tools/SelfCheck.swift`
/// собирает его одним `swiftc` и гоняет на каждой сборке. В `UpdateChecker`
/// эта логика была заперта за `import AppKit` и `appLocalizedString`, то есть
/// проверялась только вручную по флагу `--update-selftest`, который пишет в
/// лог и ничего не роняет.
enum VersionCompare {
    /// `true`, если `candidate` строго новее `version`.
    static func isNewer(candidate: String, than version: String) -> Bool {
        let a = parts(candidate)
        let b = parts(version)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Числовые компоненты релизной части.
    ///
    /// Хвост пре-релиза отрезается целиком: прежняя версия резала строку по
    /// любому нецифровому символу, поэтому "1.1.3-beta2" превращалось в
    /// [1,1,3,2] и оказывалось новее [1,1,3] — бета предлагалась как
    /// обновление поверх релиза, из которого вышла.
    ///
    /// Обратный случай ("1.1.3" поверх "1.1.3-beta2") даёт равенство, то есть
    /// «не новее». Полный порядок пре-релизов по SemVer тут не нужен:
    /// CFBundleShortVersionString в этом проекте всегда чистый "1.1.3", беты
    /// на руках у пользователей не бывает, а важная сторона — не подсовывать
    /// бету поверх релиза — закрыта.
    private static func parts(_ s: String) -> [Int] {
        let withoutPrefix = s.drop { !$0.isNumber }          // "v1.1.3" → "1.1.3"
        let release = withoutPrefix.prefix { $0.isNumber || $0 == "." }
        return release.split(separator: ".").compactMap { Int($0) }
    }
}
