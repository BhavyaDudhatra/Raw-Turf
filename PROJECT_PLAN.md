# Meridian Bay — Open-World Action-Adventure (Planning Document)
Status: Phase 0 — Planning / awaiting approval. No implementation started.
Engine recommendation: Godot 4.x (GDScript). See full report in chat.
Target hardware: Lenovo i7-8850H / 16GB / Quadro P1000 4GB.
Project dir: B:\Study\Projects\VibeCoding\GTA (empty at Phase 0 inspection, 2026-10-14).

## Locked decisions (pending approval)
1. Engine: Godot 4.x — needs approval before install (install to B:, NOT C:).
2. Art direction: stylized low-poly (not photorealistic) — fits hardware.
3. Vertical slice: 1 city block (~256×256m), on-foot + 1 car + 1 mission + HUD + save/load.

## Roadmap summary
- Phase 0: Planning (this report) — DONE pending review.
- Phase 1: Playable vertical slice (weeks 1–4).
- Phase 2: NPCs + traffic.
- Phase 3: Combat + wanted/police.
- Phase 4: Missions + side activities.
- Phase 5: Audio/weather/day-night/polish.
- Phase 6: Generative-AI extras + expansion.

## Risks
- C: drive only ~2.1GB free — never install engine/project caches there.
- Quadro P1000 4GB cannot do UE5-class photorealism — stylized direction required.
- Scope creep — vertical slice is deliberately small; do not expand until it passes acceptance.

## Next actions (require approval first)
1. Approve engine + art style + slice scope.
2. Free/confirm space on B: (46.8GB free verified).
3. Install Godot 4.x to B: + init git + LFS.
4. Scaffold project directory structure (see full report §G).
5. Begin Phase 1 task 1: third-person controller + test block.
