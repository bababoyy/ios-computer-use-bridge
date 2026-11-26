# Faz 0 — Frida prototipi (arşiv)

> **Askıya alındı (26 Kasım 2026).** Gadget eklenmiş uygulamalar iOS 27.3'te `FridaGadget.dylib`'in başlatıcısında çöktü (olası neden: JIT yok). Proje JIT gerektirmeyen native dylib ile devam ediyor: [host/README.md](../host/README.md). Aşağıdaki talimatlar kayıt için duruyor; CI artık Gadget'lı IPA üretmiyor, `odav_demo.py` [host/](../host/) altına taşındı ve `tools/inject_gadget.py` yerini `tools/inject_dylib.py`'ye bıraktı (Gadget için `--config FridaGadget.config` ile kullanılabilir).

Amaç: native dylib'e yatırım yapmadan önce Observe → Decide → Act → Verify döngüsünün UIKit, SwiftUI ve WebView uygulamalarında çalıştığını göstermek. Kapı: ODAV döngüsü 3 örnek uygulamada çalışıyor (bkz. [docs/SPEC.md](../docs/SPEC.md)).

```
Agent / odav_demo.py ──WebSocket JSON-RPC──▶ host/bridge.py ──Frida (USB)──▶ FridaGadget.dylib + agent/_agent.js
     (bilgisayar)          127.0.0.1:8765        (bilgisayar)                  (uygulamanın içinde, 127.0.0.1:27042)
```

Köprü, SPEC'teki native WebSocket kanalının (`observe`, `act`) bir alt kümesini sunar. Faz 1'deki native dylib aynı protokolü konuşacağı için host tarafındaki kod değişmeden kalır.

| Klasör | İçerik |
| --- | --- |
| `agent/` | Uygulamanın içinde çalışan Frida agent'ı (TypeScript) |
| `host/` | `bridge.py` (köprü + CLI), `odav_demo.py` (kapı testi), birim testleri |
| `../samples/` | UIKit, SwiftUI ve WebView örnek uygulamaları (XcodeGen) |
| `../tools/` | `inject_gadget.py`: bir `.app`'e Frida Gadget ekler (Linux'ta da çalışır) |

## Faz 0'da neler var, neler yok

| Yetenek | Durum |
| --- | --- |
| Ekran görüntüsü (PNG, point ölçeğinde) | Var |
| Ekran bilgisi, uygulama durumu | Var |
| Erişilebilirlik eleman listesi (etiket, değer, identifier, trait, çerçeve) | Var |
| `tap` (eleman ID'si ya da koordinat) | Var, **semantik**: UIControl eylemi, UISwitch, metin alanına odak, tablo/collection hücre seçimi, `accessibilityActivate`, WKWebView'da JavaScript tıklaması |
| Gerçek dokunma olayı (IOHIDEvent), kaydırma, sürükleme | Yok, Faz 1 (Hammer) |
| Metin girme, `waitForIdle` | Yok, Faz 2 |
| Kimlik doğrulama, TLS | Yok, Faz 3. Köprü ve Gadget yalnızca 127.0.0.1'de dinler |

## 1. IPA'ları al

CI her push'ta örnekleri derleyip `sample-ipas` artifact'ına koyar: her uygulama için düz (`UIKitSample.ipa`) ve Gadget eklenmiş (`UIKitSample-gadget.ipa`) birer IPA. IPA'lar **imzasızdır**.

```bash
gh run download -R bababoyy/ios-computer-use-bridge -n sample-ipas -D dist
```

## 2. İmzala ve kur (Linux)

Gadget eklenmiş IPA'yı kendi Apple hesabınla imzalaman gerekir. İki yol:

- **Ücretsiz Apple ID:** [Sideloader](https://github.com/Dadoum/Sideloader) gibi Linux'ta çalışan bir araç imzalamayı ve kurulumu birlikte yapar. İmza 7 gün geçerlidir, aynı anda en fazla 3 uygulama kurulabilir.
- **Ücretli geliştirici hesabı:** developer.apple.com'dan sertifika (`.p12`) ve provisioning profile al, [zsign](https://github.com/zhlynn/zsign) ile imzala, `ideviceinstaller` ile kur:

```bash
zsign -k sertifika.p12 -p 'PAROLA' -m profil.mobileprovision -o UIKitSample-signed.ipa dist/UIKitSample-gadget.ipa
```

```bash
ideviceinstaller -i UIKitSample-signed.ipa
```

Notlar:
- Bundle ID'ler `dev.computeruse.samples.*`; hesabın bunlara izin vermiyorsa zsign'da `-b <yeni.bundle.id>` ile değiştir.
- Cihazda **Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu** açık olmalı.
- Parola ve sertifika dosyalarını repoya koyma (`.gitignore` `*.p12` ve `*.mobileprovision` dosyalarını dışarıda tutar).

## 3. Host'u hazırla

```bash
cd prototype/agent && npm install && npm run build
```

```bash
cd prototype/host && python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt
```

Derlemek yerine CI'ın `frida-agent` artifact'ındaki `_agent.js` dosyasını `prototype/agent/` altına koyabilirsin.

## 4. Bağlan ve gözle

Uygulamayı cihazda aç (Gadget `on_load: resume` ile çalışır, uygulama beklemeden açılır), sonra:

```bash
python bridge.py observe --out ekran.png
```

Çıktıda her satır bir eleman: ID, `*` = etkileşimli, çerçeve (point), sınıf, etiket, trait'ler.

```bash
python bridge.py tap e1a2b3c4
```

Frida USB cihazını bulamazsa (`usbmuxd` çalışmıyor olabilir), portu elle yönlendir:

```bash
iproxy 27042 27042
```

```bash
python bridge.py --remote 127.0.0.1:27042 observe
```

`iproxy` Ubuntu'da `libusbmuxd-tools` paketindedir.

## 5. Faz 0 kapısı: ODAV testi

Bir terminalde köprüyü başlat:

```bash
python bridge.py serve
```

Diğerinde, her örnek uygulama için ana menüden Counter ekranına geç ve sayacı artır:

```bash
python odav_demo.py --tap-label Counter
```

```bash
python odav_demo.py --tap-label Increment --check-id counterLabel
```

İkinci komut `Verify: counterLabel: 'Count: 0' → 'Count: 1'` yazıp 0 ile çıkarsa döngü o uygulamada çalışıyor demektir. WebView örneğinde sayaç doğrudan ilk sayfadadır; WebView içeriği erişilebilirlik ağacında ayrı elemanlar olarak görünmediği için orada koordinatla dokun:

```bash
python bridge.py observe --out webview.png
```

```bash
python bridge.py tap 80 260
```

| Uygulama | Menü (hücre seçimi) | Sayaç (buton) | Anahtar | Sonuç |
| --- | --- | --- | --- | --- |
| UIKitSample | | | | |
| SwiftUISample | | | | |
| WebViewSample | — | | | |

## Bilinen riskler

- SwiftUI erişilebilirlik ağacı tembel oluşur. Agent yüklenirken `libAccessibility` üzerinden otomasyon modunu açmayı dener; `observe` çıktısındaki `axAutomation` bunun başarılı olup olmadığını gösterir. SwiftUI'da eleman listesi boş gelirse ilk bakılacak yer burası.
- `tap` gerçek bir dokunma değildir. Hücre seçimi delegate'i doğrudan çağırır; özel jest tanıyıcılara bağlı arayüzler Faz 1'e kadar tepki vermeyebilir.
- WebView'da tıklama noktası `adjustedContentInset` ile CSS koordinatına çevrilir; yakınlaştırılmış sayfalarda kayma olabilir.
