from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import urllib.error
import urllib.request

WORKER_URL = os.environ.get("WORKER_URL", "http://inference_worker:9000").rstrip("/")
APP_PORT = int(os.environ.get("APP_PORT", "8000"))


def check_worker():
    """Check current worker readiness for each request; do not cache startup state."""
    try:
        with urllib.request.urlopen(f"{WORKER_URL}/status", timeout=2) as response:
            if response.status != 200:
                return False
            payload = json.loads(response.read().decode("utf-8"))
            return payload.get("engine_loaded") is True and payload.get("checksum_valid") is True
    except (OSError, ValueError, urllib.error.URLError, TimeoutError):
        return False


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            worker_ok = check_worker()
            self._send(200 if worker_ok else 503, {
                "service": "vision_api",
                "status": "healthy" if worker_ok else "degraded",
                "worker_ready": worker_ok,
            })
        elif self.path == "/api/v1/detect":
            if not check_worker():
                self._send(503, {"error": "inference_worker unavailable or engine invalid"})
                return
            self._send(200, {
                "stream": "EO_CAM_01",
                "detections": [{"cls": "vehicle", "conf": 0.91}],
            })
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        print(f"[vision_api] {self.address_string()} - {fmt % args}", flush=True)


if __name__ == "__main__":
    print(f"Starting vision_api on port {APP_PORT}, worker={WORKER_URL}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", APP_PORT), Handler).serve_forever()
