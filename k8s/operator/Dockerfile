FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY operator.py .

RUN useradd -u 1000 -r -s /bin/false jarvis
USER 1000
CMD ["kopf", "run", "operator.py", "--verbose", "--liveness=http://0.0.0.0:8080/healthz", "--standalone"]
