#!/bin/bash
# Запуск тестов на машине с Command Line Tools без Xcode.
#
# Testing.framework в CLT лежит вне стандартных путей поиска, а SwiftPM передаёт
# его каталог только через -I (недостаточно для фреймворка). Флаги ниже должны
# попасть и в сгенерированный SwiftPM тест-раннер, поэтому передаются глобально,
# а не в Package.swift. С установленным Xcode достаточно обычного `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."

FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
INTEROP_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [ ! -d "$FRAMEWORKS/Testing.framework" ]; then
    exec swift test "$@"
fi

exec swift test \
    -Xswiftc -F"$FRAMEWORKS" \
    -Xlinker -F"$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$INTEROP_LIB" \
    "$@"
