#!/bin/bash
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Project Chimera MK6L - Local Branch Audit"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "🔍 [1] UV Softening (1.275V)"
if grep -q "1275000" arch/arm64/boot/dts/exynos/exynos9810-star2lte_eur_open_26.dts; then
    grep -A 2 -B 2 "1275000" arch/arm64/boot/dts/exynos/exynos9810-star2lte_eur_open_26.dts | grep -E "vdd_cpucl|max-microvolt"
    echo "  ✅ UV Softening found."
else
    echo "  ❌ 1275000 not found in DTS."
fi
echo "---"

echo "🔍 [2] ACME Schedutil Rates (1500/16000)"
if grep -q -E "1500|16000" drivers/cpufreq/exynos-acme.c; then
    grep -E "\.up_rate_limit_us|\.down_rate_limit_us" drivers/cpufreq/exynos-acme.c | grep -E "1500|16000"
    echo "  ✅ ACME Pattern B limits found."
else
    echo "  ❌ 1500/16000 rates not found in exynos-acme.c."
fi
echo "---"

echo "🔍 [3] Sugov Priority (SCHED_RR p=1)"
if grep -q -E "sched_priority.*=.*1" kernel/sched/cpufreq_schedutil.c; then
    grep -E "sched_priority.*=.*1" kernel/sched/cpufreq_schedutil.c
    echo "  ✅ priority 1 found."
else
    echo "  ❌ SCHED_RR p=1 not found."
fi
echo "---"

echo "🔍 [4] MMC Read Ahead (128)"
if grep -q -E "blk_queue_read_ahead.*128|ra_pages.*32" drivers/mmc/core/block.c drivers/mmc/core/queue.c 2>/dev/null; then
    grep -E "blk_queue_read_ahead.*128|ra_pages.*32" drivers/mmc/core/block.c drivers/mmc/core/queue.c 2>/dev/null
    echo "  ✅ 128kB read-ahead found."
else
    echo "  ❌ 128kB read-ahead missing from block.c and queue.c."
fi
echo "---"

echo "🔍 [5a] TCP BBR & Default"
if grep -q "CONFIG_DEFAULT_TCP_CONG=\"bbr\"" arch/arm64/configs/exynos9810-star2lte_defconfig; then
    grep -E "CONFIG_TCP_CONG_BBR=y|CONFIG_DEFAULT_TCP_CONG" arch/arm64/configs/exynos9810-star2lte_defconfig
    echo "  ✅ BBR Default found."
else
    echo "  ❌ BBR not set as default."
fi
echo "---"

echo "🔍 [5b] HZ_100 Cleanup"
if grep -q "CONFIG_HZ_100=y" arch/arm64/configs/exynos9810-star2lte_defconfig; then
    echo "  ❌ CONFIG_HZ_100=y IS STILL PRESENT!"
else
    echo "  ✅ Clean (HZ_100 is absent)."
fi
echo "---"

echo "🔍 [6] UFC Short-Circuit"
if grep -A 3 "exynos_ufc_init" drivers/cpufreq/exynos-ufc.c | grep -q "return 0;"; then
    echo "  ✅ UFC successfully short-circuited."
else
    echo "  ❌ return 0; not found at the top of exynos_ufc_init."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
