import AppKit
import Vision
import ImageIO
import UniformTypeIdentifiers

/// OCR из картинок без разрешения «Запись экрана»: источник пикселей —
/// буфер обмена (системный скриншот ⇧⌃⌘4, копирование изображения из
/// любого приложения) и файл, брошенный на панель. Распознавание —
/// Apple Vision, локально; текст попадает в обычный боевой перевод.
@MainActor
enum ImageOCRManager {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp",
    ]

    /// Есть ли в буфере картинка и только картинка. Копия текста, где
    /// рядом лежит изображение (страница браузера с картинкой), не
    /// считается: иначе каждый ⌘C в браузере поднимал бы бейдж.
    /// canReadObject есть только на NSItemProvider, а здесь pasteboard —
    /// фильтр по типам записей.
    static func hasImage(_ pb: NSPasteboard) -> Bool {
        guard let items = pb.pasteboardItems, !items.isEmpty else { return false }
        let imagePayloads: Set<NSPasteboard.PasteboardType> = [.png, .tiff, .fileURL]
        for item in items {
            let types = Set(item.types)
            if types.contains(.string) { continue }
            if !types.isDisjoint(with: imagePayloads) { return true }
        }
        return false
    }

    /// Вытаскивает изображение из буфера: сырой png/tiff или файл по URL.
    static func imageData(from pb: NSPasteboard) -> Data? {
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) { return data }
        guard let urls = pb.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let file = urls.first(where: { imageExtensions.contains($0.pathExtension.lowercased()) })
        else { return nil }
        return try? Data(contentsOf: file)
    }

    static func isImageData(_ data: Data) -> Bool {
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        guard let source, CGImageSourceGetCount(source) > 0 else { return false }
        return true
    }

    /// Распознавание в фоновом потоке: Vision-блокирующий вызов не должен
    /// подергивать main во время анимации панели.
    nonisolated static func recognize(_ data: Data) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: syncRecognize(data))
            }
        }
    }

    private nonisolated static func syncRecognize(_ data: Data) -> String? {
        // Порядок = приоритет подсказок Vision; локально, чтобы не тянуть
        // main-акторный state enum'а в фоновый поток.
        let languages = ["ru-RU", "en-US", "uk-UA", "de-DE", "fr-FR", "es-ES", "zh-Hans", "ja-JP", "ko-KR"]
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        guard let source,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.012

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        guard let observations = request.results, !observations.isEmpty
        else { return nil }

        // Порядок чтения: сверху вниз, в пределах одной строки — слева
        // направо. Строку склеиваем по пересечению y-интервалов: у Vision
        // боксы выровнены по базовой линии, но высоты у смешанного
        // текста (заголовок + инлайн-иконки) разные.
        struct Piece { let y: CGFloat; let height: CGFloat; let x: CGFloat; let text: String }
        let pieces: [Piece] = observations.compactMap { observation in
            guard let top = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return Piece(y: box.midY, height: max(box.height, 0.005), x: box.minX, text: top.string)
        }
        .sorted { $0.y != $1.y ? $0.y > $1.y : $0.x < $1.x }

        var lines: [[Piece]] = []
        for piece in pieces {
            if var last = lines.last, let head = last.first,
               abs(head.y - piece.y) < max(head.height, piece.height) * 1.2 {
                last.append(piece)
                lines[lines.count - 1] = last
            } else {
                lines.append([piece])
            }
        }
        let text = lines
            .map { line in line.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
