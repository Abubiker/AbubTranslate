# AbubTranslate

Меню-бар утилита для macOS: переводит текст из буфера обмена через системный
движок Apple Translation (on-device) и озвучивает результат встроенным TTS.

![platform](https://img.shields.io/badge/macOS-15%2B-black) ![swift](https://img.shields.io/badge/Swift-6-orange) ![license](https://img.shields.io/badge/license-MIT-green)

## Возможности

- Иконка в строке меню — не занимает место в Dock
- Перевод **выделенного текста** в любом приложении; если выделения нет — буфер обмена
- Языковая пара A⇄B с автовыбором направления и кнопкой свопа
- Автоматическое определение языка исходного текста (NLLanguageRecognizer)
- Перевод полностью локально (Apple Translation, macOS 15+), список языков берётся у системы
- Панель подстраивается по высоте под длину текста
- Озвучка перевода системным голосом целевого языка + кнопка стоп
- Глобальный хоткей **⌥⇧T** — перевести (работает при любой раскладке)
- Глобальный хоткей **⌥⇧Y** — озвучить последний перевод
- Настраиваемые хоткеи с предупреждением о конфликте, автозапуск при входе — в настройках
- Правый клик по иконке — меню с настройками и выходом
- Интерфейс на русском и английском
- Копирование результата обратно в буфер одним кликом

## Разрешения

Для перевода выделенного текста нужен **Универсальный доступ**
(Настройки → Конфиденциальность и безопасность → Универсальный доступ):
приложение отправляет синтетический ⌘C, читает результат и **возвращает
прежнее содержимое буфера обмена**. Без разрешения работает только режим
буфера обмена.

Приложение подписано ad-hoc, поэтому после каждой пересборки macOS сбрасывает
это разрешение — его придётся выдать заново.

## Сборка

Требуется macOS 15+, Xcode 16+ и [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen          # если ещё не установлен
xcodegen generate
xcodebuild -project AbubTranslate.xcodeproj -scheme AbubTranslate \
    -configuration Release -derivedDataPath .build build CODE_SIGN_IDENTITY="-"
```

Готовое приложение: `.build/Build/Products/Release/AbubTranslate.app`.

Подпись обязательна: без неё arm64-бинарь не запустится.

Проверка логики выбора направления перевода:

```bash
swiftc -o /tmp/testdir Sources/Managers/TranslationDirection.swift Tools/TestDirection.swift && /tmp/testdir
```

Либо просто откройте `AbubTranslate.xcodeproj` в Xcode и нажмите ⌘R.

## Использование

1. Выделите текст в любом приложении (или просто скопируйте его).
2. Нажмите ⌥⇧T либо кликните по иконке AbubTranslate в строке меню.
3. Язык определится, направление выберется само, перевод появится в панели.
4. 🔊 — озвучить перевод, 📋 — скопировать результат, ⚙️ — настройки, ⇄ — своп языков.
5. Первый перевод на новый язык: пакет скачается, в панели виден статус загрузки.

## Структура

```
Sources/
├── TranslatorApp.swift            # @main, статус-итем, поповер, меню правого клика
├── AppModel.swift                 # состояние, языковая пара, оркестрация перевода
├── Views/
│   ├── PanelView.swift            # основная панель
│   ├── SettingsView.swift         # языки, хоткеи, тема, автозапуск
│   └── HotkeyRecorder.swift       # запись комбинации
├── Managers/
│   ├── SelectionReader.swift      # выделенный текст через синтетический ⌘C
│   ├── TranslationDirection.swift # выбор направления A⇄B (чистая логика)
│   ├── ClipboardManager.swift     # NSPasteboard
│   ├── LanguageDetector.swift     # NLLanguageRecognizer
│   ├── SpeechManager.swift        # AVSpeechSynthesizer
│   └── HotKeyManager.swift        # Carbon RegisterEventHotKey
├── en.lproj/ ru.lproj/            # локализация
└── Assets.xcassets/
```

## Лицензия

MIT — см. [LICENSE](LICENSE).

Использовать, изменять и распространять можно свободно, в том числе в
коммерческих проектах. Единственное условие лицензии — сохранять текст
лицензии и указание авторства (© Dmitry Marchenko) в копиях программы и
существенных её частях.
