#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ASO VPN"
VERSION="${ASO_VPN_VERSION:-3.2}"
MIN_MACOS="12.0"
SDK="$(xcrun --show-sdk-path)"
OUT_DIR="${ROOT}/dist"
APP_DIR="${OUT_DIR}/${APP_NAME}.app"
ICON_ICNS="${ROOT}/resources/AppIcon.icns"
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1"; exit 1; }; }
need clang
need lipo
need xcrun
bash -n "${ROOT}/vpn.sh"
rm -rf "${OUT_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
echo "==> Compiling arm64..."
clang -O2 -fobjc-arc \
  -target "arm64-apple-macos${MIN_MACOS}" \
  -isysroot "${SDK}" \
  -framework Cocoa \
  "${ROOT}/VPNApp.m" \
  -o "${ROOT}/.build-arm64"
echo "==> Compiling x86_64..."
clang -O2 -fobjc-arc \
  -target "x86_64-apple-macos${MIN_MACOS}" \
  -isysroot "${SDK}" \
  -framework Cocoa \
  "${ROOT}/VPNApp.m" \
  -o "${ROOT}/.build-x86_64"
echo "==> Creating universal binary..."
lipo -create "${ROOT}/.build-arm64" "${ROOT}/.build-x86_64" -output "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${ROOT}/vpn.sh" "${APP_DIR}/Contents/Resources/vpn.sh"
chmod +x "${APP_DIR}/Contents/Resources/vpn.sh"
if [[ -f "${ICON_ICNS}" ]]; then
  cp "${ICON_ICNS}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ASO VPN</string>
  <key>CFBundleDisplayName</key><string>ASO VPN</string>
  <key>CFBundleExecutable</key><string>ASO VPN</string>
  <key>CFBundleIdentifier</key><string>com.aso.ssh-vpn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "${APP_DIR}" 2>/dev/null || true
rm -f "${ROOT}/.build-arm64" "${ROOT}/.build-x86_64"
echo "==> Built: ${APP_DIR}"
file "${APP_DIR}/Contents/MacOS/${APP_NAME}"
echo
echo "Run:"
echo "  open \"${APP_DIR}\""
echo
echo "Config is saved to:"
echo "  ~/Library/Application Support/ASO VPN/vpn.conf"
echo "(empty until you press Save Config)"
