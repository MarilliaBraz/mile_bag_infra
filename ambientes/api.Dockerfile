# Imagem da mile_bag_api para homologação e produção. O contexto é o código exportado por scripts/implantar.sh
# (git archive da versão pedida), então a imagem nunca leva arquivo local que não foi commitado.

FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /fonte
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -q -B dependency:go-offline
COPY src ./src
# Os testes rodam no CI/na máquina de desenvolvimento (Testcontainers precisa de Docker, que não existe aqui dentro).
RUN --mount=type=cache,target=/root/.m2 mvn -q -B package -DskipTests && cp target/milebag-api-*.jar /fonte/app.jar

FROM eclipse-temurin:21-jre
# Tesseract nativo + idioma português para o OCR do BDO (Tess4J). O caminho dos dados de treino muda com a versão
# do pacote, então o link fixo /opt/tessdata é criado a partir de onde o por.traineddata foi instalado.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-por curl \
 && ln -s "$(dirname "$(find /usr/share/tesseract-ocr -name por.traineddata | head -n 1)")" /opt/tessdata \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 milebag \
 && mkdir -p /dados/storage && chown milebag /dados/storage
ENV MILEBAG_TESSDATA_PATH=/opt/tessdata
COPY --from=build /fonte/app.jar /app/app.jar
USER milebag
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=10 \
  CMD curl -s -o /dev/null http://localhost:8080/api/v1/auth/login || exit 1
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
