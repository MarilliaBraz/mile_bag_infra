#!/bin/bash
# Apaga os tiles gerados pelo Valhalla (e o .pbf de outra regiao, se sobrar) para
# forcar uma reconstrucao. Os arquivos sao do usuario root do contêiner, entao a
# limpeza roda dentro de um contêiner; os .pbf que voce quer manter NAO sao apagados
# (so o que o Valhalla gera). Para trocar de regiao, remova antes o .pbf antigo.
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose stop valhalla >/dev/null 2>&1 || true
docker run --rm -v "$PWD/valhalla/custom_files:/c" alpine sh -c \
  'cd /c && rm -rf valhalla_tiles valhalla_tiles.tar valhalla.json admin_data timezone.sqlite elevation_tiles file_hashes.txt duplicateways.txt'
ls -la valhalla/custom_files
