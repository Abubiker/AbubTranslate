import Foundation
import CoreML

/// Локальный офлайн переводчик на базе OPUS-MT CoreML.
/// Low-RAM: модель грузится только на время одного перевода, потом
/// освобождается через 60с idle (autoreleasepool + nil).
/// Если модель не скачана — бросает LocalError.notDownloaded, чтобы
/// AppModel показал кнопку "Скачать в Настройках".
@MainActor
final class LocalNeuralTranslator {
    enum LocalError: LocalizedError {
        case notDownloaded(pair: String)
        case modelLoadFailed(String)
        case translationFailed(String)
        case notSupportedPair(String)

        var errorDescription: String? {
            switch self {
            case .notDownloaded(let pair):
                return String(localized: "Local model for \(pair) is not downloaded. Open Settings to download it.")
            case .modelLoadFailed(let msg):
                return String(localized: "Failed to load local model: \(msg)")
            case .translationFailed(let msg):
                return String(localized: "Local translation failed: \(msg)")
            case .notSupportedPair(let pair):
                return String(localized: "Local model does not support pair \(pair)")
            }
        }
    }

    private var loadedModel: MLModel?
    private var loadedPair: String?
    private var unloadTask: Task<Void, Never>?
    private let downloader = ModelDownloader.shared

    var providerName: String { "OPUS" }

    /// Проверяет наличие скачанной модели для пары.
    func isDownloaded(from source: String, to target: String) -> Bool {
        let key = downloader.pairKey(from: source, to: target)
        return downloader.isDownloaded(pairKey: key)
    }

    /// Основной вход — переводит чанками, каждый чанк через CoreML.
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let pairKey = downloader.pairKey(from: source, to: target)
        guard downloader.isDownloaded(pairKey: pairKey) else {
            throw LocalError.notDownloaded(pair: pairKey)
        }

        // Для reverse пары пробуем обратную модель если прямой нет
        // Но пока требуем точное совпадение направлений — OPUS модели направленные.

        var parts: [String] = []
        for chunk in TextChunker.chunks(text, limit: 800) {
            try Task.checkCancellation()
            let translated = try await translateChunk(chunk, pairKey: pairKey)
            parts.append(translated)
        }
        return parts.joined(separator: " ")
    }

    private func translateChunk(_ chunk: String, pairKey: String) async throws -> String {
        let model = try await loadModel(for: pairKey)
        // Запускаем inference вне main actor чтобы не блокировать UI
        return try await runInference(model: model, text: chunk, pairKey: pairKey)
    }

    private func loadModel(for pairKey: String) async throws -> MLModel {
        if let m = loadedModel, loadedPair == pairKey {
            // Сбрасываем таймер выгрузки
            scheduleUnload()
            return m
        }

        // Выгружаем предыдущую
        unloadModel()

        let dir = downloader.modelDirectory(for: pairKey)
        // Ищем .mlmodelc или .mlpackage
        guard let modelURL = findModelURL(in: dir) else {
            throw LocalError.modelLoadFailed("model file not found in \(dir.path)")
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all // ANE + GPU + CPU, low RAM на ANE
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            loadedModel = model
            loadedPair = pairKey
            scheduleUnload()
            return model
        } catch {
            throw LocalError.modelLoadFailed(error.localizedDescription)
        }
    }

    private func findModelURL(in dir: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        // Приоритет: .mlmodelc (скомпилированная), затем .mlpackage
        if let c = contents.first(where: { $0.pathExtension == "mlmodelc" }) { return c }
        if let p = contents.first(where: { $0.pathExtension == "mlpackage" }) { return p }
        // Иногда модель внутри подпапки
        for sub in contents where sub.hasDirectoryPath {
            if let found = findModelURL(in: sub) { return found }
        }
        return nil
    }

    private nonisolated func runInferenceOffMain(model: MLModel, text: String) throws -> String {
        try autoreleasepool {
            let inputFeatures: [String: Any] = ["text": text]
            let provider = try MLDictionaryFeatureProvider(dictionary: inputFeatures)
            let output = try model.prediction(from: provider)
            if let outText = output.featureValue(for: "output")?.stringValue {
                return outText
            }
            if let outText = output.featureValue(for: "translation")?.stringValue {
                return outText
            }
            throw LocalError.translationFailed("Model output is token IDs, tokenizer not linked yet. Use cloud fallback.")
        }
    }

    private func runInference(model: MLModel, text: String, pairKey: String) async throws -> String {
        // Не блокируем MainActor — уходим на глобальную очередь, MLModel is Sendable via @unchecked
        let modelCopy = model
        let textCopy = text
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runInferenceOffMain(model: modelCopy, text: textCopy)
                    cont.resume(returning: result)
                } catch let err as LocalError {
                    cont.resume(throwing: err)
                } catch {
                    cont.resume(throwing: LocalError.translationFailed(error.localizedDescription))
                }
            }
        }
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.unloadModel()
        }
    }

    private func unloadModel() {
        unloadTask?.cancel()
        unloadTask = nil
        loadedModel = nil
        loadedPair = nil
        // Принудительно освобождаем память
        // autoreleasepool уже отработал в inference
    }

    deinit {
        // Нельзя вызывать @MainActor методы из deinit напрямую
    }
}
