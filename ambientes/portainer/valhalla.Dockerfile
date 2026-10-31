# Valhalla (rotas) com o mapa já pronto dentro da imagem: o servidor só carrega os tiles, sem baixar nem montar
# nada. O contexto é preparado por scripts/empacotar-portainer.sh a partir de valhalla/custom_files
# (valhalla.json, valhalla_tiles.tar e admin_data, gerados por scripts/preparar-mapa.sh).
FROM ghcr.io/gis-ops/docker-valhalla/valhalla:latest
COPY --chown=59999:59999 . /custom_files/
# Mesmos parâmetros do compose de desenvolvimento, mas sem reconstruir: os tiles e o banco de fronteiras já vêm prontos.
ENV tile_urls="" \
    use_tiles_ignore_pbf=True \
    build_elevation=False \
    build_admins=False \
    build_time_zones=False \
    server_threads=2 \
    force_rebuild=False
