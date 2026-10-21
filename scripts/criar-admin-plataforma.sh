#!/bin/bash
# Cria a conta do administrador da PLATAFORMA num ambiente implantado por scripts/implantar.sh.
#
#   scripts/criar-admin-plataforma.sh producao marillia
#
# Em produção não há contas de teste (a API só as cria com o segredo de JWT de desenvolvimento), então a primeira
# conta da plataforma nasce aqui; as empresas e os administradores delas vêm depois, pelo próprio app (convite).
# A senha é pedida no terminal (não aparece nem fica no histórico) e gravada só como hash BCrypt, o mesmo
# formato do PasswordEncoder da API.
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
AMBIENTE="${1:?Uso: scripts/criar-admin-plataforma.sh homologacao|producao <login>}"
LOGIN="${2:?Informe o login da conta}"
ENV_ARQ="$RAIZ/ambientes/$AMBIENTE.env"
[ -f "$ENV_ARQ" ] || { echo "Ambiente '$AMBIENTE' ainda não implantado (falta ambientes/$AMBIENTE.env)." >&2; exit 1; }

read -rsp "Senha para '$LOGIN' (mínimo 8 caracteres): " SENHA
echo
[ "${#SENHA}" -ge 8 ] || { echo "A senha precisa ter pelo menos 8 caracteres." >&2; exit 1; }
read -rsp "Repita a senha: " CONFIRMACAO
echo
[ "$SENHA" = "$CONFIRMACAO" ] || { echo "As senhas não conferem." >&2; exit 1; }

HASH="$(docker run --rm httpd:2-alpine htpasswd -nbBC 10 "" "$SENHA" | tr -d ':\r\n')"

MILEBAG_FONTES="$RAIZ/build/$AMBIENTE" docker compose --env-file "$ENV_ARQ" -f "$RAIZ/ambientes/docker-compose.yml" \
  exec -T postgres psql -v ON_ERROR_STOP=1 -U admin -d milebag -v login="$LOGIN" -v hash="$HASH" <<'SQL'
INSERT INTO usuario_plataforma (id, login, senha_hash, criado_em)
VALUES (gen_random_uuid(), :'login', :'hash', now());
SQL
echo "Conta '$LOGIN' criada. Entre pelo app com ela."
