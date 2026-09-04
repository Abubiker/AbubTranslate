import Foundation
import CryptoKit

/// Дисковый кэш переводов: повторное выделение того же текста (или тот же
/// OCR-скриншот меню) отдаётся мгновенно и не жрёт квоту LLM/MyMemory.
/// Ключ — движок + пара + фиксированный источник + текст: смена любого
/// входа в решение обязана промахиваться мимо кэша.
/// Хранение — файл на запись в Application Support (не UserDefaults —
/// переводы весят килобайты, plist-бомбардировка defaults не для них),
/// LRU-зачистка по mtime при переполнении бюджета.
@MainActor
enum TranslationCache {
    private static let ttl: TimeInterval = 90 * 24 * 3600
    private static let budgetBytes = 20 * 1024 * 1024
    private static let version = "v1"

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AbubTranslate/cache", isDirectory: true)
    }

    static func key(engine: EngineMode, source: String, target: String, text: String) -> String {
        let raw = "\(version)\u{1f}\(engine.rawValue)\u{1f}\(source)\u{1f}\(target)\u{1f}\(text)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ key: String) -> String? {
        let url = dir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              Date().timeIntervalSince1970 - entry.ts < ttl
        else { return nil }
        return entry.text.isEmpty ? nil : entry.text
    }

    static func store(_ key: String, _ translation: String) {
        guard !translation.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Entry(text: translation, ts: Date().timeIntervalSince1970))
            try data.write(to: dir.appendingPathComponent(key), options: .atomic)
        } catch {
            NSLog("AbubTranslate cache write failed: \(error.localizedDescription)")
        }
        pruneIfNeeded()
    }

    private struct Entry: Codable {
        let text: String
        let ts: TimeInterval
    }

    private static func pruneIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var total = 0
        var sized: [(url: URL, size: Int, mtime: Date)] = []
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            total += size
            sized.append((file, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > budgetBytes else { return }
        for item in sized.sorted(by: { $0.mtime < $1.mtime }) {
            try? fm.removeItem(at: item.url)
            total -= item.size
            if total <= budgetBytes * 3 / 4 { break }
        }
    }
}
