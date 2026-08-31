import AppKit
import CryptoKit
import Foundation

/// Проверка новых релизов на GitHub и полный самоаппдейт: скачать dmg,
/// сверить sha256, примонтировать, подменить бандл в /Applications,
/// перезапуститься.
///
/// Решения, зафиксированные намеренно:
/// — sha256 берётся из самого ответа GitHub API (поле `digest` ассета):
///   подмену скачанного файла прокси видно ещё до распаковки.
/// — свап бандла — два rename внутри одного тома (/Applications), а не
///   rm+copy: rename над работающим бинарником в macOS разрешён, поэтому
///   приложение может заменить само себя; при любой ошибке после первого
///   rename старый бандл возвращается на место.
/// — из внешних утилит зовутся только hdiutil/sh/open — системные, входящие
///   в macOS. `codesign` не зовём: на машинах без Command Line Tools он
///   триггерит инсталл-диалог Apple.
@MainActor
@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading(version: String)
        case installing
        case failed(String)
    }

    static let shared = UpdateChecker()

    private(set) var status: Status = .idle
    /// Прогресс загрузки 0...1 — публикуется дельтами ≥1%, чтобы не
    /// дёргать менюбар на каждый 64КБ-чанк.
    private(set) var downloadProgress: Double = 0

    nonisolated static let repo = "Abubiker/AbubTranslate"
    nonisolated static let installDir = "/Applications"
    private nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60
    private nonisolated static let lastCheckKey = "update.lastCheck"
    private nonisolated static let availableKey = "update.availableVersion"
    private nonisolated static let fromVersionKey = "update.fromVersion"

    struct ReleaseInfo: Sendable {
        let version: String
        let downloadURL: URL
        let sha256: String
    }

    private struct ReleaseDTO: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let digest: String?
        }
        let tag_name: String
        let assets: [Asset]
    }

    enum UpdateError: LocalizedError {
        case http(Int)
        case noAsset
        case mismatch
        case mount
        case badPackage
        case notInApplications

        var errorDescription: String? {
            switch self {
            case .http(let code):
                return appLocalizedString("The update server responded with status %ld", code)
            case .noAsset:
                return appLocalizedString("No downloadable release was found")
            case .mismatch:
                return appLocalizedString("Update download failed verification")
            case .mount:
                return appLocalizedString("Could not mount the update package")
            case .badPackage:
                return appLocalizedString("Update package is malformed")
            case .notInApplications:
                return appLocalizedString("Run AbubTranslate from /Applications to update")
            }
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var cachedAvailableVersion: String? {
        UserDefaults.standard.string(forKey: Self.availableKey)
    }

    var lastCheckDate: Date? {
        let raw = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    private var pending: ReleaseInfo?

    /// Коллбек «нашли обновление» после сетевой проверки — подставляет
    /// AppDelegate для баннера/алерта. Из UI-слоя класс остаётся чистым.
    var onAvailable: (@MainActor (String) -> Void)?

    /// Вызывается со старта приложения: восстанавливает найденное ранее
    /// обновление и запускает сетевую проверку не чаще раза в сутки.
    func checkOncePerDay() {
        if let cached = cachedAvailableVersion,
           Self.isNewer(candidate: cached, than: currentVersion) {
            status = .available(version: cached)
        }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard last == 0 || Date().timeIntervalSince1970 - last >= Self.checkInterval else { return }
        Task { await check() }
    }

    @discardableResult
    func check() async -> Status {
        status = .checking
        do {
            let dto = try await Self.fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            let info = try Self.parse(dto)
            if Self.isNewer(candidate: info.version, than: currentVersion) {
                pending = info
                status = .available(version: info.version)
                UserDefaults.standard.set(info.version, forKey: Self.availableKey)
                onAvailable?(info.version)
            } else {
                pending = nil
                status = .upToDate
                UserDefaults.standard.removeObject(forKey: Self.availableKey)
            }
        } catch {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            status = .failed(error.localizedDescription)
        }
        return status
    }

    /// Полный цикл: загрузка → сверка хэша → монтаж → свап → перезапуск.
    /// При успехе приложение завершается само; при любой вине — статус failed.
    func downloadAndInstall() async {
        // Кэш доступной версии переживает рестарт, а ссылки на релиз — нет:
        // перепрашиваем API, чтобы не ставить по кэшу несуществующий адрес.
        if pending == nil { await check() }
        guard let info = pending else {
            status = .failed(UpdateError.noAsset.localizedDescription)
            return
        }
        guard Bundle.main.bundleURL.deletingLastPathComponent().path == Self.installDir else {
            status = .failed(UpdateError.notInApplications.localizedDescription)
            return
        }
        status = .downloading(version: info.version)
        downloadProgress = 0
        do {
            let dmg = try await Self.download(from: info.downloadURL) { value in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = value
                }
            }
            guard try Self.sha256Hex(of: dmg) == info.sha256 else {
                try? FileManager.default.removeItem(at: dmg)
                throw UpdateError.mismatch
            }
            status = .installing
            let old = try await Self.install(dmg: dmg, info: info)
            let current = URL(fileURLWithPath: "\(Self.installDir)/AbubTranslate.app")
            // Метка «откуда обновились» пишется только после успешного свапа:
            // между записью и перезапуском окно в доли секунды, а до свапа
            // ложный флаг не появится вообще.
            UserDefaults.standard.set(currentVersion, forKey: Self.fromVersionKey)
            Self.scheduleRestart(bundlePath: current.path, cleanupPaths: [old.path])
            NSApp.terminate(nil)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Следующий после апдейта запуск: «из какой версии пришли», разово.
    func takeCompletedUpdate() -> String? {
        guard let from = UserDefaults.standard.string(forKey: Self.fromVersionKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: Self.fromVersionKey)
        return from == currentVersion ? nil : from
    }

    // MARK: - Pure helpers (nonisolated — тестируются без UI)

    nonisolated static func isNewer(candidate: String, than version: String) -> Bool {
        let a = versionParts(candidate)
        let b = versionParts(version)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated static func versionParts(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    private nonisolated static func fetchLatest() async throws -> ReleaseDTO {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AbubTranslate", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.unsupportedURL) }
        guard (200...299).contains(http.statusCode) else { throw UpdateError.http(http.statusCode) }
        return try JSONDecoder().decode(ReleaseDTO.self, from: data)
    }

    private nonisolated static func parse(_ dto: ReleaseDTO) throws -> ReleaseInfo {
        let tag = dto.tag_name.hasPrefix("v") ? String(dto.tag_name.dropFirst()) : dto.tag_name
        guard let asset = dto.assets.first(where: { $0.name.hasSuffix(".dmg") }),
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              let url = URL(string: asset.browser_download_url)
        else { throw UpdateError.noAsset }
        return ReleaseInfo(version: tag, downloadURL: url, sha256: String(digest.dropFirst("sha256:".count)))
    }

    private nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func runTool(_ launch: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launch)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: UpdateError.mount)
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Загрузка с прогрессом: `URLSession.shared.download` его не отдаёт,
    /// поэтому делегатная сессия. Файл переезжает в стабильный путь до
    /// выхода из `didFinishDownloadingToURL` — иначе URLSession сама его
    /// удалит.
    nonisolated static func download(
        from url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 300
                let delegate = DownloadDelegate(continuation: cont, onProgress: onProgress)
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                delegate.session = session
                let task = session.downloadTask(with: url)
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private nonisolated final class TaskBox: @unchecked Sendable {
        var task: URLSessionDownloadTask?
    }

    private nonisolated final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let continuation: CheckedContinuation<URL, Error>
        private let onProgress: @Sendable (Double) -> Void
        weak var session: URLSession?
        private var lastPublishedPercent = -1
        private var resumed = false

        init(
            continuation: CheckedContinuation<URL, Error>,
            onProgress: @escaping @Sendable (Double) -> Void
        ) {
            self.continuation = continuation
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let percent = Int(fraction * 100)
            guard percent != lastPublishedPercent || fraction >= 1 else { return }
            lastPublishedPercent = percent
            onProgress(min(fraction, 1))
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                finish(with: .failure(UpdateError.http(http.statusCode)))
                return
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("AbubTranslate-download-\(UUID().uuidString).dmg")
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                finish(with: .success(destination))
            } catch {
                finish(with: .failure(error))
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: (any Error)?
        ) {
            guard let error else { return }
            finish(with: .failure(error))
        }

        private func finish(with result: Result<URL, Error>) {
            guard !resumed else { return }
            resumed = true
            switch result {
            case .success(let url): continuation.resume(returning: url)
            case .failure(let error): continuation.resume(throwing: error)
            }
            session?.finishTasksAndInvalidate()
        }
    }

    private nonisolated static func scheduleRestart(bundlePath: String, cleanupPaths: [String]) {
        let script = "sleep 2; /usr/bin/open \"\(bundlePath)\"; "
            + cleanupPaths.map { "rm -rf \"\($0)\";" }.joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
    }

    /// Монтирует dmg, копирует бандл в staging на том же томе, свапает
    /// двумя rename. Возвращает путь, по которому лежит старая версия,
    /// — перезапуск и его удаление делает вызывающая сторона на MainActor.
    private nonisolated static func install(dmg: URL, info: ReleaseInfo) async throws -> URL {
        let fm = FileManager.default
        let current = URL(fileURLWithPath: "\(installDir)/AbubTranslate.app")
        let mount = fm.temporaryDirectory
            .appendingPathComponent("AbubTranslate-mount-\(UUID().uuidString)", conformingTo: .directory)
        let staged = URL(fileURLWithPath: "\(installDir)/.AbubTranslate-staged-\(UUID().uuidString).app")
        let old = URL(fileURLWithPath: "\(installDir)/.AbubTranslate-old-\(UUID().uuidString).app")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        do {
            try await runTool("/usr/bin/hdiutil",
                              ["attach", "-nobrowse", "-quiet", "-mountpoint", mount.path, dmg.path])
            let sourceApp = mount.appendingPathComponent("AbubTranslate.app")
            guard fm.fileExists(atPath: sourceApp.path) else { throw UpdateError.badPackage }
            try fm.copyItem(at: sourceApp, to: staged)
            try fm.moveItem(at: current, to: old)
            do {
                try fm.moveItem(at: staged, to: current)
            } catch {
                try? fm.moveItem(at: old, to: current)
                throw error
            }
            try? fm.removeItem(at: dmg)
            try? await runTool("/usr/bin/hdiutil", ["detach", "-quiet", mount.path])
            return old
        } catch {
            try? fm.removeItem(at: staged)
            try? await runTool("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
            throw error
        }
    }

    /// Дочистка осколков прерванной установки (staged/old из упавшего
    /// процесса) — со старта приложения.
    nonisolated static func cleanStaleUpdateArtifacts() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: installDir) else { return }
        for name in items where name.hasPrefix(".AbubTranslate-") {
            try? fm.removeItem(atPath: "\(installDir)/\(name)")
        }
    }
}
