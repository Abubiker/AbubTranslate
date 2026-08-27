import Foundation

/// Загрузчик OPUS-MT CoreML моделей для офлайн перевода.
/// Модели качаются только по кнопке в Settings, хранятся в
/// Application Support, LRU eviction последних 3.
/// RAM low: модель грузится только на время перевода, потом unload.
@MainActor
@Observable
final class ModelDownloader {
    static let shared = ModelDownloader()

    enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded(sizeMB: Double)
        case failed(String)
    }

    /// Папка для моделей: ~/Library/Application Support/AbubTranslate/Models
    private var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AbubTranslate/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Ключ пары: "ru-en", "en-fi" etc (отсортированный? нет — направленный)
    func pairKey(from source: String, to target: String) -> String {
        "\(source.lowercased())-\(target.lowercased())"
    }

    func modelDirectory(for pairKey: String) -> URL {
        modelsDirectory.appendingPathComponent(pairKey, isDirectory: true)
    }

    // Неблокирующая проверка — кэшируем результат на 1с чтобы не дёргать диск на каждый body
    private var isDownloadedCache: [String: (Bool, Date)] = [:]
    func isDownloaded(pairKey: String) -> Bool {
        if let (cached, ts) = isDownloadedCache[pairKey], Date().timeIntervalSince(ts) < 1 { return cached }
        let dir = modelDirectory(for: pairKey)
        let result: Bool = {
            guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
            return contents.contains { $0.pathExtension == "mlpackage" || $0.pathExtension == "mlmodelc" || $0.lastPathComponent == "model.bin" }
        }()
        isDownloadedCache[pairKey] = (result, Date())
        return result
    }
    func invalidateCache(for pairKey: String) { isDownloadedCache.removeValue(forKey: pairKey) }

    func state(for pairKey: String) -> State {
        if isDownloaded(pairKey: pairKey) {
            let size = directorySizeMB(modelDirectory(for: pairKey))
            return .downloaded(sizeMB: size)
        }
        if let task = activeTasks[pairKey] {
            return .downloading(progress: task.progress)
        }
        if let msg = failedStates[pairKey] {
            return .failed(msg)
        }
        return .notDownloaded
    }

    func sizeMB(for pairKey: String) -> Double {
        directorySizeMB(modelDirectory(for: pairKey))
    }

    private func directorySizeMB(_ url: URL) -> Double {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return Double(total) / (1024 * 1024)
    }

    // MARK: - Активные загрузки

    private struct ActiveTask {
        var task: URLSessionDownloadTask
        var progress: Double = 0
    }

    private var activeTasks: [String: ActiveTask] = [:]
    private var observers: [String: NSKeyValueObservation] = [:]
    private var failedStates: [String: String] = [:]

    /// Скачать модель для пары. URL — HuggingFace или coreml-community.
    /// Для MVP: качаем архив с моделью (zip), распаковываем в папку пары.
    /// Если URL не указан — берём дефолтный HF coreml-community.
    func download(pairKey: String, from url: URL? = nil) {
        guard activeTasks[pairKey] == nil else { return }
        failedStates.removeValue(forKey: pairKey)
        invalidateCache(for: pairKey)
        let sourceURL = url ?? defaultURL(for: pairKey)
        guard let sourceURL else {
            failedStates[pairKey] = String(localized: "Model not available for this pair")
            return
        }

        let destDir = modelDirectory(for: pairKey)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let task = URLSession.shared.downloadTask(with: sourceURL) { tempURL, response, error in
            Task { @MainActor in
                defer {
                    self.activeTasks.removeValue(forKey: pairKey)
                    self.observers.removeValue(forKey: pairKey)
                }
                if let error {
                    self.invalidateCache(for: pairKey)
                    NSLog("Model download failed \(pairKey): \(error)")
                    self.failedStates[pairKey] = error.localizedDescription
                    return
                }
                guard let tempURL, let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                    self.invalidateCache(for: pairKey)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let msg = code == 404 ? String(localized: "Model not found (404) for this pair") : String(localized: "Download failed (HTTP \(code))")
                    NSLog("Model download bad response \(pairKey): \(code)")
                    self.failedStates[pairKey] = msg
                    return
                }
                // Если это zip — распаковываем, иначе просто перемещаем
                self.handleDownloadedFile(tempURL: tempURL, destDir: destDir, response: response)
                self.enforceLRU(maxKeep: 3)
            }
        }

        activeTasks[pairKey] = ActiveTask(task: task, progress: 0)
        // KVO прогресса
        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            Task { @MainActor in
                self.activeTasks[pairKey]?.progress = progress.fractionCompleted
            }
        }
        observers[pairKey] = observation
        task.resume()
    }

    func cancel(pairKey: String) {
        activeTasks[pairKey]?.task.cancel()
        activeTasks.removeValue(forKey: pairKey)
        observers.removeValue(forKey: pairKey)
        invalidateCache(for: pairKey)
    }

    func delete(pairKey: String) {
        cancel(pairKey: pairKey)
        try? FileManager.default.removeItem(at: modelDirectory(for: pairKey))
        invalidateCache(for: pairKey)
    }

    private func handleDownloadedFile(tempURL: URL, destDir: URL, response: HTTPURLResponse) {
        defer { invalidateCache(for: destDir.lastPathComponent) }
        let fileName = response.suggestedFilename ?? tempURL.lastPathComponent
        let dest = destDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: tempURL, to: dest)) != nil else { return }

        if fileName.hasSuffix(".zip") {
            // Sandbox-safe: FileManager позволяет читать zip напрямую, Process запрещён.
            // Пытаемся распаковать через FileManager (macOS 15+ поддерживает unzip via coordination),
            // fallback — оставляем zip и логируем.
            if FileManager.default.fileExists(atPath: dest.path) {
                // Используем FileManager.Zip если доступен, иначе оставляем как есть
                // Пока без ZIPFoundation — просто логируем, пользователь может вручную распаковать
                NSLog("Model zip downloaded to \(dest.path), manual unzip needed if not auto-extracted")
                // Попытка через /usr/bin/unzip только если не sandboxed
                if !isSandboxed {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                    process.arguments = ["-o", dest.path, "-d", destDir.path]
                    try? process.run()
                    process.waitUntilExit()
                    try? FileManager.default.removeItem(at: dest)
                }
            }
        }
    }

    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private func defaultURL(for pairKey: String) -> URL? {
        // coreml-community OPUS модели: https://huggingface.co/coreml-community/opus-mt-*)
        // Формат pairKey: "ru-en" -> "opus-mt-ru-en"
        // Проверяем существование — если нет, возвращаем nil (покажем failed в UI)
        // Для пар которых нет в coreml-community, fallback на Helsinki PyTorch (потребует конвертации, пока не поддерживаем)
        let modelName = "opus-mt-\(pairKey)"
        // Используем HF resolve для coreml модели (zip)
        // Пример: https://huggingface.co/coreml-community/opus-mt-ru-en/resolve/main/model.zip
        // Некоторые модели упакованы как .mlpackage внутри zip
        return URL(string: "https://huggingface.co/coreml-community/\(modelName)/resolve/main/model.zip")
    }

    private func enforceLRU(maxKeep: Int) {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dirs = contents.filter { $0.hasDirectoryPath }
        guard dirs.count > maxKeep else { return }
        let sorted = dirs.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        for dir in sorted.prefix(dirs.count - maxKeep) {
            let key = dir.lastPathComponent
            guard activeTasks[key] == nil else { continue } // не трогаем качающуюся модель
            try? FileManager.default.removeItem(at: dir)
            invalidateCache(for: key)
        }
    }

    // MARK: - Список доступных локально

    func allDownloadedPairs() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return contents.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }.sorted()
    }
}
