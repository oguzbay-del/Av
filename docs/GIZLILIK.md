# Av Haritası Gizlilik Politikası

Son güncelleme: 8 Ekim 2026

Bu politika, iOS uygulaması **Av Haritası**'nın ("uygulama") hangi verileri nasıl işlediğini açıklar. Kısaca: uygulamada hesap, reklam, analitik veya izleme yoktur; üçüncü taraf SDK kullanılmaz. Verilerinizin büyük bölümü yalnızca telefonunuzda kalır ve geliştiriciye hiçbir veri gönderilmez.

## 1. Veri sorumlusu

Veri sorumlusu uygulamanın geliştiricisidir: **[Geliştirici adı / e-posta]**

Uygulama geliştiriciye ait bir sunucuyla iletişim kurmaz. Bu nedenle geliştirici, aşağıda anlatılan ve cihazınızda kalan verilere erişemez.

## 2. Cihazınızda işlenen veriler

- **Konum:** Bulunduğunuz yerin avlak haritasında hangi bölgeye düştüğünü, yasak alanlara uzaklığınızı, av saatini (gün doğumu/batımı) değerlendirmek ve sizi uyarmak için kullanılır. Bu değerlendirme tamamen telefonda yapılır. Konum geçmişi, siz iz kaydı başlatmadıkça saklanmaz.
- **Av defteri (Bugünkü avım):** Tür bazında av sayaçlarınız yalnızca cihazda saklanır.
- **Avlanma izin belgesi:** Eklediğiniz ekran görüntüsü, fotoğraf veya PDF telefonda (Apple Vision / PDFKit ile) okunur. Yalnızca şu alanlar saklanır: avlak adı, geçerli gün, türler ve kotalar, belge numarası ve (varsa) karekod bağlantısı. Belgedeki **ad soyad, avcılık belgesi numarası ve izin kartı numarası okunur ama saklanmaz.** Görüntünün kendisi saklanmaz. Belge kayıtları iOS dosya koruması ile şifreli tutulur.
- **GPS izleri:** Yalnızca siz "İz kaydı"nı başlattığınızda konum noktaları (enlem, boylam, rakım, doğruluk, zaman) cihaza kaydedilir.
- **Tanılama verileri:** Apple MetricKit'in sağladığı performans/çökme raporları cihazda saklanır (en fazla 30 rapor). Siz paylaş düğmesine basmadıkça hiçbir yere gönderilmez.
- **Önbellekler ve ayarlar:** Son hava tahmini, görüntülediğiniz harita karoları ve uygulama ayarları cihazda tutulur. BirdNET API anahtarı girerseniz iOS Anahtar Zinciri'nde (Keychain) saklanır.
- **Ses kaydı:** Kuş sesi için yalnızca siz düğmeye bastığınızda yaklaşık 15 saniyelik kayıt alınır ve geçici bir dosyada tutulur. Sunucu adresi girmediyseniz kayıt Apple'ın cihazdaki ses sınıflandırıcısıyla telefonda analiz edilir.

## 3. Cihazınızdan çıkan veriler

Uygulama yalnızca aşağıdaki durumlarda internete veri gönderir:

| Alıcı | Gönderilen | Amaç |
|---|---|---|
| **Open-Meteo** (api.open-meteo.com) | Yaklaşık koordinat (2 ondalık basamağa yuvarlanmış, ~1 km) | Hava ve rüzgâr tahmini. Kimliğinizle ilişkilendirilmez. [Kullanım koşulları ve gizlilik](https://open-meteo.com/en/terms) |
| **OpenStreetMap** (tile.openstreetmap.org) ve **OpenTopoMap** (tile.opentopomap.org) | Harita karosu istekleri | Bu altlıkları seçtiğinizde haritayı göstermek. Sunucular IP adresinizi ve görüntülediğiniz alanı görebilir. [OSMF Gizlilik Politikası](https://osmfoundation.org/wiki/Privacy_Policy), [OpenTopoMap](https://opentopomap.org/about) |
| **Apple** (MapKit / Apple Haritalar) | Apple harita altlıkları, "Yer ara" sorgularınız, yol tarifi | Harita ve arama. [Apple Gizlilik Politikası](https://www.apple.com/legal/privacy/) |
| **Sizin girdiğiniz BirdNET sunucusu** | Ses kaydı, yaklaşık konum (2 ondalık, ~1 km), yılın haftası, varsa API anahtarınız | Kuş türü tahmini. Yalnızca Ayarlar'a adres yazdıysanız ve kayıt yaptığınızda. |
| **Google Haritalar** veya **Apple Haritalar** | Avlağın hedef koordinatı | Yalnızca "Yol tarifi"ne dokunduğunuzda o uygulama/site açılır. |

BirdNET sunucusu sizin kurduğunuz (ör. kendi bilgisayarınız veya Hugging Face Spaces) bir sunucudur; **geliştirici bu sunucuyu işletmez** ve oraya gönderilen verilere erişmez. Bu verilerin sorumluluğu sunucuyu işleten kişidedir.

**Paylaşım:** Konumunuzu paylaşma, GPX iz dosyası dışa aktarma veya tanılama raporu paylaşma yalnızca siz paylaş düğmesine dokunduğunuzda iOS paylaşım menüsüyle, seçtiğiniz uygulamaya/kişiye yapılır.

**Bildirimler ve Live Activity:** Uyarı bildirimleri ve kilit ekranı/Dynamic Island/Apple Watch gösterimi cihazda yerel olarak üretilir; uzaktan (push) bildirim sunucusu kullanılmaz.

## 4. İzinler

- **Konum – Uygulamayı Kullanırken:** Haritada bölgenizi göstermek ve uyarmak için.
- **Konum – Her Zaman (isteğe bağlı):** Arka planda takip açıksa, uygulama kapalıyken yasak alana yaklaştığınızda uyarmak için.
- **Mikrofon:** Yalnızca kuş sesi kaydı için, siz düğmeye bastığınızda.
- **Yerel ağ:** BirdNET sunucunuz ev ağınızdaki bir bilgisayardaysa ona bağlanmak için.
- **Fotoğraflar:** İzin belgesi ya da kuş fotoğrafı seçmek için sistem seçicisi kullanılır. Kuş fotoğrafı yalnızca telefonda (Apple Vision / Core ML) analiz edilir; hiçbir yere gönderilmez ve saklanmaz; uygulama yalnızca seçtiğiniz görseli alır, fotoğraf arşivinizin tamamına erişmez.
- **Bildirimler:** Yasak alan uyarıları için.

İzinleri istediğiniz zaman iPhone Ayarlar › Av Haritası'ndan değiştirebilirsiniz. İzin vermezseniz ilgili özellik çalışmaz; diğerleri çalışmaya devam eder.

## 5. Saklama ve silme

- Uygulamayı silmek, cihazdaki tüm uygulama verilerini (av defteri, izin belgeleri, izler, tanılama raporları, önbellekler, ayarlar) siler.
- Uygulama içinden izleri, izin belgelerini ve av defteri kayıtlarını tek tek silebilirsiniz. Harita karosu önbelleği Ayarlar'dan temizlenebilir.
- BirdNET API anahtarı alanını boşalttığınızda anahtar Anahtar Zinciri'nden kaldırılır.
- Tanılama raporlarının yalnızca son 30 tanesi tutulur.
- Üçüncü tarafların (Open-Meteo, OSM/OpenTopoMap, Apple, BirdNET sunucusu) tuttuğu kayıtlar kendi politikalarına tabidir.

## 6. Çocuklar

Uygulama çocuklara yönelik değildir ve bilerek çocuklardan veri toplamaz.

## 7. KVKK (6698 sayılı Kişisel Verilerin Korunması Kanunu) kapsamında aydınlatma

**Veri sorumlusu:** [Geliştirici adı / e-posta]

**İşleme amaçları:** Konumunuza göre avlak ve av kuralları değerlendirmesi ile uyarı; hava tahmini; harita gösterimi ve yer arama; izin belgesi bilgilerinin ve av defterinin tutulması; isteğe bağlı iz kaydı ve kuş sesi tanıma; uygulama kararlılığının izlenmesi.

**Hukuki sebep:** Veriler, uygulamanın sizin talep ettiğiniz özelliklerini sunabilmek için gerekli olması (KVKK m. 5/2-c, sözleşmenin kurulması veya ifasıyla doğrudan ilgili olma) ve konum, mikrofon gibi izinlerde iOS izin ekranında verdiğiniz açık rıza (m. 5/1) temelinde işlenir. Rızanızı iPhone Ayarlar'ından istediğiniz zaman geri alabilirsiniz.

**Aktarım:** Geliştiriciye veri aktarılmaz. Bölüm 3'te sayılan alıcılara veriler, sizin başlattığınız işlemlerle doğrudan cihazınızdan gönderilir. Open-Meteo, OpenStreetMap/OpenTopoMap ve Apple sunucuları **yurt dışında** bulunabilir; bu aktarım, ilgili özelliği kullanmanız ve izinlerinizle gerçekleşir (KVKK m. 9). Bu özellikleri kullanmayarak (ör. Apple veya önbellekteki altlıkları seçmek, BirdNET adresini boş bırakmak) aktarımı sınırlayabilirsiniz.

**Toplama yöntemi:** Cihaz sensörleri (GPS, mikrofon), sizin seçtiğiniz dosya/görseller ve uygulamaya girdiğiniz bilgiler aracılığıyla, otomatik ve kısmen otomatik yollarla.

**Haklarınız (KVKK m. 11):** Kişisel verinizin işlenip işlenmediğini öğrenme, işlenmişse bilgi talep etme, işleme amacını ve amacına uygun kullanılıp kullanılmadığını öğrenme, aktarıldığı üçüncü kişileri bilme, eksik/yanlış işlenmişse düzeltilmesini, silinmesini veya yok edilmesini isteme ve bunun aktarılan kişilere bildirilmesini isteme, otomatik analiz sonucu aleyhinize bir sonuca itiraz etme ve kanuna aykırı işleme nedeniyle zarara uğrarsanız zararın giderilmesini talep etme.

Cihazınızdaki verileri bölüm 5'teki yollarla kendiniz görüntüleyip silebilirsiniz. Geliştirici bu verilere erişemediği için en hızlı yol budur.

**Başvuru:** Taleplerinizi [Geliştirici adı / e-posta] adresine yazılı olarak iletebilirsiniz. Başvurular en geç 30 gün içinde ücretsiz yanıtlanır. Yanıt verilmemesi veya yanıttan memnun kalmamanız hâlinde Kişisel Verileri Koruma Kurulu'na şikâyette bulunabilirsiniz.

## 8. AB / GDPR kullanıcıları için not

Avrupa Birliği'nden kullanıyorsanız, GDPR kapsamında erişim, düzeltme, silme, işlemeyi kısıtlama, itiraz ve veri taşınabilirliği haklarına sahipsiniz ve bulunduğunuz ülkenin denetim makamına şikâyette bulunabilirsiniz. İşlemenin dayanağı, istediğiniz hizmeti sunmak (m. 6/1-b) ve izin verdiğiniz durumlarda rızanızdır (m. 6/1-a). Talepler için yukarıdaki iletişim adresini kullanabilirsiniz.

## 9. Değişiklikler

Bu politika uygulamadaki değişikliklere göre güncellenebilir. Önemli değişiklikler bu sayfada ve gerekirse uygulama içinde duyurulur. Güncel sürüm her zaman bu belgedir.

Son güncelleme: 8 Ekim 2026
