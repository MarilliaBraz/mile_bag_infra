#!/bin/bash
# Prepara o mapa do Valhalla: baixa o extrato do Sudeste (Geofabrik, ~860 MB) e
# recorta a região metropolitana de São Paulo, para o build de tiles caber em
# ~6 GB de RAM. Para outra região, mude BBOX (oeste,sul,leste,norte).
set -euo pipefail
cd "$(dirname "$0")/.."

BBOX="${BBOX:--47.3,-24.2,-45.8,-23.2}"
EXTRATO="data/sudeste-latest.osm.pbf"
SAIDA="valhalla/custom_files/saopaulo.osm.pbf"

mkdir -p data valhalla/custom_files
[ -f "$EXTRATO" ] || curl -L -C - -o "$EXTRATO" https://download.geofabrik.de/south-america/brazil/sudeste-latest.osm.pbf

docker run --rm -v "$PWD:/wkd" iboates/osmium:latest extract --overwrite --bbox "$BBOX" -o "/wkd/$SAIDA" "/wkd/$EXTRATO"
ls -lh "$SAIDA"
echo "Pronto. Suba com: docker compose up -d valhalla (a 1ª subida constrói os tiles e demora)."
