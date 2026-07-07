# JoeScreen infra — self-hosted LiveKit SFU + token server

Media plane for JoeScreen: a single-node [LiveKit](https://github.com/livekit/livekit)
SFU (Apache-2.0, pinned to `livekit/livekit-server:v1.13.3`) with embedded
TURN/TLS on :443, plus a tiny Go token server that mints short-lived JWTs.

> **REQUIRED HUMAN OPS STEP (RISKS.md R2/R3).** Nothing here works in
> production until a human supplies: (R2) a domain + DNS record + TLS certs
> for this host, and (R3) a freshly generated API key/secret that lives only
> on the server. Also note: **media is plaintext inside SFU memory** — the SFU
> decrypts SRTP to route it. True end-to-end encryption is deferred to v1.x
> (LiveKit E2EE). Treat the SFU box as trusted infrastructure accordingly.

## 1. Generate API keys (R3)

```sh
docker run --rm livekit/livekit-server:v1.13.3 generate-keys
```

(equivalently, `livekit-server generate-keys` if you have the binary). Put the
pair in two places, and keep them in sync:

1. `infra/.env` (git-ignored) — consumed by `docker-compose.yml`:

   ```sh
   LIVEKIT_API_KEY=API...           # from generate-keys
   LIVEKIT_API_SECRET=...           # from generate-keys
   LIVEKIT_URL=wss://sfu.example.com
   ```

2. `infra/livekit.yaml` — replace the placeholder under `keys:`. (The
   `LIVEKIT_KEYS` env var from compose overrides this map, but keeping the
   file correct avoids surprises when running the binary directly.)

The secret is used only by the SFU (to verify tokens) and the token server
(to sign them). It is **never** shipped in the Mac/iOS apps.

## 2. Domain + TLS certs (R2)

The embedded TURN/TLS listener on :443 needs a real domain and certificate:

- Point `sfu.example.com` (your real name) at this host's public IP.
- Set `turn.domain` in `livekit.yaml` to that name.
- Drop certs into `infra/certs/` as `fullchain.pem` and `privkey.pem`
  (e.g. from Let's Encrypt / certbot). Compose mounts this directory
  read-only into the container at `/etc/livekit-certs/`.

Open these ports on the host firewall / cloud security group:

| Port          | Proto | Purpose                          |
|---------------|-------|----------------------------------|
| 7880          | TCP   | HTTP/WS signaling                |
| 7881          | TCP   | ICE/TCP media fallback           |
| 50000–50100   | UDP   | RTP/RTCP media                   |
| 443           | TCP   | Embedded TURN over TLS           |
| 8080          | TCP   | Token endpoint (front with HTTPS)|

## 3. Token server image

Compose builds the token server from `./token-server`. Add this trivial
`token-server/Dockerfile` (kept out of the checked-in scaffold on purpose):

```dockerfile
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY . .
RUN go mod tidy && CGO_ENABLED=0 go build -o /token-server .
FROM alpine:3.20
COPY --from=build /token-server /token-server
ENTRYPOINT ["/token-server"]
```

## 4. Bring it up

```sh
cd infra
docker compose up -d
docker compose logs -f livekit   # watch for "starting LiveKit server"
```

Smoke-test the token endpoint:

```sh
curl 'http://localhost:8080/token?room=demo&identity=00000000-0000-0000-0000-000000000001'
# -> {"token":"eyJ...","url":"wss://sfu.example.com"}
```

Clients then connect to `url` with `token`; rooms auto-create on first join.

## 5. Local development without certs/domain

For loopback-only testing you can skip R2 entirely and run LiveKit in dev
mode, which uses the fixed key pair `devkey` / `secret` and requires no TLS:

```sh
docker run --rm -p 7880:7880 -p 7881:7881 -p 50000-50100:50000-50100/udp \
  livekit/livekit-server:v1.13.3 --dev
```

Then run the token server locally against it:

```sh
cd token-server
LIVEKIT_API_KEY=devkey LIVEKIT_API_SECRET=secret \
LIVEKIT_URL=ws://localhost:7880 go run .
```

Dev mode is loopback/LAN testing only — no TURN/TLS, well-known credentials.
Never expose it to the internet.
