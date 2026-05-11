// Marbles casino — Phase 1.0 client.
//
// Establishes a WebRTC peer connection with rgsd's Pion SFU:
//   1. createOffer (no media yet — we add a recv-only video transceiver
//      so the SFU's outbound video track has a slot to attach to).
//   2. POST /casino/api/offer with the SDP.
//   3. setRemoteDescription with the SDP answer.
//   4. The server-initiated DataChannel ("casino-meta") opens; we render
//      heartbeats from it as proof the metadata side-channel works.
//
// In Phase 1.1 the same code path will also receive an actual H.264 video
// track and pipe it into the <video> element. Nothing in this file needs
// to change for that — Pion handles ontrack on its own.

(() => {
  const dom = {
    rtcState:   document.getElementById("rtc-state"),
    iceState:   document.getElementById("ice-state"),
    dcState:    document.getElementById("dc-state"),
    hbSeq:      document.getElementById("hb-seq"),
    hbTime:     document.getElementById("hb-time"),
    hbSubs:     document.getElementById("hb-subs"),
    log:        document.getElementById("log"),
    connState:  document.getElementById("conn-state"),
    video:      document.getElementById("race-video"),
    overlay:    document.getElementById("video-overlay"),
    hudOverlay: document.getElementById("hud-overlay"),
    minimap:    document.getElementById("minimap"),
  };

  // Server frame size — matches rgsd's --casino-video-width/-height.
  // Used to map per-frame HUD coordinates from source pixels to the
  // rendered DOM size.
  const FRAME_W = 854;
  const FRAME_H = 480;

  // Per-marble state. Names arrives once at round start; hud arrives
  // every frame; minimap at 10 Hz.
  const marbleNames = new Map(); // id (number) → display name
  // The "your marble" highlight — for the standalone broadcast scene
  // there's no betting yet, but the wiring is here so Phase 5+ can flip it
  // by reading ?p=<id> from the URL.
  const myMarbleID = parseURLPlayerMarble();

  function parseURLPlayerMarble() {
    const p = new URLSearchParams(window.location.search).get("marble");
    if (p == null) return -1;
    const n = parseInt(p, 10);
    return Number.isFinite(n) ? n : -1;
  }

  function log(...args) {
    const ts = new Date().toISOString().slice(11, 23);
    const line = `[${ts}] ` + args.map(a => typeof a === "string" ? a : JSON.stringify(a)).join(" ");
    dom.log.textContent += line + "\n";
    dom.log.scrollTop = dom.log.scrollHeight;
    console.log(line);
  }

  function setConn(label) {
    dom.connState.className = `conn conn-${label}`;
    dom.connState.textContent = label;
  }

  async function start() {
    setConn("connecting");
    log("starting WebRTC handshake…");

    const pc = new RTCPeerConnection({});

    // Receive-only video transceiver so the answer SDP allocates a slot
    // for the SFU's outbound track (Phase 1.1+ when video is published).
    pc.addTransceiver("video", { direction: "recvonly" });

    pc.addEventListener("connectionstatechange", () => {
      dom.rtcState.textContent = pc.connectionState;
      log("pc.connectionState =", pc.connectionState);
      if (pc.connectionState === "connected") {
        setConn("connected");
      } else if (pc.connectionState === "failed" ||
                 pc.connectionState === "disconnected" ||
                 pc.connectionState === "closed") {
        setConn("idle");
      }
    });
    pc.addEventListener("iceconnectionstatechange", () => {
      dom.iceState.textContent = pc.iceConnectionState;
      log("pc.iceConnectionState =", pc.iceConnectionState);
    });
    pc.addEventListener("track", (ev) => {
      log("ontrack — kind:", ev.track.kind, " streams:", ev.streams.length);
      if (ev.streams[0]) {
        dom.video.srcObject = ev.streams[0];
        dom.overlay.classList.add("hidden");
      }
    });
    pc.addEventListener("datachannel", (ev) => {
      const dc = ev.channel;
      log("ondatachannel — label:", dc.label);
      dom.dcState.textContent = dc.readyState;
      dc.addEventListener("open",  () => { dom.dcState.textContent = "open";   log("dc open"); });
      dc.addEventListener("close", () => { dom.dcState.textContent = "closed"; log("dc closed"); });
      dc.addEventListener("error", (e) => log("dc error:", e?.message ?? e));
      dc.addEventListener("message", (msg) => {
        let m;
        try { m = JSON.parse(msg.data); } catch { log("dc <- (non-json)", msg.data); return; }
        switch (m.type) {
          case "heartbeat":
            dom.hbSeq.textContent  = m.seq;
            dom.hbTime.textContent = m.server_time;
            dom.hbSubs.textContent = m.subscribers;
            return;
          case "names":
            ingestNames(m.names || {});
            return;
          case "hud":
            renderHUD(m.marbles || []);
            return;
          case "minimap":
            renderMinimap(m.marbles || []);
            return;
        }
        log("dc <-", msg.data);
      });
    });

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    // Wait for ICE gathering so the offer carries every host candidate
    // inline; matches the server's gather-then-answer behavior.
    await new Promise((resolve) => {
      if (pc.iceGatheringState === "complete") return resolve();
      const onChange = () => {
        if (pc.iceGatheringState === "complete") {
          pc.removeEventListener("icegatheringstatechange", onChange);
          resolve();
        }
      };
      pc.addEventListener("icegatheringstatechange", onChange);
    });

    log("posting offer…");
    const resp = await fetch("/casino/api/offer", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sdp: pc.localDescription.sdp }),
    });
    if (!resp.ok) {
      const body = await resp.json().catch(() => ({}));
      log("offer failed:", body.error || resp.status);
      setConn("idle");
      return;
    }
    const answer = await resp.json();
    log("answer received — peer_id:", answer.peer_id);
    await pc.setRemoteDescription({ type: "answer", sdp: answer.sdp });
    log("remote description set; awaiting ICE…");
  }

  // ── HUD overlay (DOM labels positioned by per-frame metadata) ─────────

  // labelEls: marbleId (number) → HTMLDivElement, reused across frames so
  // the browser only does a transform/text update per frame instead of
  // tearing down + rebuilding the DOM every tick.
  const labelEls = new Map();

  function ingestNames(names) {
    for (const [k, v] of Object.entries(names)) {
      const id = parseInt(k, 10);
      if (Number.isFinite(id)) marbleNames.set(id, String(v));
    }
    log(`names: ${marbleNames.size} entries`);
  }

  function renderHUD(marbles) {
    // Map source-pixel coords (FRAME_W × FRAME_H) to the rendered video
    // pixel size; .video-wrap uses aspect-ratio so the video fills it
    // without letterboxing in the common 16:9 case.
    const vw = dom.video.clientWidth || dom.hudOverlay.clientWidth;
    const vh = dom.video.clientHeight || dom.hudOverlay.clientHeight;
    const sx = vw / FRAME_W;
    const sy = vh / FRAME_H;

    const seen = new Set();
    for (const m of marbles) {
      seen.add(m.id);
      let el = labelEls.get(m.id);
      if (el == null) {
        el = document.createElement("div");
        el.className = "hud-label";
        if (m.id === myMarbleID) el.classList.add("is-mine");
        dom.hudOverlay.appendChild(el);
        labelEls.set(m.id, el);
      }
      const name = marbleNames.get(m.id) || `#${m.id}`;
      if (el.textContent !== name) el.textContent = name;
      const px = m.x * sx;
      const py = m.y * sy;
      el.style.left = `${px}px`;
      el.style.top  = `${py}px`;
      el.classList.toggle("is-hidden", m.vis === false);
    }
    // Reap labels for marbles that vanished (round changed, etc.).
    for (const [id, el] of labelEls) {
      if (!seen.has(id)) {
        el.remove();
        labelEls.delete(id);
      }
    }
  }

  // ── Minimap (small canvas in the corner of the video) ─────────────────

  // World-space bounding box accumulator. We don't know the track's true
  // extent in advance, so we expand on the fly. Same shape the in-game
  // HUD uses for its standings widget.
  const mmBox = { minX: +Infinity, maxX: -Infinity, minZ: +Infinity, maxZ: -Infinity };

  function renderMinimap(marbles) {
    const ctx = dom.minimap.getContext("2d");
    const w = dom.minimap.width, h = dom.minimap.height;
    ctx.clearRect(0, 0, w, h);

    for (const m of marbles) {
      if (m.wx < mmBox.minX) mmBox.minX = m.wx;
      if (m.wx > mmBox.maxX) mmBox.maxX = m.wx;
      if (m.wz < mmBox.minZ) mmBox.minZ = m.wz;
      if (m.wz > mmBox.maxZ) mmBox.maxZ = m.wz;
    }
    let spanX = Math.max(mmBox.maxX - mmBox.minX, 4);
    let spanZ = Math.max(mmBox.maxZ - mmBox.minZ, 4);
    const pad = 0.08;
    const sx = (w * (1 - 2 * pad)) / spanX;
    const sz = (h * (1 - 2 * pad)) / spanZ;
    const s = Math.min(sx, sz);
    const offX = (w - spanX * s) / 2 - mmBox.minX * s;
    const offY = (h - spanZ * s) / 2 - mmBox.minZ * s;

    // Background pulse — tiny grid for spatial reference.
    ctx.strokeStyle = "rgba(255,255,255,0.06)";
    ctx.lineWidth = 1;
    for (let i = 0; i < 5; i++) {
      const x = (i / 4) * w;
      const y = (i / 4) * h;
      ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, h); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
    }

    for (const m of marbles) {
      const px = m.wx * s + offX;
      const py = m.wz * s + offY;
      const isMine = m.id === myMarbleID;
      ctx.beginPath();
      ctx.arc(px, py, isMine ? 5 : 3, 0, Math.PI * 2);
      ctx.fillStyle = isMine ? "#ffd84d" : "#60a5fa";
      ctx.fill();
      if (isMine) {
        ctx.strokeStyle = "#ffd84d";
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(px, py, 8, 0, Math.PI * 2);
        ctx.stroke();
      }
    }
  }

  // Once a track is received we can hide the "waiting" overlay early.
  // ontrack already does this; this fallback covers the case where the
  // browser autoplays before the track arrives (unlikely but cheap).
  document.addEventListener("DOMContentLoaded", () => {
    start().catch(err => {
      log("FATAL:", err.message || err);
      setConn("idle");
    });
  });
})();
