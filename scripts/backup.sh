#!/bin/bash
# Backup de um ambiente implantado por scripts/implantar.sh: o banco (pg_dump) e os arquivos enviados pelo app
# (volume "storage": fotos de BDO, comprovantes, logotipos).
#
#   scripts/backup.sh producao        # grava em data/backups/producao/AAAA-MM-DD_HHMMSS/
#
# Cada backup é uma pasta com banco.dump, storage.tar.gz e SHA256SUMS. Ela só ganha o nome final depois que tudo
# foi gravado e conferido: uma pasta terminada em ".parcial" é um backup que falhou no meio e não vale.
# MILEBAG_BACKUP_DIR muda a pasta raiz (ex.: uma pasta sincronizada com a nuvem, para ter cópia fora da máquina);
# MILEBAG_BACKUP_DIAS (padrão 14) é por quantos dias os backups ficam guardados.
# Para voltar um backup: scripts/restaurar.sh.
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
AMBIENTE="${1:-}"
case "$AMBIENTE" in
  homologacao | producao) ;;
  *)
    echo "Uso: scripts/backup.sh homologacao|producao" >&2
    exit 2
    ;;
esac

ENV_ARQ="$RAIZ/ambientes/$AMBIENTE.env"
[ -f "$ENV_ARQ" ] || { echo "Ambiente '$AMBIENTE' ainda não implantado (falta ambientes/$AMBIENTE.env)." >&2; exit 1; }
BASE="${MILEBAG_BACKUP_DIR:-$RAIZ/data/backups}/$AMBIENTE"
DIAS="${MILEBAG_BACKUP_DIAS:-14}"

compose() {
  MILEBAG_FONTES="$RAIZ/build/$AMBIENTE" docker compose --env-file "$ENV_ARQ" -f "$RAIZ/ambientes/docker-compose.yml" "$@"
}

PASTA="$BASE/$(date +%Y-%m-%d_%H%M%S)"
mkdir -p "$PASTA.parcial"
cd "$PASTA.parcial"

# Formato custom (-Fc): comprimido e restaurável por objeto. Dono e permissões vêm junto, para o pg_restore recriar
# o banco igual (inclusive o usuário milebag_app sem superusuário, de que depende o isolamento entre empresas).
compose exec -T postgres pg_dump -U admin -d milebag -Fc >banco.dump
# Um dump truncado (disco cheio, contêiner caiu) não se lista: a conferência pega antes de dar o backup por bom.
compose exec -T postgres pg_restore --list <banco.dump >/dev/null

# O volume é lido por um contêiner descartável e sai pela saída padrão: nada de caminho do Windows no "docker -v".
# MSYS_NO_PATHCONV: no Git Bash do Windows, "/storage" viraria "C:/Program Files/Git/storage" (sem efeito no Linux).
MSYS_NO_PATHCONV=1 docker run --rm -v "milebag-${AMBIENTE}_storage:/storage:ro" postgres:16 tar -czf - -C /storage . >storage.tar.gz
tar -tzf storage.tar.gz >/dev/null

sha256sum banco.dump storage.tar.gz >SHA256SUMS
cd "$BASE"
mv "$PASTA.parcial" "$PASTA"

# Retenção: só pastas de backup com nome de data (as .parcial antigas também saem).
find "$BASE" -mindepth 1 -maxdepth 1 -type d -name '20[0-9][0-9]-*' -mtime "+$DIAS" -exec rm -rf {} +

echo "Backup de $AMBIENTE em $PASTA"
du -h "$PASTA"/banco.dump "$PASTA"/storage.tar.gz
