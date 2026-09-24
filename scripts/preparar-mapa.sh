#!/bin/bash
# Prepara o mapa do Valhalla para GOIAS e as regioes que fazem divisa com
# Minas Gerais (Triangulo Mineiro), Mato Grosso (leste) e Mato Grosso do Sul
# (nordeste). Baixa os extratos da Geofabrik, recorta cada um pelo BBOX e funde
# em um unico .pbf (o Valhalla constroi tiles de TODO .pbf em custom_files).
#
#   Centro-Oeste (GO, DF, MT, MS)  ~205 MB
#   Sudeste (traz o trecho de MG)  ~860 MB
#
# BBOX = oeste,sul,leste,norte. O padrao cobre Goias com folga: de Chapadao do
# Sul/Barra do Garcas (oeste) ate a divisa com BA/TO (leste), e de Uberaba/
# Paranaiba (sul) ate o norte de Goias. NAO ha mapa de TO/BA (extratos Norte/
# Nordeste nao sao baixados): rotas que cruzem para la nao existem.
# Outra regiao: BBOX="..." REGIOES="centro-oeste sudeste" scripts/preparar-mapa.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BBOX="${BBOX:--54.0,-20.3,-45.5,-12.2}"
REGIOES="${REGIOES:-centro-oeste sudeste}"
SAIDA="valhalla/custom_files/goias.osm.pbf"

mkdir -p data valhalla/custom_files
osmium() { docker run --rm -v "$PWD:/wkd" iboates/osmium:latest "$@"; }

recortes=()
for regiao in $REGIOES; do
  bruto="data/$regiao-latest.osm.pbf"
  [ -f "$bruto" ] || curl -fsSL -C - -o "$bruto" "https://download.geofabrik.de/south-america/brazil/$regiao-latest.osm.pbf"
  osmium extract --overwrite --bbox "$BBOX" -o "/wkd/data/recorte-$regiao.osm.pbf" "/wkd/$bruto"
  recortes+=("/wkd/data/recorte-$regiao.osm.pbf")
done

# Objetos que aparecem nos dois extratos (fronteira entre regioes) sao mantidos uma vez so.
osmium merge --overwrite -o "/wkd/$SAIDA" "${recortes[@]}"
ls -lh "$SAIDA"
echo "Pronto. Se ja havia tiles de outra regiao, rode scripts/limpar-tiles.sh antes de: docker compose up -d valhalla"
