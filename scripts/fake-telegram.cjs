// SERVIDOR FALSO da Bot API do Telegram, so para desenvolvimento: nao prova nada sobre o Telegram de verdade
// (entrega, limites, formatacao). Serve para exercitar o caminho HTTP de envio da API e o script
// scripts/telegram-webhook.sh sem um bot real.
//
//   node scripts/fake-telegram.cjs            # porta 8081
//   MILEBAG_TELEGRAM_API_URL=http://localhost:8081 MILEBAG_TELEGRAM_HABILITADO=true \
//   MILEBAG_TELEGRAM_BOT_TOKEN=123:fake MILEBAG_TELEGRAM_BOT_USERNAME=milebag_fake_bot \
//   MILEBAG_TELEGRAM_WEBHOOK_SECRET=segredo-dev  (na API)
//
// GET /_enviadas devolve o que a API mandou por sendMessage; GET /_webhook devolve o ultimo setWebhook recebido.
const http = require("http");
const enviadas = [];
let webhook = { url: "", secret_token: null };

const resposta = (res, corpo, status = 200) => {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(corpo));
};

http
  .createServer((req, res) => {
    let corpo = "";
    req.on("data", (d) => (corpo += d));
    req.on("end", () => {
      if (req.method === "GET" && req.url === "/_enviadas") return resposta(res, enviadas);
      if (req.method === "GET" && req.url === "/_webhook") return resposta(res, webhook);
      const m = req.url.match(/^\/bot([^/]+)\/(\w+)$/);
      if (!m) return resposta(res, {}, 404);
      const [, token, metodo] = m;
      const dados = corpo ? JSON.parse(corpo) : {};
      switch (metodo) {
        case "sendMessage":
          enviadas.push({ token, ...dados, em: new Date().toISOString() });
          console.log("sendMessage", JSON.stringify(dados));
          return resposta(res, { ok: true, result: { message_id: enviadas.length } });
        case "getMe":
          return resposta(res, { ok: true, result: { id: 1, is_bot: true, first_name: "Milebag Fake", username: "milebag_fake_bot" } });
        case "setWebhook":
          webhook = { url: dados.url, secret_token: dados.secret_token ?? null, allowed_updates: dados.allowed_updates ?? null };
          console.log("setWebhook", dados.url);
          return resposta(res, { ok: true, result: true, description: "Webhook was set" });
        case "getWebhookInfo":
          return resposta(res, { ok: true, result: { url: webhook.url, pending_update_count: 0 } });
        case "deleteWebhook":
          webhook = { url: "", secret_token: null };
          return resposta(res, { ok: true, result: true });
        default:
          return resposta(res, { ok: false, description: "metodo nao suportado pelo servidor falso" }, 404);
      }
    });
  })
  .listen(8081, () => console.log("fake Telegram em http://localhost:8081"));
