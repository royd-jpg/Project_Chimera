#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════════
# EMS RUNTIME TUNING (Project Chimera P08)
# ═══════════════════════════════════════════════════════════════════════════════

EMS_PATHS=$(find /sys/ -name "light_task_threshold" -o -name "light_task_threshold_s" 2>/dev/null)

if [ -n "$EMS_PATHS" ]; then
    echo "⚙️ Tuning EMS Scheduler Thresholds..."
    for path in $EMS_PATHS; do
        echo "40" > "$path" 2>/dev/null
    done
    echo "✅ EMS Scheduler thresholds locked at performance profile."
else
    echo "ℹ️ EMS sysfs nodes not exposed at runtime; relying on baseline scheduling."
fi
