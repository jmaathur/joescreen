module joescreen/token-server

go 1.22

// Provides the auth package used to mint LiveKit access-token JWTs.
// Run `go mod tidy` once to resolve transitive deps and create go.sum.
require github.com/livekit/protocol v1.27.1
