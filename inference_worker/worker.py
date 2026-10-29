from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
import time

ENGINE_PATH = os.environ.get("ENGINE_PATH", "/app/models/eo_detector_fp16.engine")
MANIFEST_PATH = os.environ.get("MANIFEST_PATH", "/app/models/manifest.json")
CACHE_DIR = os.environ.get("TRT_CACHE_DIR", "/app/models/.trt_cache")
PORT = int(os.environ.get("WORKER_PORT", "9000"))
WARMUP_SECONDS = float(os.environ.get("ENGINE_WARMUP_SEC", "2.0"))


def verify_engine():
    try:
        if not os.path.isfile(ENGINE_PATH) or not os.path.isfile(MANIFEST_PATH):
            return False, "missing_files", ""
        with open(MANIFEST_PATH, "r", encoding="utf-8") as mf:
            manifest = json.load(mf)
        expected = manifest.get("sha256", "")
        if not isinstance(expected, str) or len(expected) != 64:
            return False, "invalid_manifest_sha256", ""
        digest = hashlib.sha256()
        with open(ENGINE_PATH, "rb") as engine:
            for chunk in iter(lambda: engine.read(1024 * 1024), b""):
                digest.update(chunk)
        actual = digest.hexdigest()
        if actual != expected:
            return False, expected, actual
        os.makedirs(CACHE_DIR, exist_ok=True)
        lock_file = os.path.join(CACHE_DIR, "fp16_execution_context.lock")
        with open(lock_file, "w", encoding="utf-8") as lf:
            lf.write(actual)
        return True, expected, actual
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"[inference_worker] verification error: {exc}", flush=True)
        return False, "verification_error", ""


class WorkerHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/status":
            self.send_response(404)
            self.end_headers()
            return
        valid, expected, actual = verify_engine()
        body = json.dumps({
            "service": "inference_worker",
            "engine_loaded": os.path.isfile(ENGINE_PATH),
            "checksum_valid": valid,
            "expected_sha256": expected,
            "actual_sha256": actual,
        }).encode("utf-8")
        self.send_response(200 if valid else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"[inference_worker] {self.address_string()} - {fmt % args}", flush=True)


if __name__ == "__main__":
    time.sleep(WARMUP_SECONDS)
    ok, expected, actual = verify_engine()
    print(f"[inference_worker] engine checksum valid={ok} (expected={expected[:12]}..., actual={actual[:12]}...)", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), WorkerHandler).serve_forever()
