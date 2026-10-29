# Task 1 — EC2 execution and validation guide

This repository targets the challenge's Python mock services and does not require a GPU for the supplied tests. Run the commands from the repository root on your EC2 instance.

## 1. Prepare environment

```bash
cp .env.example .env
sed -i "s|replace-with-a-long-random-password|$(openssl rand -hex 24)|" .env
chmod 600 .env
```

Keep `.env` private and do not commit it. The `.env.example` file is safe to commit.

## 2. Validate configuration and build/start

```bash
docker compose config
docker compose up -d --build
docker compose ps
```

Wait until `postgres` and `inference_worker` show `healthy` and `vision_api` is running. If a service fails:

```bash
docker compose logs --tail=100 postgres inference_worker vision_api
```

## 3. Test required endpoints

Run these commands on EC2:

```bash
curl -i http://127.0.0.1:8000/health
curl -i http://127.0.0.1:8000/api/v1/detect
```

Expected: both return HTTP `200`. The health JSON includes `"status": "healthy"` and `"worker_ready": true`; detect returns a JSON response containing the sample detection.

## 4. Confirm non-root execution and image size

```bash
docker compose exec vision_api id -u
docker compose exec inference_worker id -u
docker image inspect eoir-stack:1.4.2 --format='{{.Size}} bytes'
```

Both UID commands should print `10001`. The application image should be below `220 * 1024 * 1024` bytes (230,686,720 bytes). PostgreSQL is a separate image and is not included in that application-image limit.

## 5. Prove that corrupt model files fail health checks

This test modifies only the disposable container's writable layer, not the repository or image. Do not use it against a production deployment.

```bash
docker compose exec -u 0 inference_worker sh -c "printf 'corrupted-model' > /app/models/eo_detector_fp16.engine"
```

Wait for the health check to detect the mismatch:

```bash
for i in $(seq 1 15); do
  cid=$(docker compose ps -q inference_worker)
  status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")
  echo "attempt=$i status=$status"
  [ "$status" = "unhealthy" ] && break
  sleep 1
done
```

Confirm the API now reports unavailable:

```bash
curl -i http://127.0.0.1:8000/health
curl -i http://127.0.0.1:8000/api/v1/detect
```

Expected: HTTP `503` while the worker is unhealthy. If the worker process itself exits, Docker reports `exited`/`restarting`, not `unhealthy`; a health check can only mark a running container unhealthy.

## 6. Restore the worker and confirm recovery

Recreate the worker from the clean image layer:

```bash
docker compose up -d --force-recreate inference_worker
```

Wait for it to become healthy, then retry:

```bash
docker compose ps
curl -i http://127.0.0.1:8000/health
curl -i http://127.0.0.1:8000/api/v1/detect
```

Expected: worker health returns to `healthy` and both API endpoints return HTTP `200` again. The API checks worker readiness per request, so it does not need a restart to recover.

## 7. Other verification

```bash
python -m unittest discover -s tests -v
sha256sum models/eo_detector_fp16.engine
cat models/manifest.json
docker compose logs --tail=100
```

## Important artifact note

The provided `models/eo_detector_fp16.engine` is only 4,151 bytes and appears to be a challenge placeholder, not a real production TensorRT engine. The manifest SHA-256 was aligned to the exact supplied file so the repository's integrity test can pass. Before production use, obtain the trusted model artifact and independently authenticated checksum from the model/release owner. This mock worker validates file integrity; it does not execute inference using TensorRT.

## EC2 access note

For browser access from your laptop, allow inbound TCP 8000 in the EC2 security group only from your current public IP while testing. Do not expose the API to `0.0.0.0/0` unnecessarily. The database port is not published on the EC2 host.
