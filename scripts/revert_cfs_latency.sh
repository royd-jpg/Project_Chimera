#!/bin/bash
TARGET_FILE="kernel/sched/fair.c"
echo "⏪ Rolling back CFS variables to standard defaults..."
sed -i 's/.*unsigned int sysctl_sched_min_granularity.*/unsigned int sysctl_sched_min_granularity = 3000000ULL;/g' "$TARGET_FILE"
sed -i 's/.*unsigned int sysctl_sched_migration_cost.*/const_debug unsigned int sysctl_sched_migration_cost = 500000ULL;/g' "$TARGET_FILE"
echo "✅ Revert complete."
