FROM golang:1.24-alpine

RUN apk add --no-cache ca-certificates

WORKDIR /app

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod 0755 /usr/local/bin/docker-entrypoint

# Back4app exposes a single PORT env var; we use combined mode to serve
# both API and WebUI on that one port.
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
