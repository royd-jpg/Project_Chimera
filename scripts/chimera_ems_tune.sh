#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════════
# 99chimera_ems.sh — EMS Runtime Tuning (Project Chimera)
# Exynos Mobile Scheduler configuration for Exynos 9810 (star2lte)
#
# What EMS is:
#   Samsung's proprietary scheduler layer on top of Linux CFS. It controls
#   how tasks are placed between the LITTLE cluster (A55, efficient) and the
#   BIG cluster (M3, fast). The key tunable is light_task_threshold — a
#   utilisation value on the 0–1024 PELT scale. Tasks with util BELOW the
#   threshold are considered "light" and prefer the LITTLE cluster.
#
# Why the original script (threshold=40) caused heat:
#   40/1024 = 3.9% utilisation. Only tasks using under 3.9% CPU stayed on
#   LITTLE. Everything else went to BIG — even lightly-loaded background
#   services. This is "performance mode" and is why the device felt hot.
#
# This script uses threshold=512 (50% utilisation). Tasks under 50% load
#   stay on LITTLE. Only genuinely heavy tasks (video decode, gaming, camera)
#   get BIG cores. This matches stock Samsung firmware tuning.
# ═══════════════════════════════════════════════════════════════════════════════

# ── EMS node paths ─────────────────────────────────────────────────────────────
# EMS nodes live under /sys/kernel/ems/ — do NOT scan all of /sys/ (too slow).
EMS_ROOT="/sys/kernel/ems"

# The balanced threshold: 512 = 50% utilisation.
# Tasks with util < 512 prefer LITTLE cluster.
# Tasks with util ≥ 512 use BIG cluster.
LIGHT_TASK_THRESHOLD=512

# The suspend threshold can be tighter (more tasks on LITTLE when screen off).
LIGHT_TASK_THRESHOLD_SLEEP=700

# ── Apply ──────────────────────────────────────────────────────────────────────
if [ ! -d "$EMS_ROOT" ]; then
    echo "[EMS] $EMS_ROOT not found — EMS not exposed on this kernel."
    echo "[EMS] Relying on CFS + schedutil defaults (Brain Core handles these)."
    exit 0
fi

APPLIED=0

# Active threshold (screen on)
for node in "$EMS_ROOT"/light_task_threshold \
            "$EMS_ROOT"/domain*/light_task_threshold \
            "$EMS_ROOT"/ontime/light_task_threshold; do
    [ -f "$node" ] || continue
    echo "$LIGHT_TASK_THRESHOLD" > "$node" 2>/dev/null && {
        echo "[EMS] light_task_threshold = $LIGHT_TASK_THRESHOLD → $node"
        APPLIED=$((APPLIED + 1))
    }
done

# Suspend threshold (screen off — tighter, keep more tasks on LITTLE)
for node in "$EMS_ROOT"/light_task_threshold_s \
            "$EMS_ROOT"/domain*/light_task_threshold_s; do
    [ -f "$node" ] || continue
    echo "$LIGHT_TASK_THRESHOLD_SLEEP" > "$node" 2>/dev/null && {
        echo "[EMS] light_task_threshold_s = $LIGHT_TASK_THRESHOLD_SLEEP → $node"
        APPLIED=$((APPLIED + 1))
    }
done

# Ontime threshold — tasks that spent recent time on BIG cluster stay there
# rather than being migrated back to LITTLE mid-burst. 500 = stay on BIG
# until util drops below ~49%. Prevents rapid cluster ping-pong.
for node in "$EMS_ROOT"/ontime/up_threshold \
            "$EMS_ROOT"/ontime/threshold; do
    [ -f "$node" ] || continue
    echo "500" > "$node" 2>/dev/null && {
        echo "[EMS] ontime threshold = 500 → $node"
        APPLIED=$((APPLIED + 1))
    }
done

# ── Report ─────────────────────────────────────────────────────────────────────
if [ "$APPLIED" -gt 0 ]; then
    echo "[EMS] Applied $APPLIED nodes. Profile: balanced (50% LITTLE threshold)."
    echo "[EMS] Result: background tasks on LITTLE, media/UI on BIG when needed."
else
    echo "[EMS] No writable EMS nodes found under $EMS_ROOT."
    echo "[EMS] Kernel may not expose EMS sysfs — this is OK, CFS will handle scheduling."
fi
