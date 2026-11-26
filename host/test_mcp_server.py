"""mcp_server.py testleri: sahte bir JSON-RPC WebSocket sunucusuna karşı (cihaz gerekmez).

Çalıştırma: host/.venv/bin/python -m unittest discover -s host
mcp paketi yoksa testler atlanır.
"""
from __future__ import annotations

import asyncio
import base64
import json
import unittest

try:
    import mcp_server
    from mcp.server.mcpserver.exceptions import ToolError
    from mcp_types import ImageContent, TextContent
except ImportError:  # mcp kurulu değil
    mcp_server = None


async def call_error(server, name: str, args: dict) -> str:
    """Aracın ToolError ile başarısız olmasını bekler; mesajı döndürür (MCP bunu is_error yanıtına çevirir)."""
    try:
        await server.call_tool(name, args)
    except ToolError as e:
        return str(e)
    raise AssertionError(f"{name} hata vermeliydi")

PORT = 18790
PNG = base64.b64encode(b"\x89PNG\r\n\x1a\nfake").decode()

ELEMENTS = [
    {"id": "e1", "kind": "ax", "cls": "UILabel", "label": "Count: 0", "value": None, "hint": None,
     "identifier": "counterLabel", "traits": ["staticText"], "frame": {"x": 10, "y": 10, "w": 100, "h": 30},
     "interactive": False, "enabled": True},
    {"id": "e2", "kind": "ax", "cls": "UIButton", "label": "Increment", "value": None, "hint": None,
     "identifier": "incrementButton", "traits": ["button"], "frame": {"x": 10, "y": 60, "w": 100, "h": 40},
     "interactive": True, "enabled": True},
]
SCREEN = {"width": 402, "height": 874, "scale": 3, "orientation": "portrait",
          "app": {"bundleId": "dev.test", "state": "active"}, "bridge": {"reverse": {"state": "connected"}}}


class FakeDevice:
    """Dylib'in JSON-RPC davranışını taklit eder; gelen istekleri kaydeder."""

    def __init__(self) -> None:
        self.requests: list[dict] = []
        self.fail_with: dict | None = None

    def observation(self, screenshot: bool) -> dict:
        return {"screen": SCREEN, "elements": ELEMENTS, "truncated": False,
                "screenshot": {"format": "png", "scale": 1, "data": PNG} if screenshot else None}

    async def handler(self, ws, *_) -> None:
        async for raw in ws:
            req = json.loads(raw)
            self.requests.append(req)
            if self.fail_with is not None:
                resp = {"jsonrpc": "2.0", "id": req["id"], "error": self.fail_with}
            elif req["method"] == "screen":
                resp = {"jsonrpc": "2.0", "id": req["id"], "result": SCREEN}
            elif req["method"] == "observe":
                resp = {"jsonrpc": "2.0", "id": req["id"],
                        "result": self.observation(req["params"].get("screenshot", True))}
            elif req["method"] == "act":
                p = req["params"]
                if p.get("target") == "missing":
                    result = {"ok": False, "code": "element_not_found", "message": "Eleman yok: missing"}
                else:
                    result = {"ok": True, "method": "hid-touch"}
                if p.get("observe"):
                    result["observe"] = self.observation(p["observe"].get("screenshot", True))
                resp = {"jsonrpc": "2.0", "id": req["id"], "result": result}
            else:
                resp = {"jsonrpc": "2.0", "id": req["id"], "error": {"code": -32601, "message": "Method not found"}}
            await ws.send(json.dumps(resp))


@unittest.skipIf(mcp_server is None, "mcp kurulu değil")
class MCPServerTests(unittest.TestCase):
    def run_with_device(self, scenario):
        import websockets

        async def main():
            device = FakeDevice()
            async with websockets.serve(device.handler, "127.0.0.1", PORT):
                server, bridge = mcp_server.build_server(f"ws://127.0.0.1:{PORT}")
                try:
                    await scenario(server, device)
                finally:
                    await bridge.close()

        asyncio.run(asyncio.wait_for(main(), 15))

    def test_lists_tools(self):
        server, _ = mcp_server.build_server("ws://127.0.0.1:1")
        names = {t.name for t in asyncio.run(server.list_tools())}
        self.assertEqual(names, {"screen", "observe", "tap", "swipe", "activate", "type"})

    def test_observe_returns_image_and_elements(self):
        async def scenario(server, device):
            result = await server.call_tool("observe", {})
            self.assertFalse(result.is_error)
            self.assertIsInstance(result.content[0], ImageContent)
            self.assertEqual(result.content[0].mime_type, "image/png")
            text = result.content[1].text
            self.assertIn("dev.test", text)
            self.assertIn('e2 * "Increment" id=incrementButton (10,60 100x40) button', text)
            self.assertEqual(device.requests[0]["params"], {"screenshot": True, "maxElements": 400})

        self.run_with_device(scenario)

    def test_tap_by_id_with_observe_after(self):
        async def scenario(server, device):
            result = await server.call_tool("tap", {"element_id": "e2", "observe_after": True, "settle_ms": 0})
            self.assertFalse(result.is_error)
            self.assertEqual(device.requests[0]["params"],
                             {"type": "tap", "target": "e2", "observe": {"screenshot": False}, "settleMs": 0})
            self.assertTrue(all(isinstance(c, TextContent) for c in result.content))  # ekran görüntüsü istenmedi
            self.assertIn("hid-touch", result.content[0].text)
            self.assertIn("Count: 0", result.content[1].text)

        self.run_with_device(scenario)

    def test_swipe_and_type_params(self):
        async def scenario(server, device):
            await server.call_tool("swipe", {"x1": 2, "y1": 450, "x2": 320, "y2": 450})
            await server.call_tool("type", {"text": "merhaba", "clear": True})
            self.assertEqual(device.requests[0]["params"], {"type": "swipe", "target": {"x": 2.0, "y": 450.0},
                                                            "to": {"x": 320.0, "y": 450.0}, "duration": 0.3})
            self.assertEqual(device.requests[1]["params"], {"type": "type", "text": "merhaba", "clear": True})

        self.run_with_device(scenario)

    def test_failed_action_is_tool_error(self):
        async def scenario(server, device):
            self.assertIn("element_not_found", await call_error(server, "tap", {"element_id": "missing"}))

        self.run_with_device(scenario)

    def test_relay_error_is_tool_error(self):
        async def scenario(server, device):
            device.fail_with = {"code": -32000, "message": "Telefon bağlı değil", "data": {"code": "device_not_connected"}}
            self.assertIn("device_not_connected", await call_error(server, "observe", {}))

        self.run_with_device(scenario)

    def test_missing_target(self):
        async def scenario(server, device):
            self.assertIn("element_id ya da x ve y", await call_error(server, "tap", {}))
            self.assertEqual(device.requests, [])

        self.run_with_device(scenario)

    def test_unreachable_bridge(self):
        server, _ = mcp_server.build_server("ws://127.0.0.1:1")
        self.assertIn("bağlanılamadı", asyncio.run(call_error(server, "screen", {})))


if __name__ == "__main__":
    unittest.main()
