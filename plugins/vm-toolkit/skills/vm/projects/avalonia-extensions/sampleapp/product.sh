# Product: the avalonia-extensions SampleApp, which shows every themed control and the custom controls (sourced by the
# VM toolkit's lib/products.sh; bash 3.2 compatible). The repo ships NuGet packages, not an app: the SampleApp is what a
# VM runs to show them. Contract: references/products.md; `vmt check sampleapp`.

APP_NAME="the avalonia-extensions SampleApp"
# macOS (the MacClassic and LiquidGlass themes) comes with a macOS target; Linux (Yaru) with a Linux guest.
TARGETS="windows"
# Where its code is (repo paths, space-separated): `vmt which <path>` picks the product from these.
CODE_PATHS="src/ samples/ tests/"
