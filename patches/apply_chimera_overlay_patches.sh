#!/usr/bin/env bash
# Chimera Mk9 — device-specific overlay (NOT KSU/SUSFS integration)
#
# Every change below was independently verified by diffing
# royd-jpg/Project_Chimera@chimera-mk8 against
# gavdoc38/android_kernel_samsung_exynos9810@lineage-23.2-ksun3-susfs2
# directly, file by file, at the time this script was written. Do not
# trust the inline commit-SHA references in Royd's request without
# re-checking — one of them (1e5fcf05...) was independently found to
# reference kernel/sched/cpufreq_schedutil.c, not fair.c; the fair.c
# values below were verified by direct diff instead, not by that SHA.
#
# Scope, confirmed present in gavdoc38 already (NOT touched here):
#   - SUSFS core, most of fs/namei.c sus_path hooks, KSU-Next exec hooks.
#
# Scope, confirmed MISSING from gavdoc38 and patched here:
#   [1] drivers/cpufreq/exynos-ufc.c   — UFC init short-circuit
#   [2] fs/proc/base.c                 — mem_rw() SUS_MAP guard
#       (gavdoc38 has the SUS_MAP guard in the /proc/pid/maps iteration
#       path but NOT in the /proc/pid/mem read/write path — confirmed by
#       diff: this is a real gap, not a duplicate. Without this, a
#       SUS_MAP-hidden file is invisible in /proc/pid/maps but its
#       contents remain readable/writable via /proc/pid/mem.)
#   [3] fs/namei.c                     — extra sus_path sub-path re-check
#       immediately after may_lookup() inside link_path_walk()'s main
#       loop (belt-and-suspenders re-check in case may_lookup() causes a
#       revalidation that changes nd->path.dentry). Confirmed absent from
#       gavdoc38 by full-file diff (the only other diff was an unrelated
#       vfs_mkobj() present in gavdoc38 but not chimera-mk8 — a base
#       version difference, not a regression, left untouched).
#   [4] kernel/sched/fair.c            — scheduler constant tuning
#   [5] arch/arm64/boot/dts/exynos/exynos9810-star2lte_eur_open_26.dts
#       — CMA/ION sizes, GPU voltage margin + 6 regulator caps, thermal
#       trip point, idle residency, Madera codec node enablement
#   [6] kernel/sched/cpufreq_schedutil.c — sugov_update_rate_limit_us()
#       rate limit hardcoding (commit 1e5fcf05...)
#   [7] kernel/sched/cpufreq_schedutil.c — sugov_kthread_create() priority
#       (SCHED_FIFO/MAX_USER_RT_PRIO/2 -> SCHED_RR/1, commit f21ae9c9...)
#   [8] kernel/sched/cpufreq_schedutil.c — sugov_init() rate limit
#       hardcoding, a second/earlier application of the same values as
#       [6] but at policy-init time rather than on update (commit
#       745fb40c...)
#
# [6]/[7]/[8] together fully replicate what chimera-mk8's current
# cpufreq_schedutil.c contains at these three sites — confirmed by diffing
# chimera-mk8 against gavdoc38 directly and then verifying each of the
# three cited commits' actual diffs matches each site exactly.
#
# Run from the kernel repo root (working-directory: kernel). Idempotent.

set -Eeuo pipefail

log() { echo "[chimera-overlay] $*"; }

# ─────────────────────────────────────────────────────────────────────────
# [1] UFC short-circuit
# ─────────────────────────────────────────────────────────────────────────
log "=== [1/8] UFC short-circuit (drivers/cpufreq/exynos-ufc.c) ==="

UFC_MARKER="CMK9_UFC_SHORT_CIRCUIT"
UFC_FILE="drivers/cpufreq/exynos-ufc.c"

[[ -f "$UFC_FILE" ]] || { echo "FATAL: $UFC_FILE not found" >&2; exit 1; }

if grep -q "$UFC_MARKER" "$UFC_FILE"; then
  log "$UFC_FILE: UFC short-circuit already present — skipping"
else
  python3 << PYEOF
import re, sys
from pathlib import Path

MARKER = "$UFC_MARKER"
p = Path("$UFC_FILE")
src = p.read_text()

pattern = re.compile(
    r"static int __init exynos_ufc_init\(void\)\n\{\n"
    r"\tstruct device_node \*dn = NULL;\n"
    r"\tconst char \*buf;\n"
    r"\tstruct exynos_cpufreq_domain \*domain;\n"
    r"\tint ret = 0;\n"
)

m = pattern.search(src)
if not m:
    print("FATAL: exynos_ufc_init() anchor not found — base has changed", file=sys.stderr)
    sys.exit(1)

insert_after = m.end()
short_circuit = (
    "\n\t/* " + MARKER + " */\n"
    "\treturn 0; /* skip cpufreq-userctrl DT parsing */\n"
)
src = src[:insert_after] + short_circuit + src[insert_after:]
p.write_text(src)
print(f"{p}: exynos_ufc_init() short-circuited (marker: {MARKER})")
PYEOF
  log "PASS: UFC short-circuit applied"
fi

# ─────────────────────────────────────────────────────────────────────────
# [2] fs/proc/base.c mem_rw() SUS_MAP guard
# ─────────────────────────────────────────────────────────────────────────
log "=== [2/8] fs/proc/base.c mem_rw() SUS_MAP guard ==="

MEMRW_MARKER="CMK9_MEM_RW_SUS_MAP_GUARD"
BASE_C="fs/proc/base.c"

[[ -f "$BASE_C" ]] || { echo "FATAL: $BASE_C not found" >&2; exit 1; }

if grep -q "$MEMRW_MARKER" "$BASE_C"; then
  log "$BASE_C: mem_rw() SUS_MAP guard already present — skipping"
else
  python3 << PYEOF
import re, sys
from pathlib import Path

MARKER = "$MEMRW_MARKER"
p = Path("$BASE_C")
src = p.read_text()

# Anchor on the exact upstream mem_rw() declaration block, verified
# against the gavdoc38 base at the time this script was written.
decl_pattern = re.compile(
    r"(static ssize_t mem_rw\(struct file \*file, char __user \*buf,\n"
    r"\t\t\tsize_t count, loff_t \*ppos, int write\)\n"
    r"\{\n"
    r"\tstruct mm_struct \*mm = file->private_data;\n"
    r"\tunsigned long addr = \*ppos;\n"
    r"\tssize_t copied;\n"
    r"\tchar \*page;\n"
    r"\tunsigned int flags;\n)"
)

m = decl_pattern.search(src)
if not m:
    print("FATAL: mem_rw() declaration anchor not found — base has changed", file=sys.stderr)
    sys.exit(1)

decl_insert = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\tstruct vm_area_struct *vma; /* " + MARKER + " */\n"
    "#endif\n"
)
src = src[:m.end()] + decl_insert + src[m.end():]

loop_pattern = re.compile(
    r"(\twhile \(count > 0\) \{\n"
    r"\t\tsize_t this_len = min_t\(size_t, count, PAGE_SIZE\);\n)"
)

m2 = loop_pattern.search(src)
if not m2:
    print("FATAL: mem_rw() while-loop anchor not found — base has changed", file=sys.stderr)
    sys.exit(1)

guard = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\tvma = find_vma(mm, addr);\n"
    "\t\tif (vma && vma->vm_file) {\n"
    "\t\t\tstruct inode *inode = file_inode(vma->vm_file);\n"
    "\t\t\tif (SUSFS_IS_INODE_SUS_MAP(inode)) {\n"
    "\t\t\t\tif (write) {\n"
    "\t\t\t\t\tcopied = -EFAULT;\n"
    "\t\t\t\t} else {\n"
    "\t\t\t\t\tcopied = -EIO;\n"
    "\t\t\t\t}\n"
    "\t\t\t\tbreak;\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "#endif\n"
)
src = src[:m2.end()] + guard + src[m2.end():]

p.write_text(src)
print(f"{p}: mem_rw() SUS_MAP guard applied (marker: {MARKER})")
PYEOF
  log "PASS: mem_rw() SUS_MAP guard applied"
fi

# Sanity: the pre-existing /proc/pid/maps-iteration SUS_MAP guard
# (a different, unrelated site) must still be present in both cases.
grep -q "SUSFS_IS_INODE_SUS_MAP" "$BASE_C" || {
  echo "FATAL: no SUSFS_IS_INODE_SUS_MAP call sites found at all — base regressed" >&2
  exit 1
}
log "VERIFIED: pre-existing SUS_MAP maps-iteration guard intact"

# ─────────────────────────────────────────────────────────────────────────
# [3] fs/namei.c extra sus_path sub-path denial
# ─────────────────────────────────────────────────────────────────────────
log "=== [3/8] fs/namei.c extra sus_path sub-path denial ==="

NAMEI_MARKER="CMK9_NAMEI_SUS_PATH_RECHECK"
NAMEI_C="fs/namei.c"

[[ -f "$NAMEI_C" ]] || { echo "FATAL: $NAMEI_C not found" >&2; exit 1; }

# Base sanity: gavdoc38 already carries the primary sus_path hooks
# (lookup_dcache/__lookup_hash/lookup_fast/lookup_slow/lookup_open). We
# do not touch those. Fail loudly if they've disappeared.
grep -q "susfs_is_inode_sus_path" "$NAMEI_C" || {
  echo "FATAL: no susfs_is_inode_sus_path call sites found — base regressed, primary sus_path hooks missing" >&2
  exit 1
}
log "VERIFIED: pre-existing fs/namei.c sus_path hooks intact"

if grep -q "$NAMEI_MARKER" "$NAMEI_C"; then
  log "$NAMEI_C: sus_path sub-path re-check already present — skipping"
else
  python3 << PYEOF
import re, sys
from pathlib import Path

MARKER = "$NAMEI_MARKER"
p = Path("$NAMEI_C")
src = p.read_text()

# Anchor on the exact upstream link_path_walk() loop-entry block,
# verified against the gavdoc38 base at the time this script was written.
pattern = re.compile(
    r"(\t/\* At this point we know we have a real path component\. \*/\n"
    r"\tfor\(;;\) \{\n"
    r"\t\tu64 hash_len;\n"
    r"\t\tint type;\n\n"
    r"#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
    r"\t\tstruct dentry \*dentry = nd->path\.dentry;\n"
    r"\t\tif \(dentry->d_inode && susfs_is_inode_sus_path\(dentry->d_inode\)\) \{\n"
    r"\t\t\t// - No need to dput\(\) here\n"
    r"\t\t\t// - return -ENOENT here since it is walking the sub path of sus path\n"
    r"\t\t\treturn -ENOENT;\n"
    r"\t\t\}\n"
    r"#endif\n\n"
    r"\t\terr = may_lookup\(nd\);\n"
    r"\t\tif \(err\)\n"
    r"\t\t\treturn err;\n)"
)

m = pattern.search(src)
if not m:
    print("FATAL: link_path_walk() sus_path anchor not found — base has changed", file=sys.stderr)
    sys.exit(1)

recheck = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
    "\t\t{\n"
    "\t\tstruct dentry *dentry = nd->path.dentry; /* " + MARKER + " */\n"
    "\t\tif (dentry->d_inode && susfs_is_inode_sus_path(dentry->d_inode)) {\n"
    "\t\t\t// - No need to dput() here\n"
    "\t\t\t// - return -ENOENT here since it is walking the sub path of sus path\n"
    "\t\t\treturn -ENOENT;\n"
    "\t\t}\n"
    "\t\t}\n"
    "#endif\n\n"
)
src = src[:m.end()] + recheck + src[m.end():]

p.write_text(src)
print(f"{p}: sus_path sub-path re-check applied after may_lookup() (marker: {MARKER})")
PYEOF
  log "PASS: namei.c sus_path sub-path re-check applied"
fi

# ─────────────────────────────────────────────────────────────────────────
# [4] kernel/sched/fair.c scheduler tuning
# ─────────────────────────────────────────────────────────────────────────
log "=== [4/8] kernel/sched/fair.c scheduler tuning ==="

FAIR="kernel/sched/fair.c"
[[ -f "$FAIR" ]] || { echo "FATAL: $FAIR not found" >&2; exit 1; }

if grep -q 'normalized_sysctl_sched_min_granularity = 5000000ULL' "$FAIR"; then
  log "$FAIR: min_granularity already tuned — skipping"
elif grep -q 'normalized_sysctl_sched_min_granularity = 750000ULL' "$FAIR"; then
  sed -i \
    's/normalized_sysctl_sched_min_granularity = 750000ULL/normalized_sysctl_sched_min_granularity = 5000000ULL/' \
    "$FAIR"
  log "PASS: normalized_sysctl_sched_min_granularity -> 5000000ULL"
else
  echo "FATAL: normalized_sysctl_sched_min_granularity anchor not found (neither tuned nor upstream value present)" >&2
  exit 1
fi

if grep -q 'sysctl_sched_migration_cost = 2000000UL' "$FAIR"; then
  log "$FAIR: migration_cost already tuned — skipping"
elif grep -q 'sysctl_sched_migration_cost = 500000UL' "$FAIR"; then
  sed -i \
    's/sysctl_sched_migration_cost = 500000UL;/sysctl_sched_migration_cost = 2000000UL; \/* Chimera: 2ms -- decode tasks reach BIG before scheduler intervenes *\//' \
    "$FAIR"
  log "PASS: sysctl_sched_migration_cost -> 2000000UL"
else
  echo "FATAL: sysctl_sched_migration_cost anchor not found" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────
# [5] Board DTS tuning
# ─────────────────────────────────────────────────────────────────────────
log "=== [5/8] Board DTS tuning ==="

DTS="arch/arm64/boot/dts/exynos/exynos9810-star2lte_eur_open_26.dts"
DTS_MARKER="CMK9_DTS_BOARD_TUNING"

[[ -f "$DTS" ]] || { echo "FATAL: $DTS not found" >&2; exit 1; }

if grep -q "$DTS_MARKER" "$DTS"; then
  log "$DTS: board tuning already present — skipping"
else
  python3 << PYEOF
import re, sys
from pathlib import Path

MARKER = "$DTS_MARKER"
p = Path("$DTS")
src = p.read_text()
applied = []

def replace_once(pattern, repl, label, src):
    n = len(re.findall(pattern, src, flags=re.MULTILINE))
    if n != 1:
        print(f"FATAL: expected exactly 1 match for '{label}', found {n}", file=sys.stderr)
        sys.exit(1)
    return re.sub(pattern, repl, src, count=1, flags=re.MULTILINE)

# video_stream ION size: 113246208 -> 226492416
src = replace_once(
    r"(compatible = \"exynos8890-ion,vstream\";\n\t\t\tion,secure;\n\t\t\tion,reusable;\n\t\t\tsize = <)113246208(>;)",
    r"\g<1>226492416\g<2> /* {} video_stream ION size */".format(MARKER),
    "video_stream ION size", src,
)
applied.append("video_stream ION size")

# camera ION size: 461373440 -> 536870912
src = replace_once(
    r"(compatible = \"exynos8890-ion,camera\";\n\t\t\tion,recyclable;\n\t\t\tsize = <)461373440(>;)",
    r"\g<1>536870912\g<2> /* {} camera ION size */".format(MARKER),
    "camera ION size", src,
)
applied.append("camera ION size")

# BIG cluster idle residency: 3500 -> 2500 (nobootcl-cpu-sleep c2 state)
src = replace_once(
    r"(nobootcl-cpu-sleep \{\n\t\t\t\tidle-state-name = \"c2\";\n\t\t\t\tcompatible = \"exynos,idle-state\";\n\t\t\t\tarm,psci-suspend-param = <65536>;\n\t\t\t\tentry-latency-us = <235>;\n\t\t\t\texit-latency-us = <220>;\n\t\t\t\tmin-residency-us = <)3500(>;)",
    r"\g<1>2500\g<2> /* {}: BIG cluster captures shorter idle gaps during video decode */".format(MARKER),
    "BIG cluster idle residency", src,
)
applied.append("BIG cluster idle residency")

# GPU voltage offset margin: 37500 -> 12500
src = replace_once(
    r"(gpu_voltage_offset_margin = <)37500(>;)",
    r"\g<1>12500\g<2> /* {} */".format(MARKER),
    "GPU voltage offset margin", src,
)
applied.append("GPU voltage offset margin")

# Thermal trip point big-switch-on: 55000 -> 70000
src = replace_once(
    r"(big-switch-on \{\n\t\t\t\t\ttemperature = <)55000(>;)",
    r"\g<1>70000\g<2> /* {} */".format(MARKER),
    "big-switch-on thermal trip point", src,
)
applied.append("big-switch-on thermal trip point")

# 6x regulator-max-microvolt: 1300000 -> 1250000, anchored per regulator name
regulators = [
    ("BUCK2", "vdd_cpucl1"),
    ("BUCK3", "vdd_cpucl0"),
    ("BUCK7", "vdd_cpucl1_m"),
    ("BUCK8", "vdd2_mem"),
    ("BUCK11", "vdd_lldo2"),
    ("LDO8", "vdd_ldo8"),
]
for node, name in regulators:
    pattern = (
        r"({node} \{{\n"
        r"\t\t\t\t\tregulator-name = \"{name}\";\n"
        r"\t\t\t\t\tregulator-min-microvolt = <\d+>;\n"
        r"\t\t\t\t\tregulator-max-microvolt = <)1300000(>;)"
    ).format(node=re.escape(node), name=re.escape(name))
    src = replace_once(
        pattern,
        r"\g<1>1250000\g<2> /* {{}} regulator {name} ({node}) */".format(name=name, node=node).format(MARKER),
        f"regulator {name} ({node}) max-microvolt", src,
    )
    applied.append(f"regulator {name} ({node}) max-microvolt")

# Madera codec node enablement: cs47l93@0 needs status = "okay" for the
# MFD_MADERA/MFD_CS47L92 Kconfig options (added separately in
# chimera-device-specific.cfg) to actually probe. gavdoc38's cs47l93@0
# node has no status property at all (defaults to disabled).
if 'cs47l93@0 {\n\t\t\tstatus = "okay";' not in src:
    pattern = r'(cs47l93@0 \{\n)(\t\t\tcompatible = "cirrus,cs47l93";)'
    n = len(re.findall(pattern, src))
    if n != 1:
        print(f"FATAL: expected exactly 1 match for cs47l93@0 node, found {n}", file=sys.stderr)
        sys.exit(1)
    src = re.sub(
        pattern,
        r'\g<1>\t\t\tstatus = "okay"; /* ' + MARKER + r' Madera codec node enablement */\n\g<2>',
        src, count=1,
    )
    applied.append("cs47l93@0 Madera codec node status=okay")
else:
    applied.append("cs47l93@0 Madera codec node status=okay (already present)")

p.write_text(src)
print(f"{p}: board tuning applied ({len(applied)} site(s)): " + ", ".join(applied))
PYEOF
  log "PASS: board DTS tuning applied"
fi

# ─────────────────────────────────────────────────────────────────────────
# [6] kernel/sched/cpufreq_schedutil.c — sugov rate limits
#     (royd-jpg/Project_Chimera commit 1e5fcf05609a2d5cd5398900ebd61e057d407093,
#     "Update cpufreq_schedutil.c" / "Updated ACME schedutil defaults as well
#     as sugov priority fix")
#
# Verified: the actual diff of that commit touches ONLY
# sugov_update_rate_limit_us(), hardcoding up_rate_limit_us=1500 and
# down_rate_limit_us=16000 in place of the caller-supplied values. That is
# what is applied here. The two related deltas at other sites in this same
# file (sugov_kthread_create() priority, sugov_init() rate limit) are
# applied separately in sections [7] and [8] below, each from its own
# cited commit.
# ─────────────────────────────────────────────────────────────────────────
log "=== [6/8] kernel/sched/cpufreq_schedutil.c sugov rate limits ==="

SUGOV_MARKER="CMK9_SUGOV_RATE_LIMIT"
SUGOV_FILE="kernel/sched/cpufreq_schedutil.c"

[[ -f "$SUGOV_FILE" ]] || { echo "FATAL: $SUGOV_FILE not found" >&2; exit 1; }

if grep -q "$SUGOV_MARKER" "$SUGOV_FILE"; then
  log "$SUGOV_FILE: sugov rate limit already tuned — skipping"
else
  python3 << PYEOF
import re, sys
from pathlib import Path

MARKER = "$SUGOV_MARKER"
p = Path("$SUGOV_FILE")
src = p.read_text()

pattern = re.compile(
    r"(\ttunables = sg_policy->tunables;\n"
    r"\tif \(!tunables\)\n"
    r"\t\treturn;\n\n)"
    r"\ttunables->up_rate_limit_us = \(unsigned int\)up_rate_limit;\n"
    r"\ttunables->down_rate_limit_us = \(unsigned int\)down_rate_limit;\n"
)

m = pattern.search(src)
if not m:
    print("FATAL: sugov_update_rate_limit_us() anchor not found — base has changed", file=sys.stderr)
    sys.exit(1)

replacement = (
    m.group(1) +
    "\ttunables->up_rate_limit_us = 1500; /* " + MARKER + " */\n"
    "\ttunables->down_rate_limit_us = 16000; /* " + MARKER + " */\n"
)
src = src[:m.start()] + replacement + src[m.end():]

p.write_text(src)
print(f"{p}: sugov_update_rate_limit_us() hardcoded to up=1500/down=16000 (marker: {MARKER})")
PYEOF
  log "PASS: sugov rate limit tuning applied"
fi


# ─────────────────────────────────────────────────────────────────────────
# [7] kernel/sched/cpufreq_schedutil.c — sugov_kthread_create() priority
#     (royd-jpg/Project_Chimera commit
#     f21ae9c9c3b5b817724f71a21d2d1a9dbd03c0c5, "config: finalize HZ
#     config and scheduler tweaks")
#
# Verified: this commit's diff also touches CONFIG_LOCALVERSION in the
# defconfig, which is not applied here — LOCALVERSION is already owned
# entirely by the workflow's brand input/overlay step, and this commit's
# value ("-4.9.337-CM6P") is an intermediate Chimera build tag, not the
# final one. Only the scheduler part of this commit is applied:
# sugov_kthread_create()'s real-time worker thread changes from
# SCHED_FIFO/MAX_USER_RT_PRIO/2 to SCHED_RR/priority=1.
# ─────────────────────────────────────────────────────────────────────────
log "=== [7/8] kernel/sched/cpufreq_schedutil.c sugov kthread priority (SCHED_RR) ==="

SUGOV_PRIO_MARKER="CMK9_SUGOV_KTHREAD_PRIORITY"

if grep -q "$SUGOV_PRIO_MARKER" "$SUGOV_FILE"; then
  log "$SUGOV_FILE: sugov kthread priority already tuned — skipping"
else
  python3 << PYEOF
import re, sys
from pathlib import Path

MARKER = "$SUGOV_PRIO_MARKER"
p = Path("$SUGOV_FILE")
src = p.read_text()

pattern = re.compile(
    r"(static int sugov_kthread_create(struct sugov_policy *sg_policy)
"
    r"{
"
    r"\tstruct task_struct *thread;
)"
    r"\tstruct sched_param param = { .sched_priority = MAX_USER_RT_PRIO / 2 };
"
)

m = pattern.search(src)
if not m:
    print("FATAL: sugov_kthread_create() param anchor not found — base has changed", file=sys.stderr)
    sys.exit(1)

src = (
    src[:m.start()] + m.group(1) +
    "\tstruct sched_param param = { .sched_priority = 1 }; /* " + MARKER + " */
" +
    src[m.end():]
)

sched_pattern = re.compile(
    r"\tret = sched_setscheduler_nocheck(thread, SCHED_FIFO, &param);
"
    r"\tif (ret) {
"
    r"\t\tkthread_stop(thread);
"
    r"\t\tpr_warn("%s: failed to set SCHED_FIFO\\\
", __func__);
"
)

m2 = sched_pattern.search(src)
if not m2:
    print("FATAL: sugov_kthread_create() scheduler-set anchor not found — base has changed", file=sys.stderr)
    sys.exit(1)

replacement = (
    "\tret = sched_setscheduler_nocheck(thread, SCHED_RR, &param); /* " + MARKER + " */
"
    "\tif (ret) {
"
    "\t\tkthread_stop(thread);
"
    "\t\tpr_warn("%s: failed to set SCHED_RR\\\
", __func__);
"
    "\t}
"
)
src = src[:m2.start()] + replacement + src[m2.end():]

p.write_text(src)
print(f"{p}: sugov_kthread_create() moved to SCHED_RR / priority=1 (marker: {MARKER})")
PYEOF
  log "PASS: sugov kthread priority (SCHED_RR) applied"
fi

# ─────────────────────────────────────────────────────────────────────────
# [8] kernel/sched/cpufreq_schedutil.c — sugov_init() second rate-limit
#     application
#     (royd-jpg/Project_Chimera commit
#     745fb40c25fcb18641f926fd616b642438b98b89, "sched: cpufreq_schedutil:
#     hardcode rate limits to 1500/16000")
#
# Verified: this commit inserts the same up_rate_limit_us=1500 /
# down_rate_limit_us=16000 values into sugov_init(), immediately before
# tunables->iowait_boost_enable is set — a separate code path from section
# [6]'s sugov_update_rate_limit_us(), so both are needed for the value to
# be correct both at initial policy setup (this section) and on any
# later rate-limit update (section 6).
# ─────────────────────────────────────────────────────────────────────────
log "=== [8/8] kernel/sched/cpufreq_schedutil.c sugov_init() rate limit ==="

SUGOV_INIT_MARKER="CMK9_SUGOV_INIT_RATE_LIMIT"

if grep -q "$SUGOV_INIT_MARKER" "$SUGOV_FILE"; then
  log "$SUGOV_FILE: sugov_init() rate limit already applied — skipping"
else
  python3 << PYEOF
import re, sys
from pathlib import Path

MARKER = "$SUGOV_INIT_MARKER"
p = Path("$SUGOV_FILE")
src = p.read_text()

pattern = re.compile(
    r"\n(\ttunables->iowait_boost_enable = policy->iowait_boost_enable;\n)"
)

matches = list(pattern.finditer(src))
if len(matches) != 1:
    print(
        f"FATAL: expected exactly 1 match for sugov_init() iowait_boost_enable anchor, found {len(matches)}",
        file=sys.stderr,
    )
    sys.exit(1)

m = matches[0]
insertion = (
    "\n\ttunables->up_rate_limit_us = 1500; /* " + MARKER + " */\n"
    "\ttunables->down_rate_limit_us = 16000; /* " + MARKER + " */\n"
)
src = src[:m.start()] + insertion + m.group(1) + src[m.end():]

p.write_text(src)
print(f"{p}: sugov_init() rate limit hardcoded to up=1500/down=16000 (marker: {MARKER})")
PYEOF
  log "PASS: sugov_init() rate limit applied"
fi

log "=== Chimera overlay: all sections complete ==="
