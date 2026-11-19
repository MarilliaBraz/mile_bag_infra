#!/bin/bash
# Backup diário do Milebag DENTRO da VPS (instalado em /opt/milebag/backup.sh por scripts/vps.sh e chamado pelo cron
# às 03:30). Grava o banco (pg_dump) e os arquivos enviados pelo app (fotos de BDO, comprovantes, logotipos) em
# /opt/milebag/backups/AAAA-MM-DD_HHMMSS/ e apaga os com mais de MILEBAG_BACKUP_DIAS dias (padrão 14).
# Uma pasta terminada em ".parcial" é um backup que falhou no meio e não vale.
# Para ter uma cópia fora do servidor: scripts/vps.sh backup (no seu computador) baixa todos.
set -euo pipefail

BASE=/opt/milebag/backups
DIAS="${MILEBAG_BACKUP_DIAS:-14}"
cd /opt/milebag

PASTA="$BASE/$(date +%Y-%m-%d_%H%M%S)"
mkdir -p "$PASTA.parcial"
docker compose -p milebag --env-file .env -f milebag-stack.yml -f milebag-vps.yml \
  exec -T postgres pg_dump -U admin -d milebag -Fc >"$PASTA.parcial/banco.dump"
# Um dump truncado não se lista: a conferência pega antes de dar o backup por bom.
docker run --rm -i milebag/postgres:16 pg_restore --list <"$PASTA.parcial/banco.dump" >/dev/null
docker run --rm -v milebag_storage:/storage:ro milebag/postgres:16 tar -czf - -C /storage . >"$PASTA.parcial/storage.tar.gz"
tar -tzf "$PASTA.parcial/storage.tar.gz" >/dev/null
(cd "$PASTA.parcial" && sha256sum banco.dump storage.tar.gz >SHA256SUMS)
mv "$PASTA.parcial" "$PASTA"

find "$BASE" -mindepth 1 -maxdepth 1 -type d -name '20[0-9][0-9]-*' -mtime "+$DIAS" -exec rm -rf {} +
echo "Backup em $PASTA"
