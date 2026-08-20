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

RUN mkdir -p /data && chmod 750 /data

ENV PORT=8443 \
    DB_PATH=/data/auth-tokens.db \
    REGISTRY_URL=registry.laymatched.io \
    PRIVATE_KEY_PATH=/data/private.pem \
    PUBLIC_KEY_PATH=/data/public.pem \
    REGISTRY_PUBLIC_KEY_PATH=/data/auth-public.pem \
    RATE_LIMIT_PER_MIN=50 \
    LOG_LEVEL=info

EXPOSE 8443

USER 1000:1000

ENTRYPOINT ["./auth-api"]