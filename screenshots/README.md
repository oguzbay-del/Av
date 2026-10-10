# Ekran görüntüleri

`main` üzerinde GitHub Actions ile üretildi (simülatör, iPhone 17 Pro Max, iOS 26).

| Klasör | İçerik |
|---|---|
| `appstore/{tr,en}/` | App Store 6.9" ham görüntüler (1320×2868, saydamlık yok). App Store Connect'e bunlar yüklenir. |
| `appstore_framed/{tr,en}/` | Başlıklı ve çerçeveli tanıtım sürümleri (aynı boyut). |
| `uygulama/` | Genel uygulama ekranları (TR ve EN). |
| `onizleme_{tr,en}.jpg` | Çerçeveli görüntülerin küçük önizlemesi. |

Yeniden üretmek için:

- Actions › **App Store ekran görüntüleri** › Run workflow
- Actions › **Ekran görüntüleri** › Run workflow

Komut dosyaları: `tools/appstore_screenshots.sh`, `tools/frame_screenshots.py`, `tools/screenshots.sh`.
