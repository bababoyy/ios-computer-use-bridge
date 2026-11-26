"""bridge.py'nin JSON-RPC katmanı için testler (cihaz ve frida gerekmez).

Çalıştırma: python -m unittest discover prototype/host
"""
from __future__ import annotations

import asyncio
import json
import unittest

import bridge


class FakeAgent:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []
        self.fail = False

    def _record(self, name: str, arg: dict) -> None:
        if self.fail:
            raise bridge.AgentError("bağlantı yok")
        self.calls.append((name, arg))

    def screen(self) -> dict:
        self._record("screen", {})
        return {"width": 393, "height": 852}

    def observe(self, options: dict) -> dict:
        self._record("observe", options)
        return {"elements": [], "screen": {}}

    def act(self, action: dict) -> dict:
        self._record("act", action)
        return {"ok": True, "method": "control-action"}


def rpc(agent, payload) -> dict | None:
    raw = payload if isinstance(payload, str) else json.dumps(payload)
    out = asyncio.run(bridge.handle(agent, raw))
    return None if out is None else json.loads(out)


class HandleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.agent = FakeAgent()

    def test_parse_error(self):
        self.assertEqual(rpc(self.agent, "{nope")["error"]["code"], -32700)

    def test_invalid_request(self):
        self.assertEqual(rpc(self.agent, {"id": 1, "method": "ping"})["error"]["code"], -32600)

    def test_unknown_method(self):
        resp = rpc(self.agent, {"jsonrpc": "2.0", "id": 1, "method": "waitForIdle"})
        self.assertEqual(resp["error"]["code"], -32601)

    def test_ping(self):
        self.assertEqual(rpc(self.agent, {"jsonrpc": "2.0", "id": 7, "method": "ping"}),
                         {"jsonrpc": "2.0", "id": 7, "result": "pong"})

    def test_notification_has_no_response(self):
        self.assertIsNone(rpc(self.agent, {"jsonrpc": "2.0", "method": "ping"}))

    def test_observe_passes_options(self):
        rpc(self.agent, {"jsonrpc": "2.0", "id": 1, "method": "observe",
                         "params": {"screenshot": False, "maxElements": 50}})
        self.assertEqual(self.agent.calls, [("observe", {"screenshot": False, "maxElements": 50})])

    def test_observe_rejects_bad_scale(self):
        resp = rpc(self.agent, {"jsonrpc": "2.0", "id": 1, "method": "observe", "params": {"scale": 10}})
        self.assertEqual(resp["error"]["code"], -32602)

    def test_act_with_element_id(self):
        resp = rpc(self.agent, {"jsonrpc": "2.0", "id": 1, "method": "act",
                                "params": {"type": "tap", "target": "e0011aabb"}})
        self.assertTrue(resp["result"]["ok"])
        self.assertEqual(self.agent.calls, [("act", {"type": "tap", "target": "e0011aabb"})])

    def test_act_with_point(self):
        rpc(self.agent, {"jsonrpc": "2.0", "id": 1, "method": "act",
                         "params": {"type": "tap", "target": {"x": 10, "y": 20}}})
        self.assertEqual(self.agent.calls, [("act", {"type": "tap", "target": {"x": 10.0, "y": 20.0}})])

    def test_act_rejects_bad_target(self):
        for target in [None, "", {"x": 1}, {"x": "1", "y": 2}, {"x": True, "y": 2}]:
            resp = rpc(self.agent, {"jsonrpc": "2.0", "id": 1, "method": "act",
                                    "params": {"type": "tap", "target": target}})
            self.assertEqual(resp["error"]["code"], -32602, target)
        self.assertEqual(self.agent.calls, [])

    def test_act_with_observe(self):
        resp = rpc(self.agent, {"jsonrpc": "2.0", "id": 1, "method": "act",
                                "params": {"type": "tap", "target": "e1", "observe": {"screenshot": False},
                                           "settleMs": 0}})
        self.assertIn("observe", resp["result"])
        self.assertEqual([c[0] for c in self.agent.calls], ["act", "observe"])

    def test_agent_error(self):
        self.agent.fail = True
        resp = rpc(self.agent, {"jsonrpc": "2.0", "id": 1, "method": "screen"})
        self.assertEqual(resp["error"]["code"], -32000)
        self.assertEqual(resp["error"]["data"]["code"], "agent_unavailable")


class ServeTests(unittest.TestCase):
    def test_round_trip_and_single_client(self):
        try:
            import websockets
        except ImportError:
            self.skipTest("websockets yok")

        async def scenario():
            agent = FakeAgent()
            server = asyncio.create_task(bridge.serve(agent, "127.0.0.1", 18765))
            await asyncio.sleep(0.3)
            try:
                async with websockets.connect("ws://127.0.0.1:18765") as first:
                    await first.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}))
                    self.assertEqual(json.loads(await first.recv())["result"], "pong")
                    async with websockets.connect("ws://127.0.0.1:18765") as second:
                        with self.assertRaises(websockets.ConnectionClosed) as ctx:
                            await second.recv()
                        self.assertEqual(ctx.exception.rcvd.code, 1013)
            finally:
                server.cancel()

        asyncio.run(scenario())


if __name__ == "__main__":
    unittest.main()
