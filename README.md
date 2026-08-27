# AbubTranslate

Меню-бар переводчик для macOS. Проблема, которую решает: системный
переводчик Apple встроен только в Safari и Заметки — в остальных
приложениях перевести текст можно только скопировав его в отдельное окно
вручную. AbubTranslate даёт для этого один хоткей из любого приложения.

![platform](https://img.shields.io/badge/macOS-15%2B-black) ![swift](https://img.shields.io/badge/Swift-6-orange) ![license](https://img.shields.io/badge/license-MIT-green)

## Установка

[Скачать AbubTranslate.dmg](https://github.com/Abubiker/AbubTranslate/releases/latest/download/AbubTranslate.dmg) — macOS 15+, Apple Silicon.

Открыть образ, перетащить в Applications.

Сборка подписана сертификатом разработчика, не нотаризована. При первом
запуске: Настройки → Конфиденциальность и безопасность → Открыть всё равно.

## Использование

Два способа:

- Выделить текст в любом приложении, нажать `⌥⇧T` — панель откроется с
  переводом.
- Открыть панель кликом по иконке, вставить текст в поле «Оригинал» —
  перевод запускается сам, через 500 мс после последнего ввода.

Клик по иконке панель только открывает, ничего не переводит и не трогает
буфер обмена.

Язык оригинала определяется автоматически (можно задать вручную в панели).
Целевой язык — один, задаётся в настройках; по умолчанию язык системы.
Если оригинал уже на целевом языке — панель предлагает кнопкой перевести на
альтернативный, без автоподмены.

`⇄` — поменять оригинал и цель местами. `🔊` — озвучить перевод. `📋` —
скопировать результат. `⚙️` — настройки. Второй хоткей, `⌥⇧Y` — озвучить
последний перевод, работает при закрытой панели. Оба хоткея настраиваются;
занятая другим приложением комбинация не сохраняется, показывается
предупреждение.

Правый клик по иконке — меню: настройки, выход.

## Движки перевода

Настройки → Engine. Один активен за раз.

| Движок | Где работает | Условие |
|---|---|---|
| Apple Translation | на устройстве | встроен, без настройки; 22 языка на момент написания |
| MyMemory | облако | без ключа; 5 000 символов/сутки анонимно, 50 000 с указанной почтой (почта не проверяется, регистрация не нужна — просто ключ лимита) |
| HuggingFace | облако | нужен токен (бесплатный): huggingface.co/settings/tokens; модель — Helsinki-NLP/opus-mt по паре языков, не для всех направлений есть модель |

Apple ничего не отправляет в сеть. MyMemory и HuggingFace — отправляют
переводимый текст на сторонний сервер.

Движок, токен HuggingFace и почта MyMemory применяются только по кнопке
«Сохранить» в настройках — остальные поля (языки, хоткеи, тема, автозапуск)
применяются сразу. Причина: смена движка посреди набора токена не должна
перезапускать перевод по недописанному ключу.

Офлайн-движка на базе локально скачиваемых нейросетей в приложении нет —
единственный известный источник CoreML-моделей перевода их не публикует,
скачивание было обречено с самого начала.

## Разрешения

Перевод выделенного текста требует Универсальный доступ (Настройки →
Конфиденциальность и безопасность → Универсальный доступ). Механизм:
приложение отправляет синтетический `⌘C`, читает результат, возвращает
прежнее содержимое буфера обмена. Без разрешения — только вставка текста в
панель вручную.

Разрешение выдано, но не работает: осталась запись от прошлой сборки с
другой подписью. Удалить кнопкой `−` из списка и добавить заново, либо:

```bash
tccutil reset Accessibility com.opensource.abubtranslate
```

## Лицензия

MIT, см. [LICENSE](LICENSE). Условие — сохранять текст лицензии и указание
авторства (© Dmitry Marchenko) в копиях программы.

---

<details>
<summary><b>Сборка из исходников</b></summary>

macOS 15+, Xcode 16+, [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project AbubTranslate.xcodeproj -scheme AbubTranslate \
    -configuration Release -derivedDataPath .build build CODE_SIGN_IDENTITY="-"
```

Результат: `.build/Build/Products/Release/AbubTranslate.app`.

Подпись обязательна — без неё arm64-бинарь не запускается. Подписывать
сертификатом разработчика, не ad-hoc:

```bash
codesign --force --deep --options runtime \
    -s "Apple Development: ваш@email (TEAMID)" \
    .build/Build/Products/Release/AbubTranslate.app
```

Причина: macOS запоминает при выдаче «Универсального доступа» designated
requirement подписи.

```
ad-hoc:      designated => cdhash H"3b95b95e…"
сертификат:  designated => identifier "com.opensource.abubtranslate"
                           and anchor apple generic
                           and certificate leaf[subject.CN] = "Apple Development: …"
```

У ad-hoc требование прибито к хешу бинарника — любая пересборка ломает
выданное разрешение. У сертификата требование привязано к нему самому и
переживает пересборки.

Тесты чистой логики (выбор направления перевода, нарезка текста под лимит
запроса):

```bash
swiftc -o /tmp/selfcheck Sources/Managers/TranslationDirection.swift \
    Sources/Managers/TextChunker.swift Tools/SelfCheck.swift && /tmp/selfcheck
```

### Структура

```
Sources/
├── TranslatorApp.swift            # @main, статус-итем, поповер, меню правого клика
├── AppModel.swift                 # состояние, движки, оркестрация перевода
├── Views/
│   ├── PanelView.swift             # основная панель
│   ├── SettingsView.swift          # языки, движки, хоткеи, тема
│   ├── HotkeyRecorder.swift        # запись комбинации
│   └── DesignTokens.swift          # шкала размеров/отступов/цветов
├── Managers/
│   ├── SelectionReader.swift       # выделенный текст через синтетический ⌘C
│   ├── TranslationDirection.swift  # выбор альтернативного языка (чистая логика)
│   ├── TextChunker.swift           # нарезка под лимит запроса облачных сервисов
│   ├── TranslationProvider.swift   # протокол провайдера, EngineMode
│   ├── Providers/                  # MyMemoryProvider, HuggingFaceProvider
│   ├── CloudTranslator.swift       # HTTP-клиент MyMemory
│   ├── KeychainHelper.swift        # хранение токена/почты
│   ├── ClipboardManager.swift      # NSPasteboard
│   ├── LanguageDetector.swift      # NLLanguageRecognizer
│   ├── SpeechManager.swift         # AVSpeechSynthesizer
│   └── HotKeyManager.swift         # Carbon RegisterEventHotKey
├── en.lproj/ ru.lproj/             # локализация
└── Assets.xcassets/
```

</details>
