#!/usr/bin/env python3
"""Bir .app paketine dylib ekler (ComputerUseBridge.dylib ya da başka bir dylib).

Yapılanlar:
  1. dylib → <App>.app/Frameworks/<ad>.dylib
  2. --config verilirse → aynı klasöre <ad>.config (ör. Frida Gadget için)
  3. Ana çalıştırılabilir dosyaya LC_LOAD_DYLIB @executable_path/Frameworks/<ad>.dylib

Sonuç imzasızdır; cihaza kurmadan önce yeniden imzalanmalıdır (ör. Linux'ta zsign).
FairPlay ile şifrelenmiş (App Store'dan gelen, çözülmemiş) uygulamaları reddeder.
Bağımlılığı yoktur; Linux, macOS ve CI'da çalışır.

Kullanım:
    python tools/inject_dylib.py Payload/UIKitSample.app --dylib build/ComputerUseBridge.dylib
"""
from __future__ import annotations

import argparse
import plistlib
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import macho  # noqa: E402


def inject(app: Path, dylib: Path, config: Path | None = None) -> list[str]:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    exe = app / info["CFBundleExecutable"]
    data = bytearray(exe.read_bytes())
    if macho.is_encrypted(data):
        raise macho.MachOError(f"{exe.name} FairPlay ile şifreli; önce şifresi çözülmüş bir IPA gerekir")

    frameworks = app / "Frameworks"
    frameworks.mkdir(exist_ok=True)
    shutil.copyfile(dylib, frameworks / dylib.name)
    if config is not None:
        shutil.copyfile(config, frameworks / (dylib.stem + ".config"))

    if macho.add_load_dylib(data, f"@executable_path/Frameworks/{dylib.name}"):
        exe.write_bytes(data)
    return macho.dylibs(data)[0]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("app", type=Path, help=".app klasörü")
    p.add_argument("--dylib", type=Path, required=True)
    p.add_argument("--config", type=Path, help="dylib'in yanına <ad>.config olarak kopyalanacak dosya")
    args = p.parse_args()

    if not (args.app / "Info.plist").exists():
        print(f"{args.app} bir .app paketi değil", file=sys.stderr)
        return 2
    try:
        libs = inject(args.app, args.dylib, args.config)
    except macho.MachOError as e:
        print(f"Hata: {e}", file=sys.stderr)
        return 1
    print(f"{args.app.name}: {args.dylib.name} eklendi. Bağlı dylib'ler:")
    for lib in libs:
        print(f"  {lib}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
