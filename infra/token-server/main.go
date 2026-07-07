// JoeScreen token server.
//
// SECURITY (RISKS.md R3): the LiveKit API secret lives ONLY in this process,
// server-side. It must NEVER be embedded in the Mac/iOS app binaries. Clients
// call GET /token?room=<r>&identity=<participant-uuid> and receive a
// short-lived (~1h), room-scoped JWT plus the SFU URL to dial. The identity
// is the app's Participant UUID, so tokens are keyed to a single participant.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/livekit/protocol/auth"
)

func main() {
	apiKey := mustEnv("LIVEKIT_API_KEY")
	apiSecret := mustEnv("LIVEKIT_API_SECRET")
	lkURL := mustEnv("LIVEKIT_URL") // e.g. wss://sfu.example.com

	http.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		room := r.URL.Query().Get("room")
		identity := r.URL.Query().Get("identity") // Participant UUID from the app
		if room == "" || identity == "" {
			http.Error(w, "missing required query params: room, identity", http.StatusBadRequest)
			return
		}

		// Room-scoped grant: this token admits exactly one identity into
		// exactly one room — nothing else (no admin, no other rooms).
		grant := &auth.VideoGrant{
			RoomJoin: true,
			Room:     room,
		}
		at := auth.NewAccessToken(apiKey, apiSecret).
			SetVideoGrant(grant).
			SetIdentity(identity).
			SetValidFor(time.Hour) // short-lived: expires ~1h after mint

		token, err := at.ToJWT()
		if err != nil {
			log.Printf("token signing failed: %v", err)
			http.Error(w, "failed to sign token", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"token": token,
			"url":   lkURL,
		})
	})

	log.Println("joescreen token server listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}

// mustEnv exits at startup if a required variable is unset — fail fast rather
// than minting broken tokens at request time.
func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("required environment variable %s is not set", key)
	}
	return v
}
