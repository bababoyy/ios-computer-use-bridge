"""relay.py testleri: sahte telefon ve sahte istemciyle (ağ yalnızca 127.0.0.1).

Çalıştırma: python -m unittest discover -s host
"""
from __future__ import annotations

import asyncio
import json
import tempfile
import unittest
from pathlib import Path

import relay

DEVICE_PORT = 18770
CLIENT_PORT = 18766


def run(coro):
    return asyncio.run(asyncio.wait_for(coro, 15))


class RelayTests(unittest.TestCase):
    def setUp(self) -> None:
        try:
            import websockets  # noqa: F401
        except ImportError:
            self.skipTest("websockets yok")

    async def _with_relay(self, scenario):
        import websockets

        r = relay.Relay("sekret123")
        started = asyncio.Event()
        task = asyncio.create_task(relay.serve(r, "127.0.0.1", DEVICE_PORT, CLIENT_PORT, started))
        await started.wait()
        try:
            await scenario(websockets, r)
        finally:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    @staticmethod
    async def _fake_device(websockets, token="sekret123"):
        ws = await websockets.connect(f"ws://127.0.0.1:{DEVICE_PORT}")
        await ws.send(json.dumps({"jsonrpc": "2.0", "method": "cub.hello",
                                  "params": {"token": token, "bundleId": "dev.test", "bridge": "0.2.0"}}))
        return ws

    def test_forwards_requests_and_maps_ids(self):
        async def scenario(websockets, r):
            device = await self._fake_device(websockets)
            await asyncio.sleep(0.1)

            async def answer():
                req = json.loads(await device.recv())
                self.assertEqual(req["method"], "ping")
                self.assertNotEqual(req["id"], "abc")  # relay kendi kimliğini kullanır
                await device.send(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": "pong"}))

            async with websockets.connect(f"ws://127.0.0.1:{CLIENT_PORT}") as client:
                responder = asyncio.create_task(answer())
                await client.send(json.dumps({"jsonrpc": "2.0", "id": "abc", "method": "ping"}))
                resp = json.loads(await client.recv())
                await responder
            self.assertEqual(resp, {"jsonrpc": "2.0", "id": "abc", "result": "pong"})
            await device.close()

        run(self._with_relay(scenario))

    def test_status_and_no_device(self):
        async def scenario(websockets, r):
            async with websockets.connect(f"ws://127.0.0.1:{CLIENT_PORT}") as client:
                await client.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "relay.status"}))
                status = json.loads(await client.recv())["result"]
                self.assertFalse(status["device"])
                await client.send(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "observe"}))
                resp = json.loads(await client.recv())
                self.assertEqual(resp["error"]["data"]["code"], "device_not_connected")

        run(self._with_relay(scenario))

    def test_rejects_bad_token(self):
        async def scenario(websockets, r):
            device = await self._fake_device(websockets, token="yanlis")
            with self.assertRaises(websockets.ConnectionClosed) as ctx:
                await device.recv()
            self.assertEqual(ctx.exception.rcvd.code, 1008)
            self.assertIsNone(r.device)

        run(self._with_relay(scenario))

    def test_device_disconnect_fails_pending(self):
        async def scenario(websockets, r):
            device = await self._fake_device(websockets)
            await asyncio.sleep(0.1)
            async with websockets.connect(f"ws://127.0.0.1:{CLIENT_PORT}") as client:
                await client.send(json.dumps({"jsonrpc": "2.0", "id": 9, "method": "observe"}))
                await device.recv()   # istek telefona ulaştı
                await device.close()  # yanıt vermeden koptu
                resp = json.loads(await client.recv())
            self.assertEqual(resp["id"], 9)
            self.assertEqual(resp["error"]["data"]["code"], "device_disconnected")

        run(self._with_relay(scenario))

    def test_token_file_is_created_once(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cub" / "token"
            first = relay.load_or_create_token(path)
            self.assertEqual(relay.load_or_create_token(path), first)
            self.assertEqual(len(first), 10)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
