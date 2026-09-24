#!/bin/bash
# Cria as contas e o alias do servidor de e-mail (idempotente o bastante para
# dev: repetir só avisa que já existem). Senhas de desenvolvimento — em
# produção use segredos reais e não as publique.
set -uo pipefail

SENHA="${MILEBAG_MAIL_SENHA:-milebag-dev-1234}"
setup() { docker exec milebag-mail setup "$@"; }

setup email add noreply@milebag.local "$SENHA"      # remetente das mensagens da API (SMTP)
setup email add mensagens@milebag.local "$SENHA"    # caixa que a API lê por IMAP
setup email add ana@milebag.local "$SENHA"          # passageiros de teste
setup email add bruno@milebag.local "$SENHA"
# Toda resposta a entrega-{id}@mensagens.milebag.local cai na caixa "mensagens".
setup alias add @mensagens.milebag.local mensagens@milebag.local

docker exec milebag-mail postfix reload >/dev/null 2>&1 || true
docker exec milebag-mail setup email list
