# AbubTranslate

Меню-бар утилита для macOS: переводит выделенный текст через системный движок
Apple Translation и озвучивает результат встроенным TTS. Перевод идёт локально
на устройстве — в сеть приложение не ходит.

![platform](https://img.shields.io/badge/macOS-15%2B-black) ![swift](https://img.shields.io/badge/Swift-6-orange) ![license](https://img.shields.io/badge/license-MIT-green)

## Установка

**[Скачать AbubTranslate.dmg](https://github.com/Abubiker/AbubTranslate/releases/latest/download/AbubTranslate.dmg)** — macOS 15+, Apple Silicon.

Откройте образ и перетащите приложение в Applications.

Сборка подписана сертификатом разработчика, но не нотаризована, поэтому при
первом запуске macOS покажет предупреждение: **Настройки → Конфиденциальность
и безопасность → Открыть всё равно**.

## Использование

1. Выделите текст в любом приложении (или просто скопируйте его).
2. Нажмите ⌥⇧T либо кликните по иконке AbubTranslate в строке меню.
3. Язык определится, направление выберется само, перевод появится в панели.
4. 🔊 — озвучить перевод, 📋 — скопировать результат, ⚙️ — настройки, ⇄ — своп языков.
5. Первый перевод на новый язык: пакет скачается, в панели виден статус загрузки.

Правый клик по иконке в строке меню — настройки и выход.

## Возможности

- Иконка в строке меню — не занимает место в Dock
- Перевод **выделенного текста** в любом приложении; если выделения нет — буфер обмена
- Языковая пара A⇄B с автовыбором направления и кнопкой свопа
- Автоматическое определение языка исходного текста
- Перевод полностью локально, список языков берётся у системы
- Панель подстраивается по высоте под длину текста
- Озвучка перевода системным голосом целевого языка + кнопка стоп
- Глобальный хоткей **⌥⇧T** — перевести (работает при любой раскладке)
- Глобальный хоткей **⌥⇧Y** — озвучить последний перевод
- Настраиваемые хоткеи с предупреждением о конфликте, автозапуск при входе
- Интерфейс на русском и английском
- Копирование результата обратно в буфер одним кликом

## Разрешения

Для перевода выделенного текста нужен **Универсальный доступ**
(Настройки → Конфиденциальность и безопасность → Универсальный доступ):
приложение отправляет синтетический ⌘C, читает результат и **возвращает
прежнее содержимое буфера обмена**. Без разрешения работает только режим
буфера обмена — скопируйте текст сами и нажмите ⌥⇧T.

Если разрешение выдано, а приложение всё равно его не видит — скорее всего в
списке осталась запись от предыдущей сборки. macOS привязывает выданное
разрешение к подписи приложения, и старая запись перестаёт совпадать. Удалите
AbubTranslate из списка кнопкой **−** и добавьте заново, либо сбросьте запись:

```bash
tccutil reset Accessibility com.opensource.abubtranslate
```

## Лицензия

MIT — см. [LICENSE](LICENSE).

Использовать, изменять и распространять можно свободно, в том числе в
коммерческих проектах. Единственное условие лицензии — сохранять текст
лицензии и указание авторства (© Dmitry Marchenko) в копиях программы и
существенных её частях.

---

<details>
<summary><b>Сборка из исходников</b></summary>

Требуется macOS 15+, Xcode 16+ и [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen          # если ещё не установлен
xcodegen generate
xcodebuild -project AbubTranslate.xcodeproj -scheme AbubTranslate \
    -configuration Release -derivedDataPath .build build CODE_SIGN_IDENTITY="-"
```

Готовое приложение: `.build/Build/Products/Release/AbubTranslate.app`.

Подпись обязательна: без неё arm64-бинарь не запустится.

Подписывать лучше сертификатом разработчика, а не ad-hoc:

```bash
codesign --force --deep --options runtime \
    -s "Apple Development: ваш@email (TEAMID)" \
    .build/Build/Products/Release/AbubTranslate.app
```

Причина в том, какое требование к подписи macOS запоминает при выдаче
«Универсального доступа»:

```
ad-hoc:      designated => cdhash H"3b95b95e…"
сертификат:  designated => identifier "com.opensource.abubtranslate"
                           and anchor apple generic
                           and certificate leaf[subject.CN] = "Apple Development: …"
```

У ad-hoc сборки требование прибито к хешу конкретного бинарника, поэтому любая
пересборка ломает выданное разрешение — переключатель в настройках остаётся
включённым, но приложение считается недоверенным. С сертификатом требование
привязано к самому сертификату и переживает пересборки.

Проверка логики выбора направления перевода:

```bash
swiftc -o /tmp/testdir Sources/Managers/TranslationDirection.swift Tools/TestDirection.swift && /tmp/testdir
```

Либо просто откройте `AbubTranslate.xcodeproj` в Xcode и нажмите ⌘R.

### Структура

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

</details>
