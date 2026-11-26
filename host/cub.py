#!/usr/bin/env python3
"""ComputerUseBridge dylib'i için komut satırı istemcisi.

Dylib, uygulamanın içinde ws://127.0.0.1:8765 adresinde dinler. Bilgisayardan erişmek
için portu USB üzerinden yönlendir:

    iproxy 8765:8765

Örnekler:
    python cub.py ping
    python cub.py observe --out ekran.png
    python cub.py tap e1a2b3c4            # eleman ID'si
    python cub.py tap 200 400             # koordinat (point)
    python cub.py swipe 200 600 200 200 --duration 0.4
    python cub.py activate e1a2b3c4       # semantik (accessibilityActivate vb.)
    python cub.py type "merhaba" --clear  # odaktaki alana yaz
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import itertools
import json
import os
import sys
from pathlib import Path
from typing import Any

DEFAULT_URL = os.environ.get("CUB_URL", "ws://127.0.0.1:8765")
_ids = itertools.count(1)


class RPCError(Exception):
    def __init__(self, error: dict) -> None:
        super().__init__(f"{error.get('code')}: {error.get('message')}")
        self.error = error


async def call(ws, method: str, params: dict | None = None) -> Any:
    req_id = next(_ids)
    await ws.send(json.dumps({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}}))
    resp = json.loads(await ws.recv())
    if "error" in resp:
        raise RPCError(resp["error"])
    return resp["result"]


def parse_target(values: list[str]) -> Any:
    if len(values) == 1:
        return values[0]
    if len(values) == 2:
        return {"x": float(values[0]), "y": float(values[1])}
    raise SystemExit("hedef: bir eleman ID'si ya da X Y")


def print_elements(elements: list[dict]) -> None:
    for el in elements:
        f = el["frame"]
        name = el.get("label") or el.get("identifier") or "-"
        value = f" = {el['value']}" if el.get("value") else ""
        flags = ("*" if el.get("interactive") else " ") + (" " if el.get("enabled", True) else "x")
        ident = f" [{el['identifier']}]" if el.get("identifier") else ""
        print(f"{el['id']} {flags} ({f['x']:.0f},{f['y']:.0f} {f['w']:.0f}x{f['h']:.0f}) "
              f"{el['cls']}: {name}{value}{ident} {','.join(el.get('traits', []))}")


async def run(args: argparse.Namespace) -> int:
    import websockets

    try:
        ws_cm = websockets.connect(args.url, max_size=None, open_timeout=5)
        ws = await ws_cm.__aenter__()
    except (OSError, asyncio.TimeoutError) as e:
        print(f"{args.url} adresine bağlanılamadı ({e}).\n"
              "Uygulama açık mı, 'iproxy 8765:8765' çalışıyor mu?", file=sys.stderr)
        return 2
    try:
        if args.cmd == "ping":
            print(await call(ws, "ping"))
        elif args.cmd == "screen":
            print(json.dumps(await call(ws, "screen"), ensure_ascii=False, indent=2))
        elif args.cmd == "observe":
            result = await call(ws, "observe", {"screenshot": args.out is not None})
            shot = result.pop("screenshot", None)
            if args.out is not None and shot:
                args.out.write_bytes(base64.b64decode(shot["data"]))
                print(f"Ekran görüntüsü: {args.out}", file=sys.stderr)
            if args.json:
                print(json.dumps(result, ensure_ascii=False, indent=2))
            else:
                print(json.dumps(result["screen"], ensure_ascii=False))
                print_elements(result["elements"])
        else:
            if args.cmd == "swipe":
                params = {"type": "swipe", "target": {"x": args.x1, "y": args.y1}, "to": {"x": args.x2, "y": args.y2}}
            elif args.cmd == "type":
                params = {"type": "type", "text": args.text, "clear": args.clear}
            else:
                params = {"type": args.cmd, "target": parse_target(args.target)}
            if getattr(args, "duration", None) is not None:
                params["duration"] = args.duration
            result = await call(ws, "act", params)
            print(json.dumps(result, ensure_ascii=False))
            return 0 if result.get("ok") else 1
    except RPCError as e:
        print(f"Hata: {e}", file=sys.stderr)
        return 1
    finally:
        await ws_cm.__aexit__(None, None, None)
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default=DEFAULT_URL)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ping")
    sub.add_parser("screen")
    o = sub.add_parser("observe", help="Ekran görüntüsü ve eleman listesi")
    o.add_argument("--out", type=Path, help="PNG dosyası")
    o.add_argument("--json", action="store_true")
    for name, help_text in (("tap", "Gerçek dokunma"), ("activate", "Semantik eylem")):
        a = sub.add_parser(name, help=help_text)
        a.add_argument("target", nargs="+", help="Eleman ID'si ya da X Y")
        if name == "tap":
            a.add_argument("--duration", type=float)
    s = sub.add_parser("swipe", help="X1 Y1'den X2 Y2'ye kaydır")
    for coord in ("x1", "y1", "x2", "y2"):
        s.add_argument(coord, type=float)
    s.add_argument("--duration", type=float)
    s.set_defaults(target=[])
    t = sub.add_parser("type", help="Odaktaki metin alanına yaz (önce alana dokun)")
    t.add_argument("text")
    t.add_argument("--clear", action="store_true", help="Önce alandaki metni sil")
    return asyncio.run(run(p.parse_args(argv)))


if __name__ == "__main__":
    sys.exit(main())
