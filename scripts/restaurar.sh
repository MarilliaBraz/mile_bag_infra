#!/bin/bash
# Volta um backup feito por scripts/backup.sh: SUBSTITUI o banco e os arquivos do ambiente pelos do backup.
#
#   scripts/restaurar.sh producao data/backups/producao/2026-10-27_020000
#
# O que foi registrado depois do backup se perde. Por isso o script pede para digitar o nome do ambiente e,
# antes de restaurar, faz um backup do estado atual (que pode ser restaurado se a volta não era o que se queria).
# A API fica parada durante a restauração, para nenhum registro novo entrar no meio.
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
AMBIENTE="${1:-}"
PASTA="${2:-}"
case "$AMBIENTE" in
  homologacao | producao) ;;
  *)
    echo "Uso: scripts/restaurar.sh homologacao|producao <pasta-do-backup>" >&2
    exit 2
    ;;
esac
[ -n "$PASTA" ] && [ -f "$PASTA/SHA256SUMS" ] || { echo "Pasta de backup inválida: '$PASTA' (falta SHA256SUMS)." >&2; exit 1; }
ENV_ARQ="$RAIZ/ambientes/$AMBIENTE.env"
[ -f "$ENV_ARQ" ] || { echo "Ambiente '$AMBIENTE' ainda não implantado (falta ambientes/$AMBIENTE.env)." >&2; exit 1; }

compose() {
  MILEBAG_FONTES="$RAIZ/build/$AMBIENTE" docker compose --env-file "$ENV_ARQ" -f "$RAIZ/ambientes/docker-compose.yml" "$@"
}

(cd "$PASTA" && sha256sum --check --quiet SHA256SUMS) || { echo "Backup corrompido: os arquivos não batem com o SHA256SUMS." >&2; exit 1; }

echo "Isto substitui o banco e os arquivos de '$AMBIENTE' pelos do backup $(basename "$PASTA")."
read -rp "Para confirmar, digite o nome do ambiente ($AMBIENTE): " CONFIRMACAO
[ "$CONFIRMACAO" = "$AMBIENTE" ] || { echo "Cancelado." >&2; exit 1; }

echo "Backup do estado atual antes de restaurar..."
"$RAIZ/scripts/backup.sh" "$AMBIENTE"

compose stop api
# Se algo falhar daqui em diante, a API volta a subir do mesmo jeito (com o que estiver no banco).
trap 'compose start api >/dev/null' EXIT

# --clean recria cada objeto do backup; --single-transaction: ou restaura tudo, ou nada muda.
compose exec -T postgres pg_restore -U admin -d milebag --clean --if-exists --single-transaction <"$PASTA/banco.dump"

# MSYS_NO_PATHCONV: no Git Bash do Windows, "/storage" viraria um caminho do Windows (sem efeito no Linux).
MSYS_NO_PATHCONV=1 docker run --rm -i -v "milebag-${AMBIENTE}_storage:/storage" postgres:16 \
  sh -c 'find /storage -mindepth 1 -delete && tar -xzf - -C /storage' <"$PASTA/storage.tar.gz"

echo "Restaurado: $AMBIENTE agora está como em $(basename "$PASTA")."
