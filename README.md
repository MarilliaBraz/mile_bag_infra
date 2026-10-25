# mile_bag_infra

Infraestrutura e implantação do **Milebag — Gestão de Última Milha de Bagagens**, aplicação SaaS multi-tenant para digitalizar a devolução de bagagens extraviadas no transporte aéreo brasileiro.

## Stack

- **Contêineres:** Docker Engine ou Podman, orquestrados via Compose
- **Proxy reverso:** Caddy ou Nginx
- **Certificado TLS:** Let's Encrypt (gratuito)
- **Banco de dados:** PostgreSQL com PostGIS
- **Hospedagem (piloto):** servidor próprio da empresa parceira, sem contratação de nuvem

## Escopo

Padronização de ambiente e implantação reprodutível, sem custo de infraestrutura no piloto (orçamento do projeto é R$ 0,00 — ver TAP em [`mile_bag_documentacao`](https://github.com/MarilliaBraz/mile_bag_documentacao)), com caminho de migração para escalonamento horizontal na eventual expansão comercial.

## Ambiente de desenvolvimento (`docker-compose.yml`)

Sobe as dependências externas da API em contêineres. **Não** inclui proxy reverso nem TLS público — isso fica nos ambientes de homologação e produção (seção abaixo).

| Serviço | Para quê | Porta no host |
|---|---|---|
| `postgres` | PostgreSQL 16 com duas contas: `admin` (Flyway/seed) e `milebag_app` (a API; sem superusuário nem `BYPASSRLS`, senão o isolamento por tenant deixa de valer) | 5433 |
| `valhalla` | Motor de rotas (HU03); constrói os tiles a partir de `valhalla/custom_files/*.pbf` | 8002 |
| `mail` | Postfix + Dovecot (docker-mailserver) — HU18 T003: envio SMTP e leitura IMAP das respostas dos passageiros | 2525 (SMTP), 5587 (submission), 9993 (IMAPS) |

Primeira vez:

```bash
scripts/gerar-certificado-mail.sh   # CA e certificado de DESENVOLVIMENTO do e-mail
docker compose up -d postgres mail
scripts/configurar-mail.sh          # contas noreply@, mensagens@, ana@, bruno@ (@milebag.local) e o alias catch-all
scripts/gerar-truststore.sh         # cacerts do JDK + a CA local, em data/truststore.jks
scripts/preparar-mapa.sh            # Goiás + faixas de MG, MT e MS que fazem divisa (Centro-Oeste ~200 MB + Sudeste ~860 MB, recortados e fundidos em ~200 MB)
docker compose up -d valhalla       # a 1ª subida constrói os tiles (minutos); /status responde quando pronto
```

As respostas do passageiro chegam em `entrega-{id}@mensagens.milebag.local`; o alias catch-all as entrega na caixa `mensagens@`, que a API lê por IMAP. Senhas de desenvolvimento (`milebag-dev-1234`, `admin`, `milebag_app`) — **nunca** usar fora daqui.

### Variáveis da API para usar tudo isso

```bash
MILEBAG_DB_URL=jdbc:postgresql://localhost:5433/milebag
MILEBAG_FLYWAY_USER=admin MILEBAG_FLYWAY_PASSWORD=admin
MILEBAG_VALHALLA_URL=http://localhost:8002
MILEBAG_SMTP_HABILITADO=true MILEBAG_SMTP_HOST=localhost MILEBAG_SMTP_PORT=5587
MILEBAG_SMTP_USUARIO=noreply@milebag.local MILEBAG_SMTP_SENHA=milebag-dev-1234 MILEBAG_SMTP_REMETENTE=noreply@milebag.local
MILEBAG_MENSAGERIA_IMAP_HABILITADO=true MILEBAG_MENSAGERIA_IMAP_HOST=localhost MILEBAG_MENSAGERIA_IMAP_PORT=9993
MILEBAG_MENSAGERIA_IMAP_USUARIO=mensagens@milebag.local MILEBAG_MENSAGERIA_IMAP_SENHA=milebag-dev-1234
MILEBAG_MENSAGERIA_IMAP_INTERVALO_MS=5000
# JVM (truststore com a CA local): -Djavax.net.ssl.trustStore=<repo>/data/truststore.jks -Djavax.net.ssl.trustStorePassword=changeit
```

### Mapa (Valhalla)

O padrão é **Goiás e as regiões que fazem divisa com Minas Gerais (Triângulo Mineiro), Mato Grosso (leste) e Mato Grosso do Sul (nordeste)**: `BBOX=-54.0,-20.3,-45.5,-12.2` sobre os extratos Centro-Oeste e Sudeste da Geofabrik. Tocantins e Bahia ficam **sem mapa** (não baixamos Norte/Nordeste), então rota que cruze para lá não existe. Para outra região: `BBOX="..." REGIOES="..." scripts/preparar-mapa.sh`, depois `scripts/limpar-tiles.sh` (apaga os tiles antigos; remova antes o `.pbf` que não vale mais) e `docker compose up -d valhalla`. A 1ª construção de tiles leva dezenas de minutos e ~6 GB de RAM.

### O que NÃO está provisionado

- **Bot do Telegram real.** Exige uma conta sua no Telegram. Passo a passo:
  1. No Telegram, converse com `@BotFather`, envie `/newbot`, escolha o nome e o username e **guarde o token**.
  2. Exponha a API por **HTTPS público** (o Telegram não chama `localhost`): em desenvolvimento, um túnel como `cloudflared tunnel --url http://localhost:8080` (ou `ngrok http 8080`); em produção, o domínio com TLS.
  3. `export MILEBAG_TELEGRAM_BOT_TOKEN=<token>` e `scripts/telegram-webhook.sh configurar https://<url-publica>` — valida o token, registra o webhook em `/api/v1/webhooks/telegram` com um segredo (gerado e mostrado uma vez, ou o de `MILEBAG_TELEGRAM_WEBHOOK_SECRET`) e imprime as variáveis da API.
  4. Suba a API com `MILEBAG_TELEGRAM_HABILITADO=true`, `..._BOT_TOKEN`, `..._BOT_USERNAME` e `..._WEBHOOK_SECRET` (o **mesmo** segredo: a API responde 401 ao webhook sem ele).
  5. `scripts/telegram-webhook.sh status` mostra a URL registrada e o último erro do Telegram; `remover` desfaz.
  O script foi testado só contra o servidor **falso** (`scripts/fake-telegram.cjs`, agora com `getMe`/`setWebhook`/`getWebhookInfo`/`deleteWebhook`); nada disso foi exercitado contra o Telegram de verdade. Para desenvolvimento sem bot há `scripts/fake-telegram.cjs`, um servidor **falso** (não prova o comportamento do Telegram de verdade).
- **Certificado real do e-mail, DNS (MX/SPF/DKIM) e caixa BDO de produção** — o e-mail daqui só fala com `@milebag.local`; não entrega para a internet.

## Ambientes de homologação e produção (`ambientes/` + `scripts/implantar.sh`)

Além do compose de desenvolvimento acima, há dois ambientes completos (banco, API e app web atrás do Caddy),
cada um um projeto Compose separado, com banco e arquivos próprios:

| Ambiente | Para quê | Versão aceita | Endereço padrão |
|---|---|---|---|
| **homologação** | validar uma mudança (branch/PR) antes do merge | qualquer branch, tag ou commit | http://localhost:8081 |
| **produção** | o que o usuário final usa | só `main` ou tag `vX.Y.Z`, já publicada na `origin/main` | http://localhost:8090 (ou o domínio, com HTTPS) |

```bash
scripts/implantar.sh homologacao feature/minha-mudanca     # app nessa branch, API na branch atual do mile_bag_api
scripts/implantar.sh homologacao feature/x feature/y       # versão do app e da API
scripts/implantar.sh producao                              # main dos dois repositórios
scripts/implantar.sh producao v0.2.0 v0.1.0                # tags
scripts/implantar.sh homologacao situacao                  # versão no ar e estado dos contêineres
scripts/implantar.sh homologacao parar                     # derruba (o banco fica no volume)
```

Fluxo de uma mudança: branch → PR → `implantar.sh homologacao <branch>` → validação → merge do PR na `main`
→ `implantar.sh producao`. Até o merge, a mudança existe **só** em homologação; o script recusa levar para
produção qualquer coisa que não seja a `main` (ou uma tag) já publicada no GitHub.

Como funciona:

- O código vem de `git archive` da versão pedida (só o que está commitado), exportado para `build/<ambiente>/`
  junto com `ambientes/api.Dockerfile`, `ambientes/app.Dockerfile` e `ambientes/Caddyfile`.
- O Caddy serve o app e encaminha `/api` para a API na mesma origem. Com `MILEBAG_SITE=<domínio>` e
  `MILEBAG_PORTA_HTTPS=443` ele obtém o certificado do Let's Encrypt sozinho.
- A configuração fica em `ambientes/<ambiente>.env` (fora do Git), criado a partir do `.env.example` na 1ª
  implantação; senhas do banco e segredo do JWT vazios são gerados aleatoriamente nessa hora.
- Homologação mostra uma faixa amarela "Ambiente de Homologação" com a versão implantada, liga a
  documentação da API em `/docs` e cria as contas de teste (`admin`, `empresa`, `motorista`, senha `12345678`).
  Por isso ela **nunca** deve ficar exposta à internet.
- Produção não tem contas de teste: a 1ª conta da plataforma é criada com
  `scripts/criar-admin-plataforma.sh producao <login>` (a senha é pedida no terminal e gravada só como hash).
- Os dois usam o Valhalla do compose de desenvolvimento (`MILEBAG_VALHALLA_URL`, padrão
  `http://host.docker.internal:8002`); e-mail e Telegram seguem desligados até serem provisionados. Os dois ligam
  pelas variáveis do `.env` do ambiente (`MILEBAG_TELEGRAM_*`, `MILEBAG_SMTP_*`, `MILEBAG_IMAP_*`,
  `MILEBAG_MENSAGERIA_*`; modelos nos `.env.example`). Em homologação, `MILEBAG_MAIL_DESENVOLVIMENTO=true` liga a API
  ao servidor de e-mail de desenvolvimento (`ambientes/docker-compose.mail-dev.yml`: nome `mail.milebag.local` e
  truststore com a CA local), que só entrega para `@milebag.local`.

## Repositórios relacionados

- [`mile_bag_documentacao`](https://github.com/MarilliaBraz/mile_bag_documentacao) — documentação do projeto (TAP, escopo, sessões)
- [`mile_bag_api`](https://github.com/MarilliaBraz/mile_bag_api) — back-end (Java/Spring Boot)
- [`mile_bag_app`](https://github.com/MarilliaBraz/mile_bag_app) — front-end / aplicação do motorista
- [`mile_bag_audite`](https://github.com/MarilliaBraz/mile_bag_audite) — constituição e convenções técnicas do projeto
