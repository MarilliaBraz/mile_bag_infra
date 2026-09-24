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

Sobe as dependências externas da API em contêineres. **Não** inclui proxy reverso nem TLS público — isso é da implantação de produção, ainda não escrita.

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

- **Bot do Telegram real.** Exige uma conta sua no Telegram: falar com `@BotFather`, `/newbot`, guardar o token, e expor a API por HTTPS público para o `setWebhook` (ex.: túnel). Depois preencha `MILEBAG_TELEGRAM_HABILITADO/BOT_TOKEN/BOT_USERNAME/WEBHOOK_SECRET`. Para desenvolvimento sem bot há `scripts/fake-telegram.cjs`, um servidor **falso** (não prova o comportamento do Telegram de verdade).
- **Certificado real do e-mail, DNS (MX/SPF/DKIM) e caixa BDO de produção** — o e-mail daqui só fala com `@milebag.local`; não entrega para a internet.

## Repositórios relacionados

- [`mile_bag_documentacao`](https://github.com/MarilliaBraz/mile_bag_documentacao) — documentação do projeto (TAP, escopo, sessões)
- [`mile_bag_api`](https://github.com/MarilliaBraz/mile_bag_api) — back-end (Java/Spring Boot)
- [`mile_bag_app`](https://github.com/MarilliaBraz/mile_bag_app) — front-end / aplicação do motorista
- [`mile_bag_audite`](https://github.com/MarilliaBraz/mile_bag_audite) — constituição e convenções técnicas do projeto
