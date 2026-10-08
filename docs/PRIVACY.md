# Av Haritası Privacy Policy

This policy explains how the iOS app **Av Haritası** ("the app") handles data. In short: the app has no accounts, no ads, no analytics and no tracking, and it uses no third-party SDKs. Most of your data stays on your phone, and nothing is ever sent to the developer.

## 1. Controller

The controller is the app's developer: **[Geliştirici adı / e-posta]**

The app contacts no developer-run server, so the developer cannot access your on-device data.

## 2. Data processed on your device

- **Location:** Used on the phone to determine your hunting zone, distance to prohibited areas and legal hunting hours, and to warn you. No location history is stored unless you start track recording.
- **Harvest log ("Today's hunt"):** Your per-species counters are stored on the device only.
- **Hunting permit document:** The screenshot, photo or PDF you add is read on the phone (Apple Vision / PDFKit). Only these fields are stored: hunting area (avlak), valid date, species and quotas, permit number and the QR-code link (if any). Your **name, hunting licence number and permit card number are read but not stored.** The image itself is not stored. Permit records are encrypted with iOS file protection.
- **GPS tracks:** Location points (latitude, longitude, altitude, accuracy, time) are saved only while you have started "Track recording".
- **Diagnostics:** Performance and crash reports provided by Apple MetricKit are kept on the device (up to 30 reports). They are not sent anywhere unless you tap share.
- **Caches and settings:** The latest weather forecast, map tiles you have viewed and the app's settings are kept on the device. If you enter a BirdNET API key, it is stored in the iOS Keychain.
- **Sound recording:** A ~15-second recording is made only when you tap the button and kept in a temporary file. Without a server address, Apple's on-device sound classifier analyses it.

## 3. Data that leaves your device

The app only sends data over the internet in these cases:

| Recipient | What is sent | Purpose |
|---|---|---|
| **Open-Meteo** (api.open-meteo.com) | Approximate coordinates (4 decimals, ~10 m) | Weather and wind forecast. Not linked to your identity. [Terms and privacy](https://open-meteo.com/en/terms) |
| **OpenStreetMap** (tile.openstreetmap.org) and **OpenTopoMap** (tile.opentopomap.org) | Map tile requests | Showing the map when you choose these base layers. Their servers can see your IP address and the area you view. [OSMF Privacy Policy](https://osmfoundation.org/wiki/Privacy_Policy), [OpenTopoMap](https://opentopomap.org/about) |
| **Apple** (MapKit / Apple Maps) | Apple base maps, your "Search places" queries, directions | Maps and search. [Apple Privacy Policy](https://www.apple.com/legal/privacy/) |
| **The BirdNET server address you enter** | Sound recording, approximate location (4 decimals), week of the year, your API key if set | Bird species identification. Only if you entered an address in Settings and make a recording. |
| **Google Maps** or **Apple Maps** | Destination coordinates of the hunting area | Only when you tap "Directions", which opens that app or website. |

The BirdNET server is one you set up yourself (e.g. your own computer or Hugging Face Spaces). **The developer does not operate it** and cannot access data sent to it; whoever runs it is responsible for that data.

**Sharing:** Sharing your location, exporting a GPX track or sharing diagnostic reports happens only when you tap share, through the iOS share sheet, to the app or person you choose.

**Notifications and Live Activity:** Alert notifications and the Lock Screen / Dynamic Island / Apple Watch display are generated locally on the device; no remote (push) notification server is used.

## 4. Permissions

- **Location – While Using the App:** To show your zone on the map and warn you.
- **Location – Always (optional):** If background tracking is on, to warn you when you approach a prohibited area while the app is closed.
- **Microphone:** Only for recording bird sounds, when you tap the button.
- **Local network:** To reach your BirdNET server if it runs on a computer on your home network.
- **Photos:** The system picker is used to choose a permit image; the app receives only the image you pick and has no access to your full photo library.
- **Notifications:** For prohibited-area alerts.

You can change permissions at any time in iPhone Settings › Av Haritası. Declining one disables only the related feature.

## 5. Retention and deletion

- Deleting the app removes all of its data from the device (harvest log, permits, tracks, diagnostic reports, caches, settings).
- Inside the app you can delete individual tracks, permit documents and harvest log entries. The map tile cache can be cleared in Settings.
- When you clear the BirdNET API key field, the key is removed from the Keychain.
- Only the latest 30 diagnostic reports are kept.
- Records kept by third parties (Open-Meteo, OSM/OpenTopoMap, Apple, the BirdNET server) are governed by their own policies.

## 6. Children

The app is not directed to children and does not knowingly collect data from children.

## 7. KVKK (Turkish Personal Data Protection Law No. 6698) notice

**Data controller:** [Geliştirici adı / e-posta]

**Purposes:** Evaluating hunting zones and rules for your location and warning you; weather forecasts; displaying maps and searching places; keeping permit details and the harvest log; optional track recording and bird sound identification; monitoring app stability.

**Legal basis:** Data is processed because it is necessary to provide the features you request (KVKK Art. 5(2)(c), directly related to the establishment or performance of a contract) and, for permissions such as location and microphone, on the basis of the explicit consent you give in the iOS permission prompt (Art. 5(1)). You can withdraw consent at any time in iPhone Settings.

**Transfers:** No data is transferred to the developer. Data goes directly from your device to the recipients listed in section 3, as a result of actions you start. Open-Meteo, OpenStreetMap/OpenTopoMap and Apple servers may be located **outside Türkiye**; this transfer happens when you use the relevant feature and grant the related permissions (KVKK Art. 9). You can limit it by not using those features (e.g. choosing Apple or cached base layers, leaving the BirdNET address empty).

**Collection method:** Through device sensors (GPS, microphone), files/images you choose and information you enter in the app, by automated and partly automated means.

**Your rights (KVKK Art. 11):** To learn whether your personal data is processed and, if so, to request information about it; to learn the purpose of processing and whether data is used accordingly; to know the third parties it is transferred to; to request correction of incomplete or inaccurate data, and its deletion or destruction, and to have these notified to the recipients; to object to a result against you arising from automated analysis; and to claim compensation for damage caused by unlawful processing.

Since the developer cannot access on-device data, the quickest route is to view and delete it yourself (section 5).

**How to apply:** Send your request in writing to [Geliştirici adı / e-posta]. Requests are answered free of charge within 30 days at the latest. If you receive no answer or are not satisfied, you may complain to the Personal Data Protection Board (Kişisel Verileri Koruma Kurulu).

## 8. Note for EU / GDPR users

If you use the app from the European Union, you have the rights of access, rectification, erasure, restriction, objection and data portability under the GDPR, and you may lodge a complaint with your local supervisory authority. Processing is based on providing the service you request (Art. 6(1)(b)) and, where you grant a permission, your consent (Art. 6(1)(a)). Use the contact address above for requests.

## 9. Changes

This policy may be updated as the app changes; significant changes will be announced here and, where appropriate, in the app.

Last updated (Son güncelleme): 8 October 2026
