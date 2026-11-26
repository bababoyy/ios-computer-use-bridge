#!/usr/bin/env python3
"""ComputerUseBridge için MCP sunucusu (stdio).

Claude gibi bir MCP istemcisinin, ComputerUseBridge dylib'i yüklü iOS uygulamasını araçlarla
gözlemleyip kontrol etmesini sağlar. Dylib'e WebSocket JSON-RPC ile bağlanır:

    CUB_URL=ws://127.0.0.1:8766   reverse mod, host/relay.py üzerinden (varsayılan)
    CUB_URL=ws://127.0.0.1:8765   USB, iproxy 8765:8765 ile

Araçlar: screen, observe, tap, swipe, activate, type. Koordinatlar ekran point'idir.
Claude Code'a ekleme:
    claude mcp add cub -e CUB_URL=ws://127.0.0.1:8766 -- host/.venv/bin/python host/mcp_server.py
"""
from __future__ import annotations

import asyncio
import base64
import itertools
import json
import os
from typing import Any

from mcp.server.mcpserver import Image, MCPServer
from mcp.server.mcpserver.exceptions import ToolError

DEFAULT_URL = "ws://127.0.0.1:8766"
CALL_TIMEOUT = 60.0

INSTRUCTIONS = """\
ComputerUseBridge, bir iOS uygulamasının İÇİNDEN arayüzü gözler ve gerçek dokunma uygular.
Önerilen döngü: observe → karar ver → tap/swipe/type → sonucu observe ile doğrula
(ya da eylemde observe_after=true kullan).
- Hedeflerken öncelikle observe'un verdiği eleman ID'lerini kullan; ID yoksa ekran görüntüsünden
  point cinsinden koordinat ver (ekran görüntüsü 1x ölçekte, yani piksel = point).
- tap gerçek bir dokunmadır; bir satıra dokunmak onu açar ya da çalar. Yalnızca semantik eylem
  istiyorsan activate kullan.
- type yalnızca odaktaki metin alanına yazar; önce alana tap ile dokun.
- Uygulama arka plandaysa ya da telefon bağlı değilse araçlar hata döner.
"""


class Bridge:
    """Dylib'e (ya da relay'e) tek bir WebSocket üzerinden JSON-RPC çağrıları yapar."""

    def __init__(self, url: str) -> None:
        self.url = url
        self._ws = None
        self._lock = asyncio.Lock()
        self._ids = itertools.count(1)

    async def _connect(self) -> None:
        import websockets

        try:
            self._ws = await websockets.connect(self.url, max_size=None, open_timeout=5)
        except (OSError, asyncio.TimeoutError) as e:
            raise ToolError(f"Köprüye bağlanılamadı ({self.url}): {e}. "
                            "relay.py (reverse mod) ya da iproxy (USB) çalışıyor mu?") from e

    async def close(self) -> None:
        if self._ws is not None:
            await self._ws.close()
            self._ws = None

    async def call(self, method: str, params: dict | None = None) -> Any:
        import websockets

        async with self._lock:
            req_id = next(self._ids)
            payload = json.dumps({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}})
            # Gönderim başarısızsa istek hiç ulaşmamıştır: bir kez yeniden bağlanıp dene.
            for attempt in (0, 1):
                if self._ws is None:
                    await self._connect()
                try:
                    await self._ws.send(payload)
                    break
                except websockets.ConnectionClosed:
                    self._ws = None
                    if attempt == 1:
                        raise ToolError("Köprü bağlantısı kurulamadı") from None
            try:
                while True:
                    resp = json.loads(await asyncio.wait_for(self._ws.recv(), CALL_TIMEOUT))
                    if isinstance(resp, dict) and resp.get("id") == req_id:
                        break
            except websockets.ConnectionClosed:
                self._ws = None
                raise ToolError("Yanıt beklenirken bağlantı koptu; eylem uygulanmış olabilir, observe ile kontrol et.") \
                    from None
            except asyncio.TimeoutError:
                self._ws = None
                raise ToolError(f"Köprü {CALL_TIMEOUT:.0f} sn içinde yanıt vermedi") from None

        if "error" in resp:
            err = resp["error"] or {}
            code = (err.get("data") or {}).get("code")
            raise ToolError(f"{err.get('message', 'Bilinmeyen hata')}" + (f" ({code})" if code else ""))
        return resp.get("result")


# ---------------------------------------------------------------------------
# Biçimlendirme

def format_screen(screen: dict) -> str:
    app = screen.get("app") or {}
    reverse = ((screen.get("bridge") or {}).get("reverse") or {}).get("state")
    return (f"Ekran {screen.get('width', 0):.0f}x{screen.get('height', 0):.0f} pt "
            f"(@{screen.get('scale', 0):.0f}x, {screen.get('orientation', '?')}), "
            f"uygulama {app.get('bundleId')} [{app.get('state')}]"
            + (f", reverse: {reverse}" if reverse else ""))


def format_element(el: dict) -> str:
    f = el.get("frame") or {}
    parts = [el.get("id", "?"), "*" if el.get("interactive") else "-"]
    if el.get("enabled") is False:
        parts.append("(devre dışı)")
    if el.get("label"):
        parts.append(json.dumps(el["label"], ensure_ascii=False))
    if el.get("value"):
        parts.append("= " + json.dumps(el["value"], ensure_ascii=False))
    if el.get("identifier"):
        parts.append(f"id={el['identifier']}")
    parts.append(f"({f.get('x', 0):.0f},{f.get('y', 0):.0f} {f.get('w', 0):.0f}x{f.get('h', 0):.0f})")
    traits = ",".join(el.get("traits") or [])
    if el.get("kind") == "webview":
        traits = "webview" + ("," + traits if traits else "")
    if traits:
        parts.append(traits)
    return " ".join(parts)


def observation_content(obs: dict) -> list:
    """observe sonucunu MCP içeriğine çevirir: varsa ekran görüntüsü + metin."""
    content: list = []
    shot = obs.get("screenshot")
    if shot and shot.get("data"):
        content.append(Image(data=base64.b64decode(shot["data"]), format="png"))
    lines = [format_screen(obs.get("screen") or {})]
    elements = obs.get("elements") or []
    lines.append(f"{len(elements)} eleman" + (" (liste kesildi)" if obs.get("truncated") else "")
                 + " — ID, * = etkileşimli, etiket, = değer, id=identifier, (x,y genişlikxyükseklik) point, özellikler:")
    lines.extend(format_element(e) for e in elements)
    content.append("\n".join(lines))
    return content


# ---------------------------------------------------------------------------
# Sunucu

def build_server(url: str | None = None) -> tuple[MCPServer, Bridge]:
    bridge = Bridge(url or os.environ.get("CUB_URL", DEFAULT_URL))
    server = MCPServer("computer-use-bridge", instructions=INSTRUCTIONS, version="0.3.0")

    def target_of(element_id: str | None, x: float | None, y: float | None) -> Any:
        if element_id:
            return element_id
        if x is not None and y is not None:
            return {"x": float(x), "y": float(y)}
        raise ToolError("element_id ya da x ve y gerekli")

    async def act(params: dict, observe_after: bool, screenshot_after: bool, settle_ms: int) -> list:
        if observe_after:
            params = {**params, "observe": {"screenshot": screenshot_after}, "settleMs": settle_ms}
        result = await bridge.call("act", params)
        if not result.get("ok"):
            raise ToolError(f"{result.get('message') or 'Eylem başarısız'} ({result.get('code', 'error')})")
        obs = result.pop("observe", None)
        content: list = [json.dumps(result, ensure_ascii=False)]
        if obs:
            content.extend(observation_content(obs))
        return content

    @server.tool(description="Ekran ölçüleri, yön, safe area, uygulama ve köprü durumu.", structured_output=False)
    async def screen() -> str:
        return json.dumps(await bridge.call("screen"), ensure_ascii=False, indent=1)

    @server.tool(description="Ekran görüntüsü (PNG, 1x = point) ve erişilebilirlik eleman listesi. "
                             "Eylemden önce hedefi bulmak ve sonra doğrulamak için kullan.",
                 structured_output=False)
    async def observe(screenshot: bool = True, max_elements: int = 400) -> list:
        if not 1 <= max_elements <= 2000:
            raise ToolError("max_elements 1 ile 2000 arasında olmalı")
        return observation_content(await bridge.call("observe", {"screenshot": screenshot,
                                                                 "maxElements": max_elements}))

    @server.tool(description="Gerçek dokunma (IOHIDEvent). Hedef: observe'dan bir element_id ya da x,y (point).",
                 structured_output=False)
    async def tap(element_id: str | None = None, x: float | None = None, y: float | None = None,
                  observe_after: bool = False, screenshot_after: bool = False, settle_ms: int = 500) -> list:
        return await act({"type": "tap", "target": target_of(element_id, x, y)},
                         observe_after, screenshot_after, settle_ms)

    @server.tool(description="(x1,y1)'den (x2,y2)'ye gerçek kaydırma. Liste aşağı: y2 < y1. "
                             "Geri gitmek için soldan kenar kaydırması: x1=2.",
                 structured_output=False)
    async def swipe(x1: float, y1: float, x2: float, y2: float, duration: float = 0.3,
                    observe_after: bool = False, screenshot_after: bool = False, settle_ms: int = 500) -> list:
        return await act({"type": "swipe", "target": {"x": float(x1), "y": float(y1)},
                          "to": {"x": float(x2), "y": float(y2)}, "duration": float(duration)},
                         observe_after, screenshot_after, settle_ms)

    @server.tool(description="Semantik eylem (accessibilityActivate, UIControl eylemi, hücre seçimi, "
                             "WebView'da JS tıklaması). tap'in tepki vermediği durumlar için.",
                 structured_output=False)
    async def activate(element_id: str | None = None, x: float | None = None, y: float | None = None,
                       observe_after: bool = False, screenshot_after: bool = False, settle_ms: int = 500) -> list:
        return await act({"type": "activate", "target": target_of(element_id, x, y)},
                         observe_after, screenshot_after, settle_ms)

    @server.tool(name="type", description="Odaktaki metin alanına yazar (önce alana tap). clear=true önce siler.",
                 structured_output=False)
    async def type_text(text: str, clear: bool = False, observe_after: bool = False,
                        screenshot_after: bool = False, settle_ms: int = 500) -> list:
        return await act({"type": "type", "text": text, "clear": clear},
                         observe_after, screenshot_after, settle_ms)

    return server, bridge


def main() -> None:
    server, _ = build_server()
    server.run("stdio")


if __name__ == "__main__":
    main()
