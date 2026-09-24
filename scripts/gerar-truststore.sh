#!/bin/bash
# O servidor de e-mail de desenvolvimento usa certificado assinado por uma CA
# local (gerar-certificado-mail.sh). A API (JavaMail) só confia nele se a CA
# estiver no truststore da JVM — mas trocar o truststore por um só com essa CA
# quebraria o HTTPS público (Nominatim). Então: copia o cacerts do JDK e
# importa a CA nele.
# Uso na API: -Djavax.net.ssl.trustStore=<caminho> -Djavax.net.ssl.trustStorePassword=changeit
set -euo pipefail
cd "$(dirname "$0")/.."

command -v keytool >/dev/null || { echo "keytool nao encontrado (instale o JDK)"; exit 1; }
JAVA_HOME_GUESS="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v keytool)")")")}"
CACERTS="${CACERTS:-$JAVA_HOME_GUESS/lib/security/cacerts}"
[ -f mail/config/ssl/demoCA/cacert.pem ] || { echo "Rode antes scripts/gerar-certificado-mail.sh"; exit 1; }

mkdir -p data
cp "$CACERTS" data/truststore.jks
chmod u+w data/truststore.jks
keytool -importcert -noprompt -alias milebag-dev-ca -file mail/config/ssl/demoCA/cacert.pem -keystore data/truststore.jks -storepass changeit
echo "Truststore em data/truststore.jks"
