# AbubTranslate

Выделить текст в любом приложении macOS, нажать `⌥⇧T` — перевод в панели.

Работает на Apple Translation: на устройстве, без ключей и без сети. Можно
подключить DeepL, Google, Azure, Yandex, LibreTranslate, MyMemory или любой
OpenAI-совместимый сервер, включая локальный.

![platform](https://img.shields.io/badge/macOS-15%2B-black) ![swift](https://img.shields.io/badge/Swift-6-orange) ![license](https://img.shields.io/badge/license-GPL--3.0-blue)

## Установка

[Скачать AbubTranslate.dmg](https://github.com/Abubiker/AbubTranslate/releases/latest/download/AbubTranslate.dmg) — macOS 15+, Apple Silicon.

Не нотаризовано: при первом запуске Настройки → Конфиденциальность и
безопасность → Открыть всё равно.

## Хоткеи

| | |
|---|---|
| `⌥⇧T` | перевести выделенное |
| `⌥⇧Y` | озвучить последний перевод |
| `⌥⇧S` | перевести картинку из буфера |

## Движки

| Движок | Где работает | Условие |
|---|---|---|
| Apple Translation | на устройстве | встроен, 22 языка |
| MyMemory | облако | без ключа, 5 000 символов/сутки (50 000 с почтой) |
| Azure Translator | облако | ключ; F0 — 2 млн символов/месяц бесплатно |
| Google Translate | облако | ключ; платно сверх бесплатного лимита |
| DeepL | облако | ключ; разовый кредит 1 млн символов |
| OpenAI-совместимый | облако или локально | URL и модель; Ollama, LM Studio, прокси |
| Yandex Cloud Translate | облако | ключ сервисного аккаунта, посимвольно с первого символа |
| LibreTranslate | облако или локально | URL инстанса; свой в docker — без ключа |

Apple, локальный OpenAI-сервер и свой LibreTranslate не отправляют текст
никуда. Остальные отправляют его на сторонний сервер.

Где взять ключ и как проверить — написано в настройках приложения.

## Разрешения

Перевод выделенного требует Универсальный доступ. Если он выдан, но не
работает — осталась запись от прошлой сборки:

```bash
tccutil reset Accessibility com.opensource.abubtranslate
```

## Лицензия

GPL-3.0-only, текст в [LICENSE](LICENSE). Форк остаётся под GPL и несёт
исходники. Для закрытого продукта — отдельная платная лицензия, пишите в
[Issues](https://github.com/Abubiker/AbubTranslate/issues).

## Сборка

`./Scripts/build.sh` — только им, не голым `xcodebuild`. Почему и что нужно
выставить перед первым запуском — в комментарии в начале скрипта.
