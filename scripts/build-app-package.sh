#!/usr/bin/env bash
# Builds appPackage/build/teams-app.zip for sideloading, using outputs from the azd environment.
set -euo pipefail
cd "$(dirname "$0")/.."

BOT_ID="$(azd env get-value BOT_ID)"
BOT_ENDPOINT="$(azd env get-value BOT_ENDPOINT)"
BOT_DOMAIN="$(echo "$BOT_ENDPOINT" | sed -E 's#https://([^/]+)/.*#\1#')"

mkdir -p appPackage/build
sed -e "s/\${BOT_ID}/$BOT_ID/g" -e "s/\${BOT_DOMAIN}/$BOT_DOMAIN/g" \
  appPackage/manifest.template.json > appPackage/build/manifest.json
cp appPackage/color.png appPackage/outline.png appPackage/build/
(cd appPackage/build && rm -f teams-app.zip && python3 -m zipfile -c teams-app.zip manifest.json color.png outline.png)
echo "Created appPackage/build/teams-app.zip"
