#!/usr/bin/env bash
set -euo pipefail

# ZeroLose build + stable-sign + install script.
#
# NEDEN BU SCRIPT?
# Eski akış uygulamayı adhoc imzaliyordu (codesign --sign -). Adhoc imzanın
# designated requirement'ı (DR) binanın cdhash'inden türetildiği için her
# yeniden derlemede DR değişiyor ve macOS TCC (Erişilebilirlik / Ekran Kaydı)
# uygulamayı "yeni bir uygulama" sanıp izinleri sıfırlıyordu.
#
# ÇÖZÜM?
# Sabit bir Apple Development kimliğiyle imzala. Bu kimliğin DR'ı sertifika
# yaprağına (certificate leaf) dayanır, binary hash'e değil -> her derlemede
# aynı kalır. Böylece kullanıcı izinleri BİR KEZ verir ve kalıcı olur.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$ROOT/.derived"
APP="$DERIVED/Build/Products/Release/ZeroLose.app"
INSTALL_PATH="/Applications/ZeroLose.app"

# İmza kimliği: makinede mevcut, Son Geçerlilik 2027-08'e kadar geçerli.
SIGN_IDENTITY="${ZEROLOSE_SIGN_IDENTITY:-Apple Development: SENOL DOGAN (NTN6W8D2S6)}"

echo "==> 1/4 Release build"
xcodebuild -project "$ROOT/ZeroLose/ZeroLose.xcodeproj" \
  -scheme ZeroLose \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  build CODE_SIGNING_ALLOWED=NO

echo "==> 2/4 Sabit kimlikle imzala"
codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime "$APP"

echo "==> 3/4 İmza doğrula (stable DR)"
codesign --verify --deep --strict --verbose=2 "$APP"
DR="$(codesign -d -r- "$APP" 2>&1 | grep 'designated =>' || true)"
echo "DR: $DR"

if [[ "$DR" != *"Apple Development: SENOL DOGAN"* ]]; then
  echo "HATA: designated requirement beklenen sabit kimliği göstermiyor."
  exit 1
fi

echo "==> 4/4 /Applications'e kur"
if pgrep -f "$INSTALL_PATH" >/dev/null 2>&1; then
  echo "   Çalışan ZeroLose kapatılıyor..."
  pkill -f "$INSTALL_PATH" 2>/dev/null || true
  sleep 1
fi
ditto "$APP" "$INSTALL_PATH"

# Eski TCC kaydını değil, yeni sabit kimliği tanıması için uygulamayı taze kur.
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

echo "OK: $INSTALL_PATH imzalandı ve kuruldu."
echo "Uygulama açıldığında Erişilebilirlik / Ekran Kaydı izinlerini BİR KEZ"
echo "vermeniz yeterlidir; sonraki derlemelerde izinler kalıcı olur."
open "$INSTALL_PATH"
