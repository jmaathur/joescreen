# Multi-stage build for the JoeScreen LiveKit token server (a tiny Go HTTP service that mints
# short-lived, room-scoped JWTs). The final image is a distroless static binary — no shell, tiny.
FROM golang:1.22-alpine AS build
WORKDIR /src
# Cache deps first.
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
# Static build (no libc) so it runs on the distroless base.
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /token-server .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /token-server /token-server
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/token-server"]
