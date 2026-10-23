# syntax=docker/dockerfile:1.7
# The Fuel Rivals API (backend/). Build from the repository root so the context holds backend/:
#
#   docker buildx build -f deploy/Dockerfile --platform linux/arm64,linux/amd64 -t ghcr.io/OWNER/fuelrivals-api:dev .
#
# The build stage always runs on the builder's own architecture and cross-compiles (pure Go, CGO off), so an arm64
# image is built on an amd64 runner without emulation. The final image is distroless: no shell, no package manager,
# a non-root user. Its HEALTHCHECK uses the binary itself (`/api healthcheck`).

FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY backend/ ./
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api

FROM gcr.io/distroless/static-debian12:nonroot
ARG VERSION=dev
LABEL org.opencontainers.image.title="fuelrivals-api" \
      org.opencontainers.image.description="Fuel Rivals account, ranking and match settlement API" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.source="https://github.com/OWNER/REPO"
COPY --from=build /out/api /api
USER nonroot:nonroot
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=4s --start-period=20s --retries=3 CMD ["/api", "healthcheck"]
ENTRYPOINT ["/api"]
