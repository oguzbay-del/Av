#!/bin/bash
# iPhone simülatöründe uygulamayı farklı senaryolarda açıp ekran görüntüsü alır.
# GitHub Actions (macOS) üzerinde çalışır: .github/workflows/ekran-goruntuleri.yml
set -euo pipefail
APP=ios/build/Debug-iphonesimulator/AvHaritasi.app
BID=com.example.avharitasi
OUT=screenshots
mkdir -p "$OUT"

DEV=$(xcrun simctl list devices available | grep -E "iPhone 1[5-7]( Pro)? \(" | head -1 | sed -E 's/^ *(.*) \(([-0-9A-F]+)\).*/\2/')
echo "Simülatör: $DEV"
xcrun simctl boot "$DEV" || true
xcrun simctl bootstatus "$DEV" -b
# Temiz durum çubuğu
xcrun simctl status_bar "$DEV" override --time "10:30" --batteryState charged --batteryLevel 100 --cellularBars 4 || true
xcrun simctl install "$DEV" "$APP"
xcrun simctl privacy "$DEV" grant location "$BID" || true
xcrun simctl privacy "$DEV" grant location-always "$BID" || true

setd() { xcrun simctl spawn "$DEV" defaults write "$BID" "$@"; }

shot() {  # ad enlem boylam sekme acik-banner uyari-kabul bekleme
  local name=$1 lat=$2 lon=$3 tab=$4 expanded=$5 accepted=$6 wait=${7:-12}
  xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
  setd selectedTab -string "$tab"
  setd bannerExpanded -bool "$expanded"
  setd acceptedDisclaimer_2026 -bool "$accepted"
  setd baseLayer -string "appleHybrid"
  setd showScentCone -bool "${CONE:-false}"
  # Görüntülerde gerçekçi an: 7 Ekim 2026 Çarşamba 10:30 (İstanbul) — av günü, av saati içinde
  setd debugNow -string "2026-10-07T07:30:00Z"
  xcrun simctl location "$DEV" set "$lat,$lon"
  xcrun simctl launch "$DEV" "$BID"
  sleep "$wait"
  xcrun simctl io "$DEV" screenshot "$OUT/$name.png"
  echo "  $name.png"
}

# 0) İlk açılış uyarısı
shot 0_ilk_acilis 41.10 29.53 harita false false 8
# 1) Avlanılabilir alan: Şile ormanı (Devlet Avlağı)
shot 1_harita_avlanabilir 41.10 29.53 harita false true 20
# 2) Aynı yer, kural listesi açık
shot 2_harita_kurallar_acik 41.10 29.53 harita true true 15
# 3) Yasak alan: Sarıkavak Devlet Avlağı (2026-27 ava kapalı)
shot 3_harita_yasak_sarikavak 41.01 29.64 harita true true 20
# 4) Köy ve yol yakını (dikkat / yasak mesafe kuralları)
shot 4_harita_koy_yakini 41.135 29.85 harita true true 20
# 5) Bugün sekmesi
shot 5_bugun 41.10 29.53 bugun false true 8
# 6) Kurallar sekmesi
shot 6_kurallar 41.10 29.53 kurallar false true 8
# 7) Rüzgâr rozeti ve koku konisi (hava durumu Open-Meteo'dan)
CONE=true shot 7_harita_koku_konisi 41.10 29.53 harita false true 25
# 8) Kuş sesi tanıma
shot 8_kus_sesi 41.10 29.53 kus false true 8
ls -la "$OUT"
