# ScanForce Open mock provider: synthetic results only, never real documents.
# Run behind an HTTPS endpoint you control; the token comes from the platform's secret store.
FROM python:3.12-slim
WORKDIR /app
COPY server.py .
RUN useradd --system --home /data app && mkdir -p /data && chown app /data
USER app
ENV HOST=0.0.0.0 PORT=8787 MOCK_PROVIDER_DB=/data/jobs.sqlite3 PYTHONUNBUFFERED=1
EXPOSE 8787
CMD ["python3", "server.py"]
