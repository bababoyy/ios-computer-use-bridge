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

   Relay'i kalıcı çalıştırmak için systemd kullanıcı servisi: [systemd/cub-relay.service](systemd/cub-relay.service) (kurulum adımları dosyanın başında). Servis oturum açıldığında başlar ve çökerse 10 sn sonra yeniden başlar; oturum açılmadan da başlaması için `loginctl enable-linger` gerekir. Loglar: `journalctl --user -u cub-relay -f`.

2. Telefonda uygulama açıkken ekrana **üç parmakla 1 saniye bas**. Açılan ComputerUseBridge menüsüne URL'yi (ör. `ws://100.85.90.10:8770`) ve token'ı yaz, **Reverse modu aç**'a dokun. Menü durum satırında `Reverse: bağlı` görünmeli; relay de `telefon bağlandı` yazar.
3. İstemcileri relay'e yönlendir:

```bash
CUB_URL=ws://127.0.0.1:8766 python3 host/cub.py observe
```

Ayarlar uygulama başına saklanır (LiveContainer'da her uygulama için ayrı). Bağlantı koparsa dylib 1–30 sn aralıklarla yeniden dener; uygulama ön plana gelince hemen dener. Menü `observe` sonuçlarında görünmez ama ekran görüntüsünde görünür. `screen` yanıtındaki `bridge.reverse` alanı bağlantı durumunu verir.

Relay token'ı doğrulamadan hiçbir isteği telefona iletmez; trafiği Tailscale (WireGuard) şifreler. Relay'in telefon portu yalnızca Tailscale IP'sinde dinler, istemci portu yalnızca 127.0.0.1'de.

## 3c. MCP sunucusu (Claude'un doğrudan kullanması için)

[mcp_server.py](mcp_server.py), köprüyü MCP araçları olarak sunar: `screen`, `observe` (ekran görüntüsü görüntü olarak + eleman listesi metin olarak), `tap`, `swipe`, `activate`, `type`. Eylem araçları `observe_after` ile yeni durumu aynı yanıtta döndürebilir. Köprü hataları (telefon bağlı değil, eleman yok, odak yok, uygulama arka planda) araç hatası olarak döner.

```bash
cd host && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

Claude Code'a ekle (reverse mod için relay çalışıyor olmalı; USB için `CUB_URL=ws://127.0.0.1:8765`):

```bash
claude mcp add cub -e CUB_URL=ws://127.0.0.1:8766 -- "$PWD/host/.venv/bin/python" "$PWD/host/mcp_server.py"
```

Komutu repo kökünde çalıştır. Telefonda uygulama ön planda ve köprü bağlıyken Claude'a "telefondaki uygulamada ... yap" demek yeterli.

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
| SwiftUISample | ✓ | ✓ 4–5 eleman, `axAutomation: true` | ✓ `hid-touch` | ✓ 0 → 1 → 2 | ✓ eleman ID'siyle `tap` (0.2.0'dan itibaren), koordinatla ya da `activate` ile | ✓ kenardan geri kaydırma |
| WebViewSample | | | — | | | |

SwiftUISample sonuçları 26 Kasım 2026'da iOS 27.3 cihazda, LiveContainer'da alındı. Form ekranında Submit, geri butonu, menü hücresi ve sayaç gerçek dokunmayla (`hid-touch`) çalıştı; `swipe 2 450 320 450` sistemin kenardan geri hareketini tetikledi.

Aynı testler 0.2.0 ile reverse modda, Tailscale üzerinden (telefon dışarıda, USB yok) tekrarlandı ve hepsi geçti: `ping` ~0,16 sn, ekran görüntülü `observe` ~0,37 sn. Telefon bir kez kopup birkaç saniye içinde kendiliğinden yeniden bağlandı.

**Not, anahtarlar:** SwiftUI `Toggle`'ın erişilebilirlik çerçevesi tüm satırı kaplar (etiket + anahtar) ve anahtar sağ uçtadır. 0.1.0'da eleman ID'siyle `tap` satırın ortasına dokunduğu için anahtar değişmiyordu. 0.2.0'dan itibaren `toggleButton` özelliği taşıyan geniş elemanlarda dokunma noktası anahtarın merkezine kaydırılıyor (`x = sağ kenar − 26`); cihazda off → on → off doğrulandı.

## Bilinen riskler ve ilk bakılacak yerler

- **Dokunma sentezi private API kullanır** (`IOHIDEventCreateDigitizerEvent`, `-[UIApplication _enqueueHIDEvent:]`, `BKSHIDEventSetDigitizerInfo`). Loglarda `HID touch: available` yazmasına rağmen dokunma tepki vermiyorsa sorun büyük olasılıkla alan değerlerinde ya da pencere bağlamındadır. Bu durumda `activate` semantik yolu çalışmaya devam eder.
- **SwiftUI ağacı:** `observe` çıktısında `axAutomation: false` ise ya da SwiftUI ekranlarında eleman listesi boşsa ilk bakılacak yer otomasyon modudur.
- **LiveContainer:** Uygulama LiveContainer'ın sürecinde çalışır; `bundleId` misafir uygulamanınkidir. Aynı anda iki uygulama açılırsa ikincisi bir sonraki portu alır.
- Kimlik doğrulama ve TLS yok (Faz 3). Sunucu yalnızca cihazın kendi loopback adresinde dinler.
