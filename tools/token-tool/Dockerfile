FROM golang:1.23-alpine AS builder

RUN apk add --no-cache gcc musl-dev sqlite-dev

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build -ldflags="-s -w" -o token-tool .

FROM alpine:3.20

RUN apk add --no-cache sqlite-libs ca-certificates

WORKDIR /app

COPY --from=builder /app/token-tool .

ENTRYPOINT ["./token-tool"]