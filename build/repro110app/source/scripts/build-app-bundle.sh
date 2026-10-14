#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacRunner Control Center"
BUNDLE_ID="com.macrunner.controlcenter"
BUNDLE_VERSION="0.2.0"
BUILD_DIR=".build/release"
APP_BUNDLE="dist/${APP_NAME}.app"

echo "Building ${APP_NAME}..."
python3 scripts/gen-tested-games.py --check
swift build -c release

echo "Assembling .app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy executable
cp "${BUILD_DIR}/MacRunnerControlCenter" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# ★★★ РЕСУРСНЫЙ БАНДЛ SPM — ОБЯЗАТЕЛЕН, БЕЗ НЕГО ПРИЛОЖЕНИЕ УМИРАЕТ НА СТАРТЕ.
# Пакет объявляет `resources: [.process("Resources")]`, и обращение к `Bundle.module`
# ищет рядом с двоичным файл `<Пакет>_<Цель>.bundle`. Не нашёл — fatalError, окно не
# появляется вовсе. При этом сборка проходит УСПЕШНО, `open` возвращает ноль, и снаружи
# это выглядит как «запустилось и сразу закрылось» без единой строки в журнале.
# Поймано 10.09.2026: бандл собирался, но сюда не копировался ни разу.
RESOURCE_BUNDLE="MacRunnerControlCenter_MacRunnerControlCenter.bundle"
if [ -d "${BUILD_DIR}/${RESOURCE_BUNDLE}" ]; then
    cp -R "${BUILD_DIR}/${RESOURCE_BUNDLE}" "${APP_BUNDLE}/Contents/Resources/"
else
    echo "ОТКАЗ: не найден ${BUILD_DIR}/${RESOURCE_BUNDLE} — приложение не запустится" >&2
    exit 1
fi

# ★★★ КАРКАСЫ SPARKLE И CRASHREPORTER — ТОЖЕ ОБЯЗАТЕЛЬНЫ.
# Двоичный ссылается на них через @rpath, и без них dyld убивает процесс ещё до main:
# в отчёте о падении стоит «Library missing», окна нет, журнал пуст. Симптом снаружи
# тот же самый, что и у пропавшего ресурсного бандла, — «открылось и закрылось».
mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
for FW in Sparkle CrashReporter; do
    if [ -d "Frameworks/${FW}.framework" ]; then
        cp -R "Frameworks/${FW}.framework" "${APP_BUNDLE}/Contents/Frameworks/"
    else
        echo "ОТКАЗ: нет Frameworks/${FW}.framework — приложение не запустится" >&2
        exit 1
    fi
done
# Путь поиска: каркасы лежат в Contents/Frameworks относительно двоичного в Contents/MacOS.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

# Write Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MacRunner Control Center</string>
    <key>CFBundleIdentifier</key>
    <string>com.macrunner.controlcenter</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MacRunner</string>
    <key>CFBundleDisplayName</key>
    <string>MacRunner</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSBackgroundOnly</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 MacRunner Project</string>
</dict>
</plist>
EOF

# ★ ЗНАЧОК ПРИЛОЖЕНИЯ — НАСТОЯЩИЙ, А НЕ ПУСТЫШКА.
# Раньше здесь стоял `touch`: файл нулевой длины, и Finder с Dock показывали
# чужой общий значок. Значок собирается из знака MR сценарием
# scripts/make-app-icon.swift и лежит в хранилище готовым, чтобы сборка бандла
# не зависела от шрифтов и отрисовки на машине сборщика.
# Имя пакета и путь бандла (APP_NAME) НЕ меняются: игроку показывается
# CFBundleName/CFBundleDisplayName = «MacRunner», а файлы остаются, где были.
APP_ICON="scripts/assets/AppIcon.icns"
if [ -s "${APP_ICON}" ]; then
    cp "${APP_ICON}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
else
    echo "ОТКАЗ: нет ${APP_ICON} — пересоберите значок: swift scripts/make-app-icon.swift" >&2
    exit 1
fi

# Copy docs into Resources
cp -R docs "${APP_BUNDLE}/Contents/Resources/" 2>/dev/null || true
cp README.md "${APP_BUNDLE}/Contents/Resources/" 2>/dev/null || true

# Ad-hoc sign the bundle
codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true

echo "App bundle created at: $(pwd)/${APP_BUNDLE}"
