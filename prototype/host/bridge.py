#!/usr/bin/env python3
"""Faz 0 host köprüsü.

Frida Gadget'a (USB ya da iproxy ile yönlendirilmiş port) bağlanır, agent'ı yükler ve
SPEC'teki native WebSocket kanalını (JSON-RPC 2.0) 127.0.0.1 üzerinde sunar.
Bu sayede host tarafı, ileride aynı protokolü konuşacak native dylib'e karşı
değişmeden geliştirilebilir.

Kullanım:
    python bridge.py serve                 # ws://127.0.0.1:8765
    python bridge.py observe --out ekran.png
    python bridge.py tap e1a2b3c4          # eleman ID'si ile
    python bridge.py tap 120 340           # koordinatla (point)
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import json
import sys
import time
from pathlib import Path
from typing import Any, Callable, Protocol

AGENT_DIR = Path(__file__).resolve().parent.parent / "agent"
DEFAULT_PORT = 8765


class Agent(Protocol):
    def screen(self) -> dict: ...
    def observe(self, options: dict) -> dict: ...
    def act(self, action: dict) -> dict: ...


class AgentError(Exception):
    """Agent'a ulaşılamadı ya da agent içinde hata oluştu."""


class InvalidParams(Exception):
    pass


# ---------------------------------------------------------------------------
# Frida bağlantısı

class FridaAgent:
    def __init__(self, device_id: str | None = None, remote: str | None = None,
                 target: str = "Gadget", agent_path: Path | None = None) -> None:
        self.device_id = device_id
        self.remote = remote
        self.target = target
        self.agent_path = agent_path
        self._api = None
        self._session = None

    def _load_source(self, frida) -> str:
        if self.agent_path is not None:
            return self.agent_path.read_text()
        built = AGENT_DIR / "_agent.js"
        if built.exists():
            return built.read_text()
        if not (AGENT_DIR / "node_modules").exists():
            raise AgentError(f"Derlenmiş agent yok. Önce: cd {AGENT_DIR} && npm install && npm run build")
        return frida.Compiler().build("src/index.ts", project_root=str(AGENT_DIR))

    def connect(self) -> None:
        try:
            import frida
        except ImportError as e:
            raise AgentError("frida modülü yok: pip install -r requirements.txt") from e
        try:
            if self.remote:
                device = frida.get_device_manager().add_remote_device(self.remote)
            elif self.device_id:
                device = frida.get_device(self.device_id, timeout=5)
            else:
                device = frida.get_usb_device(timeout=5)
            self._session = device.attach(self.target)
        except Exception as e:  # frida kendi hata tiplerini kullanır
            raise AgentError(f"Gadget'a bağlanılamadı ({e}). Uygulama açık mı, cihaz bağlı mı?") from e
        self._session.on("detached", self._on_detached)
        script = self._session.create_script(self._load_source(frida))
        script.on("message", self._on_message)
        script.load()
        self._api = script.exports_sync

    def _on_message(self, message: dict, data: Any) -> None:
        if message.get("type") == "error":
            print(f"[agent hata] {message.get('stack') or message.get('description')}", file=sys.stderr)
        elif message.get("type") == "log":
            print(f"[agent] {message.get('payload')}", file=sys.stderr)

    def _on_detached(self, reason: str, *_: Any) -> None:
        print(f"[köprü] Gadget bağlantısı koptu: {reason}", file=sys.stderr)
        self._api = None

    def _call(self, fn: Callable[[Any], Any]) -> Any:
        if self._api is None:
            raise AgentError("Agent bağlı değil")
        try:
            return fn(self._api)
        except AgentError:
            raise
        except Exception as e:
            raise AgentError(str(e)) from e

    def screen(self) -> dict:
        return self._call(lambda api: api.screen())

    def observe(self, options: dict) -> dict:
        return self._call(lambda api: api.observe(options))

    def act(self, action: dict) -> dict:
        return self._call(lambda api: api.act(action))


# ---------------------------------------------------------------------------
# JSON-RPC

def _observe_options(params: dict) -> dict:
    opts: dict = {}
    if "screenshot" in params:
        if not isinstance(params["screenshot"], bool):
            raise InvalidParams("screenshot bool olmalı")
        opts["screenshot"] = params["screenshot"]
    if "scale" in params:
        scale = params["scale"]
        if not isinstance(scale, (int, float)) or isinstance(scale, bool) or not 0.25 <= scale <= 3:
            raise InvalidParams("scale 0.25 ile 3 arasında olmalı")
        opts["scale"] = scale
    if "maxElements" in params:
        n = params["maxElements"]
        if not isinstance(n, int) or isinstance(n, bool) or not 1 <= n <= 2000:
            raise InvalidParams("maxElements 1 ile 2000 arasında olmalı")
        opts["maxElements"] = n
    return opts


def _validate_target(target: Any) -> Any:
    if isinstance(target, str) and target:
        return target
    if (isinstance(target, dict) and set(target) == {"x", "y"}
            and all(isinstance(target[k], (int, float)) and not isinstance(target[k], bool) for k in ("x", "y"))):
        return {"x": float(target["x"]), "y": float(target["y"])}
    raise InvalidParams("target bir eleman ID'si ya da {x, y} olmalı")


def m_ping(agent: Agent, params: dict) -> str:
    return "pong"


def m_screen(agent: Agent, params: dict) -> dict:
    return agent.screen()


def m_observe(agent: Agent, params: dict) -> dict:
    return agent.observe(_observe_options(params))


def m_act(agent: Agent, params: dict) -> dict:
    action_type = params.get("type")
    if not isinstance(action_type, str):
        raise InvalidParams("type gerekli (Faz 0: tap)")
    result = agent.act({"type": action_type, "target": _validate_target(params.get("target"))})
    observe = params.get("observe")
    if observe:
        settle_ms = params.get("settleMs", 400)
        if not isinstance(settle_ms, int) or isinstance(settle_ms, bool) or not 0 <= settle_ms <= 10_000:
            raise InvalidParams("settleMs 0 ile 10000 arasında olmalı")
        time.sleep(settle_ms / 1000)
        result = {**result, "observe": agent.observe(_observe_options(observe if isinstance(observe, dict) else {}))}
    return result


METHODS: dict[str, Callable[[Agent, dict], Any]] = {
    "ping": m_ping,
    "screen": m_screen,
    "observe": m_observe,
    "act": m_act,
}


def _error(req_id: Any, code: int, message: str, data: Any = None) -> str:
    err: dict = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return json.dumps({"jsonrpc": "2.0", "id": req_id, "error": err}, ensure_ascii=False)


async def handle(agent: Agent, raw: str | bytes) -> str | None:
    """Tek bir JSON-RPC isteğini işler. Bildirimlerde (id yok) None döner."""
    try:
        req = json.loads(raw)
    except (ValueError, TypeError):
        return _error(None, -32700, "Parse error")
    if not isinstance(req, dict) or req.get("jsonrpc") != "2.0" or not isinstance(req.get("method"), str):
        return _error(req.get("id") if isinstance(req, dict) else None, -32600, "Invalid Request")
    req_id = req.get("id")
    fn = METHODS.get(req["method"])
    if fn is None:
        return _error(req_id, -32601, f"Method not found: {req['method']}")
    params = req.get("params", {})
    if params is None:
        params = {}
    if not isinstance(params, dict):
        return _error(req_id, -32602, "params bir nesne olmalı")
    try:
        result = await asyncio.get_running_loop().run_in_executor(None, fn, agent, params)
    except InvalidParams as e:
        return _error(req_id, -32602, str(e))
    except AgentError as e:
        return _error(req_id, -32000, str(e), {"code": "agent_unavailable"})
    if "id" not in req:
        return None
    return json.dumps({"jsonrpc": "2.0", "id": req_id, "result": result}, ensure_ascii=False)


async def serve(agent: Agent, host: str, port: int) -> None:
    import websockets

    busy = asyncio.Lock()

    async def handler(ws, *_: Any) -> None:
        if busy.locked():
            await ws.close(code=1013, reason="Başka bir istemci kontrol ediyor")
            return
        async with busy:
            print("[köprü] istemci bağlandı", file=sys.stderr)
            try:
                async for message in ws:
                    response = await handle(agent, message)
                    if response is not None:
                        await ws.send(response)
            finally:
                print("[köprü] istemci ayrıldı", file=sys.stderr)

    async with websockets.serve(handler, host, port, max_size=None):
        print(f"[köprü] ws://{host}:{port} dinleniyor", file=sys.stderr)
        await asyncio.Future()


# ---------------------------------------------------------------------------
# CLI

def _print_elements(elements: list[dict]) -> None:
    for el in elements:
        f = el["frame"]
        name = el.get("label") or el.get("identifier") or "-"
        value = f" = {el['value']}" if el.get("value") else ""
        flags = ("*" if el.get("interactive") else " ") + (" " if el.get("enabled", True) else "x")
        print(f"{el['id']} {flags} ({f['x']:.0f},{f['y']:.0f} {f['w']:.0f}x{f['h']:.0f}) "
              f"{el['cls']}: {name}{value} {','.join(el.get('traits', []))}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Faz 0 Frida köprüsü")
    p.add_argument("--device", help="Frida cihaz ID'si (varsayılan: ilk USB cihazı)")
    p.add_argument("--remote", help="host:port, ör. iproxy ile yönlendirilmiş 127.0.0.1:27042")
    p.add_argument("--target", default="Gadget", help="Bağlanılacak süreç adı (varsayılan: Gadget)")
    p.add_argument("--agent", type=Path, help="Derlenmiş agent JS dosyası")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("serve", help="WebSocket JSON-RPC sunucusunu başlatır")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=DEFAULT_PORT)

    o = sub.add_parser("observe", help="Ekran görüntüsü ve eleman listesi")
    o.add_argument("--out", type=Path, help="PNG dosyası")
    o.add_argument("--json", action="store_true", help="Ham JSON yazdır")

    t = sub.add_parser("tap", help="Eleman ID'si ya da X Y koordinatıyla dokun")
    t.add_argument("target", nargs="+")

    args = p.parse_args(argv)
    if args.cmd == "serve" and args.host not in ("127.0.0.1", "::1", "localhost"):
        print("Uyarı: köprü loopback dışında dinliyor; Faz 0'da kimlik doğrulama yok.", file=sys.stderr)

    agent = FridaAgent(args.device, args.remote, args.target, args.agent)
    try:
        agent.connect()
    except AgentError as e:
        print(f"Hata: {e}", file=sys.stderr)
        return 2

    if args.cmd == "serve":
        try:
            asyncio.run(serve(agent, args.host, args.port))
        except KeyboardInterrupt:
            pass
        return 0

    if args.cmd == "observe":
        result = agent.observe({"screenshot": args.out is not None})
        shot = result.pop("screenshot", None)
        if args.out is not None and shot:
            args.out.write_bytes(base64.b64decode(shot["data"]))
            print(f"Ekran görüntüsü: {args.out}", file=sys.stderr)
        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            print(json.dumps(result["screen"], ensure_ascii=False))
            _print_elements(result["elements"])
        return 0

    if args.cmd == "tap":
        if len(args.target) == 1:
            target: Any = args.target[0]
        elif len(args.target) == 2:
            target = {"x": float(args.target[0]), "y": float(args.target[1])}
        else:
            print("tap: ID ya da X Y verin", file=sys.stderr)
            return 2
        result = agent.act({"type": "tap", "target": target})
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result.get("ok") else 1

    return 2


if __name__ == "__main__":
    sys.exit(main())
