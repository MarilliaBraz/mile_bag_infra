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

## Repositórios relacionados

- [`mile_bag_documentacao`](https://github.com/MarilliaBraz/mile_bag_documentacao) — documentação do projeto (TAP, escopo, sessões)
- [`mile_bag_api`](https://github.com/MarilliaBraz/mile_bag_api) — back-end (Java/Spring Boot)
- [`mile_bag_app`](https://github.com/MarilliaBraz/mile_bag_app) — front-end / aplicação do motorista
- [`mile_bag_audite`](https://github.com/MarilliaBraz/mile_bag_audite) — constituição e convenções técnicas do projeto
