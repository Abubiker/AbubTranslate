#!/bin/bash
set -euo pipefail

# Байтовое сравнение вместо локального: под UTF-8-локалью sort/uniq/comm
# складывают порядок по правилам языка и игнорируют пунктуацию — "Settings"
# и "Settings…" становятся равны, uniq -d репортит несуществующий дубликат,
# а comm врёт про недостающие ключи. Скрипт вызывается из build.sh под
# set -e, поэтому ложное срабатывание блокирует сборку целиком.
export LC_ALL=C

# Полнота локализаций: каждый ключ, который код передаёт в
# localizedString/appLocalizedString, должен быть объявлен в КАЖДОЙ
# .lproj/Localizable.strings.
#
# ЗАЧЕМ: пропущенный ключ не роняет сборку и не даёт ошибки в рантайме —
# localizedStringCore отдаёт value:key, то есть сам английский ключ. На
# русском интерфейсе это выглядит как один пункт меню, внезапно
# оставшийся английским среди переведённых соседей ("Cloud models
# (Yandex)" рядом с "Облачные модели (Azure)"). Заметно только глазами и
# только если открыть именно это меню именно на этом языке — поэтому
# проверка скриптом, а не вниманием.
#
# Обратную сторону (объявлен, но не используется) намеренно не проверяем:
# часть строк приходит из SwiftUI Text(LocalizedStringKey) и грепом по
# вызовам функций не ловится — такой чек давал бы ложные срабатывания.
#
# Запуск: bash Scripts/check-locales.sh

cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Ключи из кода. Учитываются только строковые литералы: localizedString(var)
# грепом не виден и проверке не подлежит.
grep -rhoE '(appLocalizedString|localizedString)\("([^"\\]|\\.)*"' --include='*.swift' Sources \
    | sed -E 's/^(appLocalizedString|localizedString)\("//; s/"$//' \
    | sort -u > "$work/used.txt"

echo "ключей в коде: $(wc -l < "$work/used.txt" | tr -d ' ')"

failed=0
for file in Sources/*.lproj/Localizable.strings; do
    locale=$(basename "$(dirname "$file")" .lproj)
    # Ключ — левая часть строки "KEY" = "VALUE";
    grep -oE '^"([^"\\]|\\.)*"' "$file" | sed 's/^"//; s/"$//' | sort -u > "$work/$locale.txt"

    # Дубликат ключа .strings не считает ошибкой — молча побеждает последний.
    # Пока значения совпадают, это незаметно; расходятся — и правка первого
    # вхождения просто не действует.
    duplicates=$(grep -oE '^"([^"\\]|\\.)*"' "$file" | sort | uniq -d)

    missing=$(comm -23 "$work/used.txt" "$work/$locale.txt")
    if [ -n "$missing" ] || [ -n "$duplicates" ]; then
        echo "FAIL $locale"
        if [ -n "$missing" ]; then
            echo "  нет ключа:"
            printf '      %s\n' "$missing"
        fi
        if [ -n "$duplicates" ]; then
            echo "  дубликат:"
            printf '      %s\n' "$duplicates"
        fi
        failed=1
    else
        echo "OK   $locale"
    fi
done

if [ "$failed" -ne 0 ]; then
    echo
    echo "Непереведённые ключи показываются пользователю как английский текст."
    exit 1
fi

echo "Локализации полные."
