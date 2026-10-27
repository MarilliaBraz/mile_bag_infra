#!/bin/bash
# Implanta uma versão exata do Milebag (mile_bag_api + mile_bag_app) em HOMOLOGAÇÃO ou PRODUÇÃO.
#
#   scripts/implantar.sh homologacao [versao-app] [versao-api]   # padrão: a branch atual de cada repositório
#   scripts/implantar.sh producao    [versao-app] [versao-api]   # padrão: main
#   scripts/implantar.sh <ambiente> parar                        # derruba os contêineres (os dados ficam)
#   scripts/implantar.sh <ambiente> situacao                     # o que está no ar e em qual versão
#
# "versao" é qualquer referência do Git: branch, tag ou commit.
#
# Regra de promoção (o motivo de existirem dois ambientes):
#   - homologação aceita QUALQUER versão: é onde uma mudança de branch/PR é validada antes do merge;
#   - produção só aceita a main ou uma tag vX.Y.Z, e só se ela já tiver sido publicada no GitHub (origin):
#     o que não passou por PR e merge não chega ao usuário final.
#
# O código vem de "git archive" (só o que está commitado), nunca da pasta de trabalho, e a versão de cada
# repositório fica gravada em build/<ambiente>/VERSAO e aparece no app (faixa de homologação).
# Os repositórios são procurados ao lado deste (../mile_bag_app, ../mile_bag_api); MILEBAG_REPOS muda isso.
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
REPOS="${MILEBAG_REPOS:-$RAIZ/..}"
AMBIENTE="${1:-}"

case "$AMBIENTE" in
  homologacao | producao) ;;
  *)
    echo "Uso: scripts/implantar.sh homologacao|producao [versao-app|parar|situacao] [versao-api]" >&2
    exit 2
    ;;
esac

ENV_ARQ="$RAIZ/ambientes/$AMBIENTE.env"
FONTES="$RAIZ/build/$AMBIENTE"

if [ ! -f "$ENV_ARQ" ]; then
  cp "$RAIZ/ambientes/$AMBIENTE.env.example" "$ENV_ARQ"
  echo "Criado ambientes/$AMBIENTE.env a partir do modelo - revise os valores."
fi

# Senhas e segredo vazios ganham um valor aleatório na 1ª implantação (e ficam no .env, fora do Git).
preencher_segredo() { # variavel
  if grep -qE "^$1=$" "$ENV_ARQ"; then
    local valor
    valor="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)"
    sed -i "s|^$1=$|$1=$valor|" "$ENV_ARQ"
    echo "Gerado $1 em ambientes/$AMBIENTE.env"
  fi
}
preencher_segredo MILEBAG_PG_ADMIN_SENHA
preencher_segredo MILEBAG_PG_APP_SENHA
preencher_segredo MILEBAG_JWT_SECRET

compose() {
  local arquivos=(-f "$RAIZ/ambientes/docker-compose.yml")
  if grep -qE '^MILEBAG_PORTA_HTTPS=[0-9]+' "$ENV_ARQ"; then
    arquivos+=(-f "$RAIZ/ambientes/docker-compose.tls.yml")
  fi
  if grep -qE '^MILEBAG_MAIL_DESENVOLVIMENTO=true' "$ENV_ARQ"; then
    [ "$AMBIENTE" = producao ] && { echo "MILEBAG_MAIL_DESENVOLVIMENTO não vale em produção." >&2; exit 1; }
    [ -f "$RAIZ/data/truststore.jks" ] || { echo "Falta data/truststore.jks: rode scripts/gerar-truststore.sh." >&2; exit 1; }
    arquivos+=(-f "$RAIZ/ambientes/docker-compose.mail-dev.yml")
  fi
  MILEBAG_FONTES="$FONTES" docker compose --env-file "$ENV_ARQ" "${arquivos[@]}" "$@"
}

case "${2:-}" in
  parar)
    compose down
    exit 0
    ;;
  situacao)
    [ -f "$FONTES/VERSAO" ] && cat "$FONTES/VERSAO"
    compose ps
    exit 0
    ;;
esac

if [ "$AMBIENTE" = producao ]; then
  PADRAO_APP=main
  PADRAO_API=main
else
  PADRAO_APP="$(git -C "$REPOS/mile_bag_app" rev-parse --abbrev-ref HEAD)"
  PADRAO_API="$(git -C "$REPOS/mile_bag_api" rev-parse --abbrev-ref HEAD)"
fi
VERSAO_APP="${2:-$PADRAO_APP}"
VERSAO_API="${3:-$PADRAO_API}"

# Produção: só main ou tag vX.Y.Z, e o commit tem que existir no origin (já passou por PR/merge e foi publicado).
validar_producao() { # repositorio versao
  local repo="$REPOS/$1" versao="$2"
  if [[ "$versao" != main && ! "$versao" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Produção só recebe a main ou uma tag vX.Y.Z ($1: '$versao'). Valide antes em homologação e faça o merge do PR." >&2
    exit 1
  fi
  git -C "$repo" fetch --quiet --tags origin
  local commit
  commit="$(git -C "$repo" rev-parse "$versao^{commit}")"
  if [ "$versao" = main ] && [ "$commit" != "$(git -C "$repo" rev-parse origin/main)" ]; then
    echo "$1: a main local difere da origin/main. Atualize (git pull) ou publique (PR) antes de implantar em produção." >&2
    exit 1
  fi
  if ! git -C "$repo" branch -r --contains "$commit" | grep -q 'origin/main'; then
    echo "$1: o commit de '$versao' não está na origin/main." >&2
    exit 1
  fi
}

if [ "$AMBIENTE" = producao ]; then
  validar_producao mile_bag_app "$VERSAO_APP"
  validar_producao mile_bag_api "$VERSAO_API"
fi

exportar() { # repositorio versao destino
  local repo="$REPOS/$1"
  git -C "$repo" rev-parse --verify --quiet "$2^{commit}" >/dev/null || {
    echo "$1: versão '$2' não encontrada." >&2
    exit 1
  }
  rm -rf "$3"
  mkdir -p "$3"
  git -C "$repo" archive "$2" | tar -x -C "$3"
}

echo "Exportando mile_bag_app@$VERSAO_APP e mile_bag_api@$VERSAO_API para build/$AMBIENTE/ ..."
exportar mile_bag_app "$VERSAO_APP" "$FONTES/app"
exportar mile_bag_api "$VERSAO_API" "$FONTES/api"
cp "$RAIZ/ambientes/app.Dockerfile" "$FONTES/app/Dockerfile"
cp "$RAIZ/ambientes/Caddyfile" "$FONTES/app/Caddyfile"
cp "$RAIZ/ambientes/api.Dockerfile" "$FONTES/api/Dockerfile"

curto() { git -C "$REPOS/$1" rev-parse --short "$2^{commit}"; }
export MILEBAG_VERSAO="app $VERSAO_APP@$(curto mile_bag_app "$VERSAO_APP") · api $VERSAO_API@$(curto mile_bag_api "$VERSAO_API")"
{
  echo "ambiente: $AMBIENTE"
  echo "implantado em: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "mile_bag_app: $VERSAO_APP ($(git -C "$REPOS/mile_bag_app" rev-parse "$VERSAO_APP^{commit}"))"
  echo "mile_bag_api: $VERSAO_API ($(git -C "$REPOS/mile_bag_api" rev-parse "$VERSAO_API^{commit}"))"
} >"$FONTES/VERSAO"

compose up -d --build --remove-orphans

URL="$(grep -E '^MILEBAG_URL_PUBLICA=' "$ENV_ARQ" | cut -d= -f2-)"
echo
cat "$FONTES/VERSAO"
echo "No ar em $URL (a API leva cerca de um minuto para terminar de subir; acompanhe com: scripts/implantar.sh $AMBIENTE situacao)."
