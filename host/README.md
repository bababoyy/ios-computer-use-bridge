# Faz 1 — native dylib ile test

`ComputerUseBridge.dylib` uygulamanın içinde `ws://127.0.0.1:8765` adresinde JSON-RPC 2.0 sunar. Bu klasördeki araçlar bilgisayardan ona bağlanır.

```
cub.py / odav_demo.py ──WebSocket──▶ iproxy (USB) ──▶ ComputerUseBridge.dylib (uygulamanın içinde, 127.0.0.1:8765)
```

| Metot | Ne yapar |
| --- | --- |
| `ping` | `"pong"` |
| `screen` | Ekran ölçüleri, ölçek, yön, safe area, uygulama durumu |
| `observe` | Ekran görüntüsü (PNG, point ölçeği) + erişilebilirlik eleman listesi. Seçenekler: `screenshot`, `scale`, `maxElements` |
| `act` | `type: "tap"` (IOHIDEvent ile gerçek dokunma), `"swipe"` (`to: {x, y}` gerekli), `"activate"` (semantik). `target`: eleman ID'si ya da `{x, y}`. İsteğe bağlı `observe` ve `settleMs` ile yanıtta yeni durum döner |

Yanıtlardaki `method` alanı dokunmanın nasıl yapıldığını söyler: `hid-touch`, `hid-swipe`, ya da dokunma sentezi kullanılamazsa `semantic-fallback:...`.

## 1. Dosyaları al

CI her push'ta `sample-ipas` artifact'ını üretir:

| Dosya | Ne için |
| --- | --- |
| `ComputerUseBridge.dylib` | LiveContainer tweak'i |
| `UIKitSample.ipa`, `SwiftUISample.ipa`, `WebViewSample.ipa` | Düz örnek uygulamalar (LiveContainer'a kurulur) |
| `*-cub.ipa` | Dylib eklenmiş örnekler (LiveContainer kullanmadan doğrudan imzalayıp kurmak için) |

```bash
gh run download -R bababoyy/ios-computer-use-bridge -n sample-ipas -D dist
```

## 2. LiveContainer'a kur

1. Düz IPA'ları LiveContainer'a ekle.
2. `ComputerUseBridge.dylib` dosyasını LiveContainer'ın Tweaks bölümüne ekle (ör. `ComputerUseBridge` adlı bir klasöre).
3. Her örnek uygulamanın ayarlarında tweak klasörü olarak bunu seç.
4. Uygulamayı LiveContainer'dan aç. JIT gerekmez.

Dylib yüklendiyse cihaz loglarında şu satırlar görünür:

```bash
idevicesyslog | grep ComputerUseBridge
```

```
[ComputerUseBridge] loaded into dev.computeruse.samples.uikit
[ComputerUseBridge] AX automation: on
[ComputerUseBridge] listening on ws://127.0.0.1:8765
```

Port doluysa sunucu sonraki portları dener (8766, 8767, …); seçilen port bu satırda yazar. Farklı bir port için `CUB_PORT` ortam değişkeni kullanılabilir.

## 3. Bilgisayardan bağlan

`iproxy`, Ubuntu'da `libusbmuxd-tools` paketindedir.

```bash
iproxy 8765:8765
```

(Eski sürümlerde sözdizimi `iproxy 8765 8765`.) Diğer terminalde:

```bash
cd host && python3 cub.py ping
```

```bash
python3 cub.py observe --out ekran.png
```

Her satır bir eleman: ID, `*` = etkileşimli, çerçeve (point), sınıf, etiket, `[identifier]`, trait'ler.

```bash
python3 cub.py tap e1a2b3c4
```

```bash
python3 cub.py swipe 200 600 200 200 --duration 0.4
```

## 3b. Reverse mod (Tailscale üzerinden, kablosuz)

Dylib bilgisayara kendisi bağlanır; telefonda dinleyen port olmaz. Telefon ve bilgisayar aynı tailnet'te olmalı ve Tailscale VPN'i telefonda açık olmalı.

```
cub.py ──ws://127.0.0.1:8766──▶ relay.py ◀──ws://<bilgisayarın Tailscale IP'si>:8770── dylib (telefon)
```

1. Bilgisayarda relay'i başlat. İlk satırda telefona girilecek URL ve token yazar (token `~/.config/cub/token` dosyasında saklanır):

```bash
python3 host/relay.py
```

2. Telefonda uygulama açıkken ekrana **üç parmakla 1 saniye bas**. Açılan ComputerUseBridge menüsüne URL'yi (ör. `ws://100.85.90.10:8770`) ve token'ı yaz, **Reverse modu aç**'a dokun. Menü durum satırında `Reverse: bağlı` görünmeli; relay de `telefon bağlandı` yazar.
3. İstemcileri relay'e yönlendir:

```bash
CUB_URL=ws://127.0.0.1:8766 python3 host/cub.py observe
```

Ayarlar uygulama başına saklanır (LiveContainer'da her uygulama için ayrı). Bağlantı koparsa dylib 1–30 sn aralıklarla yeniden dener; uygulama ön plana gelince hemen dener. Menü `observe` sonuçlarında görünmez ama ekran görüntüsünde görünür. `screen` yanıtındaki `bridge.reverse` alanı bağlantı durumunu verir.

Relay token'ı doğrulamadan hiçbir isteği telefona iletmez; trafiği Tailscale (WireGuard) şifreler. Relay'in telefon portu yalnızca Tailscale IP'sinde dinler, istemci portu yalnızca 127.0.0.1'de.

## 4. Kapı testi: ODAV döngüsü

SPEC'teki Faz 1 kapısı: agent bir UIKit uygulamasında görevi bitiriyor. Her örnek uygulamada:

```bash
python3 odav_demo.py --tap-label Counter
```

```bash
python3 odav_demo.py --tap-label Increment --check-id counterLabel
```

İkinci komut `Verify: counterLabel: 'Count: 0' → 'Count: 1'` yazıp 0 ile çıkarsa döngü çalışıyor. WebView örneğinde sayaç ilk sayfadadır; içerik erişilebilirlik ağacında ayrı elemanlar olarak görünmeyebilir, o durumda ekran görüntüsünden koordinat alıp `cub.py tap X Y` kullan.

| Uygulama | `ping` | `observe` (eleman sayısı, `axAutomation`) | Menü → Counter | Increment | Switch/Toggle | `swipe` |
| --- | --- | --- | --- | --- | --- | --- |
| UIKitSample | | | | | | |
| SwiftUISample | ✓ | ✓ 4–5 eleman, `axAutomation: true` | ✓ `hid-touch` | ✓ 0 → 1 → 2 | ✓ anahtarın üstüne koordinatla ya da `activate` ile (eleman merkezine `tap` değiştirmez, bkz. not) | ✓ kenardan geri kaydırma |
| WebViewSample | | | — | | | |

SwiftUISample sonuçları 26 Kasım 2026'da iOS 27.3 cihazda, LiveContainer'da alındı. Form ekranında Submit, geri butonu, menü hücresi ve sayaç gerçek dokunmayla (`hid-touch`) çalıştı; `swipe 2 450 320 450` sistemin kenardan geri hareketini tetikledi.

**Not, anahtarlar:** SwiftUI `Toggle`'ın erişilebilirlik çerçevesi tüm satırı kaplar (etiket + anahtar). Eleman ID'siyle `tap` satırın ortasına dokunur; gerçek bir parmakta olduğu gibi bu anahtarı değiştirmez. Anahtarı değiştirmek için `activate` kullan ya da anahtarın üstüne koordinatla dokun.

## Bilinen riskler ve ilk bakılacak yerler

- **Dokunma sentezi private API kullanır** (`IOHIDEventCreateDigitizerEvent`, `-[UIApplication _enqueueHIDEvent:]`, `BKSHIDEventSetDigitizerInfo`). Loglarda `HID touch: available` yazmasına rağmen dokunma tepki vermiyorsa sorun büyük olasılıkla alan değerlerinde ya da pencere bağlamındadır. Bu durumda `activate` semantik yolu çalışmaya devam eder.
- **SwiftUI ağacı:** `observe` çıktısında `axAutomation: false` ise ya da SwiftUI ekranlarında eleman listesi boşsa ilk bakılacak yer otomasyon modudur.
- **LiveContainer:** Uygulama LiveContainer'ın sürecinde çalışır; `bundleId` misafir uygulamanınkidir. Aynı anda iki uygulama açılırsa ikincisi bir sonraki portu alır.
- Kimlik doğrulama ve TLS yok (Faz 3). Sunucu yalnızca cihazın kendi loopback adresinde dinler.
