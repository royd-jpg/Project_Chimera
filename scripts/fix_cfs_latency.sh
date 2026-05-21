#!/bin/bash
TARGET_FILE="kernel/sched/fair.c"

echo "⚙️ Reversing the broken global find-and-replace..."
sed -i 's/sysctl_sched_min_granularity   = 750000ULL;/sysctl_sched_min_granularity/g' "$TARGET_FILE"
sed -i 's/sysctl_sched_migration_cost    = 5000000ULL;/sysctl_sched_migration_cost/g' "$TARGET_FILE"

echo "⚙️ Applying the precise low latency -02 declarations..."
sed -i 's/.*unsigned int sysctl_sched_min_granularity.*/unsigned int sysctl_sched_min_granularity = 750000ULL;/g' "$TARGET_FILE"
sed -i 's/.*unsigned int sysctl_sched_migration_cost.*/const_debug unsigned int sysctl_sched_migration_cost = 5000000ULL;/g' "$TARGET_FILE"

echo "✅ C syntax repaired."
