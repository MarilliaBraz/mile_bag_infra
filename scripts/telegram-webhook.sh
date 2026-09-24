#!/bin/bash
# Configura o webhook do bot do Telegram (HU18) depois que o bot existe.
#
# O bot em si so voce cria: no Telegram, converse com @BotFather, envie /newbot, escolha nome e username e guarde o
# TOKEN. Este script cuida do resto da configuracao (validar o token, registrar o webhook com o segredo, conferir).
#
#   export MILEBAG_TELEGRAM_BOT_TOKEN=123456:ABC...      # do @BotFather
#   scripts/telegram-webhook.sh configurar https://api.seudominio.com.br
#   scripts/telegram-webhook.sh status
#   scripts/telegram-webhook.sh remover
#
# A URL tem que ser HTTPS PUBLICO (o Telegram nao chama localhost). Em desenvolvimento, um tunel resolve, por exemplo:
#   cloudflared tunnel --url http://localhost:8080      (ou: ngrok http 8080)
# e a URL https://....trycloudflare.com que ele imprimir e a que entra aqui.
#
# O segredo do webhook vem de MILEBAG_TELEGRAM_WEBHOOK_SECRET; se nao existir, o script gera um e o mostra UMA vez -
# a API precisa subir com esse MESMO valor (ela recusa, com 401, chamadas sem o cabecalho certo).
#
# TELEGRAM_API_URL so serve para testar este script contra o servidor falso (scripts/fake-telegram.cjs).
set -euo pipefail

API="${TELEGRAM_API_URL:-https://api.telegram.org}"
: "${MILEBAG_TELEGRAM_BOT_TOKEN:?Defina MILEBAG_TELEGRAM_BOT_TOKEN (token do @BotFather)}"
BOT="$API/bot$MILEBAG_TELEGRAM_BOT_TOKEN"
CAMINHO_WEBHOOK="/api/v1/webhooks/telegram"

chamar() { # metodo [corpo-json]
  if [ -n "${2:-}" ]; then
    curl -fsS -X POST -H "Content-Type: application/json" -d "$2" "$BOT/$1"
  else
    curl -fsS "$BOT/$1"
  fi
}

# Extrai um campo do JSON sem depender de jq (node ja e requisito do projeto).
campo() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);const v=process.argv[1].split(".").reduce((a,k)=>a==null?a:a[k],j);console.log(v===undefined?"":v)})' "$1"; }

comando="${1:-}"
case "$comando" in
  configurar)
    BASE="${2:?Informe a URL publica HTTPS, ex.: https://api.seudominio.com.br}"
    case "$BASE" in https://*) ;; *) echo "A URL precisa ser https:// (o Telegram so chama HTTPS)."; exit 1 ;; esac
    BASE="${BASE%/}"

    eu=$(chamar getMe)
    [ "$(echo "$eu" | campo ok)" = "true" ] || { echo "Token recusado pelo Telegram."; exit 1; }
    USUARIO=$(echo "$eu" | campo result.username)
    echo "Bot validado: @$USUARIO"

    SEGREDO="${MILEBAG_TELEGRAM_WEBHOOK_SECRET:-}"
    GEROU=0
    if [ -z "$SEGREDO" ]; then
      SEGREDO="$(openssl rand -hex 24)"
      GEROU=1
    fi

    resposta=$(chamar setWebhook "{\"url\":\"$BASE$CAMINHO_WEBHOOK\",\"secret_token\":\"$SEGREDO\",\"allowed_updates\":[\"message\"]}")
    [ "$(echo "$resposta" | campo ok)" = "true" ] || { echo "setWebhook falhou: $resposta"; exit 1; }
    echo "Webhook registrado em $BASE$CAMINHO_WEBHOOK"

    echo
    echo "Suba a API com estas variaveis (guarde o segredo; ele so foi mostrado agora):"
    echo "  MILEBAG_TELEGRAM_HABILITADO=true"
    echo "  MILEBAG_TELEGRAM_BOT_USERNAME=$USUARIO"
    echo "  MILEBAG_TELEGRAM_BOT_TOKEN=<o mesmo token>"
    if [ "$GEROU" = 1 ]; then
      echo "  MILEBAG_TELEGRAM_WEBHOOK_SECRET=$SEGREDO"
    else
      echo "  MILEBAG_TELEGRAM_WEBHOOK_SECRET=<o mesmo segredo que voce informou>"
    fi
    ;;
  status)
    info=$(chamar getWebhookInfo)
    echo "URL registrada:      $(echo "$info" | campo result.url)"
    echo "Atualizacoes na fila: $(echo "$info" | campo result.pending_update_count)"
    erro=$(echo "$info" | campo result.last_error_message)
    [ -n "$erro" ] && echo "Ultimo erro do Telegram: $erro"
    exit 0
    ;;
  remover)
    chamar deleteWebhook >/dev/null
    echo "Webhook removido."
    ;;
  *)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
