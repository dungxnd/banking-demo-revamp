# Multi-stage build for banking-demo/api-producer.
# Build context: repo root (docker-compose / CI context: .)
#
# GOWORK=off: each service Dockerfile copies only internal/ + itself into the
# image.  go.work lists all six workspace modules, so the toolchain would fail
# trying to open the absent ones.  With GOWORK=off the toolchain uses this
# service's go.mod directly; the replace directive already points internal/ at
# the correct relative path.
FROM golang:1.26-alpine AS builder

ENV GOWORK=off

WORKDIR /src

# Copy only the two module manifests needed for dependency caching.
COPY internal/go.mod internal/go.sum ./internal/
COPY producer/go.mod producer/go.sum ./producer/

# Download dependencies before copying source (layer cache).
RUN cd /src/producer && go mod download

# Copy source.
COPY internal/ ./internal/
COPY producer/ ./producer/

# Build the binary.
RUN cd /src/producer && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o /out/api-producer .

# ── Runtime image ─────────────────────────────────────────────────────────────
FROM alpine:3.23
RUN apk add --no-cache ca-certificates curl
WORKDIR /app
COPY --from=builder /out/api-producer /app/api-producer
EXPOSE 8080
CMD ["/app/api-producer"]
