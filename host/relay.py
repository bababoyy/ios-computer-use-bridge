#!/usr/bin/env python3
"""Reverse mod aracısı (relay).

Telefondaki dylib reverse modda bu relay'e kendisi bağlanır (ör. Tailscale üzerinden).
Relay, bilgisayardaki istemcilere (cub.py, odav_demo.py, ileride MCP adaptörü) yerel bir
WebSocket sunar ve istekleri telefona iletir:

    cub.py ──ws://127.0.0.1:8766──▶ relay.py ◀──ws://100.x.y.z:8770── dylib (telefon)

Telefon tarafı:
  - İlk mesaj `cub.hello` bildirimi olmalı ve doğru token'ı taşımalı; yoksa bağlantı kapatılır.
  - Aynı anda tek telefon: yeni bağlanan eskisinin yerini alır (ağ değişince telefon yeniden bağlanır).
İstemci tarafı:
  - Yalnızca 127.0.0.1'de dinler, aynı anda tek istemci.
  - `relay.status` relay'in kendisi yanıtlar; diğer istekler telefona iletilir.

Token ilk çalıştırmada üretilir ve ~/.config/cub/token dosyasında saklanır.

Kullanım:
    python relay.py                      # telefon portu Tailscale IP'sinde (tailscale ip -4)
    python relay.py --device-host 0.0.0.0 --device-port 8770 --client-port 8766
    CUB_URL=ws://127.0.0.1:8766 python cub.py observe
"""
from __future__ import annotations

import argparse
import asyncio
import hmac
import itertools
import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

TOKEN_FILE = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "cub" / "token"
TOKEN_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"  # telefonda yazması kolay, karışan karakterler yok
HELLO_TIMEOUT = 10.0
REQUEST_TIMEOUT = 60.0


def log(msg: str) -> None:
    print(f"[relay {time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def load_or_create_token(path: Path = TOKEN_FILE) -> str:
    if path.exists():
        token = path.read_text().strip()
        if token:
            return token
    token = "".join(secrets.choice(TOKEN_ALPHABET) for _ in range(10))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(token + "\n")
    path.chmod(0o600)
    return token


def tailscale_ip() -> str | None:
    try:
        out = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    ip = out.stdout.strip().splitlines()[0] if out.returncode == 0 and out.stdout.strip() else None
    return ip


def _error(req_id: Any, code: int, message: str, data: Any = None) -> str:
    err: dict = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return json.dumps({"jsonrpc": "2.0", "id": req_id, "error": err}, ensure_ascii=False)


class Relay:
    def __init__(self, token: str) -> None:
        self.token = token
        self.device = None          # telefonun WebSocket bağlantısı
        self.device_info: dict = {}
        self.client = None          # yerel istemcinin bağlantısı
        self._ids = itertools.count(1)
        self._pending: dict[int, tuple[Any, Any, asyncio.TimerHandle]] = {}  # relay id → (istemci ws, asıl id, zaman aşımı)

    # --- telefon tarafı -----------------------------------------------------

    async def handle_device(self, ws, *_: Any) -> None:
        try:
            raw = await asyncio.wait_for(ws.recv(), HELLO_TIMEOUT)
            hello = json.loads(raw)
        except (asyncio.TimeoutError, ValueError, TypeError):
            await ws.close(code=1008, reason="cub.hello bekleniyordu")
            return
        except Exception:
            return
        params = hello.get("params") if isinstance(hello, dict) else None
        if not (isinstance(hello, dict) and hello.get("method") == "cub.hello" and isinstance(params, dict)
                and isinstance(params.get("token"), str)
                and hmac.compare_digest(params["token"].encode(), self.token.encode())):
            log(f"telefon reddedildi (geçersiz hello/token) {getattr(ws, 'remote_address', '')}")
            await ws.close(code=1008, reason="Geçersiz token")
            return

        if self.device is not None:
            log("yeni telefon bağlantısı eskisinin yerini alıyor")
            old = self.device
            self.device = None
            self._fail_pending("device_disconnected", "Telefon yeniden bağlandı")
            await old.close(code=1001, reason="Yerine yeni bağlantı geldi")

        self.device = ws
        self.device_info = {k: params.get(k) for k in ("bundleId", "os", "bridge")}
        log(f"telefon bağlandı: {self.device_info} {getattr(ws, 'remote_address', '')}")
        try:
            async for message in ws:
                await self._from_device(message)
        except Exception as e:
            log(f"telefon bağlantı hatası: {e}")
        finally:
            if self.device is ws:
                self.device = None
                self._fail_pending("device_disconnected", "Telefon bağlantısı koptu")
                log("telefon ayrıldı")

    async def _from_device(self, message: str | bytes) -> None:
        try:
            msg = json.loads(message)
        except ValueError:
            return
        if not isinstance(msg, dict) or "id" not in msg or "method" in msg:
            return  # telefondan gelen bildirimler şimdilik yok sayılır
        entry = self._pending.pop(msg["id"], None) if isinstance(msg["id"], int) else None
        if entry is None:
            return
        client_ws, original_id, timer = entry
        timer.cancel()
        msg["id"] = original_id
        try:
            await client_ws.send(json.dumps(msg, ensure_ascii=False))
        except Exception:
            pass

    def _fail_pending(self, code: str, message: str) -> None:
        pending, self._pending = self._pending, {}
        for client_ws, original_id, timer in pending.values():
            timer.cancel()
            asyncio.ensure_future(self._safe_send(client_ws, _error(original_id, -32000, message, {"code": code})))

    @staticmethod
    async def _safe_send(ws, text: str) -> None:
        try:
            await ws.send(text)
        except Exception:
            pass

    # --- istemci tarafı -----------------------------------------------------

    async def handle_client(self, ws, *_: Any) -> None:
        if self.client is not None:
            await ws.close(code=1013, reason="Başka bir istemci bağlı")
            return
        self.client = ws
        try:
            async for message in ws:
                await self._from_client(ws, message)
        except Exception:
            pass
        finally:
            self.client = None

    async def _from_client(self, ws, message: str | bytes) -> None:
        try:
            req = json.loads(message)
        except ValueError:
            await ws.send(_error(None, -32700, "Parse error"))
            return
        if not isinstance(req, dict) or not isinstance(req.get("method"), str):
            await ws.send(_error(req.get("id") if isinstance(req, dict) else None, -32600, "Invalid Request"))
            return
        req_id = req.get("id")
        if req["method"] == "relay.status":
            if "id" in req:
                await ws.send(json.dumps({"jsonrpc": "2.0", "id": req_id, "result": {
                    "device": self.device is not None, "deviceInfo": self.device_info}}, ensure_ascii=False))
            return
        if self.device is None:
            if "id" in req:
                await ws.send(_error(req_id, -32000, "Telefon bağlı değil", {"code": "device_not_connected"}))
            return
        if "id" not in req:
            await self._safe_send(self.device, json.dumps(req, ensure_ascii=False))
            return
        relay_id = next(self._ids)
        timer = asyncio.get_running_loop().call_later(REQUEST_TIMEOUT, self._timeout, relay_id)
        self._pending[relay_id] = (ws, req_id, timer)
        await self._safe_send(self.device, json.dumps({**req, "id": relay_id}, ensure_ascii=False))

    def _timeout(self, relay_id: int) -> None:
        entry = self._pending.pop(relay_id, None)
        if entry:
            client_ws, original_id, _ = entry
            asyncio.ensure_future(self._safe_send(
                client_ws, _error(original_id, -32000, "Telefon yanıt vermedi", {"code": "timeout"})))


async def serve(relay: Relay, device_host: str, device_port: int, client_port: int,
                started: asyncio.Event | None = None) -> None:
    import websockets

    async with websockets.serve(relay.handle_device, device_host, device_port, max_size=None), \
            websockets.serve(relay.handle_client, "127.0.0.1", client_port, max_size=None):
        log(f"telefon için: ws://{device_host}:{device_port}   istemciler için: ws://127.0.0.1:{client_port}")
        if started is not None:
            started.set()
        await asyncio.Future()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--device-host", help="Telefonun bağlanacağı adres (varsayılan: tailscale ip -4)")
    p.add_argument("--device-port", type=int, default=8770)
    p.add_argument("--client-port", type=int, default=8766)
    p.add_argument("--token", help="Varsayılan: ~/.config/cub/token (yoksa üretilir)")
    args = p.parse_args()

    host = args.device_host or tailscale_ip()
    if not host:
        print("Tailscale IP'si bulunamadı; --device-host verin.", file=sys.stderr)
        return 2
    token = args.token or load_or_create_token()
    log(f"telefon menüsüne girilecekler: URL ws://{host}:{args.device_port}  token {token}")
    try:
        asyncio.run(serve(Relay(token), host, args.device_port, args.client_port))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
