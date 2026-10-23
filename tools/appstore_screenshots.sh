#!/bin/bash
# App Store ürün sayfası ekran görüntüleri (6.9" iPhone, 1320×2868 dikey, alfa kanalsız PNG).
# Türkçe ve İngilizce, ürün sayfasındaki sırayla 10 sahne çeker (App Store'da dil başına en çok 10):
#   screenshots/appstore/<tr|en>/<n>_<ad>.png
# GitHub Actions (macOS, Xcode 26) üzerinde çalışır: .github/workflows/appstore-ekran.yml
# Önce uygulama simülatör için derlenmiş olmalı (ios/build/Debug-iphonesimulator/AvHaritasi.app).
# Gerekli: python3 + Pillow (alfa kanalını kaldırmak için).
#
# KUME=kilavuz: aynı simülatörle web sitesindeki kullanım kılavuzu görselleri (Kilavuz.json `gorsel` sahneleri):
#   screenshots/kilavuz/<tr|en>/<sahne>.png → tools/kilavuz_gorsel.py küçültüp docs/site/gorsel/'e yazar.
# KUME=yerlesim: harita ekranı yerleşim denetimi (küçük/büyük iPhone, normal/saha modu, açık kartlar, yasak alan):
#   screenshots/yerlesim/<cihaz>/<sahne>.png (YERLESIM_CIHAZLAR ile cihazlar değiştirilebilir; boyut denetimi yok)
set -euo pipefail
APP=${APP:-ios/build/Debug-iphonesimulator/AvHaritasi.app}
BID=com.example.avharitasi
KUME=${KUME:-appstore}
if [ "$KUME" = kilavuz ]; then
  OUT=${OUT:-screenshots/kilavuz}
elif [ "$KUME" = yerlesim ]; then
  OUT=${OUT:-screenshots/yerlesim}
  LANGS=${LANGS:-tr}
else
  OUT=${OUT:-screenshots/appstore}
fi
WANT_W=1320
WANT_H=2868
LANGS=${LANGS:-"tr en"}

[ -d "$APP" ] || { echo "Uygulama bulunamadı: $APP (önce xcodebuild ile derleyin)"; exit 1; }
python3 -c 'import PIL' 2>/dev/null || { echo "Pillow gerekli: python3 -m pip install --user pillow"; exit 1; }

# --- Simülatör: en yeni iOS çalışma zamanında DEVICE_NAME (varsayılan "iPhone 17 Pro Max"; yoksa en yeni
# "Pro Max"; o da yoksa oluştur). KUME=yerlesim birkaç cihazı sırayla kullanır (aşağıda).
pick_device() {  # cihaz-adı
  DEVICE_NAME="$1" xcrun simctl list -j | DEVICE_NAME="$1" python3 -c '
import json, os, re, sys, subprocess
j = json.load(sys.stdin)
want = os.environ["DEVICE_NAME"]
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
promax = want.endswith("Pro Max")
udid = pick(lambda n: n == want) or (promax and pick(lambda n: re.fullmatch(r"iPhone \d+ Pro Max", n)))
if not udid:
    types = rt.get("supportedDeviceTypes", j["devicetypes"])
    exact = [t for t in types if t["name"] == want]
    if not exact and promax:
        exact = [t for t in types if re.fullmatch(r"iPhone \d+ Pro Max", t["name"])]
        exact.sort(key=lambda t: [-x for x in ver(t["name"])])
    if not exact:
        sys.exit("Cihaz tipi bulunamadı: " + want)
    t = exact[0]
    udid = subprocess.check_output(["xcrun", "simctl", "create", "AppStore " + t["name"], t["identifier"], rt["identifier"]], text=True).strip()
    print("Oluşturuldu: " + t["name"] + " (" + rt["name"] + ")", file=sys.stderr)
else:
    print("Çalışma zamanı: " + rt["name"], file=sys.stderr)
print(udid)
'
}

prepare_device() {  # cihaz-adı → DEV, DATA
  DEV=$(pick_device "$1")
  echo "Simülatör: $1 ($DEV)"
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
  # Uygulamanın veri klasörü (önceki sahnenin örnek işaretleri silinsin diye)
  DATA=$(xcrun simctl get_app_container "$DEV" "$BID" data 2>/dev/null || true)
  # Kuş tanıma sahneleri için örnek görüntüler (CC0; tools/ekran_demo/README.md). Simülatörde kamera ve galeri
  # seçimi olmadığından DEBUG derlemesi -kusDemo ile bunlardan hazır sonuç gösterir.
  if [ -n "$DATA" ]; then
    mkdir -p "$DATA/Documents/ekran_demo"
    cp tools/ekran_demo/*.jpg "$DATA/Documents/ekran_demo/"
  fi
}

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
  setd bannerExpanded -bool "${BANNER:-false}"
  setd panelExpanded -bool false
  setd acceptedDisclaimer_2026 -bool true
  # "Haritayı indir" önerisi görüntüleri kalabalıklaştırmasın (CI'da hiç çevrimdışı paket yok)
  setd offlinePromptShown -bool "${OFFLINE_ONERI_GIZLI:-true}"
  # TANITIM=false: ilk açılış tanıtımı görünsün
  setd tanitimGosterildi -bool "${TANITIM:-true}"
  setd baseLayer -string "appleHybrid"
  setd showZones -bool true
  setd showOfficial -bool false
  setd showScentCone -bool "${CONE:-false}"
  setd highlightedAvlak -string "${AVLAK:-}"
  # Av günü, av saati içinde bir an (yukarıda seçildi)
  setd debugNow -string "$DEBUG_NOW"
  xcrun simctl location "$DEV" set "$lat,$lon"
  # Sekme argüman alanıyla da verilir: uygulama Ayarlar'da açılınca selectedTab'ı kendisi "harita"ya yazar
  # (AvHaritasiApp) ve o andan sonra simülatörde `defaults write` ile verilen sekme etkisiz kalıyordu.
  # shellcheck disable=SC2086
  if [ "$lang" = "en" ]; then
    xcrun simctl launch "$DEV" "$BID" -AppleLanguages "(en)" -AppleLocale en_GB -selectedTab "$tab" ${EXTRA:-}
  else
    xcrun simctl launch "$DEV" "$BID" -AppleLanguages "(tr)" -AppleLocale tr_TR -selectedTab "$tab" ${EXTRA:-}
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
  if [ "$KUME" != yerlesim ] && { [ "$w" != "$WANT_W" ] || [ "$h" != "$WANT_H" ]; }; then
    echo "HATA: $file boyutu ${w}×${h}; beklenen ${WANT_W}×${WANT_H}"
    exit 1
  fi
  echo "  $file (${w}×${h})"
}

# Hava durumunu önceden ısıt (Open-Meteo önbelleğe alınır; sonraki çekimlerde hızlı görünür)
warm_up() {
  xcrun simctl location "$DEV" set "41.10,29.53"
  setd acceptedDisclaimer_2026 -bool true
  setd tanitimGosterildi -bool true
  setd debugNow -string "$DEBUG_NOW"
  xcrun simctl launch "$DEV" "$BID" -AppleLanguages "(tr)" >/dev/null || true
  sleep 20
}

# Harita ekranı yerleşimi: her sahne normal ve saha modunda (S="" / "-fieldMode YES")
yerlesim_scenes() {
  local D=$1 M S
  for M in normal saha; do
    if [ "$M" = saha ]; then S="-fieldMode YES"; else S=""; fi
    EXTRA="$S" shot "$D" "${M}_guvenli" 41.10 29.53 harita 20
    EXTRA="$S -sorgula 41.0150,29.6420 -haritaAcikligi 4000" shot "$D" "${M}_sorgu" 41.10 29.53 harita 20
    EXTRA="$S" shot "$D" "${M}_yasak" 41.01 29.64 harita 20
    OFFLINE_ONERI_GIZLI=false EXTRA="$S -sorgula 41.0150,29.6420 -haritaAcikligi 4000" \
      shot "$D" "${M}_yasak_sorgu_oneri" 41.01 29.64 harita 20
    EXTRA="$S -demoKonum -demoDurak 30 -demoHassasiyet 25 -haritaAcikligi 1100" \
      shot "$D" "${M}_sinir" 41.02161 29.65196 harita 40
    EXTRA="$S -demoKonum -demoDurak 3 -demoKonumYasi 300 -haritaAcikligi 1500" \
      shot "$D" "${M}_gps_eski" 41.02350 29.65650 harita 25
  done
}

if [ "$KUME" = yerlesim ]; then
  IFS=',' read -r -a CIHAZLAR <<< "${YERLESIM_CIHAZLAR:-iPhone SE (3rd generation),iPhone 17 Pro,iPhone 17 Pro Max}"
  for C in "${CIHAZLAR[@]}"; do
    prepare_device "$C"
    warm_up
    D=$(echo "$C" | tr -c 'A-Za-z0-9\n' '_')
    rm -f "$OUT/$D"/*.png
    yerlesim_scenes "$D"
    xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
    xcrun simctl shutdown "$DEV" 2>/dev/null || true
  done
  find "$OUT" -name '*.png' | sort
  exit 0
fi

prepare_device "${DEVICE_NAME:-iPhone 17 Pro Max}"
warm_up

# Kullanım kılavuzu sahneleri (web sitesi). Adlar Kilavuz.json'daki `gorsel` değerleridir.
kilavuz_scenes() {
  local L=$1
  # Harita ve renkler: Sarıkavak çevresi, geniş görünüm (kırmızı yasak alan ve çevresindeki avlaklar)
  EXTRA="-haritaAcikligi 9000" shot "$L" harita 41.0350 29.6700 harita 20
  # Bir noktayı sorgulamak: Sarıkavak'ta (ava kapalı) bir nokta sorgulanmış, kart açık
  EXTRA="-sorgula 41.0150,29.6420 -haritaAcikligi 4000" shot "$L" sorgula 41.02161 29.65196 harita 20
  # Yasak alan uyarısı
  shot "$L" yasak_alan 41.01 29.64 harita 20
  # Yaklaşma mesafesi: sınıra ~200 m
  EXTRA="-demoKonum -demoDurak 30 -demoHassasiyet 25 -haritaAcikligi 1100" \
    shot "$L" sinir_mesafesi 41.02161 29.65196 harita 40
  # GPS bayat: demo konumları 5 dk eski gelir → "Konum güncel değil", ayrıntı açık
  BANNER=true EXTRA="-demoKonum -demoDurak 3 -demoKonumYasi 300 -haritaAcikligi 1500" \
    shot "$L" gps_eski 41.02350 29.65650 harita 25
  shot "$L" bugun 41.10 29.53 bugun 25
  CONE=true shot "$L" ruzgar 41.10 29.53 harita 25
  shot "$L" kurallar 41.10 29.53 kurallar 10
  shot "$L" kus_ses 41.10 29.53 kus 10
  EXTRA="-kusDemo foto" shot "$L" kus_foto 41.10 29.53 kus 12
  EXTRA="-kusDemo video" shot "$L" kus_video 41.10 29.53 kus 12
  EXTRA="-ayarlarKaydir cevrimici" shot "$L" cevrimici 41.10 29.53 ayarlar 16
  EXTRA="-demoIsaretler -acYonlendir arac" shot "$L" isaret_yonlendir 41.02150 29.65200 harita 15
  EXTRA="-demoIsaretler -fieldMode YES -nightRedMode on -haritaAcikligi 2200" \
    shot "$L" saha_gece 41.02330 29.65600 harita 20
  EXTRA="-ayarlarKaydir takip" shot "$L" ayarlar_takip 41.10 29.53 ayarlar 16
  EXTRA="-ayarlarKaydir gizlilik" shot "$L" ayarlar_gizlilik 41.10 29.53 ayarlar 16
  EXTRA="-yardimAc" shot "$L" yardim 41.10 29.53 ayarlar 16
}

for L in $LANGS; do
  echo "== $L =="
  if [ "$KUME" = kilavuz ]; then
    rm -f "$OUT/$L"/*.png
    kilavuz_scenes "$L"
    continue
  fi
  # Eski sahne adları (depodaki önceki görüntüler) karışmasın
  rm -f "$OUT/$L"/*.png
  # 1) Yasak alan: Sarıkavak Devlet Avlağı (2026-27 ava kapalı) — kırmızı "AVLANMAYIN" şeridi, vektör bölgeler
  shot "$L" 1_yasak_alan 41.01 29.64 harita 20
  # 2) Güvenli: Şile Devlet Avlağı, avlak kartı vurgulu — yeşil durum
  AVLAK="Şile Devlet Avlağı" shot "$L" 2_avlanabilir_avlak 41.10 29.53 harita 20
  # 3) Sınır mesafesi: demo yürüyüşü (Sarıkavak) yasak alana ~200 m kala (30. adımda) durur — turuncu "Dikkat",
  #    "Sınıra … m" çipi, sınıra kesikli çizgi ve GPS hassasiyet dairesi. Simülatör konumu da aynı noktada
  #    (MapKit'in mavi noktası ve ilk yakınlaşma için).
  EXTRA="-demoKonum -demoDurak 30 -demoHassasiyet 25 -haritaAcikligi 1100" \
    shot "$L" 3_sinir_mesafesi 41.02161 29.65196 harita 40
  # 4) Bugün: av günü, av saati, hava, av defteri (hava durumunun yüklenmesini bekle)
  shot "$L" 4_bugun 41.10 29.53 bugun 25
  # 5) Rüzgâr rozeti ve koku konisi
  CONE=true shot "$L" 5_ruzgar_koku_konisi 41.10 29.53 harita 25
  # 6) Fotoğraftan tanıma: kuş bulucunun sarı çerçevesi (1) ve ikinci kuş (2), farklı türler
  EXTRA="-kusDemo foto" shot "$L" 6_kus_foto 41.10 29.53 kus 12
  # 7) Videodan tanıma: seçilen 10 sn'lik bölüm, zaman çizelgesi, görüntü + ses birleşik sonuç
  EXTRA="-kusDemo video" shot "$L" 7_kus_video 41.10 29.53 kus 12
  # 10) İlk açılış tanıtımı: "Yasak alan uyarıları susturulmaz" sayfası (tanıtımın 2. sayfası)
  TANITIM=false EXTRA="-tanitimSayfa 1" shot "$L" 10_tanitim 41.10 29.53 harita 10
  # 8) İşaretler: araca tam ekran yönlendirme (pusula; simülatörde pusula yok → kuzeye göre ok)
  EXTRA="-demoIsaretler -acYonlendir arac" shot "$L" 8_isaret_yonlendir 41.02150 29.65200 harita 15
  # 9) Saha modu (büyük düğmeler) ve gece (kırmızı) teması, örnek işaretlerle. Ayarlar UserDefaults argüman
  #    alanından verilir (kaydedilmez; sonraki sahneler, ör. İngilizce görüntüler, gece temasında kalmaz)
  EXTRA="-demoIsaretler -fieldMode YES -nightRedMode on -haritaAcikligi 2200" \
    shot "$L" 9_saha_gece 41.02330 29.65600 harita 20
done

xcrun simctl terminate "$DEV" "$BID" 2>/dev/null || true
find "$OUT" -name '*.png' | sort
