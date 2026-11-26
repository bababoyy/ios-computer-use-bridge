# iOS In-App Computer Use Bridge

Bir iOS uygulamasına enjekte edilen tek bir `.dylib` sayesinde harici bir AI agent'ın o uygulamayı gözlemleyip kontrol etmesini sağlayan köprü. Proje erken aşamada; şu an yalnızca tasarım belgesi ve CI iskeleti var.

- Tasarım: [docs/SPEC.md](docs/SPEC.md)
- Faz 0 (Frida prototipi), kurulum ve test: [prototype/README.md](prototype/README.md)
- Derleme: GitHub Actions macOS runner'ında, [.github/workflows/build.yml](.github/workflows/build.yml). Çıktılar `ComputerUseBridge-dylib-xcode-27` (iOS 27 SDK) ve `ComputerUseBridge-dylib-macos-latest` (iOS 26 SDK) artifact'larıdır.
