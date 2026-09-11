FROM golang:1.25-alpine AS builder

RUN apk add --no-cache gcc musl-dev sqlite-dev

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build -ldflags="-s -w" -o auth-api .

FROM alpine:3.20

RUN apk add --no-cache sqlite-libs ca-certificates tzdata

WORKDIR /app

COPY --from=builder /app/auth-api .

RUN mkdir -p /data && chown 2001:2001 /data && chmod 750 /data

ENV PORT=8443 \
    DB_PATH=/data/auth-tokens.db \
    APPROVED_VERSION_PATH=/data/approved_version.txt \
    REGISTRY_URL=registry.matched.laysports.co.uk \
    PRIVATE_KEY_PATH=/data/private.pem \
    PUBLIC_KEY_PATH=/data/public.pem \
    REGISTRY_PUBLIC_KEY_PATH=/data/auth-public.pem \
    REGISTRY_CERT_PATH=/data/auth-cert.pem \
    RATE_LIMIT_PER_MIN=50 \
    LOG_LEVEL=info

EXPOSE 8443

USER 2001:2001

ENTRYPOINT ["./auth-api"]
