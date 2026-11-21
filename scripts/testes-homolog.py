#!/usr/bin/env python3
"""Testes de ponta a ponta na HOMOLOGAÇÃO: dispensa da entrega (V46) e cancelamento do BDO pela empresa (V47).

Uso (antes de levar uma versão da homologação para a produção):
    python3 scripts/testes-homolog.py

- Roda só na empresa "teste-automatizado" da homologação. As credenciais NÃO ficam no repositório: vêm de
  ~/.config/milebag-testes/homolog.env (ou do arquivo em $MILEBAG_TESTES_ENV), com MILEBAG_TESTE_URL,
  MILEBAG_TESTE_ADMIN_LOGIN/SENHA e MILEBAG_TESTE_MOTORISTA{1,2}_LOGIN/SENHA.
- Recusa qualquer endereço que não seja o da homologação (MILEBAG_URL_PUBLICA de ambientes/vps-homolog.env).
- Rota sempre "própria": não chama os serviços de mapa (que a produção divide com a homologação na mesma VPS).
- O banco da homologação é só LIDO por SSH (servidor de MILEBAG_VPS em ambientes/vps-homolog.env): código do link do
  passageiro, trajeto e volume do plano.
- Cada execução cria BDOs novos nessa empresa; nada é apagado. Sai com código 1 se alguma verificação falhar.
"""
import json
import os
import struct
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
import zlib

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def ler_env(caminho):
    valores = {}
    for linha in open(caminho, encoding="utf-8"):
        if "=" in linha and not linha.lstrip().startswith("#"):
            k, v = linha.strip().split("=", 1)
            valores[k] = v
    return valores


CFG = ler_env(os.environ.get("MILEBAG_TESTES_ENV", os.path.expanduser("~/.config/milebag-testes/homolog.env")))
HOMOLOG = ler_env(os.path.join(RAIZ, "ambientes", "vps-homolog.env"))
URL = CFG["MILEBAG_TESTE_URL"]
if not HOMOLOG.get("MILEBAG_URL_PUBLICA") or URL != HOMOLOG["MILEBAG_URL_PUBLICA"]:
    sys.exit(f"Recusado: {URL} não é a homologação ({HOMOLOG.get('MILEBAG_URL_PUBLICA')}). Estes testes nunca rodam na produção.")
VPS = HOMOLOG.get("MILEBAG_VPS") or ler_env(os.path.join(RAIZ, "ambientes", "vps.env")).get("MILEBAG_VPS")

resultados = []


def req(metodo, caminho, token=None, corpo=None, multipart=None):
    cabecalhos = {}
    dados = None
    if token:
        cabecalhos["Authorization"] = "Bearer " + token
    if corpo is not None:
        dados = json.dumps(corpo).encode()
        cabecalhos["Content-Type"] = "application/json"
    if multipart is not None:
        fronteira = uuid.uuid4().hex
        nome, conteudo = multipart
        dados = (f"--{fronteira}\r\nContent-Disposition: form-data; name=\"imagem\"; filename=\"{nome}\"\r\n"
                 f"Content-Type: image/png\r\n\r\n").encode() + conteudo + f"\r\n--{fronteira}--\r\n".encode()
        cabecalhos["Content-Type"] = "multipart/form-data; boundary=" + fronteira
    r = urllib.request.Request(URL + caminho, data=dados, method=metodo, headers=cabecalhos)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            txt = resp.read().decode() or "null"
            return resp.status, json.loads(txt)
    except urllib.error.HTTPError as e:
        txt = e.read().decode()
        try:
            return e.code, json.loads(txt)
        except ValueError:
            return e.code, txt


def sql(consulta):
    cmd = ["ssh", "-o", "ConnectTimeout=15", VPS,
           f"docker exec milebag-homolog-postgres-1 psql -U admin -d milebag -At -c \"{consulta}\""]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout.strip()


def checar(nome, condicao, detalhe=""):
    resultados.append((nome, bool(condicao), detalhe))
    print(("OK   " if condicao else "FALHA") + " " + nome + ("" if condicao else f"  -> {detalhe}"))


def msg(corpo):
    return corpo.get("detail") if isinstance(corpo, dict) else str(corpo)


def login(chave):
    s, c = req("POST", "/api/v1/auth/login", corpo={"login": CFG[chave + "_LOGIN"], "senha": CFG[chave + "_SENHA"]})
    assert s == 200, (chave, s, c)
    return c["token"]


def png():
    linha = b"\x00" + b"\xff" * 30
    bruto = zlib.compress(linha * 10)
    def bloco(tipo, dados):
        return struct.pack(">I", len(dados)) + tipo + dados + struct.pack(">I", zlib.crc32(tipo + dados) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + bloco(b"IHDR", struct.pack(">IIBBBBB", 10, 10, 8, 2, 0, 0, 0)) + bloco(b"IDAT", bruto) + bloco(b"IEND", b"")


def novo_bdo(token_motorista, rotulo):
    s, bdo = req("POST", "/api/v1/bdos", token_motorista, multipart=("bdo.png", png()))
    assert s == 201, (s, bdo)
    numero = "TST" + uuid.uuid4().hex[:7].upper()
    campos = {"numero": numero, "passageiroNome": f"Passageiro {rotulo}", "enderecoEntrega": "Av. Goiás, 100, Goiânia - GO",
              "companhiaAerea": "LA", "telefonePassageiro": "62999990000", "emailPassageiro": None, "etiquetaBagagem": "LA123456"}
    s, bdo = req("PATCH", f"/api/v1/bdos/{bdo['id']}/conferencia", token_motorista, corpo=campos)
    assert s == 200, (s, bdo)
    return bdo["id"], numero


def assumir(token, bdo_id):
    s, e = req("POST", f"/api/v1/entregas/{bdo_id}/autoatribuir", token)
    return s, e


def sair_em_rota(token, entrega_id):
    s, c = req("POST", f"/api/v1/entregas/{entrega_id}/rotas/selecionar", token, corpo={
        "tipoSelecao": "PROPRIA", "alternativaId": None, "justificativa": "teste automatizado",
        "tracadoManual": [{"latitude": -16.632, "longitude": -49.221}, {"latitude": -16.686, "longitude": -49.264}]})
    assert s == 200, ("rota", s, c)
    s, c = req("POST", f"/api/v1/entregas/{entrega_id}/viagem/iniciar", token, corpo={"lat": -16.632, "lng": -49.221})
    assert s in (200, 201), ("iniciar", s, c)


def disponiveis(token):
    return [b["bdoId"] for b in req("GET", "/api/v1/motorista/bdos-disponiveis", token)[1]["bdos"]]


def motivos(token, finalidade):
    return req("GET", f"/api/v1/configuracoes/motivos-ocorrencia?finalidade={finalidade}", token)[1]


def historico(token_admin, entrega_id):
    return [e["tipo"] for e in req("GET", f"/api/v1/gestao/entregas/{entrega_id}/historico", token_admin)[1]["eventos"]]


def uso_plano(bdo_qualquer):
    return int(sql("SELECT count(*) FROM bdo b WHERE status_conferencia='CONFIRMADO' "
                   "AND date_trunc('month', data_captura)=date_trunc('month', now()) "
                   f"AND tenant_id=(SELECT tenant_id FROM bdo WHERE id='{bdo_qualquer}') "
                   "AND NOT EXISTS (SELECT 1 FROM cancelamento_bdo x WHERE x.bdo_id=b.id)"))


def main():
    adm = login("MILEBAG_TESTE_ADMIN")
    m1 = login("MILEBAG_TESTE_MOTORISTA1")
    m2 = login("MILEBAG_TESTE_MOTORISTA2")
    CANCELADA = "A empresa cancelou esta entrega."

    mot_dispensa = motivos(m1, "DISPENSA")
    mot_cancel = motivos(adm, "CANCELAMENTO")
    checar("empresa nova tem 4 motivos de dispensa e 4 de cancelamento", len(mot_dispensa) == 4 and len(mot_cancel) == 4,
           f"{len(mot_dispensa)} / {len(mot_cancel)}")

    print("\n--- Item 1: dispensa ---")
    a, _ = novo_bdo(m1, "A")
    s, ent = assumir(m1, a)
    checar("motorista 1 assume o BDO A", s in (200, 201), (s, ent))
    ea = ent["id"]
    det = req("GET", f"/api/v1/entregas/{ea}/detalhe", m1)[1]
    checar("antes de sair, dispensa não exige motivo", det.get("motivoDispensaObrigatorio") is False, det)
    s, c = req("POST", f"/api/v1/entregas/{ea}/dispensas", m1, corpo={})
    checar("dispensa sem motivo antes de sair é aceita", s == 201, (s, c))
    checar("BDO A volta para os disponíveis do motorista 2", a in disponiveis(m2))
    checar("histórico tem a dispensa sem bagagem", "DISPENSA_SEM_BAGAGEM" in historico(adm, ea), historico(adm, ea))

    b, _ = novo_bdo(m1, "B")
    eb = assumir(m1, b)[1]["id"]
    sair_em_rota(m1, eb)
    s, c = req("POST", f"/api/v1/entregas/{eb}/dispensas", m1, corpo={})
    checar("em rota, dispensa sem motivo é recusada (400)", s == 400, (s, c))
    s, c = req("POST", f"/api/v1/entregas/{eb}/dispensas", m1, corpo={"motivoId": mot_dispensa[0]["id"], "complemento": "pneu furado"})
    checar("em rota, dispensa com motivo é aceita e marca 'com bagagem'", s == 201 and c.get("comBagagem") is True, (s, c))
    traj = sql(f"SELECT status, dispensa_id IS NOT NULL FROM trajeto WHERE entrega_id = '{eb}'")
    checar("viagem dispensada fica encerrada e vinculada à dispensa (entra no pagamento)", traj == "ENCERRADO|t", traj)
    s, c = assumir(m2, b)
    checar("motorista 2 assume a nova tentativa", s in (200, 201), (s, c))
    s, c = req("POST", f"/api/v1/entregas/{eb}/dispensas", m2, corpo={})
    checar("nova tentativa: dispensa sem motivo é recusada", s == 400, (s, c))
    s, c = req("POST", f"/api/v1/entregas/{eb}/dispensas", m1, corpo={"motivoId": mot_dispensa[0]["id"]})
    checar("motorista 1 não dispensa entrega do motorista 2 (409)", s == 409, (s, c))

    print("\n--- Item 2: cancelamento ---")
    s, c = req("POST", f"/api/v1/gestao/bdos/{b}/cancelamento", m2, corpo={"motivoId": mot_cancel[0]["id"]})
    checar("motorista não consegue cancelar BDO (403)", s == 403, (s, c))

    cbdo, _ = novo_bdo(m1, "C")
    linhas = req("GET", "/api/v1/gestao/entregas", adm)[1]
    linha_c = next((l for l in linhas if l["bdoId"] == cbdo), None)
    checar("tela Entregas mostra BDO que ninguém assumiu (sem entrega)", linha_c and linha_c["entregaId"] is None
           and linha_c["status"] == "AGUARDANDO_ATRIBUICAO", linha_c)
    uso_antes = uso_plano(cbdo)
    s, c = req("POST", f"/api/v1/gestao/bdos/{cbdo}/cancelamento", adm, corpo={"complemento": "sem motivo"})
    checar("cancelar sem motivo é recusado (400)", s == 400, (s, c))
    s, c = req("POST", f"/api/v1/gestao/bdos/{cbdo}/cancelamento", adm, corpo={"motivoId": mot_dispensa[0]["id"]})
    checar("motivo de dispensa não serve para cancelar (404)", s == 404, (s, c))
    s, c = req("POST", f"/api/v1/gestao/bdos/{cbdo}/cancelamento", adm, corpo={"motivoId": mot_cancel[0]["id"], "complemento": "teste"})
    checar("cancelar BDO sem motorista com motivo é aceito", s == 201, (s, c))
    checar("BDO cancelado sai dos disponíveis", cbdo not in disponiveis(m1))
    s, c = assumir(m1, cbdo)
    checar("assumir BDO cancelado: 409 com a mensagem da empresa", s == 409 and msg(c) == CANCELADA, (s, c))
    s, c = req("POST", f"/api/v1/gestao/bdos/{cbdo}/cancelamento", adm, corpo={"motivoId": mot_cancel[0]["id"]})
    checar("cancelar de novo: 409", s == 409, (s, c))
    uso_depois = uso_plano(cbdo)
    checar("BDO cancelado deixa de contar no volume do plano", uso_depois == uso_antes - 1, (uso_antes, uso_depois))

    d, _ = novo_bdo(m1, "D")
    ed = assumir(m1, d)[1]["id"]
    s, c = req("POST", f"/api/v1/gestao/bdos/{d}/cancelamento", adm, corpo={"motivoId": mot_cancel[1]["id"]})
    checar("cancelar entrega atribuída é aceito e registra o motorista", s == 201 and c.get("motoristaAnteriorNome") == "Motorista Teste 1", (s, c))
    painel = [i["entregaId"] for i in req("GET", "/api/v1/motorista/painel-entregas", m1)[1]["entregas"]]
    checar("entrega cancelada sai do painel do motorista", ed not in painel)
    s, c = req("GET", f"/api/v1/entregas/{ed}/detalhe", m1)
    checar("abrir a entrega cancelada mostra a mensagem da empresa", s == 409 and msg(c) == CANCELADA, (s, c))
    s, c = req("POST", f"/api/v1/entregas/{ed}/dispensas", m1, corpo={})
    checar("dispensar entrega cancelada: mensagem da empresa", s == 409 and msg(c) == CANCELADA, (s, c))
    s, c = req("POST", f"/api/v1/entregas/{ed}/viagem/iniciar", m1, corpo={})
    checar("iniciar viagem em entrega cancelada: mensagem da empresa", s == 409 and msg(c) == CANCELADA, (s, c))

    e, _ = novo_bdo(m1, "E")
    ee = assumir(m1, e)[1]["id"]
    sair_em_rota(m1, ee)
    codigo = sql(f"SELECT codigo FROM link_acompanhamento WHERE entrega_id = '{ee}' ORDER BY criado_em DESC LIMIT 1")
    s, c = req("GET", f"/api/v1/acompanhamento/{codigo}")
    checar("link do passageiro em rota mostra a viagem", s == 200 and c.get("etapa") == "VIAGEM_INICIADA", (s, c))
    s, c = req("POST", f"/api/v1/gestao/bdos/{e}/cancelamento", adm, corpo={"motivoId": mot_cancel[1]["id"]})
    checar("cancelar com motorista em rota é aceito (emRota)", s == 201 and c.get("emRota") is True, (s, c))
    s, c = req("POST", f"/api/v1/entregas/{ee}/viagem/checkpoints", m1, corpo={"tipo": "A_CAMINHO"})
    checar("registrar 'a caminho' depois do cancelamento: mensagem da empresa", s == 409 and msg(c) == CANCELADA, (s, c))
    s, c = req("GET", f"/api/v1/acompanhamento/{codigo}")
    checar("link do passageiro fica 'encerrado', sem posição e sem falar em cancelamento",
           s == 200 and c.get("etapa") == "ENCERRADO" and c.get("posicao") is None, (s, c))
    traj = sql(f"SELECT status, cancelamento_id IS NOT NULL, ocorrencia_id IS NULL AND dispensa_id IS NULL FROM trajeto WHERE entrega_id = '{ee}'")
    checar("viagem cancelada encerrada, sem ocorrência/dispensa (não entra no pagamento)", traj == "ENCERRADO|t|t", traj)
    msgs = sql(f"SELECT count(*) FROM mensagem WHERE entrega_id = '{ee}' AND conteudo ILIKE '%cancel%'")
    checar("nenhuma mensagem de cancelamento para o passageiro", msgs == "0", msgs)
    hist = historico(adm, ee)
    checar("histórico da mala termina com o cancelamento", hist and hist[-1] == "CANCELADO", hist)
    s, c = req("GET", "/api/v1/gestao/entregas?status=CANCELADA", adm)
    checar("filtro 'Cancelada' traz as 3 entregas canceladas", s == 200 and {cbdo, d, e} <= {l["bdoId"] for l in c},
           (s, len(c) if isinstance(c, list) else c))

    falhas = [r for r in resultados if not r[1]]
    print(f"\n{len(resultados) - len(falhas)} de {len(resultados)} verificações passaram.")
    return 1 if falhas else 0


if __name__ == "__main__":
    sys.exit(main())
