#!/bin/bash
set -euo pipefail

# Единая точка сборки + подписи + установки — использовать вместо ручного
# xcodebuild, любым инструментом (не только этой сессией).
#
# ЗАЧЕМ ЭТОТ СКРИПТ СУЩЕСТВУЕТ: голый `xcodebuild ... CODE_SIGN_IDENTITY="-"`
# подписывает ad-hoc. У ad-hoc designated requirement — это хеш бинарника
# (cdhash), он меняется на КАЖДОЙ пересборке. macOS привязывает к
# designated requirement и разрешение Accessibility (Универсальный доступ),
# и Keychain-доступ к уже сохранённым секретам (API-ключам Azure/Google/
# DeepL/OpenAI) — при ad-hoc пересборке оба тихо ломаются: разрешение
# отваливается без предупреждения, а ключи из Settings перестают
# читаться (Keychain видит «другое приложение», хотя бандл тот же).
# Сертификат разработчика даёт designated requirement, привязанный к
# самому сертификату — переживает любые пересборки.
#
# Если этот проект собирает не только эта сессия, а ещё какой-то другой
# инструмент/агент — используйте именно этот скрипт, а не свой собственный
# `xcodebuild`, иначе первая же ad-hoc сборка сломает уже сохранённые ключи
# и Accessibility-грант у всех остальных сборок, включая эту сессию.
#
# Настройка (один раз): узнать identity через
#   security find-identity -v -p codesigning
# и экспортировать:
#   export ABUBTRANSLATE_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"

: "${ABUBTRANSLATE_SIGN_IDENTITY:?Задайте ABUBTRANSLATE_SIGN_IDENTITY — см. комментарий в начале скрипта}"

cd "$(dirname "$0")/.."

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild (Release)"
xcodebuild -project AbubTranslate.xcodeproj -scheme AbubTranslate \
    -configuration Release -derivedDataPath .build build CODE_SIGN_IDENTITY="-"

APP=".build/Build/Products/Release/AbubTranslate.app"

echo "==> codesign сертификатом (не ad-hoc)"
codesign --force --deep --options runtime -s "$ABUBTRANSLATE_SIGN_IDENTITY" "$APP"
codesign --verify --verbose "$APP"

echo "==> установка в /Applications"
pkill -9 -f AbubTranslate.app 2>/dev/null || true
sleep 1
rm -rf /Applications/AbubTranslate.app
cp -R "$APP" /Applications/
codesign --verify --verbose /Applications/AbubTranslate.app

echo "==> готово: /Applications/AbubTranslate.app"
