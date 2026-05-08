// Package casino serves the player-facing browser frontend.
//
// Architecture (M29+):
//
//	┌────────────────┐  raw frames  ┌─────────┐  H.264 RTP  ┌───────────────┐
//	│ Godot          │ ───────────▶ │ ffmpeg  │ ──────────▶ │ Pion SFU      │
//	│ (server-side   │              │ (encode │             │ (in rgsd)     │
//	│  3D render)    │              │  H.264) │             │               │
//	└────────────────┘              └─────────┘             └───────┬───────┘
//	                                                                │
//	         Per-frame metadata (HUD coords, minimap, names) ───────┤  WebRTC
//	         goes via SFU DataChannel, PTS-stamped                  │
//	                                                                ▼
//	                                                       ┌───────────────┐
//	                                                       │ Browser       │
//	                                                       │  <video>      │
//	                                                       │  + DOM labels │
//	                                                       │  + minimap    │
//	                                                       └───────────────┘
//
// One server-side render fanned out to N viewers via the SFU. Browser does
// no physics, no camera control, no rendering of the race itself — only
// the HUD overlay (DOM labels) and the minimap canvas, both driven by
// metadata streamed alongside the video on a WebRTC DataChannel.
//
// Anti-cheat: the only surface the client sees is encoded pixels + already-
// projected screen coordinates. There's no game state, no seed, no logic.
//
// Routes:
//
//	GET  /casino/                     — SPA HTML
//	GET  /casino/static/...           — JS / CSS
//	POST /casino/api/offer            — WebRTC SDP exchange (browser → server)
//	GET  /casino/api/health           — liveness
package casino

import (
	"embed"
	"io/fs"
)

//go:embed templates static
var embedded embed.FS

func embeddedFS() fs.FS { return embedded }
