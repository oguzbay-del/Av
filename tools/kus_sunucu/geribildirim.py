"""Uygulama içi geri bildirim: doğrulama, hız sınırı ve GitHub konusu (issue) üretimi.

`POST /geribildirim` (app.py) gelen JSON'u burada doğrular ve geliştiricinin ÖZEL GitHub
deposunda bir konu açar. Bu modül yalnızca standart kitaplığı kullanır (birim testleri
model bağımlılıkları olmadan koşar: `python -m pytest tools/kus_sunucu`).

Gizlilik: IP adresi ve istek başlıkları saklanmaz. Hız sınırı bellekte, IP'nin süreç başına
rastgele tuzla karılmış özetiyle tutulur; kopya kapanınca silinir. Konuya yalnızca
kullanıcının formda gördüğü alanlar yazılır.
"""
import base64
import binascii
import hashlib
import json
import math
import os
import re
import secrets
import time
import urllib.error
import urllib.request
import uuid
from collections import defaultdict, deque
from dataclasses import dataclass

TURLER = {
    "hata": ("Hata", "hata"),
    "oneri": ("Öneri", "oneri"),
    "harita": ("Harita / alan", "harita"),
    "kus": ("Kuş tanıma", "kus"),
}
ALANLAR = {"tur", "metin", "iletisim", "uygulama", "ios", "cihaz", "konum", "gorsel"}
METIN_SINIRI = 2000
ILETISIM_SINIRI = 200
BILGI_SINIRI = 40          # uygulama / ios / cihaz
GORSEL_SINIRI = 1_572_864  # 1,5 MB (çözülmüş JPEG)
# base64 4/3 büyütür; alanlar ve JSON için pay
GOVDE_SINIRI = GORSEL_SINIRI * 4 // 3 + 16 * 1024
BASLIK_UZUNLUGU = 60
UYGULAMA_BASLIGI = "x-av-uygulama"  # gürültü süzgeci (güvenlik değil): uygulama "1" gönderir
VARSAYILAN_DEPO = "oguzbay-del/av-geribildirim"

_BILGI_DESENI = re.compile(r"^[A-Za-z0-9 .,_()+-]*$")
_KONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


class GecersizIstek(ValueError):
    """İstemciye 400 olarak dönen doğrulama hatası (mesaj Türkçe)."""


@dataclass(frozen=True)
class Geribildirim:
    tur: str
    metin: str
    iletisim: str | None = None
    uygulama: str | None = None
    ios: str | None = None
    cihaz: str | None = None
    konum: tuple[float, float] | None = None
    gorsel: bytes | None = None


def _metin_alani(veri: dict, ad: str, sinir: int, zorunlu: bool = False, cok_satir: bool = False) -> str | None:
    deger = veri.get(ad)
    if deger is None:
        if zorunlu:
            raise GecersizIstek(f"'{ad}' alanı zorunlu.")
        return None
    if not isinstance(deger, str):
        raise GecersizIstek(f"'{ad}' metin olmalı.")
    deger = deger.replace("\r\n", "\n").strip()
    if _KONTROL.search(deger) or (not cok_satir and "\n" in deger):
        raise GecersizIstek(f"'{ad}' geçersiz karakter içeriyor.")
    if len(deger) > sinir:
        raise GecersizIstek(f"'{ad}' en çok {sinir} karakter olabilir.")
    if not deger:
        if zorunlu:
            raise GecersizIstek(f"'{ad}' boş olamaz.")
        return None
    return deger


def _sayi(d, ad: str, alt: float, ust: float) -> float:
    if isinstance(d, bool) or not isinstance(d, (int, float)) or not math.isfinite(d) or not alt <= d <= ust:
        raise GecersizIstek(f"Konum '{ad}' geçersiz.")
    return float(d)


def dogrula(veri) -> Geribildirim:
    """Gelen JSON nesnesini sıkı biçimde doğrular. Bilinmeyen alan reddedilir."""
    if not isinstance(veri, dict):
        raise GecersizIstek("Gövde bir JSON nesnesi olmalı.")
    fazla = set(veri) - ALANLAR
    if fazla:
        raise GecersizIstek("Bilinmeyen alan: " + ", ".join(sorted(fazla)))
    tur = veri.get("tur")
    if tur not in TURLER:
        raise GecersizIstek("'tur' şunlardan biri olmalı: " + ", ".join(TURLER))
    metin = _metin_alani(veri, "metin", METIN_SINIRI, zorunlu=True, cok_satir=True)
    iletisim = _metin_alani(veri, "iletisim", ILETISIM_SINIRI)
    bilgi = {}
    for ad in ("uygulama", "ios", "cihaz"):
        d = _metin_alani(veri, ad, BILGI_SINIRI)
        if d is not None and not _BILGI_DESENI.match(d):
            raise GecersizIstek(f"'{ad}' geçersiz karakter içeriyor.")
        bilgi[ad] = d
    konum = None
    if veri.get("konum") is not None:
        if tur != "harita":
            raise GecersizIstek("Konum yalnızca harita bildirimlerinde gönderilebilir.")
        k = veri["konum"]
        if not isinstance(k, dict) or set(k) != {"lat", "lon"}:
            raise GecersizIstek("'konum' {lat, lon} olmalı.")
        konum = (_sayi(k["lat"], "lat", -90, 90), _sayi(k["lon"], "lon", -180, 180))
    gorsel = None
    if veri.get("gorsel") is not None:
        g = veri["gorsel"]
        if not isinstance(g, str) or len(g) > GORSEL_SINIRI * 4 // 3 + 8:
            raise GecersizIstek("Görsel en çok 1,5 MB olabilir.")
        try:
            gorsel = base64.b64decode(g, validate=True)
        except (binascii.Error, ValueError):
            raise GecersizIstek("Görsel base64 olarak okunamadı.") from None
        if len(gorsel) > GORSEL_SINIRI:
            raise GecersizIstek("Görsel en çok 1,5 MB olabilir.")
        if not gorsel.startswith(b"\xff\xd8\xff"):
            raise GecersizIstek("Görsel JPEG olmalı.")
    return Geribildirim(tur=tur, metin=metin, iletisim=iletisim, konum=konum, gorsel=gorsel, **bilgi)


class HizSiniri:
    """Anahtar (IP) başına kayan pencereli sınırlar, ör. saatte 5 ve günde 20 istek.

    Anahtarlar süreç başına rastgele tuzla karılır; IP'nin kendisi bellekte de tutulmaz.
    """

    def __init__(self, sinirlar=((5, 3600), (20, 86400)), en_cok_anahtar: int = 10000):
        self.sinirlar = tuple(sinirlar)
        self.pencere = max(s for _, s in self.sinirlar)
        self.en_cok_anahtar = en_cok_anahtar
        self._tuz = secrets.token_bytes(16)
        self._kayit: dict[str, deque] = defaultdict(deque)

    def _anahtar(self, ham: str) -> str:
        return hashlib.sha256(self._tuz + ham.encode()).hexdigest()[:24]

    def izin(self, ham_anahtar: str, simdi: float | None = None) -> bool:
        """İsteğe izin verilirse True döner ve isteği sayar; sınır aşıldıysa False (sayılmaz)."""
        simdi = time.monotonic() if simdi is None else simdi
        q = self._kayit[self._anahtar(ham_anahtar)]
        while q and simdi - q[0] >= self.pencere:
            q.popleft()
        for adet, sure in self.sinirlar:
            if sum(1 for t in q if simdi - t < sure) >= adet:
                return False
        q.append(simdi)
        if len(self._kayit) > self.en_cok_anahtar:
            for k in [k for k, v in self._kayit.items() if not v or simdi - v[-1] >= self.pencere]:
                del self._kayit[k]
        return True


def tek_satir(metin: str) -> str:
    return " ".join(metin.split())


def baslik(g: Geribildirim) -> str:
    ozet = tek_satir(g.metin)
    if len(ozet) > BASLIK_UZUNLUGU:
        ozet = ozet[:BASLIK_UZUNLUGU].rstrip() + "…"
    return f"[{g.tur}] {ozet}"


def harita_baglantisi(lat: float, lon: float) -> str:
    la, lo = f"{round(lat, 5):.5f}", f"{round(lon, 5):.5f}"
    return f"https://www.openstreetmap.org/?mlat={la}&mlon={lo}#map=17/{la}/{lo}"


def _kod(metin: str) -> str:
    """Kullanıcı metnini Markdown olarak yorumlanmayacak biçimde (çit bloğu) yazar."""
    en_uzun = max((len(m) for m in re.findall(r"`+", metin)), default=0)
    cit = "`" * max(3, en_uzun + 1)
    return f"{cit}text\n{metin}\n{cit}"


def _satir_ici(metin: str) -> str:
    return "`" + metin.replace("`", "'") + "`"


def govde(g: Geribildirim, gorsel_url: str | None = None, gorsel_hatasi: bool = False) -> str:
    """Konu gövdesi (Markdown). Kullanıcı metinleri kod olarak yazılır (bahsetme/bağlantı işlenmez)."""
    satirlar = [f"**Tür:** {TURLER[g.tur][0]}", "", "**Metin:**", "", _kod(g.metin), ""]
    if g.iletisim:
        satirlar += [f"**İletişim:** {_satir_ici(g.iletisim)}", ""]
    if g.konum:
        lat, lon = g.konum
        satirlar += [f"**Konum:** [{lat:.5f}, {lon:.5f}]({harita_baglantisi(lat, lon)})", ""]
    if gorsel_url:
        satirlar += ["**Görsel:**", "", f"![ek]({gorsel_url})", ""]
    elif gorsel_hatasi:
        satirlar += ["**Görsel:** yüklenemedi", ""]
    bilgi = [f"{ad}: {_satir_ici(d)}" for ad, d in (("Uygulama", g.uygulama), ("iOS", g.ios), ("Cihaz", g.cihaz)) if d]
    if bilgi:
        satirlar += ["---", " · ".join(bilgi)]
    return "\n".join(satirlar).rstrip() + "\n"


def etiketler(g: Geribildirim) -> list[str]:
    return ["geri-bildirim", TURLER[g.tur][1]]


class GitHubHatasi(RuntimeError):
    pass


class GitHub:
    """Özel depoda konu açan küçük istemci (yalnızca urllib)."""

    def __init__(self, depo: str, token: str, zaman_asimi: float = 20):
        self.depo, self._token, self.zaman_asimi = depo, token, zaman_asimi

    @classmethod
    def ortamdan(cls) -> "GitHub | None":
        token = os.environ.get("GERIBILDIRIM_GITHUB_TOKEN", "").strip()
        if not token:
            return None
        return cls(os.environ.get("GERIBILDIRIM_REPO", "").strip() or VARSAYILAN_DEPO, token)

    def _istek(self, yontem: str, yol: str, veri: dict) -> dict:
        istek = urllib.request.Request(
            f"https://api.github.com/repos/{self.depo}/{yol}", method=yontem,
            data=json.dumps(veri).encode(),
            headers={"Authorization": f"Bearer {self._token}", "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "av-haritasi-geribildirim",
                     "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(istek, timeout=self.zaman_asimi) as y:
                return json.loads(y.read() or b"{}")
        except (urllib.error.URLError, TimeoutError, ValueError) as e:
            kod = getattr(e, "code", None)
            raise GitHubHatasi(f"GitHub {yontem} {yol.split('/')[0]}: {kod or type(e).__name__}") from None

    def gorsel_yukle(self, veri: bytes) -> str:
        yol = f"ekler/{uuid.uuid4()}.jpg"
        y = self._istek("PUT", f"contents/{yol}", {"message": "Geri bildirim eki",
                                                   "content": base64.b64encode(veri).decode()})
        url = (y.get("content") or {}).get("html_url")
        if not url:
            raise GitHubHatasi("GitHub contents: html_url yok")
        return url + "?raw=true"

    def gonder(self, g: Geribildirim) -> int:
        """Görseli (varsa) yükler, konuyu açar ve konu numarasını döndürür."""
        gorsel_url, hata = None, False
        if g.gorsel:
            try:
                gorsel_url = self.gorsel_yukle(g.gorsel)
            except GitHubHatasi:
                hata = True  # konu yine açılsın; metin kaybolmasın
        y = self._istek("POST", "issues", {"title": baslik(g), "body": govde(g, gorsel_url, hata),
                                           "labels": etiketler(g)})
        return int(y.get("number") or 0)
