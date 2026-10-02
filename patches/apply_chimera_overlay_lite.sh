#!/usr/bin/env bash
# Chimera Mk9 — LITE overlay profile (subset of apply_chimera_overlay_patches.sh)
#
# Applies ONLY:
#   [1] drivers/cpufreq/exynos-ufc.c            CMK9_UFC_SHORT_CIRCUIT
#   [2] fs/proc/base.c                          CMK9_MEM_RW_SUS_MAP_GUARD
#   [3] fs/namei.c                              CMK9_NAMEI_SUS_PATH_RECHECK
#   [4] kernel/sched/fair.c                     min_granularity = 5000000ULL, migration_cost = 2000000UL
#   [5] kernel/sched/cpufreq_schedutil.c        CMK9_SUGOV_RATE_LIMIT
#   [6] kernel/sched/cpufreq_schedutil.c        CMK9_SUGOV_KTHREAD_PRIORITY
#   [7] kernel/sched/cpufreq_schedutil.c        CMK9_SUGOV_INIT_RATE_LIMIT
#
# Deliberately NOT applied (present in the full script): board DTS tuning
# (CMK9_DTS_BOARD_TUNING) and the madera-core settle-delay patch.
#
# Patch bodies and anchors are copied verbatim from apply_chimera_overlay_patches.sh.
# Only the plumbing differs: every heredoc is quoted ('PYEOF') and receives its
# marker/file via exported environment variables (no bash expansion of the body).
#
# Run from the kernel repo root. Idempotent: marker present => no-op.

set -Eeuo pipefail

log()   { echo "[chimera-overlay-lite] $*"; }
fatal() { echo "FATAL: $*" >&2; exit 1; }

[[ -f Makefile && -d kernel/sched ]] || fatal "not at a kernel tree root (cwd=$PWD)"

# ─────────────────────────────────────────────────────────────────────────
# [1] UFC short-circuit
# ─────────────────────────────────────────────────────────────────────────
log "=== [1/7] UFC short-circuit (drivers/cpufreq/exynos-ufc.c) ==="
export UFC_MARKER="CMK9_UFC_SHORT_CIRCUIT"
export UFC_FILE="drivers/cpufreq/exynos-ufc.c"

[[ -f "$UFC_FILE" ]] || fatal "$UFC_FILE not found"

if grep -q "$UFC_MARKER" "$UFC_FILE"; then
  log "$UFC_FILE: UFC short-circuit already present — skipping"
else
  python3 << 'PYEOF'

import os, re, sys
from pathlib import Path

MARKER = os.environ["UFC_MARKER"]
p = Path(os.environ["UFC_FILE"])
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
log "=== [2/7] fs/proc/base.c mem_rw() SUS_MAP guard ==="
export MEMRW_MARKER="CMK9_MEM_RW_SUS_MAP_GUARD"
export BASE_C="fs/proc/base.c"

[[ -f "$BASE_C" ]] || fatal "$BASE_C not found"

if grep -q "$MEMRW_MARKER" "$BASE_C"; then
  log "$BASE_C: mem_rw() SUS_MAP guard already present — skipping"
else
  python3 << 'PYEOF'

import os, re, sys
from pathlib import Path

MARKER = os.environ["MEMRW_MARKER"]
p = Path(os.environ["BASE_C"])
src = p.read_text()

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

grep -q "SUSFS_IS_INODE_SUS_MAP" "$BASE_C" || \
  fatal "no SUSFS_IS_INODE_SUS_MAP call sites found at all — base regressed"
log "VERIFIED: SUS_MAP guard present in $BASE_C"

# ─────────────────────────────────────────────────────────────────────────
# [3] fs/namei.c extra sus_path sub-path denial
# ─────────────────────────────────────────────────────────────────────────
log "=== [3/7] fs/namei.c extra sus_path sub-path denial ==="
export NAMEI_MARKER="CMK9_NAMEI_SUS_PATH_RECHECK"
export NAMEI_C="fs/namei.c"

[[ -f "$NAMEI_C" ]] || fatal "$NAMEI_C not found"

grep -q "susfs_is_inode_sus_path" "$NAMEI_C" || \
  fatal "no susfs_is_inode_sus_path call sites found — base regressed, primary sus_path hooks missing"
log "VERIFIED: pre-existing fs/namei.c sus_path hooks intact"

if grep -q "$NAMEI_MARKER" "$NAMEI_C"; then
  log "$NAMEI_C: sus_path sub-path re-check already present — skipping"
else
  python3 << 'PYEOF'

import os, re, sys
from pathlib import Path

MARKER = os.environ["NAMEI_MARKER"]
p = Path(os.environ["NAMEI_C"])
src = p.read_text()

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
# [4] kernel/sched/fair.c scheduler tuning (same sed edits as the full script)
#     Idempotent: already tuned => skip; upstream value => sed; else FATAL.
# ─────────────────────────────────────────────────────────────────────────
log "=== [4/7] kernel/sched/fair.c scheduler tuning ==="
FAIR="kernel/sched/fair.c"
[[ -f "$FAIR" ]] || fatal "$FAIR not found"

if grep -q 'normalized_sysctl_sched_min_granularity = 5000000ULL' "$FAIR"; then
  log "$FAIR: min_granularity already tuned — skipping"
elif grep -q 'normalized_sysctl_sched_min_granularity = 750000ULL' "$FAIR"; then
  sed -i \
    's/normalized_sysctl_sched_min_granularity = 750000ULL/normalized_sysctl_sched_min_granularity = 5000000ULL/' \
    "$FAIR"
  log "PASS: normalized_sysctl_sched_min_granularity -> 5000000ULL"
else
  fatal "normalized_sysctl_sched_min_granularity anchor not found in $FAIR (neither tuned nor upstream 750000ULL present)"
fi

if grep -q 'sysctl_sched_migration_cost = 2000000UL' "$FAIR"; then
  log "$FAIR: migration_cost already tuned — skipping"
elif grep -q 'sysctl_sched_migration_cost = 500000UL' "$FAIR"; then
  sed -i \
    's/sysctl_sched_migration_cost = 500000UL;/sysctl_sched_migration_cost = 2000000UL; \/* Chimera: 2ms -- decode tasks reach BIG before scheduler intervenes *\//' \
    "$FAIR"
  log "PASS: sysctl_sched_migration_cost -> 2000000UL"
else
  fatal "sysctl_sched_migration_cost anchor not found in $FAIR (neither tuned nor upstream 500000UL present)"
fi

grep -q 'normalized_sysctl_sched_min_granularity = 5000000ULL' "$FAIR" || fatal "fair.c min_granularity check failed after patch"
grep -q 'sysctl_sched_migration_cost = 2000000UL' "$FAIR"              || fatal "fair.c migration_cost check failed after patch"

# ─────────────────────────────────────────────────────────────────────────
# [5] kernel/sched/cpufreq_schedutil.c — sugov_update_rate_limit_us()
# ─────────────────────────────────────────────────────────────────────────
log "=== [5/7] kernel/sched/cpufreq_schedutil.c sugov rate limits ==="
export SUGOV_MARKER="CMK9_SUGOV_RATE_LIMIT"
export SUGOV_FILE="kernel/sched/cpufreq_schedutil.c"

[[ -f "$SUGOV_FILE" ]] || fatal "$SUGOV_FILE not found"

if grep -q "$SUGOV_MARKER" "$SUGOV_FILE"; then
  log "$SUGOV_FILE: sugov rate limit already tuned — skipping"
else
  python3 << 'PYEOF'

import re, sys, os
from pathlib import Path

MARKER = os.environ["SUGOV_MARKER"]
p = Path(os.environ["SUGOV_FILE"])
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
# [6] kernel/sched/cpufreq_schedutil.c — sugov_kthread_create() SCHED_RR prio
# ─────────────────────────────────────────────────────────────────────────
log "=== [6/7] kernel/sched/cpufreq_schedutil.c sugov kthread priority (SCHED_RR) ==="
export SUGOV_PRIO_MARKER="CMK9_SUGOV_KTHREAD_PRIORITY"

if grep -q "$SUGOV_PRIO_MARKER" "$SUGOV_FILE"; then
  log "$SUGOV_FILE: sugov kthread priority already tuned — skipping"
else
  python3 << 'PYEOF'

import re, sys, os
from pathlib import Path

MARKER = os.environ["SUGOV_PRIO_MARKER"]
p = Path(os.environ["SUGOV_FILE"])
src = p.read_text()

# Match the ENTIRE function body from its signature through the closing
# brace, using a balanced-brace-free approach: this function's body
# contains no nested braces of its own other than the single
# `if (IS_ERR(thread)) { ... }` and `if (ret) { ... }` blocks, both of
# which are included explicitly below, so a literal text match is safe
# and unambiguous here (unlike fs/namei.c's do_umount(), this function
# has no #ifdef/#else branches that would desync a literal match).
pattern = re.compile(
    r"static int sugov_kthread_create\(struct sugov_policy \*sg_policy\)\n"
    r"\{\n"
    r"\tstruct task_struct \*thread;\n"
    r"\tstruct sched_param param = \{ \.sched_priority = MAX_USER_RT_PRIO / 2 \};\n"
    r"\tstruct cpufreq_policy \*policy = sg_policy->policy;\n"
    r"\tint ret;\n"
    r"\n"
    r"\t/\* kthread only required for slow path \*/\n"
    r"\tif \(policy->fast_switch_enabled\)\n"
    r"\t\treturn 0;\n"
    r"\n"
    r"\tkthread_init_work\(&sg_policy->work, sugov_work\);\n"
    r"\tkthread_init_worker\(&sg_policy->worker\);\n"
    r"\tthread = kthread_create\(kthread_worker_fn, &sg_policy->worker,\n"
    r"\t\t\t\t\"sugov:%d\",\n"
    r"\t\t\t\tcpumask_first\(policy->related_cpus\)\);\n"
    r"\tif \(IS_ERR\(thread\)\) \{\n"
    r"\t\tpr_err\(\"failed to create sugov thread: %ld\\n\", PTR_ERR\(thread\)\);\n"
    r"\t\treturn PTR_ERR\(thread\);\n"
    r"\t\}\n"
    r"\n"
    r"\tret = sched_setscheduler_nocheck\(thread, SCHED_FIFO, &param\);\n"
    r"\tif \(ret\) \{\n"
    r"\t\tkthread_stop\(thread\);\n"
    r"\t\tpr_warn\(\"%s: failed to set SCHED_FIFO\\n\", __func__\);\n"
    r"\t\treturn ret;\n"
    r"\t\}\n"
    r"\n"
    r"\tsg_policy->thread = thread;\n"
    r"\tkthread_bind_mask\(thread, policy->related_cpus\);\n"
    r"\tinit_irq_work\(&sg_policy->irq_work, sugov_irq_work\);\n"
    r"\tmutex_init\(&sg_policy->work_lock\);\n"
    r"\n"
    r"\twake_up_process\(thread\);\n"
    r"\n"
    r"\treturn 0;\n"
    r"\}\n"
)

matches = list(pattern.finditer(src))
if len(matches) != 1:
    print(
        f"FATAL: expected exactly 1 match for sugov_kthread_create() full body, found {len(matches)}",
        file=sys.stderr,
    )
    sys.exit(1)

m = matches[0]

replacement = (
    "static int sugov_kthread_create(struct sugov_policy *sg_policy)\n"
    "{\n"
    "\tstruct task_struct *thread;\n"
    "\tstruct sched_param param = { .sched_priority = 1 }; /* " + MARKER + " */\n"
    "\tstruct cpufreq_policy *policy = sg_policy->policy;\n"
    "\tint ret;\n"
    "\n"
    "\t/* kthread only required for slow path */\n"
    "\tif (policy->fast_switch_enabled)\n"
    "\t\treturn 0;\n"
    "\n"
    "\tkthread_init_work(&sg_policy->work, sugov_work);\n"
    "\tkthread_init_worker(&sg_policy->worker);\n"
    "\tthread = kthread_create(kthread_worker_fn, &sg_policy->worker,\n"
    "\t\t\t\t\"sugov:%d\",\n"
    "\t\t\t\tcpumask_first(policy->related_cpus));\n"
    "\tif (IS_ERR(thread)) {\n"
    "\t\tpr_err(\"failed to create sugov thread: %ld\\n\", PTR_ERR(thread));\n"
    "\t\treturn PTR_ERR(thread);\n"
    "\t}\n"
    "\n"
    "\tret = sched_setscheduler_nocheck(thread, SCHED_RR, &param); /* " + MARKER + " */\n"
    "\tif (ret) {\n"
    "\t\tkthread_stop(thread);\n"
    "\t\tpr_warn(\"%s: failed to set SCHED_RR\\n\", __func__);\n"
    "\t\treturn ret;\n"
    "\t}\n"
    "\n"
    "\tsg_policy->thread = thread;\n"
    "\tkthread_bind_mask(thread, policy->related_cpus);\n"
    "\tinit_irq_work(&sg_policy->irq_work, sugov_irq_work);\n"
    "\tmutex_init(&sg_policy->work_lock);\n"
    "\n"
    "\twake_up_process(thread);\n"
    "\n"
    "\treturn 0;\n"
    "}\n"
)

src = src[:m.start()] + replacement + src[m.end():]
p.write_text(src)
print(f"{p}: sugov_kthread_create() moved to SCHED_RR / priority=1 (marker: {MARKER}, full-body replace)")
PYEOF
  log "PASS: sugov kthread priority (SCHED_RR) applied"
fi

# ─────────────────────────────────────────────────────────────────────────
# [7] kernel/sched/cpufreq_schedutil.c — sugov_init() second rate-limit
# ─────────────────────────────────────────────────────────────────────────
log "=== [7/7] kernel/sched/cpufreq_schedutil.c sugov_init() rate limit ==="
export SUGOV_INIT_MARKER="CMK9_SUGOV_INIT_RATE_LIMIT"

if grep -q "$SUGOV_INIT_MARKER" "$SUGOV_FILE"; then
  log "$SUGOV_FILE: sugov_init() rate limit already applied — skipping"
else
  python3 << 'PYEOF'

import re, sys, os
from pathlib import Path

MARKER = os.environ["SUGOV_INIT_MARKER"]
p = Path(os.environ["SUGOV_FILE"])
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

# ─────────────────────────────────────────────────────────────────────────
# Final self-check (independent of the workflow's verification step)
# ─────────────────────────────────────────────────────────────────────────
chk() { grep -q "$2" "$3" || fatal "$1 — marker '$2' missing in $3"; }
chk "UFC short-circuit"      CMK9_UFC_SHORT_CIRCUIT       drivers/cpufreq/exynos-ufc.c
chk "mem_rw SUS_MAP guard"   CMK9_MEM_RW_SUS_MAP_GUARD    fs/proc/base.c
chk "namei sus_path recheck" CMK9_NAMEI_SUS_PATH_RECHECK  fs/namei.c
chk "sugov rate limit"       CMK9_SUGOV_RATE_LIMIT        kernel/sched/cpufreq_schedutil.c
chk "sugov kthread prio"     CMK9_SUGOV_KTHREAD_PRIORITY  kernel/sched/cpufreq_schedutil.c
chk "sugov_init rate limit"  CMK9_SUGOV_INIT_RATE_LIMIT   kernel/sched/cpufreq_schedutil.c

log "=== Chimera LITE overlay: all 7 sections complete ==="
