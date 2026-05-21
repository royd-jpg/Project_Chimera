#!/bin/bash
echo "🔍 Checking PMIC voltage ceilings in Device Trees..."
grep -n -E "regulator-(min|max)-microvolt = <1250000>|regulator-(min|max)-microvolt = <1275000>" arch/arm64/boot/dts/exynos/exynos9810-*.dts
echo "====================================================="
