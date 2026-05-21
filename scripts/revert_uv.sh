#!/bin/bash
echo "⏪ Rolling voltage back to -50mV (1.25V)..."
sed -i 's/regulator-min-microvolt = <1275000>;/regulator-min-microvolt = <1250000>;/g' arch/arm64/boot/dts/exynos/exynos9810-*.dts
sed -i 's/regulator-max-microvolt = <1275000>;/regulator-max-microvolt = <1250000>;/g' arch/arm64/boot/dts/exynos/exynos9810-*.dts
echo "✅ Revert complete. Run ./scripts/check_uv.sh to verify."
