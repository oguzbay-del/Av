"""geribildirim.py birim testleri (model bağımlılığı yok): python -m pytest tools/kus_sunucu"""
import base64

import pytest

import geribildirim as gb

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 100


def gecerli(**ek):
    return {"tur": "hata", "metin": "Harita açılmıyor", "uygulama": "1.4 (52)", "ios": "26.0.1",
            "cihaz": "iPhone17,1", **ek}


def test_gecerli_en_az_alan():
    g = gb.dogrula({"tur": "oneri", "metin": "  Güzel  "})
    assert g.tur == "oneri" and g.metin == "Güzel" and g.iletisim is None and g.konum is None


def test_tum_alanlar():
    g = gb.dogrula(gecerli(tur="harita", iletisim="a@b.co", konum={"lat": 41.12345, "lon": 29.1},
                           gorsel=base64.b64encode(JPEG).decode()))
    assert g.konum == (41.12345, 29.1) and g.gorsel == JPEG and g.iletisim == "a@b.co"


@pytest.mark.parametrize("veri", [
    [],
    {"tur": "hata"},
    {"tur": "x", "metin": "a"},
    {"tur": "hata", "metin": "   "},
    {"tur": "hata", "metin": 5},
    {"tur": "hata", "metin": "a" * 2001},
    gecerli(bilinmeyen=1),
    gecerli(iletisim="a" * 201),
    gecerli(iletisim="a\nb"),
    gecerli(cihaz="iPhone<script>"),
    gecerli(metin="kontrol\x00"),
    gecerli(konum={"lat": 41, "lon": 29}),                  # harita değil
    gecerli(tur="harita", konum={"lat": 91, "lon": 29}),
    gecerli(tur="harita", konum={"lat": True, "lon": 29}),
    gecerli(tur="harita", konum={"lat": 41, "lon": 29, "z": 1}),
    gecerli(tur="harita", konum=[41, 29]),
    gecerli(gorsel="!!!"),
    gecerli(gorsel=base64.b64encode(b"\x89PNG....").decode()),
    gecerli(gorsel=base64.b64encode(b"\xff\xd8\xff" + b"0" * gb.GORSEL_SINIRI).decode()),
])
def test_gecersiz(veri):
    with pytest.raises(gb.GecersizIstek):
        gb.dogrula(veri)


def test_metin_siniri_tam():
    assert len(gb.dogrula(gecerli(metin="ç" * 2000)).metin) == 2000


def test_hiz_siniri_saat_ve_gun():
    h = gb.HizSiniri(((5, 3600), (20, 86400)))
    t = 1000.0
    assert all(h.izin("1.2.3.4", t + i) for i in range(5))
    assert not h.izin("1.2.3.4", t + 10)
    assert h.izin("5.6.7.8", t + 10), "başka IP etkilenmez"
    # saat dolunca yeniden; günde 20'de durur
    izinli = sum(h.izin("1.2.3.4", t + 3600 * k + j) for k in range(1, 10) for j in range(5))
    assert izinli == 15
    assert h.izin("1.2.3.4", t + 86400 + 1)


def test_hiz_siniri_ip_saklamaz():
    h = gb.HizSiniri()
    h.izin("203.0.113.9", 0)
    assert all("203.0.113.9" not in k for k in h._kayit)


def test_baslik_ve_govde():
    g = gb.dogrula(gecerli(tur="harita", metin="Bu alan\n yasak olmalı " + "x" * 80, iletisim="a@b.co",
                           konum={"lat": 41.123456789, "lon": 29.987654321}))
    b = gb.baslik(g)
    assert b.startswith("[harita] Bu alan yasak olmalı") and len(b) <= len("[harita] ") + 61
    md = gb.govde(g, gorsel_url="https://github.com/x/y/blob/main/ekler/a.jpg?raw=true")
    assert "mlat=41.12346&mlon=29.98765" in md
    assert "```text\nBu alan\n yasak olmalı" in md
    assert "![ek](https://github.com/x/y/blob/main/ekler/a.jpg?raw=true)" in md
    assert "`iPhone17,1`" in md
    assert gb.etiketler(g) == ["geri-bildirim", "harita"]


def test_govde_kod_citi_kacmaz():
    g = gb.dogrula(gecerli(metin="a ```` b @kisi"))
    md = gb.govde(g)
    assert "`````text" in md


class SahteGitHub(gb.GitHub):
    def __init__(self, gorsel_hatasi=False):
        super().__init__("o/r", "t")
        self.cagrilar, self.gorsel_hatasi = [], gorsel_hatasi

    def _istek(self, yontem, yol, veri):
        self.cagrilar.append((yontem, yol, veri))
        if yol.startswith("contents/"):
            if self.gorsel_hatasi:
                raise gb.GitHubHatasi("x")
            return {"content": {"html_url": "https://github.com/o/r/blob/main/" + yol[9:]}}
        return {"number": 7}


def test_gonder_gorselli():
    s = SahteGitHub()
    assert s.gonder(gb.dogrula(gecerli(gorsel=base64.b64encode(JPEG).decode()))) == 7
    (y1, yol1, _), (y2, yol2, v2) = s.cagrilar
    assert y1 == "PUT" and yol1.startswith("contents/ekler/") and yol1.endswith(".jpg")
    assert y2 == "POST" and yol2 == "issues" and "?raw=true" in v2["body"]


def test_gonder_gorsel_hatasinda_konu_yine_acilir():
    s = SahteGitHub(gorsel_hatasi=True)
    assert s.gonder(gb.dogrula(gecerli(gorsel=base64.b64encode(JPEG).decode()))) == 7
    assert "yüklenemedi" in s.cagrilar[-1][2]["body"]


def test_ortamdan(monkeypatch):
    monkeypatch.delenv("GERIBILDIRIM_GITHUB_TOKEN", raising=False)
    assert gb.GitHub.ortamdan() is None
    monkeypatch.setenv("GERIBILDIRIM_GITHUB_TOKEN", "deneme")
    monkeypatch.delenv("GERIBILDIRIM_REPO", raising=False)
    assert gb.GitHub.ortamdan().depo == gb.VARSAYILAN_DEPO
