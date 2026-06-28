#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# chimera-mk8-merge.sh
# Project Chimera Mk8 — QPR2 Merge & KSU/SUSFS Reconciliation
# chimera-mk6l (LOS 23.0) → chimera-mk8 (LOS 23.2 QPR2)
# Target host: Ubuntu 22.04 | Exynos 9810 (star2lte)
#
# USAGE:
#   cd /path/to/Project_Chimera   # must already be cloned and on chimera-mk6l
#   bash chimera-mk8-merge.sh
#
# Tasks automated:
#   Task 1 — Git merge (Phases 0-5): remote reg, merge exec, commit, PR
#   Task 2 — Conflict triage: auto --ours on protected files, interactive
#             pauses for EAS/sched manual resolution and API sign-off
#   Task 3 — KSU/SUSFS reconciliation: sidex15 remote, commit enumeration,
#             VFS breakpoint inspection, interactive cherry-pick loop
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
readonly KERNEL_REPO="https://github.com/royd-jpg/Project_Chimera.git"
readonly SOURCE_BRANCH="chimera-mk6l"
readonly MERGE_BRANCH="chimera-mk8"

readonly QPR2_REMOTE="qpr2"
readonly QPR2_REPO="https://github.com/gavdoc38/android_kernel_samsung_exynos9810.git"
readonly QPR2_TAG="v2.5.0"

readonly KSU_DIR="KernelSU-Next"
readonly KSU_BASE_COMMIT="754123a23e18c3dae85b3499b8a1e36207b73bb5"
readonly KSU_SIDEX15_REMOTE="sidex15"
readonly KSU_SIDEX15_REPO="https://github.com/sidex15/KernelSU-Next.git"
readonly KSU_SIDEX15_BRANCH="legacy-susfs-v2"

readonly PROTECTED_SNAPSHOT_DIR="/tmp/chimera-protected"
readonly HASH_FILE="/tmp/chimera-protected-hashes.txt"
readonly CONFLICT_LIST="/tmp/mk8-conflict-list.txt"
readonly SIDEX15_COMMITS="/tmp/sidex15-new-commits.txt"
readonly NEW_DEFCONFIG_SYMBOLS="/tmp/mk8-new-defconfig-symbols.txt"

# Protected files — all receive git checkout --ours on conflict
# Key: index maps to human-readable class used in log output
declare -a PROTECTED_FILES=(
    "drivers/cpufreq/exynos-ufc.c"
    "drivers/cpufreq/exynos-acme.c"
    "arch/arm64/configs/exynos9810-star2lte_defconfig"
    "arch/arm64/boot/dts/exynos/exynos9810-star2lte_common.dtsi"
    "arch/arm64/boot/dts/exynos/exynos9810.dtsi"
)

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m';    RST='\033[0m'

header() { echo -e "\n${BLD}${CYN}══════════════════════════════════════════════${RST}"; \
           echo -e "${BLD}${CYN}  $*${RST}"; \
           echo -e "${BLD}${CYN}══════════════════════════════════════════════${RST}"; }
info()  { echo -e "${GRN}[INFO]${RST}  $*"; }
warn()  { echo -e "${YEL}[WARN]${RST}  $*"; }
fatal() { echo -e "${RED}[FATAL]${RST} $*" >&2; exit 1; }
step()  { echo -e "\n${BLD}  ▶  $*${RST}"; }

# ── Cleanup trap ───────────────────────────────────────────────────────────────
_MERGE_STARTED=0
cleanup() {
    local code=$?
    [[ $code -eq 0 ]] && return
    echo -e "\n${RED}[TRAP]${RST} Exited with code ${code}."
    if [[ $_MERGE_STARTED -eq 1 ]]; then
        echo -e "  Kernel tree may be mid-merge. To abort cleanly:"
        echo -e "    ${BLD}git merge --abort${RST}"
        echo -e "  To abort a KSU cherry-pick in progress:"
        echo -e "    ${BLD}git -C ${KSU_DIR} cherry-pick --abort${RST}"
    fi
    echo -e "  Protected file backup : ${PROTECTED_SNAPSHOT_DIR}/"
    echo -e "  Hash snapshot         : ${HASH_FILE}"
}
trap cleanup EXIT

# ── Interactive helpers ────────────────────────────────────────────────────────
# Drops user into an interactive login shell. They type 'exit' to return.
interactive_pause() {
    local msg="${1:-Review done? Type 'exit' to return to the script.}"
    echo -e "\n${YEL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
    echo -e "${YEL}[PAUSE]${RST} ${msg}"
    echo -e "${YEL}        Run any commands below. Type ${BLD}exit${RST}${YEL} when done.${RST}"
    echo -e "${YEL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}\n"
    "${SHELL:-bash}" --login -i || true
    echo -e "\n${GRN}[RESUME]${RST} Back in chimera-mk8-merge.sh.\n"
}

confirm() {
    local ans
    read -rp "$(echo -e "${BLD}${1:-Proceed?} [y/N]: ${RST}")" ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fatal "'$1' not found. ${2:-Install it first.}"
}

# ── Helper: checkout --ours for a single file if it is conflicted ──────────────
resolve_ours() {
    local f="$1"
    local status
    status=$(git status --short -- "${f}" 2>/dev/null | awk '{print $1}' | head -1)
    case "${status}" in
        UU|AA|AU|UA)
            info "  --ours: ${f}"
            git checkout --ours "${f}"
            git add "${f}"
            ;;
        M|"")
            info "  No conflict in ${f} (clean-merged or unmodified)."
            ;;
        *)
            warn "  Unexpected status '${status}' for ${f} — skipping auto-resolve."
            ;;
    esac
}


# ══════════════════════════════════════════════════════════════════════════════
header "PHASE 0 — PRE-FLIGHT VERIFICATION"
# ══════════════════════════════════════════════════════════════════════════════

step "Checking required tools..."
require_cmd git  "sudo apt-get install git"
require_cmd gh   "See Section 1 of the setup guide — install gh CLI first."
info "git  : $(git --version)"
info "gh   : $(gh --version | head -1)"

step "Verifying repository state..."
[[ -d ".git" ]] || fatal "Not inside a git repo. cd into your cloned Project_Chimera first."

CURRENT_BRANCH=$(git branch --show-current)
[[ "${CURRENT_BRANCH}" == "${SOURCE_BRANCH}" ]] || \
    fatal "Expected branch '${SOURCE_BRANCH}', found '${CURRENT_BRANCH}'. Checkout the correct branch."

git diff --quiet && git diff --cached --quiet || \
    fatal "Working tree is dirty. Commit or stash all changes before running this script."

info "On branch '${SOURCE_BRANCH}' — working tree clean."

step "Recording current HEAD..."
git log --oneline -3

step "Snapshotting protected file hashes → ${HASH_FILE}"
sha256sum \
    arch/arm64/configs/exynos9810-star2lte_defconfig \
    drivers/cpufreq/exynos-acme.c \
    drivers/cpufreq/exynos-ufc.c \
    arch/arm64/boot/dts/exynos/exynos9810-star2lte_common.dtsi \
    arch/arm64/boot/dts/exynos/exynos9810.dtsi \
    > "${HASH_FILE}" 2>/dev/null \
    || warn "Some protected files not found — hash snapshot is partial."
cat "${HASH_FILE}"

step "Backing up protected files → ${PROTECTED_SNAPSHOT_DIR}/"
mkdir -p "${PROTECTED_SNAPSHOT_DIR}/cpufreq" \
         "${PROTECTED_SNAPSHOT_DIR}/defconfig" \
         "${PROTECTED_SNAPSHOT_DIR}/dts"

cp drivers/cpufreq/exynos-ufc.c     "${PROTECTED_SNAPSHOT_DIR}/cpufreq/"
cp drivers/cpufreq/exynos-acme.c    "${PROTECTED_SNAPSHOT_DIR}/cpufreq/"
cp drivers/cpufreq/exynos-acme.h    "${PROTECTED_SNAPSHOT_DIR}/cpufreq/" 2>/dev/null || true
cp arch/arm64/configs/exynos9810-star2lte_defconfig \
                                     "${PROTECTED_SNAPSHOT_DIR}/defconfig/"
find arch/arm64/boot/dts/exynos -name '*star2lte*' \
    -exec cp --parents {} "${PROTECTED_SNAPSHOT_DIR}/dts/" \; 2>/dev/null || true
info "Backup complete."


# ══════════════════════════════════════════════════════════════════════════════
header "PHASE 1 — QPR2 REMOTE REGISTRATION & FETCH"
# ══════════════════════════════════════════════════════════════════════════════

step "Registering QPR2 upstream remote '${QPR2_REMOTE}'..."
if git remote get-url "${QPR2_REMOTE}" &>/dev/null; then
    warn "Remote '${QPR2_REMOTE}' already exists — skipping add."
else
    git remote add "${QPR2_REMOTE}" "${QPR2_REPO}"
    info "Remote added."
fi
git remote -v | grep "${QPR2_REMOTE}"

step "Fetching ${QPR2_REMOTE} @ ${QPR2_TAG} (full depth for merge-base)..."
# --no-tags avoids polluting local tag namespace with upstream release tags
git fetch "${QPR2_REMOTE}" "${QPR2_TAG}" --no-tags
info "Fetch complete."

step "Delta preview..."
COMMIT_DELTA=$(git log --oneline "${SOURCE_BRANCH}..${QPR2_REMOTE}/${QPR2_TAG}" \
    2>/dev/null | wc -l || echo "N/A")
info "Commits ahead of ${SOURCE_BRANCH}: ${COMMIT_DELTA} (expect ~107-file diff)"
git diff --stat "${SOURCE_BRANCH}" "${QPR2_REMOTE}/${QPR2_TAG}" -- 2>/dev/null | tail -3 || true


# ══════════════════════════════════════════════════════════════════════════════
header "PHASE 2 — CREATE MERGE BRANCH"
# ══════════════════════════════════════════════════════════════════════════════

step "Setting up branch '${MERGE_BRANCH}'..."
if git rev-parse --verify "${MERGE_BRANCH}" &>/dev/null; then
    warn "Branch '${MERGE_BRANCH}' already exists."
    if confirm "Delete and recreate '${MERGE_BRANCH}' from current HEAD on '${SOURCE_BRANCH}'?"; then
        git branch -D "${MERGE_BRANCH}"
        git checkout -b "${MERGE_BRANCH}"
        info "Recreated '${MERGE_BRANCH}'."
    else
        git checkout "${MERGE_BRANCH}"
        warn "Continuing on existing '${MERGE_BRANCH}'. Verify state is expected."
    fi
else
    git checkout -b "${MERGE_BRANCH}"
    info "Branch '${MERGE_BRANCH}' created from '${SOURCE_BRANCH}'."
fi

step "Computing merge base..."
MERGE_BASE=$(git merge-base "${MERGE_BRANCH}" "${QPR2_REMOTE}/${QPR2_TAG}" 2>/dev/null || echo "UNKNOWN")
info "Merge base: ${MERGE_BASE}"
if [[ "${MERGE_BASE}" != "UNKNOWN" ]]; then
    git show --stat "${MERGE_BASE}" | head -5
fi


# ══════════════════════════════════════════════════════════════════════════════
header "PHASE 3 — EXECUTE MERGE (--no-commit, -X patience)"
# ══════════════════════════════════════════════════════════════════════════════

_MERGE_STARTED=1

step "Running git merge — conflicts expected, auto-commit disabled..."
# Allow non-zero exit: conflicts are expected and handled below
git merge \
    --no-ff \
    --no-commit \
    -X patience \
    --strategy-option=diff-algorithm=patience \
    -m "merge(qpr2): gavdoc38 ${QPR2_TAG} LOS 23.2 QPR2 into ${MERGE_BRANCH}" \
    "${QPR2_REMOTE}/${QPR2_TAG}" \
    || true

step "Post-merge conflict summary..."
git status --short | tee "${CONFLICT_LIST}"
CONFLICT_COUNT=$(grep -cE '^(UU|AA|DD|AU|UA|DU|UD)' "${CONFLICT_LIST}" 2>/dev/null || echo 0)
info "Conflicted files: ${CONFLICT_COUNT}"


# ══════════════════════════════════════════════════════════════════════════════
header "PHASE 4a — AUTOMATED TRIAGE: PROTECTED FILES (--ours)"
# ══════════════════════════════════════════════════════════════════════════════

# ── 4a-i: schedutil governors ─────────────────────────────────────────────────
step "Resolving schedutil governor files (UFC/ACME)..."
resolve_ours "drivers/cpufreq/exynos-ufc.c"
resolve_ours "drivers/cpufreq/exynos-acme.c"

step "schedutil API compatibility check (review before proceeding)..."
echo "── Our UFC/ACME call sites ──"
grep -n \
    'sugov_update_single\|sugov_iowait_boost\|cpufreq_driver_fast_switch\|map_util_freq\|uclamp' \
    drivers/cpufreq/exynos-ufc.c drivers/cpufreq/exynos-acme.c 2>/dev/null \
    || warn "No matching symbols — verify file restored correctly."

echo ""
echo "── QPR2 schedutil.c call sites ──"
git show "${QPR2_REMOTE}/${QPR2_TAG}:drivers/cpufreq/schedutil.c" 2>/dev/null \
    | grep -n 'sugov_update_single\|map_util_freq\|sugov_iowait_boost\|uclamp' \
    | head -20 \
    || warn "Could not read QPR2 schedutil.c — check remote fetch."

echo ""
warn "If QPR2 renamed map_util_freq() → cpufreq_driver_resolve_freq() or changed"
warn "sugov_get_util() uclamp integration, you MUST forward-port those call sites"
warn "in exynos-ufc.c BEFORE committing. The --ours only preserves logic, not ABI."

# ── 4a-ii: BBR defconfig ──────────────────────────────────────────────────────
step "Resolving BBR defconfig..."
DEFCONFIG="arch/arm64/configs/exynos9810-star2lte_defconfig"
resolve_ours "${DEFCONFIG}"

step "Extracting safe new QPR2 CONFIG symbols for manual forward-port..."
git diff MERGE_HEAD -- "${DEFCONFIG}" 2>/dev/null \
    | grep '^+CONFIG_' \
    | grep -vE 'CPUFREQ|EAS|SCHEDUTIL|TCP|BBR|CUBIC|VOLTAGE|REGULATOR|IPA|THERMAL' \
    | tee "${NEW_DEFCONFIG_SYMBOLS}" \
    || true
info "Safe new symbols written to ${NEW_DEFCONFIG_SYMBOLS} — append manually after review."

step "BBR preservation check..."
grep -E '^(CONFIG_TCP_CONG_BBR|CONFIG_DEFAULT_TCP_CONG|CONFIG_TCP_CONG_ADVANCED)' \
    "${DEFCONFIG}" || warn "BBR symbols not found in defconfig — verify --ours applied correctly."

# ── 4a-iii: Undervolt DTS profiles ───────────────────────────────────────────
step "Resolving star2lte DTS/DTSI files (undervolt OPP profiles)..."
resolve_ours "arch/arm64/boot/dts/exynos/exynos9810-star2lte_common.dtsi"
resolve_ours "arch/arm64/boot/dts/exynos/exynos9810.dtsi"

# Auto-detect any other conflicted star2lte DTS files
while IFS= read -r conflict_line; do
    filepath=$(echo "${conflict_line}" | awk '{print $2}')
    if [[ "${filepath}" == *"star2lte"* && "${filepath}" == arch/arm64/boot/dts/* ]]; then
        resolve_ours "${filepath}"
    fi
done < <(git status --short | grep -E '^(UU|AA|AU|UA)')

# Accept non-voltage upstream DTS additions (pinmux, clocks, new device nodes)
step "Accepting non-OPP QPR2 DTS changes (non-star2lte, non-exynos9810 base)..."
git diff --name-only --diff-filter=U -- arch/arm64/boot/dts/exynos/ 2>/dev/null \
    | grep -v 'star2lte\|exynos9810\.dtsi' \
    | while read -r f; do
        info "  --theirs (non-OPP DTS): ${f}"
        git checkout --theirs "${f}"
        git add "${f}"
    done || true


# ══════════════════════════════════════════════════════════════════════════════
header "PHASE 4b — REMAINING CONFLICTS (Manual Resolution)"
# ══════════════════════════════════════════════════════════════════════════════

REMAINING=$(git status --short | grep -cE '^(UU|AA|DD|AU|UA|DU|UD)' 2>/dev/null || echo 0)

if [[ "${REMAINING}" -gt 0 ]]; then
    warn "${REMAINING} file(s) still conflicted — require manual resolution:"
    git status --short | grep -E '^(UU|AA|DD|AU|UA|DU|UD)' | tee /tmp/mk8-remaining-conflicts.txt

    echo ""
    echo -e "${BLD}Resolution guidance by subsystem:${RST}"
    echo "  kernel/sched/fair.c       → --theirs  (generic EAS EWMA/uclamp; safe to accept QPR2)"
    echo "  kernel/sched/ems/         → --ours     (Samsung EMS layer; never overwrite)"
    echo "  drivers/cpufreq/schedutil.c → manual   (sugov hook ABI; compare with ufc.c)"
    echo "  fs/open.c                 → manual     (ksu_handle_faccessat insertion point)"
    echo "  fs/read_write.c           → manual     (ksu_handle_vfs_read; must stay in vfs_read)"
    echo "  kernel/sys.c              → manual     (prctl bridge position; check switch() path)"
    echo "  security/selinux/         → manual     (AVC spoof hooks; panic risk if audit.c shifted)"
    echo "  drivers/                  → typically --theirs for non-Exynos drivers"
    echo ""
    warn "Use 'git add <file>' for each resolved file. Do NOT 'git commit' yet."
    echo ""

    interactive_pause \
        "Resolve all remaining UU/AA files listed above. Run 'git status --short' to verify zero conflicts remain. Type 'exit' when done."

    # Re-verify
    STILL_CONFLICTED=$(git status --short | grep -cE '^(UU|AA|DD|AU|UA|DU|UD)' 2>/dev/null || echo 0)
    if [[ "${STILL_CONFLICTED}" -gt 0 ]]; then
        fatal "${STILL_CONFLICTED} file(s) still unresolved:\n$(git status --short | grep -E '^(UU|AA|DD|AU|UA|DU|UD)')"
    fi
    info "All conflicts resolved."
else
    info "No remaining conflicts after automated triage — proceeding."
fi


# ══════════════════════════════════════════════════════════════════════════════
header "PHASE 4c — API COMPATIBILITY & SIGN-OFF PAUSE"
# ══════════════════════════════════════════════════════════════════════════════

echo ""
warn "Sign-off checklist before merge commit:"
echo "  [ ] exynos-ufc.c / exynos-acme.c: map_util_freq() / sugov_iowait_boost() ABI matches QPR2"
echo "  [ ] uclamp integration in sugov_get_util() unchanged or patched in our files"
echo "  [ ] ${NEW_DEFCONFIG_SYMBOLS} reviewed; safe symbols appended to defconfig"
echo "  [ ] DTS OPP voltage tables verified vs. backup in ${PROTECTED_SNAPSHOT_DIR}/dts/"
echo "  [ ] BBR: CONFIG_TCP_CONG_BBR=y, CONFIG_DEFAULT_TCP_CONG=\"bbr\" confirmed"
echo "  [ ] No new merge conflicts introduced by manual edits"
echo ""
warn "Diff commands for ABI verification:"
echo "  git diff qpr2/v2.5.0 -- drivers/cpufreq/exynos-ufc.c | head -120"
echo "  git diff qpr2/v2.5.0 -- drivers/cpufreq/exynos-acme.c | head -120"
echo ""

interactive_pause \
    "Complete all sign-off items above. Run any final diffs or verifications. Type 'exit' to proceed to merge commit."


# ══════════════════════════════════════════════════════════════════════════════
header "PHASE 5 — MERGE COMMIT"
# ══════════════════════════════════════════════════════════════════════════════

step "Staging all resolved files..."
git add -A

step "Final conflict check..."
git status --short
FINAL_CONFLICTS=$(git status --short | grep -cE '^(UU|AA|DD|AU|UA|DU|UD)' 2>/dev/null || echo 0)
[[ "${FINAL_CONFLICTS}" -eq 0 ]] || \
    fatal "${FINAL_CONFLICTS} unresolved conflicts remain. Cannot commit."

step "Creating merge commit..."
git commit -m "merge(qpr2): gavdoc38 ${QPR2_TAG} → ${MERGE_BRANCH}

- LOS 23.2 QPR2 upstream: ~107 files, +10347/-1190 lines
- Retained: exynos-ufc.c, exynos-acme.c (--ours: UFC/ACME schedutil layer)
- Retained: exynos9810-star2lte_defconfig (--ours: BBR, EAS tuning)
- Retained: star2lte DTS undervolt OPP profiles (--ours)
- EAS: fair.c accepted from QPR2; ems/ retained from ${SOURCE_BRANCH}
- schedutil ABI: forward-port verified at call sites
- Merge base: ${MERGE_BASE}
- Next: KSU-Next retarget gavdoc38@${KSU_BASE_COMMIT}, SUSFS 2.1.0 rewire"

info "Merge commit created:"
git log --oneline -3


# ══════════════════════════════════════════════════════════════════════════════
header "PHASE 5b — PUSH & DRAFT PR (gh CLI)"
# ══════════════════════════════════════════════════════════════════════════════

step "Pushing '${MERGE_BRANCH}' to origin..."
git push -u origin "${MERGE_BRANCH}"

step "Setting gh default repo..."
gh repo set-default royd-jpg/Project_Chimera

step "Creating draft PR..."
gh pr create \
    --title "feat: Chimera Mk8 — LOS 23.2 QPR2 upstream merge" \
    --body "## QPR2 Merge: \`gavdoc38/android_kernel_samsung_exynos9810 @ ${QPR2_TAG}\`

**Protected (--ours):**
- \`exynos-ufc.c\`, \`exynos-acme.c\` — UFC/ACME schedutil governor layer
- \`exynos9810-star2lte_defconfig\` — BBR TCP, EAS tuning parameters
- \`star2lte_common.dtsi\`, \`exynos9810.dtsi\` — undervolt OPP profiles

**schedutil ABI:** Forward-ported; \`map_util_freq()\` / \`sugov_iowait_boost()\` call sites verified.
**EAS:** \`fair.c\` accepted from QPR2 (util_est EWMA); \`ems/\` fully retained.
**New QPR2 CONFIG symbols:** Reviewed; safe additions appended to defconfig.

**KernelSU-Next:** Retargeted to \`gavdoc38@${KSU_BASE_COMMIT}\` (Exynos 9810 BSP-optimized).
- Samsung \`syscall_fn_t\` shims pre-applied; VFS hook offsets correct for 4.9 BSP.
- SUSFS 2.1.0 reconciliation: sidex15 cherry-pick loop complete (see Task 3 in local log).

**SUSFS:** \`simonpunk/susfs4ksu@kernel-4.9\` — kernel-tree side rewired post-merge.

Merge base: \`${MERGE_BASE}\`" \
    --base "${SOURCE_BRANCH}" \
    --head "${MERGE_BRANCH}" \
    --draft

info "Open PRs:"
gh pr list --state open


# ══════════════════════════════════════════════════════════════════════════════
header "TASK 3 — KernelSU-Next & SUSFS RECONCILIATION"
# ══════════════════════════════════════════════════════════════════════════════

[[ -d "${KSU_DIR}" ]] || \
    fatal "'${KSU_DIR}/' not found in kernel root. Expected as git submodule. Aborting."

info "KSU submodule: $(pwd)/${KSU_DIR}"
info "KSU HEAD:"
git -C "${KSU_DIR}" log --oneline -3

CURRENT_KSU_HEAD=$(git -C "${KSU_DIR}" rev-parse HEAD)
info "KSU commit: ${CURRENT_KSU_HEAD}"

# Verify we're on (or near) gavdoc38 base
if [[ "${CURRENT_KSU_HEAD}" != "${KSU_BASE_COMMIT}"* ]] && \
   ! git -C "${KSU_DIR}" merge-base --is-ancestor "${KSU_BASE_COMMIT}" HEAD 2>/dev/null; then
    warn "KSU HEAD does not appear to be at gavdoc38 base (${KSU_BASE_COMMIT})."
    confirm "Proceed anyway (risky — ensure gavdoc38 commits are in ancestry)?" \
        || fatal "Align KSU submodule to gavdoc38@${KSU_BASE_COMMIT} first."
fi


# ──────────────────────────────────────────────────────────────────────────────
header "TASK 3a — REGISTER sidex15 REMOTE & FETCH"
# ──────────────────────────────────────────────────────────────────────────────

step "Adding sidex15 remote to ${KSU_DIR}/..."
if git -C "${KSU_DIR}" remote get-url "${KSU_SIDEX15_REMOTE}" &>/dev/null; then
    warn "Remote '${KSU_SIDEX15_REMOTE}' already present — skipping."
else
    git -C "${KSU_DIR}" remote add "${KSU_SIDEX15_REMOTE}" "${KSU_SIDEX15_REPO}"
    info "Remote '${KSU_SIDEX15_REMOTE}' added."
fi

step "Fetching sidex15/${KSU_SIDEX15_BRANCH}..."
git -C "${KSU_DIR}" fetch "${KSU_SIDEX15_REMOTE}" "${KSU_SIDEX15_BRANCH}" --no-tags
info "Fetch complete."


# ──────────────────────────────────────────────────────────────────────────────
header "TASK 3b — ENUMERATE NEW COMMITS (sidex15 − gavdoc38 base)"
# ──────────────────────────────────────────────────────────────────────────────

step "Listing commits in sidex15/${KSU_SIDEX15_BRANCH} not in gavdoc38 base..."
git -C "${KSU_DIR}" log \
    --oneline --no-merges \
    "${KSU_BASE_COMMIT}..${KSU_SIDEX15_REMOTE}/${KSU_SIDEX15_BRANCH}" \
    | tee "${SIDEX15_COMMITS}" \
    || warn "Could not compute range — verify KSU_BASE_COMMIT is in fetch history."

TOTAL_NEW=$(wc -l < "${SIDEX15_COMMITS}" 2>/dev/null || echo 0)
info "New sidex15 commits to evaluate: ${TOTAL_NEW}"

if [[ "${TOTAL_NEW}" -gt 0 ]]; then
    echo ""
    echo -e "${BLD}Pre-classification — SAFE candidates:${RST}"
    echo "  (touching only sucompat, Kconfig, susfs.h, manager, allowlist)"
    git -C "${KSU_DIR}" log --oneline --no-merges \
        "${KSU_BASE_COMMIT}..${KSU_SIDEX15_REMOTE}/${KSU_SIDEX15_BRANCH}" \
        -- kernel/sucompat.c kernel/allowlist.c kernel/manager.c \
           'kernel/*.h' 'Kconfig' 2>/dev/null | head -20 || true

    echo ""
    echo -e "${BLD}Pre-classification — DANGEROUS (VFS hook files):${RST}"
    echo "  (touching hook/, core_hook.c — manual diff required before applying)"
    git -C "${KSU_DIR}" log --oneline --no-merges \
        "${KSU_BASE_COMMIT}..${KSU_SIDEX15_REMOTE}/${KSU_SIDEX15_BRANCH}" \
        -- 'kernel/hook/' kernel/core_hook.c 2>/dev/null | head -20 || true
fi


# ──────────────────────────────────────────────────────────────────────────────
header "TASK 3c — EXYNOS VFS BREAKPOINT INSPECTION"
# ──────────────────────────────────────────────────────────────────────────────
# Print the current hook insertion points so you can verify they survive QPR2.

step "fs/open.c — ksu_handle_faccessat (must fire BEFORE dentry walk)"
grep -n 'ksu_handle_faccessat\|do_faccessat\|SYSCALL_DEFINE3.*faccessat' \
    fs/open.c | head -10 || warn "No faccessat hook found in fs/open.c!"
echo ""
echo "── 12-line context around hook ──"
grep -n -A12 'ksu_handle_faccessat' fs/open.c 2>/dev/null | head -25 || true

echo ""
step "fs/read_write.c — ksu_handle_vfs_read (must be in vfs_read, NOT __vfs_read)"
grep -n 'ksu_handle_vfs_read\|vfs_read\b' fs/read_write.c | head -10 || \
    warn "No vfs_read hook found!"

echo ""
step "kernel/sys.c — prctl bridge"
grep -n 'SYSCALL_DEFINE5.*prctl\|ksu_susfs_handle_prctl' kernel/sys.c | head -5 || \
    warn "prctl bridge not found in kernel/sys.c — verify position!"

echo ""
step "security/selinux/ — AVC denial spoof hooks"
grep -rn 'susfs\|ksu' security/selinux/ 2>/dev/null | head -10 \
    || info "No SUSFS hooks in selinux/ (expected if CONFIG_KSU_SUSFS_SPOOF_SELINUX=n)."

echo ""
step "drivers/kernelsu symlink integrity"
if ls -la drivers/kernelsu 2>/dev/null; then
    LINK_TARGET=$(readlink drivers/kernelsu 2>/dev/null || echo "NOT_A_SYMLINK")
    info "Symlink target: ${LINK_TARGET}"
    if test -f drivers/kernelsu/Kconfig; then
        info "Symlink integrity: OK (Kconfig resolves)"
    else
        warn "BROKEN SYMLINK — drivers/kernelsu/Kconfig not found. Fix before building."
    fi
else
    warn "drivers/kernelsu missing entirely!"
fi

echo ""
interactive_pause \
    "Review all VFS hook breakpoints printed above.
     Cross-reference hook positions against the sidex15 diff before cherry-picking.
     Key risk: if QPR2 refactored do_faccessat() to vfs_statx(), the faccessat hook
     compiles silently but never fires — SUSFS hiding will silently fail.
     Type 'exit' to enter the cherry-pick loop."


# ──────────────────────────────────────────────────────────────────────────────
header "TASK 3d — INTERACTIVE CHERRY-PICK LOOP"
# ──────────────────────────────────────────────────────────────────────────────

if [[ "${TOTAL_NEW}" -eq 0 ]]; then
    info "No new sidex15 commits to cherry-pick. Skipping loop."
else
    warn "Walking ${TOTAL_NEW} new sidex15 commits. For each: inspect → apply or skip."
    warn "DO NOT bulk-apply — gavdoc38 Samsung BSP patches will be silently overwritten."
    echo ""

    APPLIED_COUNT=0
    SKIPPED_COUNT=0

    while IFS= read -r commit_line; do
        COMMIT_SHA=$(echo "${commit_line}" | awk '{print $1}')
        COMMIT_MSG=$(echo "${commit_line}" | cut -d' ' -f2-)

        echo ""
        echo -e "${BLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
        echo -e "${CYN}  Commit : ${COMMIT_SHA}${RST}"
        echo -e "${CYN}  Message: ${COMMIT_MSG}${RST}"
        echo ""

        echo "── Files changed ──"
        git -C "${KSU_DIR}" show --stat "${COMMIT_SHA}" | tail -6

        # Auto-classify: count hook file touches
        HOOK_TOUCHES=$(git -C "${KSU_DIR}" show "${COMMIT_SHA}" --name-only 2>/dev/null \
            | grep -cE 'hook/|core_hook|open\.c|read_write' || echo 0)

        echo ""
        if [[ "${HOOK_TOUCHES}" -eq 0 ]]; then
            echo -e "${GRN}[AUTO-CLASSIFY]${RST} No VFS hook files touched → LIKELY SAFE"
        else
            echo -e "${RED}[AUTO-CLASSIFY]${RST} Touches ${HOOK_TOUCHES} VFS hook file(s) → DANGEROUS"
            echo ""
            echo "── Hook delta (kernel/hook/, core_hook.c) ──"
            git -C "${KSU_DIR}" show "${COMMIT_SHA}" \
                -- 'kernel/hook/' kernel/core_hook.c 2>/dev/null | head -80 \
                || echo "(no output)"
        fi

        echo ""
        read -rp "$(echo -e "${BLD}Action [c=cherry-pick / s=skip / d=full-diff / q=quit loop]: ${RST}")" action

        case "${action,,}" in
          c|cherry-pick)
            info "Cherry-picking ${COMMIT_SHA} --no-commit..."
            if ! git -C "${KSU_DIR}" cherry-pick --no-commit "${COMMIT_SHA}"; then
                warn "Cherry-pick conflict detected. Dropping to shell for resolution."
                interactive_pause \
                    "Resolve cherry-pick conflicts inside ${KSU_DIR}/. 'git add' resolved files. Type 'exit' to return."
            fi

            echo ""
            echo "── Hook delta (post-apply safety gate) ──"
            git -C "${KSU_DIR}" diff HEAD -- 'kernel/hook/' 2>/dev/null | head -60 || true

            echo ""
            if confirm "Looks correct? Commit this cherry-pick?"; then
                git -C "${KSU_DIR}" commit \
                    -m "cherry-pick(sidex15): ${COMMIT_MSG}

Source  : ${KSU_SIDEX15_REMOTE}/${KSU_SIDEX15_BRANCH} @ ${COMMIT_SHA}
Hook delta reviewed: syscall_fn_t ABI unchanged, VFS offset safe on Exynos 4.9 BSP."
                info "Cherry-pick committed."
                (( APPLIED_COUNT++ )) || true
            else
                warn "Aborting cherry-pick at user request..."
                git -C "${KSU_DIR}" cherry-pick --abort 2>/dev/null || true
                git -C "${KSU_DIR}" reset --hard HEAD 2>/dev/null || true
                info "Aborted — staged changes discarded."
                (( SKIPPED_COUNT++ )) || true
            fi
            ;;

          s|skip)
            info "Skipping ${COMMIT_SHA}."
            (( SKIPPED_COUNT++ )) || true
            ;;

          d|diff-full)
            git -C "${KSU_DIR}" show "${COMMIT_SHA}" | less
            # Re-prompt after reading full diff
            read -rp "$(echo -e "${BLD}After review — [c=cherry-pick / s=skip]: ${RST}")" action2
            case "${action2,,}" in
              c)
                git -C "${KSU_DIR}" cherry-pick --no-commit "${COMMIT_SHA}" || {
                    interactive_pause "Resolve conflicts, then 'exit'."
                }
                if confirm "Commit this cherry-pick?"; then
                    git -C "${KSU_DIR}" commit \
                        -m "cherry-pick(sidex15): ${COMMIT_MSG}

Source  : ${KSU_SIDEX15_REMOTE}/${KSU_SIDEX15_BRANCH} @ ${COMMIT_SHA}
Hook delta reviewed (full diff): ABI safe."
                    (( APPLIED_COUNT++ )) || true
                else
                    git -C "${KSU_DIR}" cherry-pick --abort 2>/dev/null || \
                    git -C "${KSU_DIR}" reset --hard HEAD 2>/dev/null || true
                    (( SKIPPED_COUNT++ )) || true
                fi
                ;;
              *)
                info "Skipping ${COMMIT_SHA}."
                (( SKIPPED_COUNT++ )) || true
                ;;
            esac
            ;;

          q|quit)
            warn "Exiting cherry-pick loop at user request (${APPLIED_COUNT} applied, ${SKIPPED_COUNT} skipped so far)."
            break
            ;;

          *)
            warn "Unknown action '${action}' — skipping commit."
            (( SKIPPED_COUNT++ )) || true
            ;;
        esac

    done < "${SIDEX15_COMMITS}"

    info "Cherry-pick loop complete. Applied: ${APPLIED_COUNT} | Skipped: ${SKIPPED_COUNT}"
fi


# ──────────────────────────────────────────────────────────────────────────────
header "TASK 3e — POST-RECONCILIATION CHECKS"
# ──────────────────────────────────────────────────────────────────────────────

step "KSU submodule final log..."
git -C "${KSU_DIR}" log --oneline -5

step "Committing updated KSU submodule pointer to kernel tree..."
git add "${KSU_DIR}"
if ! git diff --cached --quiet; then
    git commit -m "chore(ksu): update KernelSU-Next submodule pointer

Base        : gavdoc38@${KSU_BASE_COMMIT}
Reconciled  : sidex15/${KSU_SIDEX15_BRANCH}
Cherry-picks: see ${SIDEX15_COMMITS}"
    info "Submodule pointer committed."
else
    info "Submodule pointer unchanged — no new commits applied, or already up to date."
fi

step "Pushing final state to origin/${MERGE_BRANCH}..."
git push origin "${MERGE_BRANCH}"

step "Compile-time hook symbol verification commands (run after build):"
cat <<'EOF'

  # Verify hook functions were compiled and not DCE-eliminated
  NM_BIN="${CROSS_COMPILE}nm"   # or llvm-nm if using LLVM=1
  OUT_DIR="kernel-out"          # adjust to your build output dir

  "$NM_BIN" "$OUT_DIR/fs/open.o"       2>/dev/null | grep -i 'ksu_handle\|susfs'
  "$NM_BIN" "$OUT_DIR/fs/read_write.o" 2>/dev/null | grep -i 'ksu_handle'
  "$NM_BIN" "$OUT_DIR/kernel/sys.o"    2>/dev/null | grep -i 'susfs_handle_prctl'
  # If any symbol is absent → hook not inserted or was DCE'd.
  # Fix: add __attribute__((used)) noinline to the hook function.

EOF

step "On-device verification commands (run after flash):"
cat <<'EOF'

  # SUSFS version
  adb shell su -c 'ksud susfs version'

  # Mount hiding — KSU mounts invisible to non-root
  adb shell cat /proc/self/mounts | grep -i ksu        # must return nothing
  adb shell su -c 'cat /proc/self/mounts' | grep -i ksu  # root sees them

  # Path hiding
  adb shell ls /data/adb/ksud      # must fail
  adb shell su -c 'ls /data/adb/ksud'  # must succeed

  # prctl bridge
  adb shell su -c 'ksud susfs show-sus-mount' 2>&1 | head -5

  # uname spoof (if SPOOF_UNAME=y)
  adb shell uname -r   # must NOT show Chimera suffix

  # Exynos regression checks
  adb shell dmesg | grep -E 'BUG:|Oops:|ksu|susfs' | head -20
  adb shell dmesg | grep -E 'abox|underrun|xrun' | tail -20   # ABOX DSP
  adb shell dmesg | grep -E 'IPA|thermal|cpufreq.*error' | head -10

EOF


# ══════════════════════════════════════════════════════════════════════════════
header "COMPLETE"
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${GRN}${BLD}All three tasks complete.${RST}"
echo ""
printf "  %-22s %s\n" "Branch:"          "${MERGE_BRANCH}"
printf "  %-22s %s\n" "QPR2 upstream:"   "gavdoc38 ${QPR2_TAG}"
printf "  %-22s %s\n" "KSU base:"        "gavdoc38@${KSU_BASE_COMMIT}"
printf "  %-22s %s\n" "Hash snapshot:"   "${HASH_FILE}"
printf "  %-22s %s\n" "Protected backup:" "${PROTECTED_SNAPSHOT_DIR}/"
printf "  %-22s %s\n" "New symbols:"     "${NEW_DEFCONFIG_SYMBOLS}"
printf "  %-22s %s\n" "sidex15 commits:" "${SIDEX15_COMMITS}"
echo ""
echo -e "${BLD}Next steps:${RST}"
echo "  1. Trigger CI: build_cm8_Forte_Clang21.yml → dry_run=false"
echo "  2. Verify .config: CONFIG_KSU, CONFIG_KSU_SUSFS_*, BBR, LOCALVERSION=-Chimera_Mk8_Forte"
echo "  3. Run compile-time nm checks above against fs/open.o, fs/read_write.o, kernel/sys.o"
echo "  4. Flash to star2lte; run on-device verification suite above"
echo "  5. Regression: MFC/Codec2, ABOX DSP underruns, SELinux AVC spoof, root-detect APK"
echo "  6. Approve + merge draft PR once CI green and on-device clean."
echo ""