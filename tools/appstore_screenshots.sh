#!/bin/bash
# App Store ürün sayfası ekran görüntüleri (6.9" iPhone, 1320×2868 dikey, alfa kanalsız PNG).
# Türkçe ve İngilizce, ürün sayfasındaki sırayla 9 sahne çeker (App Store'da dil başına en çok 10):
#   screenshots/appstore/<tr|en>/<n>_<ad>.png
# GitHub Actions (macOS, Xcode 26) üzerinde çalışır: .github/workflows/appstore-ekran.yml
# Önce uygulama simülatör için derlenmiş olmalı (ios/build/Debug-iphonesimulator/AvHaritasi.app).
# Gerekli: python3 + Pillow (alfa kanalını kaldırmak için).
set -euo pipefail
APP=${APP:-ios/build/Debug-iphonesimulator/AvHaritasi.app}
BID=com.example.avharitasi
OUT=${OUT:-screenshots/appstore}
WANT_W=1320
WANT_H=2868
LANGS=${LANGS:-"tr en"}

[ -d "$APP" ] || { echo "Uygulama bulunamadı: $APP (önce xcodebuild ile derleyin)"; exit 1; }
python3 -c 'import PIL' 2>/dev/null || { echo "Pillow gerekli: python3 -m pip install --user pillow"; exit 1; }

# --- Simülatör: en yeni iOS çalışma zamanında "iPhone 17 Pro Max" (yoksa en yeni "Pro Max"; o da yoksa oluştur)
DEV=$(xcrun simctl list -j | python3 -c '
import json, re, sys, subprocess
j = json.load(sys.stdin)
def ver(s): return [int(x) for x in re.findall(r"\d+", s)]
rts = sorted((r for r in j["runtimes"] if r.get("isAvailable") and r["identifier"].split(".")[-1].startswith("iOS-")),
             key=lambda r: ver(r["version"]))
if not rts:
    sys.exit("iOS çalışma zamanı yok")
rt = rts[-1]
devs = [d for d in j["devices"].get(rt["identifier"], []) if d.get("isAvailable", True)]
def pick(pred):
    c = [d for d in devs if pred(d["name"])]
    c.sort(key=lambda d: ver(d["name"]))
    return c[-1]["udid"] if c else None
udid = pick(lambda n: n == "iPhone 17 Pro Max") or pick(lambda n: re.fullmatch(r"iPhone \d+ Pro Max", n))
if not udid:
    # Cihaz tipi: çalışma zamanının desteklediği en yeni "Pro Max", tercihen iPhone 17 Pro Max
    types = [t for t in rt.get("supportedDeviceTypes", j["devicetypes"]) if re.fullmatch(r"iPhone \d+ Pro Max", t["name"])]
    types.sort(key=lambda t: (t["name"] != "iPhone 17 Pro Max", [-x for x in ver(t["name"])]))
    if not types:
        sys.exit("Pro Max cihaz tipi bulunamadı")
    t = types[0]
    udid = subprocess.check_output(["xcrun", "simctl", "create", "AppStore " + t["name"], t["identifier"], rt["identifier"]], text=True).strip()
    print("Oluşturuldu: " + t["name"] + " (" + rt["name"] + ")", file=sys.stderr)
else:
    print("Çalışma zamanı: " + rt["name"], file=sys.stderr)
print(udid)
')
echo "Simülatör: $DEV"
xcrun simctl list devices | grep "$DEV" || true
xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl bootstatus "$DEV" -b
# Arayüz açık temada
xcrun simctl ui "$DEV" appearance light || true
# Temiz durum çubuğu: 9:41, tam pil, tam sinyal
xcrun simctl status_bar "$DEV" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100
xcrun simctl install "$DEV" "$APP"
xcrun simctl privacy "$DEV" grant location "$BID" || true
xcrun simctl privacy "$DEV" grant location-always "$BID" || true
# Kuş Sesi sekmesi mikrofon izni ekranı göstermesin
xcrun simctl privacy "$DEV" grant microphone "$BID" || true

setd() { xcrun simctl spawn "$DEV" defaults write "$BID" "$@"; }

# Uygulama saati (debugNow). Hava durumu yalnızca Open-Meteo tahmin penceresi içindeki bir an için görünür
# (son 6 saat … önümüzdeki 3 gün), bu yüzden sabit bir tarih yerine gerçek zamana yakın bir av günü seçilir:
# pencere içindeki ilk Çarşamba/Cumartesi/Pazar 10:30 (İstanbul); yoksa aynı günlerde 08:00–16:00 arası ilk an.
# Hiçbiri yoksa sabit 7 Ekim 2026 10:30 kullanılır (hava/rüzgâr görünmez). DEBUG_NOW ile elle verilebilir.
if [ -z "${DEBUG_NOW:-}" ]; then
DEBUG_NOW=$(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
ist = timezone(timedelta(hours=3))
now = datetime.now(timezone.utc)
start = now - timedelta(hours=5)
start = start.replace(minute=30 if start.minute <= 30 else 0, second=0, microsecond=0) + (timedelta(hours=1) if start.minute > 30 else timedelta(0))
cands = [start + timedelta(minutes=30 * i) for i in range(int(66 * 2))]
hunting = [c for c in cands if c.astimezone(ist).weekday() in (2, 5, 6)]
exact = [c for c in hunting if (c.astimezone(ist).hour, c.astimezone(ist).minute) == (10, 30)]
loose = [c for c in hunting if 8 <= c.astimezone(ist).hour < 16]
pick = (exact or loose or [datetime(2026, 10, 7, 7, 30, tzinfo=timezone.utc)])[0]
print(pick.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)
fi
echo "Uygulama saati (debugNow): $DEBUG_NOW"

# Uygulamanın veri klasörü (önceki sahnenin örnek işaretleri silinsin diye)
DATA=$(xcrun simctl get_app_container "$DEV" "$BID" data 2>/dev/null || true)

# EXTRA: ek açılış argümanları (yalnızca DEBUG derlemesinde etkili, bkz. ScreenshotArguments.swift)
shot() {  # dil dosya-adı enlem boylam sekme bekleme
  local lang=$1 name=$2 lat=$3 lon=$4 tab=$5 wait=${6:-12}
  local dir="$OUT/$lang" file="$OUT/$lang/$name.png"
  mkdir -p "$dir"
  xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
  [ -n "$DATA" ] && rm -f "$DATA/Library/Application Support/isaretler.json"
  setd fieldMode -bool false
  setd nightRedMode -string off
  setd selectedTab -string "$tab"
  setd bannerExpanded -bool false
  setd panelExpanded -bool false
  setd acceptedDisclaimer_2026 -bool true
  setd baseLayer -string "appleHybrid"
  setd showZones -bool true
  setd showOfficial -bool false
  setd showScentCone -bool "${CONE:-false}"
  setd highlightedAvlak -string "${AVLAK:-}"
  # Av günü, av saati içinde bir an (yukarıda seçildi)
  setd debugNow -string "$DEBUG_NOW"
  xcrun simctl location "$DEV" set "$lat,$lon"
  # shellcheck disable=SC2086
  if [ "$lang" = "en" ]; then
    xcrun simctl launch "$DEV" "$BID" -AppleLanguages "(en)" -AppleLocale en_GB ${EXTRA:-}
  else
    xcrun simctl launch "$DEV" "$BID" -AppleLanguages "(tr)" -AppleLocale tr_TR ${EXTRA:-}
  fi
  sleep "$wait"
  xcrun simctl io "$DEV" screenshot --type=png "$file"
  # Alfa kanalını kaldır (App Store alfa kanallı PNG kabul etmez)
  python3 - "$file" <<'PY'
import sys
from PIL import Image
p = sys.argv[1]
im = Image.open(p)
if im.mode != "RGB":
    bg = Image.new("RGB", im.size, (255, 255, 255))
    rgba = im.convert("RGBA")
    bg.paste(rgba, mask=rgba.getchannel("A"))
    im = bg
im.save(p, "PNG", optimize=True)
PY
  local w h
  w=$(sips -g pixelWidth "$file" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$file" | awk '/pixelHeight/{print $2}')
  if [ "$w" != "$WANT_W" ] || [ "$h" != "$WANT_H" ]; then
    echo "HATA: $file boyutu ${w}×${h}; beklenen ${WANT_W}×${WANT_H}"
    exit 1
  fi
  echo "  $file (${w}×${h})"
}

# Hava durumunu önceden ısıt (Open-Meteo önbelleğe alınır; sonraki çekimlerde hızlı görünür)
xcrun simctl location "$DEV" set "41.10,29.53"
setd acceptedDisclaimer_2026 -bool true
setd debugNow -string "$DEBUG_NOW"
xcrun simctl launch "$DEV" "$BID" -AppleLanguages "(tr)" >/dev/null || true
sleep 20

for L in $LANGS; do
  echo "== $L =="
  # 1) Yasak alan: Sarıkavak Devlet Avlağı (2026-27 ava kapalı) — kırmızı "AVLANMAYIN" şeridi, vektör bölgeler
  shot "$L" 1_yasak_alan 41.01 29.64 harita 20
  # 2) Güvenli: Şile Devlet Avlağı, avlak kartı vurgulu — yeşil durum
  AVLAK="Şile Devlet Avlağı" shot "$L" 2_avlanabilir_avlak 41.10 29.53 harita 20
  # 3) Bugün: av günü, av saati, hava, av defteri (hava durumunun yüklenmesini bekle)
  shot "$L" 3_bugun 41.10 29.53 bugun 25
  # 4) Rüzgâr rozeti ve koku konisi
  CONE=true shot "$L" 4_ruzgar_koku_konisi 41.10 29.53 harita 25
  # 5) Kurallar
  shot "$L" 5_kurallar 41.10 29.53 kurallar 10
  # 6) Kuş sesi tanıma
  shot "$L" 6_kus_sesi 41.10 29.53 kus 10
  # 7) Sınır mesafesi: demo yürüyüşü (Sarıkavak) yasak alana ~200 m kala (30. adımda) durur — turuncu "Dikkat",
  #    "Sınıra … m" çipi, sınıra kesikli çizgi ve GPS hassasiyet dairesi. Simülatör konumu da aynı noktada
  #    (MapKit'in mavi noktası ve ilk yakınlaşma için).
  EXTRA="-demoKonum -demoDurak 30 -demoHassasiyet 25 -haritaAcikligi 1100" \
    shot "$L" 7_sinir_mesafesi 41.02161 29.65196 harita 40
  # 8) İşaretler: araca tam ekran yönlendirme (pusula; simülatörde pusula yok → kuzeye göre ok)
  EXTRA="-demoIsaretler -acYonlendir arac" shot "$L" 8_isaret_yonlendir 41.02150 29.65200 harita 15
  # 9) Saha modu (büyük düğmeler) ve gece (kırmızı) teması, örnek işaretlerle
  EXTRA="-demoIsaretler -sahaModu -geceKirmizi -haritaAcikligi 2200" \
    shot "$L" 9_saha_gece 41.02330 29.65600 harita 20
done

xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
find "$OUT" -name '*.png' | sort
