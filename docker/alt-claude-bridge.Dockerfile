FROM python:3.12-alpine

RUN apk add --no-cache openssh-client \
    && addgroup -g 1000 bridge \
    && adduser -D -u 1000 -G bridge -h /home/bridge bridge

WORKDIR /app
COPY scripts/alt-claude-http-bridge.py /app/alt-claude-http-bridge.py

USER bridge
ENTRYPOINT ["python3", "/app/alt-claude-http-bridge.py"]
