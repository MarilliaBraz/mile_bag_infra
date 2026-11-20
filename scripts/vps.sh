#!/bin/bash
# Implanta o Milebag numa VPS própria (Ubuntu 24.04 com root), rodando do SEU computador por SSH. Sem Portainer e
# sem código-fonte no servidor: vão só as imagens prontas (as mesmas do pacote do Portainer), a stack e o .env.
#
#   scripts/vps.sh preparar              # 1ª vez: chave SSH, Docker, firewall, swap, backup diário; fecha login por senha
#   scripts/vps.sh subir [tag]           # envia as imagens que faltam e sobe (ou atualiza) o Milebag
#   scripts/vps.sh criar-admin <login>   # 1ª vez: conta do administrador da plataforma (pede a senha)
#   scripts/vps.sh dns                   # confere se o domínio já aponta para a VPS
#   scripts/vps.sh zona <servidor-dns>   # antes de trocar o DNS de provedor: confere a zona nova contra a atual
#   scripts/vps.sh telegram              # registra o webhook do bot (depois que o HTTPS estiver no ar)
#   scripts/vps.sh situacao              # contêineres, memória e disco
#   scripts/vps.sh logs [serviço]        # acompanha os logs (api, web, postgres, valhalla)
#   scripts/vps.sh backup                # faz um backup agora e baixa todos para data/backups/vps/
#   scripts/vps.sh entrar                # abre um terminal no servidor
#   scripts/vps.sh homolog <comando>     # o mesmo na HOMOLOGAÇÃO (subir, criar-admin, dns, situacao, logs, entrar)
#
# A configuração fica em ambientes/vps.env (fora do Git), criada na 1ª vez a partir de ambientes/portainer.env (mesmas
# senhas, token do Telegram e chaves de push). Preencha nela MILEBAG_VPS=root@<IP da VPS>.
#
# A homologação roda na mesma VPS, em homolog.<domínio>, com banco e segredos próprios (ambientes/vps-homolog.env,
# criado na 1ª vez) e sem Telegram nem e-mail, que são da produção. Toda versão passa por ela antes: a produção só
# aceita a tag que está na homologação.
#
# "tag" é a versão das imagens, no formato <commit do app>-<commit da api> (ex.: 9be1a96-599f3ff). Sem ela, vale a
# última usada (gravada no .env do ambiente) ou, na 1ª vez, a da main. As imagens são geradas por
# scripts/empacotar-portainer.sh, que só aceita a main publicada: atualizar é "merge do PR -> empacotar-portainer.sh
# -> vps.sh homolog subir <tag nova> -> conferir em homolog.<domínio> -> vps.sh subir <tag nova>".
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
REPOS="${MILEBAG_REPOS:-$RAIZ/..}"
ENV_PRODUCAO="${MILEBAG_VPS_ENV:-$RAIZ/ambientes/vps.env}"
ENV_HOMOLOG="${MILEBAG_VPS_HOMOLOG_ENV:-$RAIZ/ambientes/vps-homolog.env}"
# Rede do Docker que liga o Caddy da produção (dono das portas 80/443) ao web da homologação.
REDE_BORDA=milebag-borda
COMPOSE_PRODUCAO="docker compose -p milebag --env-file .env -f milebag-stack.yml -f milebag-vps.yml"
DESTINO_PRODUCAO=/opt/milebag
if [ "${1:-}" = homolog ]; then
  shift
  HOMOLOG=1
  # shellcheck disable=SC2034 # AMBIENTE é usado nas mensagens de comum.sh
  AMBIENTE=vps-homolog
  ENV_ARQ="$ENV_HOMOLOG"
  DESTINO=/opt/milebag-homolog
  EXTRA=milebag-vps-homolog.yml
  COMPOSE="docker compose -p milebag-homolog --env-file .env -f milebag-stack.yml -f $EXTRA"
else
  HOMOLOG=0
  # shellcheck disable=SC2034
  AMBIENTE=vps
  ENV_ARQ="$ENV_PRODUCAO"
  DESTINO="$DESTINO_PRODUCAO"
  EXTRA=milebag-vps.yml
  COMPOSE="$COMPOSE_PRODUCAO"
fi
CHAVE="$HOME/.ssh/id_ed25519"
# accept-new: na 1ª conexão grava a identidade do servidor sem perguntar; depois disso, uma identidade diferente
# (servidor trocado ou ataque) faz o SSH recusar a conexão.
SSH_OPCOES=(-i "$CHAVE" -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o "ControlPath=${XDG_RUNTIME_DIR:-$HOME/.ssh}/milebag-%C"
  -o ControlPersist=120 -o ServerAliveInterval=30)

# shellcheck source=comum.sh
. "$RAIZ/scripts/comum.sh"

falhar() { echo "$*" >&2; exit 1; }

# Valor de uma variável num .env (vazio se o arquivo ou a variável não existir).
valor_em() { # arquivo variavel
  [ -f "$1" ] || return 0
  { grep -E "^$2=" "$1" || true; } | tail -n1 | cut -d= -f2-
}

# Valor de uma variável do .env do ambiente em uso.
valor() { valor_em "$ENV_ARQ" "$1"; }

gravar() { # variavel valor
  if grep -qE "^$1=" "$ENV_ARQ"; then
    sed -i "s|^$1=.*|$1=$2|" "$ENV_ARQ"
  else
    echo "$1=$2" >>"$ENV_ARQ"
  fi
}

criar_env() {
  [ -f "$ENV_ARQ" ] && return
  if [ "$HOMOLOG" = 1 ]; then
    criar_env_homolog
    return
  fi
  local base="$RAIZ/ambientes/portainer.env"
  [ -f "$base" ] || base="$RAIZ/ambientes/portainer.env.example"
  (umask 077 && grep -vE '^MILEBAG_PORTA_HTTP=' "$base" >"$ENV_ARQ")
  cat >>"$ENV_ARQ" <<'EOF'

# --- VPS (scripts/vps.sh) ---
# Acesso SSH ao servidor: root@<IP da VPS>. A porta só precisa ser preenchida se não for a 22.
MILEBAG_VPS=
MILEBAG_VPS_PORTA=
# Domínio principal (o Caddy tira o certificado dele) e o domínio sem www, que redireciona para o principal.
MILEBAG_SITE=www.milebag.com.br
MILEBAG_DOMINIO_SEM_WWW=milebag.com.br
MILEBAG_PORTA_HTTP=80
EOF
  echo "Criado ambientes/vps.env a partir de $(basename "$base")."
}

# A homologação usa o servidor da produção, mas banco, segredos e chaves de push próprios (gerados em seguida).
# Telegram e e-mail ficam desligados: o bot só tem um webhook, e a caixa de mensagens lida pela produção não pode
# ser consumida por outra API.
criar_env_homolog() {
  local dominio
  [ -f "$ENV_PRODUCAO" ] || falhar "Configure antes a produção (ambientes/vps.env): a homologação roda no mesmo servidor."
  dominio="$(valor_em "$ENV_PRODUCAO" MILEBAG_DOMINIO_SEM_WWW)"
  [ -n "$dominio" ] || falhar "Preencha MILEBAG_DOMINIO_SEM_WWW em ambientes/vps.env (a homologação fica em homolog.<domínio>)."
  (umask 077 && cat >"$ENV_ARQ" <<EOF
# Homologação na VPS (scripts/vps.sh homolog ...): mesmo servidor da produção, banco e segredos próprios.
MILEBAG_VPS=$(valor_em "$ENV_PRODUCAO" MILEBAG_VPS)
MILEBAG_VPS_PORTA=$(valor_em "$ENV_PRODUCAO" MILEBAG_VPS_PORTA)
MILEBAG_SITE=homolog.$dominio
MILEBAG_URL_PUBLICA=https://homolog.$dominio
# Faixa no topo do app avisando que não é produção.
MILEBAG_AMBIENTE_ROTULO=Homologação
# Exigida pela stack, mas sem efeito: a homologação não publica porta (o Caddy da produção encaminha para ela).
MILEBAG_PORTA_HTTP=80
MILEBAG_PG_ADMIN_SENHA=
MILEBAG_PG_APP_SENHA=
MILEBAG_JWT_SECRET=
MILEBAG_NOMINATIM_USER_AGENT=$(valor_em "$ENV_PRODUCAO" MILEBAG_NOMINATIM_USER_AGENT)
MILEBAG_PUSH_ASSUNTO=$(valor_em "$ENV_PRODUCAO" MILEBAG_PUSH_ASSUNTO)
MILEBAG_TELEGRAM_HABILITADO=false
MILEBAG_SMTP_HABILITADO=false
MILEBAG_IMAP_HABILITADO=false
MILEBAG_MENSAGERIA_IMAP_HABILITADO=false
EOF
  )
  echo "Criado ambientes/vps-homolog.env (homolog.$dominio)."
}

# Regra do projeto: nada vai para a produção sem ter passado pela homologação.
exigir_homologada() {
  [ "$HOMOLOG" = 0 ] || return 0
  local tag_homolog
  tag_homolog="$(valor_em "$ENV_HOMOLOG" MILEBAG_TAG)"
  [ "$TAG" = "$tag_homolog" ] ||
    falhar "A versão $TAG não está na homologação (lá está: ${tag_homolog:-nenhuma}). Rode antes: scripts/vps.sh homolog subir $TAG"
}

exigir_vps() {
  VPS="$(valor MILEBAG_VPS)"
  [ -n "$VPS" ] || { echo "Preencha MILEBAG_VPS=root@<IP da VPS> em ambientes/vps.env e rode de novo." >&2; exit 1; }
  local porta
  porta="$(valor MILEBAG_VPS_PORTA)"
  [ -z "$porta" ] || SSH_OPCOES+=(-p "$porta")
  mkdir -p "$HOME/.ssh"
}

exigir_conexao() {
  ssh "${SSH_OPCOES[@]}" -o ConnectTimeout=15 "$VPS" true 2>/dev/null ||
    { echo "Sem conexão SSH com $VPS. Rode antes: scripts/vps.sh preparar (e confira o IP no vps.env)." >&2; exit 1; }
}

remoto() { ssh "${SSH_OPCOES[@]}" "$VPS" "$@"; }

# --- preparar -------------------------------------------------------------------------------------------------

garantir_chave() {
  if [ ! -f "$CHAVE.pub" ]; then
    echo "Criando a sua chave SSH ($CHAVE). Pode deixar a frase-senha em branco ou criar uma."
    ssh-keygen -t ed25519 -C milebag-vps -f "$CHAVE"
  fi
  if ! ssh "${SSH_OPCOES[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$VPS" true 2>/dev/null; then
    echo "Instalando a chave no servidor: digite a senha de root que a KingHost enviou (só desta vez)."
    ssh-copy-id -i "$CHAVE.pub" "${SSH_OPCOES[@]:2}" "$VPS"
  fi
  ssh "${SSH_OPCOES[@]}" -o BatchMode=yes "$VPS" true ||
    { echo "A entrada por chave não funcionou; nada foi alterado no servidor." >&2; exit 1; }
}

preparar() {
  garantir_chave
  remoto 'bash -s' <"$RAIZ/ambientes/vps/preparar-servidor.sh"
  remoto "cat >$DESTINO/backup.sh && chmod 700 $DESTINO/backup.sh" <"$RAIZ/ambientes/vps/backup-servidor.sh"
  # A chave já entrou (conferido acima): fecha a entrada por senha, alvo comum de robôs. O console web do painel
  # da KingHost continua aceitando a senha de root, se um dia precisar.
  remoto "printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n' \
    >/etc/ssh/sshd_config.d/00-milebag.conf && mkdir -p /run/sshd && sshd -t && systemctl reload ssh"
  echo "VPS preparada. Próximo passo: scripts/vps.sh subir"
}

# --- subir ----------------------------------------------------------------------------------------------------

resolver_tags() { # [tag]
  TAG="${1:-$(valor MILEBAG_TAG)}"
  if [ -z "$TAG" ]; then
    git -C "$REPOS/mile_bag_app" fetch --quiet origin && git -C "$REPOS/mile_bag_api" fetch --quiet origin
    TAG="$(curto mile_bag_app origin/main)-$(curto mile_bag_api origin/main)"
  fi
  TAG_VALHALLA="$(valor MILEBAG_TAG_VALHALLA)"
  [ -n "$TAG_VALHALLA" ] || TAG_VALHALLA="$(docker images milebag/valhalla --format '{{.Tag}}' | head -n1)"
  local imagem
  for imagem in "milebag/api:$TAG" "milebag/web:$TAG" milebag/postgres:16 "milebag/valhalla:$TAG_VALHALLA"; do
    docker image inspect "$imagem" >/dev/null 2>&1 ||
      { echo "Falta a imagem $imagem neste computador. Gere com: scripts/empacotar-portainer.sh" >&2; exit 1; }
  done
}

# Cada imagem é identificada pelo nome e pela data de criação (que o docker save/load preserva): só vai o que mudou.
enviar_imagem() { # imagem
  local aqui la
  aqui="$(docker image inspect -f '{{.Created}}' "$1")"
  la="$(remoto "docker image inspect -f '{{.Created}}' $1 2>/dev/null" || true)"
  if [ "$aqui" = "$la" ]; then
    echo "  $1: já está no servidor."
    return
  fi
  echo "  $1: enviando ($(docker image inspect -f '{{.Size}}' "$1" | awk '{printf "%d MB", $1/1048576}') antes de comprimir) ..."
  docker save "$1" | gzip -1 | remoto 'gunzip | docker load -q'
}

gerar_arquivos() { # pasta
  # .env do servidor: o vps.env sem as variáveis que só servem a este script, mais as versões das imagens.
  grep -vE '^\s*(#|$)|^MILEBAG_(VPS|VPS_PORTA|DOMINIO_SEM_WWW|TAG|TAG_VALHALLA)=' "$ENV_ARQ" >"$1/.env"
  printf 'MILEBAG_TAG=%s\nMILEBAG_TAG_VALHALLA=%s\n' "$TAG" "$TAG_VALHALLA" >>"$1/.env"
  cp "$RAIZ/ambientes/portainer/milebag-stack.yml" "$RAIZ/ambientes/vps/$EXTRA" "$1/"
  # A homologação usa o Caddyfile da própria imagem (só HTTP); o da produção é o que tem os domínios públicos.
  [ "$HOMOLOG" = 0 ] || return 0
  cp "$RAIZ/ambientes/Caddyfile" "$1/Caddyfile"
  local sem_www site_homolog
  sem_www="$(valor MILEBAG_DOMINIO_SEM_WWW)"
  if [ -n "$sem_www" ]; then
    printf '\n# Gerado por scripts/vps.sh: o domínio sem www vai para o principal.\n%s {\n\tredir https://%s{uri} permanent\n}\n' \
      "$sem_www" "$(valor MILEBAG_SITE)" >>"$1/Caddyfile"
  fi
  site_homolog="$(valor_em "$ENV_HOMOLOG" MILEBAG_SITE)"
  if [ -n "$site_homolog" ]; then
    printf '\n# Gerado por scripts/vps.sh: a homologação, na mesma VPS (rede %s), fora dos buscadores.\n%s {\n\theader X-Robots-Tag "noindex, nofollow"\n\treverse_proxy milebag-homolog-web:80\n}\n' \
      "$REDE_BORDA" "$site_homolog" >>"$1/Caddyfile"
  fi
}

esperar_saude() {
  echo "Esperando os serviços ficarem saudáveis (a API leva cerca de 1 minuto e meio) ..."
  local tentativa estado=""
  for tentativa in $(seq 1 60); do
    estado="$(remoto "cd $DESTINO && for s in postgres valhalla api; do \
      printf '%s=%s ' \$s \$(docker inspect -f '{{.State.Health.Status}}' \$($COMPOSE ps -q \$s) 2>/dev/null || echo parado); done")"
    if [ "$estado" = "postgres=healthy valhalla=healthy api=healthy " ]; then
      echo "Tudo saudável."
      return
    fi
    [ $((tentativa % 6)) -eq 0 ] && echo "  $estado"
    sleep 5
  done
  echo "Algum serviço não ficou saudável em 5 minutos: $estado" >&2
  echo "Veja com: scripts/vps.sh logs api" >&2
  exit 1
}

subir() { # [tag]
  exigir_conexao
  resolver_tags "${1:-}"
  exigir_homologada
  echo "Versão $TAG (mapa $TAG_VALHALLA) para $VPS ($AMBIENTE)"
  local imagem
  for imagem in milebag/postgres:16 "milebag/valhalla:$TAG_VALHALLA" "milebag/api:$TAG" "milebag/web:$TAG"; do
    enviar_imagem "$imagem"
  done

  local pasta caddy_antes caddy_depois
  pasta="$(mktemp -d)"
  gerar_arquivos "$pasta"
  caddy_antes="$(remoto "sha256sum $DESTINO/Caddyfile 2>/dev/null" || true)"
  (cd "$pasta" && tar -cf - .env ./*) |
    remoto "mkdir -p $DESTINO && tar -C $DESTINO --no-same-owner -xf - && chmod 600 $DESTINO/.env && \
      chmod 644 $DESTINO/milebag-stack.yml $DESTINO/$EXTRA && { [ ! -f $DESTINO/Caddyfile ] || chmod 644 $DESTINO/Caddyfile; }"
  rm -r "$pasta"

  remoto "docker network inspect $REDE_BORDA >/dev/null 2>&1 || docker network create $REDE_BORDA >/dev/null"
  remoto "cd $DESTINO && $COMPOSE up -d --remove-orphans"
  # O Docker não percebe mudança num arquivo montado: se só o Caddyfile mudou, o web precisa reiniciar para lê-lo.
  if [ "$HOMOLOG" = 0 ]; then
    caddy_depois="$(remoto "sha256sum $DESTINO/Caddyfile")"
    if [ -n "$caddy_antes" ] && [ "$caddy_antes" != "$caddy_depois" ]; then
      remoto "cd $DESTINO && $COMPOSE restart web"
    fi
  fi
  gravar MILEBAG_TAG "$TAG"
  gravar MILEBAG_TAG_VALHALLA "$TAG_VALHALLA"
  esperar_saude
  conferir_dns || true
}

# --- domínio --------------------------------------------------------------------------------------------------

conferir_dns() {
  local ip host apontado pendente=0
  ip="$(remoto 'curl -4 -fsS --max-time 10 https://api.ipify.org' 2>/dev/null || echo "${VPS#*@}")"
  for host in "$(valor MILEBAG_SITE)" "$(valor MILEBAG_DOMINIO_SEM_WWW)"; do
    [ -n "$host" ] || continue
    apontado="$(dig +short "$host" A | tail -n1)"
    if [ "$apontado" = "$ip" ]; then
      echo "  $host -> $ip (certo)"
    else
      echo "  $host -> ${apontado:-nada} (precisa ser $ip)"
      pendente=1
    fi
  done
  if [ "$pendente" -eq 0 ]; then
    conferir_https
  else
    echo "O DNS ainda não aponta para $ip (a mudança leva até 1 hora; veja o guia). O HTTPS sai sozinho depois."
  fi
  return "$pendente"
}

# O Caddy pede o certificado assim que sobe e, se o domínio ainda não apontava para cá, tenta de novo com intervalos
# cada vez maiores. Reiniciar o web faz a nova tentativa na hora.
conferir_https() {
  local site
  site="$(valor MILEBAG_SITE)"
  if curl -fsS -o /dev/null --max-time 15 "https://$site"; then
    echo "HTTPS no ar: https://$site"
    return
  fi
  echo "Domínio apontado, mas o HTTPS ainda não respondeu. Reiniciando o web para pedir o certificado agora ..."
  # O certificado (também o da homologação) é tirado pelo Caddy da produção.
  remoto "cd $DESTINO_PRODUCAO && $COMPOSE_PRODUCAO restart web" >/dev/null
  echo "Espere 1 minuto e rode de novo: scripts/vps.sh dns"
}

# --- outros ---------------------------------------------------------------------------------------------------

criar_admin() { # login
  local login="${1:?Uso: scripts/vps.sh criar-admin <login>}" senha confirmacao hash
  [[ "$login" =~ ^[a-z0-9._-]{3,40}$ ]] || { echo "Login: só letras minúsculas, números, ponto, - e _." >&2; exit 1; }
  read -rsp "Senha para '$login' (mínimo 8 caracteres): " senha
  echo
  [ "${#senha}" -ge 8 ] || { echo "A senha precisa ter pelo menos 8 caracteres." >&2; exit 1; }
  read -rsp "Repita a senha: " confirmacao
  echo
  [ "$senha" = "$confirmacao" ] || { echo "As senhas não conferem." >&2; exit 1; }
  # Hash BCrypt calculado aqui (mesmo formato do PasswordEncoder da API): a senha não sai deste computador.
  hash="$(docker run --rm httpd:2-alpine htpasswd -nbBC 10 "" "$senha" | tr -d ':\r\n')"
  printf "INSERT INTO usuario_plataforma (id, login, senha_hash, criado_em) VALUES (gen_random_uuid(), '%s', '%s', now());\n" \
    "$login" "$hash" | remoto "cd $DESTINO && $COMPOSE exec -T postgres psql -q -v ON_ERROR_STOP=1 -U admin -d milebag"
  echo "Conta '$login' criada. Entre em https://$(valor MILEBAG_SITE) com ela."
}

telegram() {
  MILEBAG_TELEGRAM_BOT_TOKEN="$(valor MILEBAG_TELEGRAM_BOT_TOKEN)" \
    MILEBAG_TELEGRAM_WEBHOOK_SECRET="$(valor MILEBAG_TELEGRAM_WEBHOOK_SECRET)" \
    "$RAIZ/scripts/telegram-webhook.sh" configurar "https://$(valor MILEBAG_SITE)"
}

backup() {
  remoto "$DESTINO/backup.sh"
  mkdir -p "$RAIZ/data/backups/vps" && chmod 700 "$RAIZ/data/backups/vps"
  rsync -a --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= -e "ssh ${SSH_OPCOES[*]}" "$VPS:$DESTINO/backups/" "$RAIZ/data/backups/vps/"
  echo "Cópia local em data/backups/vps/"
}

# Respostas de um servidor DNS normalizadas para comparar provedores: TXT longos (DKIM) vêm partidos em pedaços de
# tamanhos diferentes em cada provedor, e a prioridade do MX não importa para o Google (só há um servidor).
consultar() {
  dig +short +norecurse "@$1" "$2" "$3" | sed -e 's/" "//g' -e 's/^[0-9]* \(.*\)/\1/' -e 's/\.$//' | sort
}

# Compara a zona já montada no provedor novo com a que está no ar, ANTES de trocar os servidores DNS no Registro.br.
# O site deve apontar para a VPS; e-mail (MX, SPF, verificação e DKIM do Google) deve ser idêntico ao atual.
conferir_zona() {
  local novo="${1:-}" atual="${MILEBAG_DNS_ATUAL:-d.sec.dns.br}" dominio site ip nome tipo esperado obtido falhas=0
  [ -n "$novo" ] || falhar "Uso: scripts/vps.sh zona <servidor DNS do provedor novo, ex.: dns1.kinghost.com.br>"
  dominio="$(valor MILEBAG_DOMINIO_SEM_WWW)"
  site="$(valor MILEBAG_SITE)"
  ip="$(remoto 'curl -4 -fsS --max-time 10 https://api.ipify.org' 2>/dev/null || echo "${VPS#*@}")"
  [ -n "$(consultar "$novo" "$dominio" SOA)" ] || falhar "$novo não responde pela zona $dominio. A zona já foi criada no painel?"
  for nome in "$dominio" "$site"; do
    obtido="$(consultar "$novo" "$nome" A | paste -sd' ')"
    if [ "$obtido" = "$ip" ]; then echo "  ok      A    $nome -> $ip"; else
      echo "  ERRADO  A    $nome -> ${obtido:-nada} (precisa ser $ip)"; falhas=1; fi
  done
  for par in "$dominio MX" "$dominio TXT" "google._domainkey.$dominio TXT" "_dmarc.$dominio TXT"; do
    read -r nome tipo <<<"$par"
    esperado="$(consultar "$atual" "$nome" "$tipo")"
    obtido="$(consultar "$novo" "$nome" "$tipo")"
    [ -z "$esperado" ] && [ -z "$obtido" ] && continue
    if [ "$esperado" = "$obtido" ]; then printf "  ok      %-4s %s\n" "$tipo" "$nome"; else
      printf "  ERRADO  %-4s %s\n" "$tipo" "$nome"
      diff <(echo "$esperado") <(echo "$obtido") | sed -n 's/^< /          falta: /p; s/^> /          sobra: /p' | cut -c1-110
      falhas=1
    fi
  done
  if [ "$falhas" -eq 0 ]; then
    echo "Zona completa em $novo. Pode trocar os servidores DNS no Registro.br."
  else
    echo "NÃO troque os servidores DNS ainda: corrija no painel o que está ERRADO e rode de novo."
  fi
  return "$falhas"
}

comando="${1:-}"
[ $# -gt 0 ] && shift
if [ "$HOMOLOG" = 1 ]; then
  case "$comando" in
    preparar | zona | telegram | backup)
      falhar "'$comando' só existe para a produção (o servidor, o DNS, o bot e o backup diário são os dela)." ;;
  esac
fi
case "$comando" in
  preparar | subir | criar-admin | dns | zona | telegram | situacao | logs | backup | entrar)
    criar_env
    preencher_segredo MILEBAG_PG_ADMIN_SENHA
    preencher_segredo MILEBAG_PG_APP_SENHA
    preencher_segredo MILEBAG_JWT_SECRET
    gerar_chaves_push
    exigir_vps
    ;;
  *)
    sed -n '4,15p' "$0" >&2
    exit 2
    ;;
esac
case "$comando" in
  preparar) preparar ;;
  subir) subir "${1:-}" ;;
  criar-admin) criar_admin "${1:-}" ;;
  dns) conferir_dns ;;
  zona) conferir_zona "${1:-}" ;;
  telegram) telegram ;;
  situacao) remoto "cd $DESTINO && $COMPOSE ps && echo && free -h && df -h /" ;;
  logs) ssh -t "${SSH_OPCOES[@]}" "$VPS" "cd $DESTINO && $COMPOSE logs -f --tail 200 ${1:-}" ;;
  backup) backup ;;
  entrar) ssh "${SSH_OPCOES[@]}" "$VPS" ;;
esac
