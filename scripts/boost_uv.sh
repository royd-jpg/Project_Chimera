#!/bin/bash
echo "⚙️ Boosting max voltage limits from -50mV (1.25V) to -25mV (1.275V)..."
sed -i 's/regulator-min-microvolt = <1250000>;/regulator-min-microvolt = <1275000>;/g' arch/arm64/boot/dts/exynos/exynos9810-*.dts
sed -i 's/regulator-max-microvolt = <1250000>;/regulator-max-microvolt = <1275000>;/g' arch/arm64/boot/dts/exynos/exynos9810-*.dts
echo "✅ Voltage boosted. Run ./scripts/check_uv.sh to verify."
