# MinIO built from source: upstream stopped publishing public images/binaries, and the last ones carry
# Go stdlib + grpc CVEs. Built with the current Go toolchain and bumped deps. MINIO_VERSION is a git tag.
ARG MINIO_VERSION=RELEASE.2025-10-15T17-29-55Z
FROM golang:1-alpine AS build
ARG MINIO_VERSION
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch ${MINIO_VERSION} https://github.com/minio/minio.git .
RUN go get google.golang.org/grpc@latest github.com/rabbitmq/amqp091-go@latest github.com/apache/thrift@latest github.com/buger/jsonparser@latest github.com/prometheus/prometheus@latest golang.org/x/crypto@latest && go mod tidy
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/minio .

FROM alpine:3
RUN apk upgrade --no-cache && apk add --no-cache ca-certificates curl && adduser -D -u 1001 minio && mkdir /data && chown 1001:1001 /data
COPY --from=build /out/minio /usr/bin/minio
USER 1001
ENV MINIO_CONFIG_ENV_FILE=
EXPOSE 9000
ENTRYPOINT ["/usr/bin/minio"]
CMD ["server", "/data", "--address", ":9000", "--console-address", ":9001"]
