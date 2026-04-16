#!/usr/bin/env python3
"""
Independent Python reference implementation of the fairness protocol,
used to generate docs/fairness-vectors.json.

Implements the spec from docs/fairness.md literally, with no dependency
on the Godot code. If Godot's game/fairness/seed.gd disagrees with the
vectors produced here, one of the two is wrong relative to the spec.

Run: python scripts/gen_fairness_vectors.py
"""

import hashlib
import json
import struct
from pathlib import Path


def hash_marble(server_seed: bytes, round_id: int, client_seed: str, marble_index: int) -> bytes:
    """SHA-256(server_seed || round_id u64 BE || client_seed UTF-8 || marble_index u32 BE).
    If client_seed is empty, no bytes are fed for it (matches Godot's skip-on-empty guard)."""
    h = hashlib.sha256()
    h.update(server_seed)
    h.update(struct.pack(">Q", round_id))
    cs = client_seed.encode("utf-8")
    if len(cs) > 0:
        h.update(cs)
    h.update(struct.pack(">I", marble_index))
    return h.digest()


def derive_spawn_slots(server_seed: bytes, round_id: int, client_seeds: list[str], slot_count: int) -> list[int]:
    """Assign each marble a slot in [0, slot_count). Linear-probe on collision.
    Marbles MUST be iterated in ascending marble_index — see fairness.md order invariant."""
    taken: set[int] = set()
    slots: list[int] = []
    for i, cs in enumerate(client_seeds):
        raw = hash_marble(server_seed, round_id, cs, i)
        slot = struct.unpack(">I", raw[0:4])[0] % slot_count
        while slot in taken:
            slot = (slot + 1) % slot_count
        taken.add(slot)
        slots.append(slot)
    return slots


def vector(name: str, description: str, server_seed_hex: str, round_id: int,
           client_seeds: list[str], slot_count: int) -> dict:
    server_seed = bytes.fromhex(server_seed_hex)
    assert len(server_seed) == 32, f"server_seed must be 32 bytes, got {len(server_seed)}"
    per_marble = []
    for i, cs in enumerate(client_seeds):
        h = hash_marble(server_seed, round_id, cs, i)
        # Color: R=h[4], G=h[5], B=h[6], A=0xFF, packed big-endian into u32.
        rgba_u32 = (h[4] << 24) | (h[5] << 16) | (h[6] << 8) | 0xFF
        per_marble.append({
            "marble_index": i,
            "client_seed": cs,
            "hash_marble_hex": h.hex(),
            "color_rgba_u32": rgba_u32,
            "color_rgba_hex": f"{rgba_u32:08x}",
        })
    slots = derive_spawn_slots(server_seed, round_id, client_seeds, slot_count)
    server_seed_hash = hashlib.sha256(server_seed).hexdigest()
    return {
        "name": name,
        "description": description,
        "inputs": {
            "server_seed_hex": server_seed_hex,
            "round_id": round_id,
            "client_seeds": client_seeds,
            "slot_count": slot_count,
        },
        "expected": {
            "server_seed_hash_hex": server_seed_hash,
            "per_marble_hashes": per_marble,
            "spawn_slots": slots,
        },
    }


def main() -> None:
    vectors = [
        vector(
            name="minimal_zero_seed",
            description="All-zero server_seed, round_id=1, three single-char client seeds. Sanity baseline — a Python/JS/Go port hashing this differently is off-spec.",
            server_seed_hex="00" * 32,
            round_id=1,
            client_seeds=["a", "b", "c"],
            slot_count=24,
        ),
        vector(
            name="empty_client_seeds",
            description="Empty client_seed on every marble exercises the zero-length-buffer guard in _hash_marble. Hash must equal SHA-256(server_seed || round_id_u64_be || marble_index_u32_be) with NO bytes written for the empty seed.",
            server_seed_hex="00" * 32,
            round_id=1,
            client_seeds=["", "", ""],
            slot_count=24,
        ),
        vector(
            name="forced_collision_small_slot_count",
            description="slot_count=4 with 4 marbles forces the linear-probe path at least once (pigeonhole unless every hash maps to a distinct slot). Catches order-invariant bugs and off-by-one probe errors.",
            server_seed_hex="00" * 32,
            round_id=1,
            client_seeds=["a", "b", "c", "d"],
            slot_count=4,
        ),
        vector(
            name="realistic_20_marbles",
            description="Full-size round: 20 marbles over 24 slots, non-zero server_seed, real-ish round_id. Mirrors production shape; a regression here means a production round would change.",
            server_seed_hex="deadbeefcafebabe0123456789abcdeffedcba9876543210112233445566778899"[:64],
            round_id=1_234_567,
            client_seeds=[f"player_{i:02d}" for i in range(20)],
            slot_count=24,
        ),
    ]
    out = {
        "protocol_version": 2,
        "spec": "docs/fairness.md",
        "reference_impl": "scripts/gen_fairness_vectors.py",
        "notes": [
            "hash_marble_hex is the 32-byte SHA-256 output, lowercase hex.",
            "server_seed_hash_hex is SHA-256(server_seed), the commit value.",
            "Byte order: round_id and marble_index are serialized BIG-endian into the hash. The replay FILE format is little-endian — see docs/tick-schema.md §Byte order.",
            "Marble order: entries in per_marble_hashes and spawn_slots are in ascending marble_index order. Linear probing requires this ordering — see fairness.md §Order invariant.",
            "Color: color_rgba_u32 = (h[4]<<24)|(h[5]<<16)|(h[6]<<8)|0xFF where h is the _hash_marble output. color_rgba_hex is the same value as 8-char lowercase hex. See fairness.md §Color derivation.",
        ],
        "vectors": vectors,
    }
    path = Path(__file__).resolve().parent.parent / "docs" / "fairness-vectors.json"
    path.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
