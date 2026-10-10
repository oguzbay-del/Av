# Av Haritası Gizlilik Politikası

Son güncelleme: 9 Ekim 2026

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
- **Saha kaydı (isteğe bağlı):** Ayarlar › Gelişmiş › Tanı raporları › "Saha kaydı" açıkken uygulama, sahada ne yaptığını olay olay cihaza yazar: açılış/arka plan geçişleri, konum ölçümleri (enlem/boylam 4 ondalığa, yaklaşık 10 m'ye yuvarlanmış; doğruluk, yaş, hız; en çok 10 saniyede bir), uyarı seviyesi değişimleri ve gönderilen uyarılar, GPS kesintileri ve konum hataları, pil tasarrufu kademesi, güvenli daire (bölge izleme) olayları, demo modu, hava durumu alınıp alınamadığı (koordinatsız), internet bağlantısı ve Live Activity durumu. Kayıt **konum içerir**; yalnızca telefonda, iOS dosya korumasıyla şifreli (telefon açıldıktan sonraki ilk kilit açmaya kadar okunamaz; böylece telefon cepte kilitliyken de yazılabilir) ve iCloud/iTunes yedeğine alınmadan tutulur. 7 günden eski olaylar uygulama açılışında (ve açık kaldıkça günde bir) kendiliğinden silinir; dosya en çok ~4 MB'tır. Geliştiriciye ya da başka bir yere gönderilmez; yalnızca siz "Saha kaydını paylaş"a dokunursanız iOS paylaşım menüsüyle seçtiğiniz kişiye/uygulamaya gider. Varsayılan olarak tüm sürümlerde kapalıdır; yalnızca siz açarsanız kaydedilir ve istediğiniz zaman kapatıp "Kaydı sil" ile silebilirsiniz.
- **Önbellekler ve ayarlar:** Son hava tahmini, görüntülediğiniz harita karoları ve uygulama ayarları cihazda tutulur.
- **Çevrimdışı harita:** İndirdiğiniz topoğrafik harita paketi cihazda (iCloud yedeğine alınmadan) saklanır; harita internetsiz, tamamen telefonda çizilir.
- **Ses kaydı:** Kuş sesi için yalnızca siz düğmeye bastığınızda yaklaşık 15 saniyelik kayıt alınır ve geçici bir dosyada tutulur. Kayıt **yalnızca telefonda**, uygulamayla gelen BirdNET modeliyle (tür düzeyinde, internetsiz) analiz edilir. Ses kaydı ve konum hiçbir zaman telefondan çıkmaz; tür listesini daraltmak için yalnızca tarihten hesaplanan hafta ve uygulamayla gelen İstanbul tür listesi kullanılır.

## 3. Cihazınızdan çıkan veriler

Uygulama yalnızca aşağıdaki durumlarda internete veri gönderir:

| Alıcı | Gönderilen | Amaç |
|---|---|---|
| **Open-Meteo** (api.open-meteo.com) | Yaklaşık koordinat (2 ondalık basamağa yuvarlanmış, ~1 km) | Hava ve rüzgâr tahmini. Kimliğinizle ilişkilendirilmez. [Kullanım koşulları ve gizlilik](https://open-meteo.com/en/terms) |
| **OpenStreetMap** (tile.openstreetmap.org) ve **OpenTopoMap** (tile.opentopomap.org) | Harita karosu istekleri | Bu altlıkları seçtiğinizde haritayı göstermek. Sunucular IP adresinizi ve görüntülediğiniz alanı görebilir. [OSMF Gizlilik Politikası](https://osmfoundation.org/wiki/Privacy_Policy), [OpenTopoMap](https://opentopomap.org/about) |
| **Apple** (MapKit / Apple Haritalar) | Apple harita altlıkları, "Yer ara" sorgularınız, yol tarifi | Harita ve arama. [Apple Gizlilik Politikası](https://www.apple.com/legal/privacy/) |
| **Google Haritalar** veya **Apple Haritalar** | Avlağın hedef koordinatı | Yalnızca "Yol tarifi"ne dokunduğunuzda o uygulama/site açılır. |
| **GitHub Releases** (github.com ve GitHub'ın dosya sunucuları) | Standart indirme isteği (IP adresi, uygulama adı içeren User-Agent); konum **gönderilmez** | Çevrimdışı topoğrafik haritanın bilgi dosyası ve harita paketi. Yalnızca siz "İndir", "Güncelle" veya "Güncellemeleri denetle"ye dokunduğunuzda. [GitHub Gizlilik Bildirimi](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement) |


**Paylaşım:** Konumunuzu paylaşma, GPX iz dosyası dışa aktarma, tanılama raporu ya da saha kaydı paylaşma yalnızca siz paylaş düğmesine dokunduğunuzda iOS paylaşım menüsüyle, seçtiğiniz uygulamaya/kişiye yapılır.

**Bildirimler ve Live Activity:** Uyarı bildirimleri ve kilit ekranı/Dynamic Island/Apple Watch gösterimi cihazda yerel olarak üretilir; uzaktan (push) bildirim sunucusu kullanılmaz.

## 4. İzinler

- **Konum – Uygulamayı Kullanırken:** Haritada bölgenizi göstermek ve uyarmak için.
- **Konum – Her Zaman (isteğe bağlı):** Arka planda takip açıksa, uygulama kapalıyken yasak alana yaklaştığınızda uyarmak için.
- **Mikrofon:** Yalnızca kuş sesi kaydı için, siz düğmeye bastığınızda.
- **Fotoğraflar:** İzin belgesi ya da kuş fotoğrafı seçmek için sistem seçicisi kullanılır. Kuş fotoğrafı yalnızca telefonda (Apple Vision / Core ML) analiz edilir; hiçbir yere gönderilmez ve saklanmaz; uygulama yalnızca seçtiğiniz görseli alır, fotoğraf arşivinizin tamamına erişmez.
- **Bildirimler:** Yasak alan uyarıları için.
- **Face ID / Touch ID (isteğe bağlı):** Ayarlar › Gizlilik › "Uygulamayı Face ID ile kilitle" açıksa uygulama açılırken kimliğinizi doğrulamak için. Doğrulamayı tamamen iOS yapar (Apple LocalAuthentication); uygulama yüz/parmak izi verisine ya da cihaz parolanıza **hiçbir zaman erişmez**, yalnızca "doğrulandı / doğrulanmadı" yanıtını alır. Hiçbir biyometrik veri saklanmaz veya gönderilmez. Kilit yalnızca ekranı örter; konum takibi ve yasak alan uyarıları kilitliyken de çalışır.

İzinleri istediğiniz zaman iPhone Ayarlar › Av Haritası'ndan değiştirebilirsiniz. İzin vermezseniz ilgili özellik çalışmaz; diğerleri çalışmaya devam eder.

## 5. Saklama ve silme

- Uygulamayı silmek, cihazdaki tüm uygulama verilerini (av defteri, izin belgeleri, izler, tanılama raporları, saha kaydı, önbellekler, ayarlar) siler.
- Uygulama içinden izleri, izin belgelerini ve av defteri kayıtlarını tek tek silebilirsiniz. Harita karosu önbelleği Ayarlar'dan temizlenebilir; indirilen çevrimdışı harita Ayarlar ya da Katmanlar › Çevrimdışı harita › Sil ile silinir.
- Tanılama raporlarının yalnızca son 30 tanesi tutulur.
- Saha kaydındaki olaylar 7 gün sonra kendiliğinden silinir; Ayarlar › Gelişmiş › Tanı raporları › "Kaydı sil" ile hemen silinebilir.
- Üçüncü tarafların (Open-Meteo, OSM/OpenTopoMap, Apple, GitHub) tuttuğu kayıtlar kendi politikalarına tabidir.

## 6. Çocuklar

Uygulama çocuklara yönelik değildir ve bilerek çocuklardan veri toplamaz.

## 7. KVKK (6698 sayılı Kişisel Verilerin Korunması Kanunu) kapsamında aydınlatma

**Veri sorumlusu:** [Geliştirici adı / e-posta]

**İşleme amaçları:** Konumunuza göre avlak ve av kuralları değerlendirmesi ile uyarı; hava tahmini; harita gösterimi ve yer arama; izin belgesi bilgilerinin ve av defterinin tutulması; isteğe bağlı iz kaydı ve kuş sesi tanıma; uygulama kararlılığının ve (isteğe bağlı saha kaydıyla) uyarı davranışının izlenmesi.

**Hukuki sebep:** Veriler, uygulamanın sizin talep ettiğiniz özelliklerini sunabilmek için gerekli olması (KVKK m. 5/2-c, sözleşmenin kurulması veya ifasıyla doğrudan ilgili olma) ve konum, mikrofon gibi izinlerde iOS izin ekranında verdiğiniz açık rıza (m. 5/1) temelinde işlenir. Rızanızı iPhone Ayarlar'ından istediğiniz zaman geri alabilirsiniz.

**Aktarım:** Geliştiriciye veri aktarılmaz. Bölüm 3'te sayılan alıcılara veriler, sizin başlattığınız işlemlerle doğrudan cihazınızdan gönderilir. Open-Meteo, OpenStreetMap/OpenTopoMap, Apple ve GitHub sunucuları **yurt dışında** bulunabilir; bu aktarım, ilgili özelliği kullanmanız ve izinlerinizle gerçekleşir (KVKK m. 9). Bu özellikleri kullanmayarak (ör. Apple, önbellekteki ya da çevrimdışı altlıkları seçmek, çevrimdışı haritayı indirmemek) aktarımı sınırlayabilirsiniz.

**Toplama yöntemi:** Cihaz sensörleri (GPS, mikrofon), sizin seçtiğiniz dosya/görseller ve uygulamaya girdiğiniz bilgiler aracılığıyla, otomatik ve kısmen otomatik yollarla.

**Haklarınız (KVKK m. 11):** Kişisel verinizin işlenip işlenmediğini öğrenme, işlenmişse bilgi talep etme, işleme amacını ve amacına uygun kullanılıp kullanılmadığını öğrenme, aktarıldığı üçüncü kişileri bilme, eksik/yanlış işlenmişse düzeltilmesini, silinmesini veya yok edilmesini isteme ve bunun aktarılan kişilere bildirilmesini isteme, otomatik analiz sonucu aleyhinize bir sonuca itiraz etme ve kanuna aykırı işleme nedeniyle zarara uğrarsanız zararın giderilmesini talep etme.

Cihazınızdaki verileri bölüm 5'teki yollarla kendiniz görüntüleyip silebilirsiniz. Geliştirici bu verilere erişemediği için en hızlı yol budur.

**Başvuru:** Taleplerinizi [Geliştirici adı / e-posta] adresine yazılı olarak iletebilirsiniz. Başvurular en geç 30 gün içinde ücretsiz yanıtlanır. Yanıt verilmemesi veya yanıttan memnun kalmamanız hâlinde Kişisel Verileri Koruma Kurulu'na şikâyette bulunabilirsiniz.

## 8. AB / GDPR kullanıcıları için not

Avrupa Birliği'nden kullanıyorsanız, GDPR kapsamında erişim, düzeltme, silme, işlemeyi kısıtlama, itiraz ve veri taşınabilirliği haklarına sahipsiniz ve bulunduğunuz ülkenin denetim makamına şikâyette bulunabilirsiniz. İşlemenin dayanağı, istediğiniz hizmeti sunmak (m. 6/1-b) ve izin verdiğiniz durumlarda rızanızdır (m. 6/1-a). Talepler için yukarıdaki iletişim adresini kullanabilirsiniz.

## 9. Değişiklikler

Bu politika uygulamadaki değişikliklere göre güncellenebilir. Önemli değişiklikler bu sayfada ve gerekirse uygulama içinde duyurulur. Güncel sürüm her zaman bu belgedir.

Son güncelleme: 9 Ekim 2026
