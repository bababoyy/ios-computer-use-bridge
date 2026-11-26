#!/usr/bin/env python3
"""Bir .app paketine Frida Gadget ekler (Faz 0 prototipi için).

Yapılanlar:
  1. FridaGadget.dylib → <App>.app/Frameworks/FridaGadget.dylib
  2. FridaGadget.config → aynı klasöre (varsayılan: yalnızca 127.0.0.1'de dinle, uygulamayı bekletme)
  3. Ana çalıştırılabilir dosyaya LC_LOAD_DYLIB @executable_path/Frameworks/FridaGadget.dylib

Sonuç imzasızdır; cihaza kurmadan önce yeniden imzalanmalıdır (ör. Linux'ta zsign).
FairPlay ile şifrelenmiş (App Store'dan gelen, çözülmemiş) uygulamaları reddeder.

Kullanım:
    python tools/inject_gadget.py Payload/UIKitSample.app --gadget FridaGadget.dylib
"""
from __future__ import annotations

import argparse
import json
import plistlib
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import macho  # noqa: E402

GADGET_NAME = "FridaGadget.dylib"
LOAD_PATH = f"@executable_path/Frameworks/{GADGET_NAME}"

DEFAULT_CONFIG = {
    "interaction": {
        "type": "listen",
        "address": "127.0.0.1",
        "port": 27042,
        "on_port_conflict": "pick-next",
        "on_load": "resume",
    }
}


def inject(app: Path, gadget: Path, config: dict) -> list[str]:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    exe = app / info["CFBundleExecutable"]
    data = bytearray(exe.read_bytes())
    if macho.is_encrypted(data):
        raise macho.MachOError(f"{exe.name} FairPlay ile şifreli; önce şifresi çözülmüş bir IPA gerekir")

    frameworks = app / "Frameworks"
    frameworks.mkdir(exist_ok=True)
    shutil.copyfile(gadget, frameworks / GADGET_NAME)
    (frameworks / "FridaGadget.config").write_text(json.dumps(config, indent=2) + "\n")

    changed = macho.add_load_dylib(data, LOAD_PATH)
    if changed:
        exe.write_bytes(data)
    return macho.dylibs(data)[0]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("app", type=Path, help=".app klasörü")
    p.add_argument("--gadget", type=Path, required=True, help="iOS FridaGadget.dylib (frida-gadget-*-ios-universal)")
    p.add_argument("--config", type=Path, help="Özel FridaGadget.config (JSON)")
    args = p.parse_args()

    if not (args.app / "Info.plist").exists():
        print(f"{args.app} bir .app paketi değil", file=sys.stderr)
        return 2
    config = json.loads(args.config.read_text()) if args.config else DEFAULT_CONFIG
    try:
        libs = inject(args.app, args.gadget, config)
    except macho.MachOError as e:
        print(f"Hata: {e}", file=sys.stderr)
        return 1
    print(f"{args.app.name}: Gadget eklendi. Bağlı dylib'ler:")
    for lib in libs:
        print(f"  {lib}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
