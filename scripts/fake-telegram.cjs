// SERVIDOR FALSO da Bot API do Telegram, só para desenvolvimento: não prova
// nada sobre o Telegram de verdade (entrega, limites, formatação). Serve para
// exercitar o caminho HTTP de envio da API sem um bot real.
//
//   node scripts/fake-telegram.cjs            # porta 8081
//   MILEBAG_TELEGRAM_API_URL=http://localhost:8081 MILEBAG_TELEGRAM_HABILITADO=true \
//   MILEBAG_TELEGRAM_BOT_TOKEN=123:fake MILEBAG_TELEGRAM_BOT_USERNAME=milebag_fake_bot \
//   MILEBAG_TELEGRAM_WEBHOOK_SECRET=segredo-dev  (na API)
//
// GET /_enviadas devolve o que a API mandou por sendMessage.
const http = require("http");
const enviadas = [];

http
  .createServer((req, res) => {
    let corpo = "";
    req.on("data", (d) => (corpo += d));
    req.on("end", () => {
      if (req.method === "GET" && req.url === "/_enviadas") {
        res.setHeader("Content-Type", "application/json");
        return res.end(JSON.stringify(enviadas));
      }
      const m = req.url.match(/^\/bot([^/]+)\/sendMessage$/);
      if (req.method === "POST" && m) {
        const dados = JSON.parse(corpo || "{}");
        enviadas.push({ token: m[1], ...dados, em: new Date().toISOString() });
        console.log("sendMessage", JSON.stringify(dados));
        res.setHeader("Content-Type", "application/json");
        return res.end(JSON.stringify({ ok: true, result: { message_id: enviadas.length } }));
      }
      res.statusCode = 404;
      res.end("{}");
    });
  })
  .listen(8081, () => console.log("fake Telegram em http://localhost:8081"));
