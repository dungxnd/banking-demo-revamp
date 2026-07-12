# Multi-stage build for banking-demo/auth-service.
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
COPY services/auth-service/go.mod services/auth-service/go.sum ./services/auth-service/

# Download dependencies before copying source (layer cache).
RUN cd /src/services/auth-service && go mod download

# Copy source.
COPY internal/ ./internal/
COPY services/auth-service/ ./services/auth-service/

# Build the binary.
RUN cd /src/services/auth-service && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o /out/auth-service .

# ── Runtime image ─────────────────────────────────────────────────────────────
FROM alpine:3.23
RUN apk add --no-cache ca-certificates curl
WORKDIR /app
COPY --from=builder /out/auth-service /app/auth-service
EXPOSE 8001
CMD ["/app/auth-service"]
