FROM python:3.13-slim
WORKDIR /app
COPY service.py /app/service.py
RUN useradd --uid 10001 --create-home assistant && mkdir /data && chown assistant:assistant /data
USER assistant
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 HISTORY_DB=/data/assistant.sqlite3
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health',timeout=2)"
CMD ["python", "service.py"]
