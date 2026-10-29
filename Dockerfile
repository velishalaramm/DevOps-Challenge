FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# The challenge services use only the Python standard library at runtime.
RUN groupadd --system --gid 10001 appuser \
    && useradd --system --uid 10001 --gid appuser --home-dir /app --no-create-home appuser

COPY --chown=appuser:appuser vision_api/ /app/vision_api/
COPY --chown=appuser:appuser inference_worker/ /app/inference_worker/
COPY --chown=appuser:appuser models/ /app/models/

RUN mkdir -p /app/models/.trt_cache \
    && chown -R appuser:appuser /app

USER 10001:10001

EXPOSE 8000 9000

CMD ["python", "vision_api/app.py"]
