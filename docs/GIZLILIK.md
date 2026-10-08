# Av Haritası — Gizlilik politikası

Son güncelleme: 8 Ekim 2026 · [English](PRIVACY.md)

Av Haritası bağımsız, resmi olmayan bir uygulamadır. Hesap, reklam, analiz aracı ya da üçüncü taraf izleme
yazılımı (SDK) içermez. Geliştiricinin çalıştırdığı bir sunucu yoktur; geliştirici sizinle ilgili hiçbir veri almaz.

## Cihazda kalan veriler

- **Konum:** bulunduğunuz yerin avlak haritasındaki durumunu hesaplamak için cihazda kullanılır. Konum geçmişi
  sunucuya gönderilmez. İz kaydını siz başlatırsanız iz yalnızca cihazda saklanır; GPX dışa aktarma ve konum
  paylaşma yalnızca sizin seçtiğiniz uygulamaya ya da kişiye gider.
- **Avlanma İzin Belgesi:** eklediğiniz görüntü ya da PDF telefonda (Apple Vision / PDFKit) okunur. Avlak, gün,
  tür ve kota bilgisi saklanır; ad soyad ve belge/kart numaraları saklanmaz.
- **Av defteri, ayarlar, tanı raporları:** yalnızca cihazda. Tanı raporlarını (MetricKit) yalnızca siz
  paylaşırsanız gönderilir.

## Cihazdan çıkan veriler

| Ne zaman | Nereye | Ne gönderilir |
|---|---|---|
| Hava ve rüzgâr tahmini | [Open-Meteo](https://open-meteo.com) | Bulunduğunuz yerin koordinatları (4 ondalık basamak, ~10 m) |
| Harita karoları (OSM / Topo altlık seçilirse) | OpenStreetMap, OpenTopoMap | Görüntülenen harita karolarının adresleri |
| Apple haritası, arama, yol tarifi | Apple (MapKit) / seçerseniz Google Haritalar | Apple'ın ya da Google'ın kendi politikalarına göre |
| Kuş sesi tanıma (yalnızca sunucu adresi girdiyseniz ve düğmeye bastığınızda) | **Sizin belirlediğiniz** BirdNET sunucusu | 15 sn'lik ses kaydı, koordinatlar, yılın haftası |

Bu verilerle sizi tanımlayan bir hesap ya da kimlik ilişkilendirilmez.

## İzinler

- **Konum (Kullanırken):** haritadaki durum ve uyarılar.
- **Konum (Her Zaman):** yalnızca Ayarlar'da "Uygulama kapalıyken de uyar"ı açarsanız; yasak alana yaklaşınca
  uyarmak için.
- **Mikrofon:** yalnızca Kuş Sesi sekmesinde düğmeye bastığınızda.
- **Bildirimler:** yasak alan uyarıları.
- **Yerel ağ:** kuş sesi sunucusu evinizdeki bir bilgisayardaysa.

Tüm izinleri iPhone Ayarlar › Av Haritası'ndan geri alabilirsiniz. Uygulamayı silmek cihazdaki tüm verilerini siler.

## Çocuklar

Uygulama avcılara yöneliktir ve çocuklardan bilerek veri toplamaz.

## İletişim

Sorular ve talepler için: <https://github.com/oguzbay-del/Av/issues>
