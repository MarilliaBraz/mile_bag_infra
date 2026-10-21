# Imagem do mile_bag_app (back-office + PWA do motorista) servida pelo Caddy, que também encaminha /api para a
# mile_bag_api: navegador, app e API ficam na mesma origem. O contexto é o código exportado por scripts/implantar.sh.

FROM node:22-alpine AS build
WORKDIR /fonte
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
# Variáveis do Vite entram no build (o resultado é estático): endereço da API, nome do ambiente e versão.
ARG VITE_API_BASE_URL
ARG VITE_AMBIENTE=""
ARG VITE_VERSAO=""
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL VITE_AMBIENTE=$VITE_AMBIENTE VITE_VERSAO=$VITE_VERSAO
RUN npm run build

FROM caddy:2-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /fonte/dist /srv
