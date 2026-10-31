#!/bin/bash
# Gera o pacote do Milebag para implantar numa stack do Portainer, sem código-fonte no servidor: só as imagens
# compiladas (docker save), a stack e o .env.
#
#   scripts/empacotar-portainer.sh [versao-app] [versao-api]   # padrão: main (só main ou tag vX.Y.Z, como produção)
#   scripts/empacotar-portainer.sh testar                      # sobe o pacote aqui na porta 8095, confere e derruba
#
# O pacote sai em build/portainer/pacote/:
#   milebag-api-<versao>.tar.gz, milebag-web-<versao>.tar.gz   a cada versão nova;
#   milebag-postgres-16.tar.gz, milebag-valhalla-<mapa>.tar.gz  só quando mudam (normalmente, uma vez só);
#   milebag-stack.yml e milebag.env                             a stack e as variáveis (com as senhas - não compartilhe).
#
# No Portainer: Images > Import (cada .tar.gz novo); Stacks > Add stack > Upload (milebag-stack.yml), "Load variables
# from .env file" (milebag.env) e Deploy. Nas versões seguintes: importe api e web, troque MILEBAG_TAG nas variáveis
# da stack e use "Update the stack". Os volumes (banco e arquivos) continuam.
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
REPOS="${MILEBAG_REPOS:-$RAIZ/..}"
AMBIENTE=portainer
ENV_ARQ="$RAIZ/ambientes/portainer.env"
FONTES="$RAIZ/build/portainer"
PACOTE="$FONTES/pacote"
# shellcheck source=comum.sh
. "$RAIZ/scripts/comum.sh"

# Globais (não "local"): o trap de saída roda depois que testar() já retornou e ainda precisa delas.
PORTA_TESTE=8095
PROJETO_TESTE=milebag-portainer-teste
teste() { MILEBAG_PORTA_HTTP=$PORTA_TESTE docker compose -p "$PROJETO_TESTE" --env-file "$PACOTE/milebag.env" -f "$PACOTE/milebag-stack.yml" "$@"; }

testar() {
  [ -f "$PACOTE/milebag.env" ] || { echo "Gere o pacote antes: scripts/empacotar-portainer.sh" >&2; exit 1; }
  local porta=$PORTA_TESTE projeto=$PROJETO_TESTE arquivo
  # O Portainer recebe os .tar.gz pela API do Docker, a mesma que o "docker load" usa.
  for arquivo in "$PACOTE"/milebag-*.tar.gz; do docker load -q -i "$arquivo"; done
  trap 'teste down -v >/dev/null 2>&1 || echo "Não consegui remover o teste: docker compose -p $PROJETO_TESTE down -v" >&2' EXIT
  teste up -d
  echo "Aguardando a API (até 3 minutos)..."
  local codigo=000 tentativa
  for tentativa in $(seq 1 36); do
    # Pedido de demonstração com o campo-armadilha preenchido: a API descarta e responde 204 sem enviar nada.
    codigo="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:$porta/api/v1/publico/demonstracao" \
      -H 'Content-Type: application/json' -d '{"site":"robo","preenchidoEmMs":1}' || true)"
    [ "$codigo" = 204 ] && break
    sleep 5
  done
  local pagina valhalla
  pagina="$(curl -s "http://localhost:$porta/" | grep -o '<title>[^<]*</title>' || true)"
  valhalla="$(docker inspect -f '{{.State.Health.Status}}' "$(teste ps -q valhalla)")"
  teste ps
  echo
  echo "página: ${pagina:-sem título} | API: $codigo (esperado 204) | Valhalla: $valhalla"
  [ "$codigo" = 204 ] && [ -n "$pagina" ] || { echo "Falhou: veja os logs com 'docker compose -p $projeto logs'" >&2; trap - EXIT; exit 1; }
  echo "Pacote OK. Ambiente de teste removido."
}

if [ "${1:-}" = testar ]; then
  testar
  exit 0
fi

if [ ! -f "$ENV_ARQ" ]; then
  cp "$RAIZ/ambientes/portainer.env.example" "$ENV_ARQ"
  echo "Criado ambientes/portainer.env a partir do modelo - revise os valores."
fi
preencher_segredo MILEBAG_PG_ADMIN_SENHA
preencher_segredo MILEBAG_PG_APP_SENHA
preencher_segredo MILEBAG_JWT_SECRET
gerar_chaves_push

VERSAO_APP="${1:-main}"
VERSAO_API="${2:-main}"
validar_producao mile_bag_app "$VERSAO_APP"
validar_producao mile_bag_api "$VERSAO_API"

MAPA="$RAIZ/valhalla/custom_files"
[ -f "$MAPA/valhalla_tiles.tar" ] || { echo "Falta o mapa: rode scripts/preparar-mapa.sh e suba o Valhalla uma vez." >&2; exit 1; }

echo "Exportando mile_bag_app@$VERSAO_APP e mile_bag_api@$VERSAO_API para build/portainer/ ..."
exportar mile_bag_app "$VERSAO_APP" "$FONTES/app"
exportar mile_bag_api "$VERSAO_API" "$FONTES/api"
cp "$RAIZ/ambientes/app.Dockerfile" "$FONTES/app/Dockerfile"
cp "$RAIZ/ambientes/Caddyfile" "$FONTES/app/Caddyfile"
cp "$RAIZ/ambientes/api.Dockerfile" "$FONTES/api/Dockerfile"

TAG="$(curto mile_bag_app "$VERSAO_APP")-$(curto mile_bag_api "$VERSAO_API")"
URL="$(grep -E '^MILEBAG_URL_PUBLICA=' "$ENV_ARQ" | cut -d= -f2-)"

docker build -t "milebag/api:$TAG" "$FONTES/api"
docker build -t "milebag/web:$TAG" \
  --build-arg VITE_API_BASE_URL="$URL" \
  --build-arg VITE_VERSAO="app $VERSAO_APP@$(curto mile_bag_app "$VERSAO_APP") · api $VERSAO_API@$(curto mile_bag_api "$VERSAO_API")" \
  "$FONTES/app"
docker build -t milebag/postgres:16 -f "$RAIZ/ambientes/portainer/postgres.Dockerfile" "$RAIZ/postgres"

# A imagem do Valhalla leva o nome do mapa (resumo do valhalla_tiles.tar): só muda quando o mapa muda.
TAG_VALHALLA="$(sha256sum "$MAPA/valhalla_tiles.tar" | cut -c1-12)"
if ! docker image inspect "milebag/valhalla:$TAG_VALHALLA" >/dev/null 2>&1; then
  rm -rf "$FONTES/valhalla"
  mkdir -p "$FONTES/valhalla"
  cp "$MAPA/valhalla.json" "$MAPA/valhalla_tiles.tar" "$FONTES/valhalla/"
  cp -r "$MAPA/admin_data" "$FONTES/valhalla/"
  docker build -t "milebag/valhalla:$TAG_VALHALLA" -f "$RAIZ/ambientes/portainer/valhalla.Dockerfile" "$FONTES/valhalla"
fi

mkdir -p "$PACOTE"
NOVOS=()
salvar() { # imagem arquivo
  if [ -f "$PACOTE/$2" ]; then
    echo "$2 já está no pacote (não precisa importar de novo)."
    return
  fi
  echo "Salvando $1 em $2 ..."
  docker save "$1" | gzip -1 >"$PACOTE/$2.parcial"
  mv "$PACOTE/$2.parcial" "$PACOTE/$2"
  NOVOS+=("$2")
}
salvar "milebag/api:$TAG" "milebag-api-$TAG.tar.gz"
salvar "milebag/web:$TAG" "milebag-web-$TAG.tar.gz"
salvar milebag/postgres:16 milebag-postgres-16.tar.gz
salvar "milebag/valhalla:$TAG_VALHALLA" "milebag-valhalla-$TAG_VALHALLA.tar.gz"

cp "$RAIZ/ambientes/portainer/milebag-stack.yml" "$PACOTE/"
{
  grep -vE '^\s*(#|$)' "$ENV_ARQ"
  echo "MILEBAG_TAG=$TAG"
  echo "MILEBAG_TAG_VALHALLA=$TAG_VALHALLA"
} >"$PACOTE/milebag.env"

echo
echo "Pacote em build/portainer/pacote/ (versão $TAG, mapa $TAG_VALHALLA)."
if [ ${#NOVOS[@]} -gt 0 ]; then
  echo "Importe no Portainer (Images > Import):"
  for arquivo in "${NOVOS[@]}"; do echo "  $arquivo ($(du -h "$PACOTE/$arquivo" | cut -f1))"; done
fi
echo "Stack: milebag-stack.yml + milebag.env (MILEBAG_TAG=$TAG). Teste antes com: scripts/empacotar-portainer.sh testar"
