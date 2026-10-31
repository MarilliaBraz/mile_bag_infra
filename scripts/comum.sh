#!/bin/bash
# Funções compartilhadas por scripts/implantar.sh e scripts/empacotar-portainer.sh (carregadas com "source").
# Usam as variáveis globais de quem as carrega:
#   ENV_ARQ  - o .env do ambiente (fora do Git), onde os segredos gerados são gravados;
#   AMBIENTE - nome do ambiente, só para as mensagens;
#   REPOS    - pasta com os repositórios mile_bag_app e mile_bag_api.

# Senhas e segredo vazios ganham um valor aleatório na 1ª implantação (e ficam no .env, fora do Git).
preencher_segredo() { # variavel
  if grep -qE "^$1=$" "$ENV_ARQ"; then
    local valor
    valor="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)"
    sed -i "s|^$1=$|$1=$valor|" "$ENV_ARQ"
    echo "Gerado $1 em ambientes/$AMBIENTE.env"
  fi
}

# Par VAPID do Web Push (HU32, aviso de BDO novo): curva P-256, as duas chaves em base64url (sem "="), no formato
# que a API e o navegador esperam - a privada são os 32 bytes do escalar, a pública o ponto não comprimido
# (65 bytes). Gerado uma única vez: trocar o par invalida as inscrições dos aparelhos já feitas.
gerar_chaves_push() {
  grep -qE '^MILEBAG_PUSH_CHAVE_PRIVADA=.+' "$ENV_ARQ" && return
  command -v openssl >/dev/null || { echo "Sem openssl: o Web Push fica desligado (MILEBAG_PUSH_* vazias)." >&2; return; }
  local pem base64url publica privada
  pem="$(openssl ecparam -name prime256v1 -genkey -noout)"
  base64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
  privada="$(printf '%s\n' "$pem" | openssl ec -outform DER 2>/dev/null | tail -c +8 | head -c 32 | base64url)"
  publica="$(printf '%s\n' "$pem" | openssl ec -pubout -outform DER 2>/dev/null | tail -c 65 | base64url)"
  sed -i '/^MILEBAG_PUSH_CHAVE_\(PUBLICA\|PRIVADA\)=/d' "$ENV_ARQ"
  printf '\n# Web Push (HU32) - gerado por implantar.sh; nao troque sem necessidade.\nMILEBAG_PUSH_CHAVE_PUBLICA=%s\nMILEBAG_PUSH_CHAVE_PRIVADA=%s\n' "$publica" "$privada" >>"$ENV_ARQ"
  echo "Gerado o par VAPID (MILEBAG_PUSH_CHAVE_*) em ambientes/$AMBIENTE.env"
}

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

# O código vem de "git archive" (só o que está commitado), nunca da pasta de trabalho.
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

curto() { git -C "$REPOS/$1" rev-parse --short "$2^{commit}"; }
