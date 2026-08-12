#!/usr/bin/env python3
"""Minimal GPU-aware HTTP inference stub for Kubernetes readiness probes.

Not a production model server — replace with TorchServe, Triton, vLLM, etc.
"""
from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import torch


DEVICE = os.environ.get("MODEL_DEVICE", "cuda:0" if torch.cuda.is_available() else "cpu")
PORT = int(os.environ.get("PORT", "8080"))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:  # quieter logs
        return

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/healthz", "/readyz"):
            ok = True
            detail = {"device": DEVICE}
            if DEVICE.startswith("cuda"):
                ok = torch.cuda.is_available()
                if ok:
                    detail["gpu"] = torch.cuda.get_device_name(0)
            self._json(200 if ok else 503, {"status": "ok" if ok else "degraded", **detail})
            return
        if self.path == "/v1/info":
            self._json(
                200,
                {
                    "torch": torch.__version__,
                    "cuda": torch.version.cuda,
                    "device": DEVICE,
                    "gpu_count": torch.cuda.device_count() if torch.cuda.is_available() else 0,
                },
            )
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/v1/predict":
            self._json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(length) if length else b""
        # Placeholder "inference": matmul on device
        device = torch.device(DEVICE if torch.cuda.is_available() or DEVICE == "cpu" else "cpu")
        x = torch.randn(256, 256, device=device)
        y = (x @ x).mean().item()
        if device.type == "cuda":
            torch.cuda.synchronize()
        self._json(200, {"ok": True, "score": float(y), "device": str(device)})


def main() -> None:
    print(f"listening on :{PORT} device={DEVICE} cuda_available={torch.cuda.is_available()}", flush=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
