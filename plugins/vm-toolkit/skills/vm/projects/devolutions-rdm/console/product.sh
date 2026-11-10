# Product: Devolutions Console, the Avalonia port of the DVLS Console (sourced by the VM toolkit's lib/products.sh;
# bash 3.2 compatible). Contract: references/products.md; `vmt check console`.

APP_NAME="Devolutions Console"
# Linux (Console.Linux) comes with a Linux guest.
TARGETS="windows"
# Where its code is (repo paths, space-separated): `vmt which <path>` picks the product from these.
# DVLS/Console/Console.Common (and its tests) is the DVLS console's business layer, which the Avalonia Console ships.
CODE_PATHS="Console/ DVLS/Console/Console.Common/ DVLS/Console/Console.Common.Tests/"
