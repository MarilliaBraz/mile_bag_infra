// Porta de entrada SÓ do webhook do Telegram, para expor por um túnel (cloudflared) sem publicar o resto do ambiente.
// Homologação nunca pode ficar exposta (contas de teste, segredo de JWT de desenvolvimento): este filtro repassa
// apenas POST /api/v1/webhooks/telegram ao ambiente e responde 404 a qualquer outra coisa.
//
//   node scripts/filtro-webhook-telegram.cjs                      # escuta 8092, repassa para http://localhost:8081
//   FILTRO_PORTA=8092 FILTRO_DESTINO=http://localhost:8081 node scripts/filtro-webhook-telegram.cjs
//   cloudflared tunnel --url http://localhost:8092                 # a URL https://....trycloudflare.com vai para
//   scripts/telegram-webhook.sh configurar <essa URL>
const http = require("http");

const PORTA = Number(process.env.FILTRO_PORTA ?? 8092);
const DESTINO = new URL(process.env.FILTRO_DESTINO ?? "http://localhost:8081");
const CAMINHO = "/api/v1/webhooks/telegram";
const LIMITE_BYTES = 1024 * 1024;

http
  .createServer((req, res) => {
    if (req.method !== "POST" || req.url !== CAMINHO) {
      res.statusCode = 404;
      return res.end();
    }
    const cabecalhos = { "content-type": "application/json" };
    const segredo = req.headers["x-telegram-bot-api-secret-token"];
    if (segredo) cabecalhos["x-telegram-bot-api-secret-token"] = segredo;

    let tamanho = 0;
    const partes = [];
    req.on("data", (parte) => {
      tamanho += parte.length;
      if (tamanho > LIMITE_BYTES) {
        res.statusCode = 413;
        res.end();
        req.destroy();
        return;
      }
      partes.push(parte);
    });
    req.on("end", () => {
      if (res.writableEnded) return;
      const corpo = Buffer.concat(partes);
      const repasse = http.request(
        { hostname: DESTINO.hostname, port: DESTINO.port, path: CAMINHO, method: "POST", headers: { ...cabecalhos, "content-length": corpo.length } },
        (resposta) => {
          res.statusCode = resposta.statusCode ?? 502;
          resposta.resume();
          resposta.on("end", () => res.end());
          console.log(new Date().toISOString(), "webhook ->", res.statusCode);
        },
      );
      repasse.on("error", (erro) => {
        console.error(new Date().toISOString(), "falha ao repassar:", erro.message);
        res.statusCode = 502;
        res.end();
      });
      repasse.end(corpo);
    });
  })
  .listen(PORTA, () => console.log(`filtro do webhook do Telegram em http://localhost:${PORTA} -> ${DESTINO.origin}${CAMINHO}`));
