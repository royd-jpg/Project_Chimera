#!/usr/bin/env bash
# Chimera Mk9 — device-specific overlay (NOT KSU/SUSFS integration)
#
# Scope: this script patches exactly what is genuinely Chimera-specific and
# is NOT already present in the gavdoc38 lineage-23.2-ksun3-susfs2 base.
# Verified by diffing royd-jpg/Project_Chimera@chimera-mk8 against
# gavdoc38/android_kernel_samsung_exynos9810@lineage-23.2-ksun3-susfs2
# directly (not assumed):
#
#   - SUSFS core, fs/namei.c sus_path hooks, fs/proc/base.c SUS_MAP guard,
#     and KSU-Next exec hooks are ALL already present in the gavdoc38 base.
#     They are NOT reproduced here — doing so would re-patch files that
#     already have this logic and either no-op destructively or duplicate
#     symbols. Do not add them back without re-verifying the base has
#     regressed.
#
#   - drivers/cpufreq/exynos-ufc.c: Chimera short-circuits exynos_ufc_init()
#     to skip the cpufreq-userctrl devicetree parsing loop entirely. This IS
#     Chimera-specific and is NOT in the gavdoc38 base. Patched below.
#
#   - Kconfig deltas (Madera/CS47L92 codec, CONFIG_HZ_300 override, TCP BBR,
#     Knox/DEFEX/TIMA off, debug stripping) are Chimera-specific and are
#     handled as a Kconfig fragment (chimera-device-specific.cfg) merged in
#     the same workflow step as chimera-ksu-susfs.cfg — NOT via sed against
#     the defconfig text here, to avoid ordering conflicts with the
#     LOCALVERSION/HOSTNAME sed already performed by the workflow's overlay
#     step.
#
# Run from the kernel repo root (working-directory: kernel). Idempotent.

set -Eeuo pipefail

MARKER="CMK9_UFC_SHORT_CIRCUIT"
FILE="drivers/cpufreq/exynos-ufc.c"

log() { echo "[chimera-overlay] $*"; }

[[ -f "$FILE" ]] || {
  echo "FATAL: $FILE not found — base tree layout may have changed" >&2
  exit 1
}

if grep -q "$MARKER" "$FILE"; then
  log "$FILE: UFC short-circuit already present — skipping"
  exit 0
fi

python3 << PYEOF
import re
import sys
from pathlib import Path

MARKER = "$MARKER"
p = Path("$FILE")
src = p.read_text()

# Anchor on the exact upstream function signature + body opening, verified
# against the gavdoc38 base source at the time this script was written.
# If this anchor is missing, the base has changed and the patch must be
# re-derived rather than force-applied.
pattern = re.compile(
    r"static int __init exynos_ufc_init\(void\)\n\{\n"
    r"\tstruct device_node \*dn = NULL;\n"
    r"\tconst char \*buf;\n"
    r"\tstruct exynos_cpufreq_domain \*domain;\n"
    r"\tint ret = 0;\n"
)

m = pattern.search(src)
if not m:
    print("FATAL: exynos_ufc_init() anchor not found — base has changed, "
          "re-derive this patch before applying", file=sys.stderr)
    sys.exit(1)

# Insert the short-circuit immediately after the top-of-function
# declarations (avoids declaration-after-statement warnings under -Werror).
# Everything after the return is left in place but becomes unreachable,
# which is intentional and matches the verified Chimera Mk8 behavior.
insert_after = m.end()
short_circuit = (
    "\n\t/* " + MARKER + " */\n"
    "\treturn 0; /* skip cpufreq-userctrl DT parsing */\n"
)

src = src[:insert_after] + short_circuit + src[insert_after:]
p.write_text(src)
print(f"{p}: exynos_ufc_init() short-circuited (marker: {MARKER})")
PYEOF

log "PASS: Chimera device-specific overlay applied"
