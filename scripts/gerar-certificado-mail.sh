#!/bin/bash
# Gera a CA e o certificado do servidor de e-mail de DESENVOLVIMENTO (o
# docker-mailserver em SSL_TYPE=self-signed exige esses arquivos prontos).
# Produção usa certificado real (Let's Encrypt) — este aqui não serve para lá.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="mail.milebag.local"
DESTINO="mail/config/ssl"
mkdir -p "$DESTINO/demoCA"

openssl_docker() {
  docker run --rm --entrypoint openssl -v "$PWD/$DESTINO:/ssl" -w /ssl ghcr.io/docker-mailserver/docker-mailserver:latest "$@"
}

openssl_docker req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=Milebag Dev CA" \
  -keyout demoCA/cakey.pem -out demoCA/cacert.pem
openssl_docker req -newkey rsa:2048 -nodes -subj "/CN=$HOST" -keyout "$HOST-key.pem" -out "$HOST.csr"
printf "subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\n" "$HOST" > "$DESTINO/san.ext"
openssl_docker x509 -req -in "$HOST.csr" -CA demoCA/cacert.pem -CAkey demoCA/cakey.pem -CAcreateserial \
  -days 825 -extfile san.ext -out "$HOST-cert.pem"
rm -f "$DESTINO/$HOST.csr" "$DESTINO/san.ext"
echo "Certificado gerado em $DESTINO"
