# iOS In-App Computer Use Bridge

Bir iOS uygulamasına enjekte edilen tek bir `.dylib` sayesinde harici bir AI agent'ın o uygulamayı gözlemleyip kontrol etmesini sağlayan köprü. Proje erken aşamada: Faz 1 MVP (native Objective-C dylib) cihaz testini bekliyor.

- Tasarım: [docs/SPEC.md](docs/SPEC.md)
- Faz 1 (native dylib), LiveContainer ile kurulum ve test: [host/README.md](host/README.md)
- Faz 0 (Frida prototipi, askıda): [prototype/README.md](prototype/README.md)
- Derleme: GitHub Actions macOS runner'ında, [.github/workflows/build.yml](.github/workflows/build.yml). Dylib iş akışı `ComputerUseBridge-dylib-*` artifact'larını, [samples.yml](.github/workflows/samples.yml) ise dylib, düz ve dylib eklenmiş örnek IPA'ları (`sample-ipas`) üretir.
