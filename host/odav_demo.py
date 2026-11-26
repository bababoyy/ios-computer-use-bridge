#!/usr/bin/env python3
"""Faz 0 kapısı için ODAV (Observe → Decide → Act → Verify) testi.

Köprüye (bridge.py serve) WebSocket ile bağlanır, ekranı gözler, etiketine göre bir
elemanı seçer, ona dokunur ve bir başka elemanın değerinin değiştiğini doğrular.
Agent'ın yerine basit bir kural koyar; amaç döngünün uçtan uca çalıştığını göstermek.

Örnek (örnek uygulamalardaki sayaç ekranı):
    python odav_demo.py --tap-label Increment --check-id counterLabel
"""
from __future__ import annotations

import argparse
import asyncio
import itertools
import json
import os
import sys
from typing import Any

_ids = itertools.count(1)


async def call(ws, method: str, params: dict | None = None) -> Any:
    req_id = next(_ids)
    await ws.send(json.dumps({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}}))
    resp = json.loads(await ws.recv())
    if "error" in resp:
        raise RuntimeError(f"{method}: {resp['error']}")
    return resp["result"]


def find(elements: list[dict], *, label: str | None = None, identifier: str | None = None) -> dict | None:
    for el in elements:
        if label is not None and (el.get("label") or "").strip().lower() == label.lower():
            return el
        if identifier is not None and el.get("identifier") == identifier:
            return el
    return None


def text_of(el: dict | None) -> str | None:
    if el is None:
        return None
    return el.get("value") or el.get("label")


async def run(args: argparse.Namespace) -> int:
    import websockets

    async with websockets.connect(args.url, max_size=None) as ws:
        # Observe
        before = await call(ws, "observe", {"screenshot": False})
        print(f"Observe: {len(before['elements'])} eleman, uygulama {before['screen']['app']}")

        # Decide
        target = find(before["elements"], label=args.tap_label)
        if target is None:
            print(f"'{args.tap_label}' etiketli eleman yok. Görünen etiketler:")
            for el in before["elements"]:
                print(f"  {el['id']}  {el.get('label')!r}  id={el.get('identifier')!r}")
            return 1
        checked_before = text_of(find(before["elements"], identifier=args.check_id)) if args.check_id else None
        print(f"Decide: {target['id']} ({target['cls']}: {target.get('label')!r}) seçildi")

        # Act
        result = await call(ws, "act", {"type": "tap", "target": target["id"],
                                        "observe": {"screenshot": False}, "settleMs": args.settle_ms})
        after = result.pop("observe")
        print(f"Act: {json.dumps(result, ensure_ascii=False)}")
        if not result.get("ok"):
            return 1

        # Verify
        if args.check_id is None:
            changed = [e["id"] for e in after["elements"]] != [e["id"] for e in before["elements"]]
            print(f"Verify: ekran {'değişti' if changed else 'değişmedi'}")
            return 0 if changed else 1
        checked_after = text_of(find(after["elements"], identifier=args.check_id))
        print(f"Verify: {args.check_id}: {checked_before!r} → {checked_after!r}")
        return 0 if checked_after is not None and checked_after != checked_before else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default=os.environ.get("CUB_URL", "ws://127.0.0.1:8765"))
    p.add_argument("--tap-label", required=True, help="Dokunulacak elemanın erişilebilirlik etiketi")
    p.add_argument("--check-id", help="Değeri değişmesi beklenen elemanın accessibilityIdentifier'ı")
    p.add_argument("--settle-ms", type=int, default=500)
    return asyncio.run(run(p.parse_args()))


if __name__ == "__main__":
    sys.exit(main())
