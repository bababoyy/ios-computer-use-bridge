# iOS In-App Computer Use Bridge

Bir iOS uygulamasına enjekte edilen tek bir `.dylib` sayesinde harici bir AI agent'ın o uygulamayı gözlemleyip kontrol etmesini sağlayan köprü. Proje erken aşamada; şu an yalnızca tasarım belgesi ve CI iskeleti var.

- Tasarım: [docs/SPEC.md](docs/SPEC.md)
- Derleme: GitHub Actions macOS runner'ında, [.github/workflows/build.yml](.github/workflows/build.yml). Çıktı, iş akışının `ComputerUseBridge-dylib` artifact'ıdır.
