FROM python:3.12-alpine

RUN apk add --no-cache openssh-client

WORKDIR /app
COPY scripts/alt-claude-http-bridge.py /app/alt-claude-http-bridge.py

ENTRYPOINT ["python3", "/app/alt-claude-http-bridge.py"]
