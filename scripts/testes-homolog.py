#!/usr/bin/env python3
"""Testes de ponta a ponta na HOMOLOGAÇÃO: dispensa da entrega (V46), cancelamento do BDO pela empresa (V47) e
retirada da bagagem e passo a passo da entrega com fotos (V48).

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


def req(metodo, caminho, token=None, corpo=None, multipart=None, formulario=None):
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
    if formulario is not None:
        fronteira = uuid.uuid4().hex
        partes = b""
        for nome, valor in formulario:
            if isinstance(valor, bytes):
                partes += (f"--{fronteira}\r\nContent-Disposition: form-data; name=\"{nome}\"; filename=\"{nome}.png\"\r\n"
                           "Content-Type: image/png\r\n\r\n").encode() + valor + b"\r\n"
            else:
                partes += (f"--{fronteira}\r\nContent-Disposition: form-data; name=\"{nome}\"\r\n\r\n{valor}\r\n").encode()
        dados = partes + f"--{fronteira}--\r\n".encode()
        cabecalhos["Content-Type"] = "multipart/form-data; boundary=" + fronteira
    r = urllib.request.Request(URL + caminho, data=dados, method=metodo, headers=cabecalhos)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            corpo = resp.read()
            if "json" not in (resp.headers.get("Content-Type") or "json"):
                return resp.status, corpo
            return resp.status, json.loads(corpo.decode() or "null")
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


def campos_bdo(numero, passageiro, **extra):
    campos = {"numero": numero, "passageiroNome": passageiro, "enderecoEntrega": "Av. Goiás, 100", "companhiaAerea": "LATAM",
              "telefonePassageiro": "62999990000", "emailPassageiro": None, "etiquetaBagagem": "LA123456", "tipoProcesso": "AHL",
              "cidade": "Goiânia", "uf": "GO", "cep": "74000-100", "instrucoesEntrega": None, "aeroportoRetirada": "GYN",
              "vooChegada": None, "dataEntregaPrevista": None, "quantidadeMalas": 1, "coresBagagem": None, "valorInformado": None}
    campos.update(extra)
    return campos


def novo_bdo(token_admin, rotulo):
    """V49: o BDO entra pela empresa (a captura por foto do motorista saiu)."""
    numero = "TST" + uuid.uuid4().hex[:7].upper()
    s, bdo = req("POST", "/api/v1/gestao/bdos", token_admin, corpo={"campos": campos_bdo(numero, f"Passageiro {rotulo}"),
                                                                      "textoOriginal": None})
    assert s == 201, (s, bdo)
    return bdo["id"], numero


def assumir(token, bdo_id):
    s, e = req("POST", f"/api/v1/entregas/{bdo_id}/autoatribuir", token)
    return s, e


def retirar(token, entrega_id, avarias=0):
    campos = [("foto", png()), ("latitude", "-16.632"), ("longitude", "-49.221"), ("idLocal", str(uuid.uuid4()))]
    campos += [("avarias", png()) for _ in range(avarias)]
    if avarias:
        campos.append(("observacaoAvaria", "arranhao na lateral"))
    return req("POST", f"/api/v1/entregas/{entrega_id}/retirada", token, formulario=campos)


def sair_em_rota(token, entrega_id):
    s, c = retirar(token, entrega_id)
    assert s == 201, ("retirada", s, c)
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

    # V52: toda empresa tem bases e todo motorista tem base - preparar antes de qualquer BDO.
    def base_por_codigo(codigo, nome):
        existentes = req("GET", "/api/v1/configuracoes/bases-aeroportuarias", adm)[1]
        achada = [b for b in existentes if b["codigoIata"] == codigo]
        if achada:
            return achada[0]
        s, c = req("POST", "/api/v1/configuracoes/bases-aeroportuarias", adm, corpo={"codigoIata": codigo, "nome": nome})
        assert s == 201, (s, c)
        return c

    base_gyn = base_por_codigo("GYN", "Santa Genoveva")
    if not base_gyn.get("principal"):
        req("POST", f"/api/v1/configuracoes/bases-aeroportuarias/{base_gyn['id']}/principal", adm)
    base_bsb = base_por_codigo("BSB", "Brasilia")
    motoristas = {m["login"]: m for m in req("GET", "/api/v1/motoristas", adm)[1]}

    def mover(chave, base):
        motorista = motoristas[CFG[chave + "_LOGIN"]]
        s, c = req("PATCH", f"/api/v1/motoristas/{motorista['id']}", adm, corpo={"baseId": base["id"]})
        assert s == 200, (s, c)

    mover("MILEBAG_TESTE_MOTORISTA1", base_gyn)
    mover("MILEBAG_TESTE_MOTORISTA2", base_gyn)

    mot_dispensa = motivos(m1, "DISPENSA")
    mot_cancel = motivos(adm, "CANCELAMENTO")
    checar("empresa nova tem 4 motivos de dispensa e 4 de cancelamento", len(mot_dispensa) == 4 and len(mot_cancel) == 4,
           f"{len(mot_dispensa)} / {len(mot_cancel)}")

    print("\n--- Item 1: dispensa ---")
    a, _ = novo_bdo(adm, "A")
    s, ent = assumir(m1, a)
    checar("motorista 1 assume o BDO A", s in (200, 201), (s, ent))
    ea = ent["id"]
    det = req("GET", f"/api/v1/entregas/{ea}/detalhe", m1)[1]
    checar("antes de sair, dispensa não exige motivo", det.get("motivoDispensaObrigatorio") is False, det)
    s, c = req("POST", f"/api/v1/entregas/{ea}/dispensas", m1, corpo={})
    checar("dispensa sem motivo antes de sair é aceita", s == 201, (s, c))
    checar("BDO A volta para os disponíveis do motorista 2", a in disponiveis(m2))
    checar("histórico tem a dispensa sem bagagem", "DISPENSA_SEM_BAGAGEM" in historico(adm, ea), historico(adm, ea))

    b, _ = novo_bdo(adm, "B")
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

    cbdo, _ = novo_bdo(adm, "C")
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

    d, _ = novo_bdo(adm, "D")
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

    e, _ = novo_bdo(adm, "E")
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

    print("\n--- Itens 4 e 5: retirada e passo a passo da entrega ---")
    mot_recebedor = motivos(m1, "RECEBEDOR")
    checar("empresa tem a lista de quem pode assinar (5 opções)", len(mot_recebedor) == 5, len(mot_recebedor))
    f, _ = novo_bdo(adm, "F")
    ef = assumir(m1, f)[1]["id"]
    det = req("GET", f"/api/v1/entregas/{ef}/detalhe", m1)[1]
    checar("entrega assumida ainda sem retirada", det.get("retiradaRegistrada") is False, det.get("retiradaRegistrada"))
    req("POST", f"/api/v1/entregas/{ef}/rotas/selecionar", m1, corpo={
        "tipoSelecao": "PROPRIA", "alternativaId": None, "justificativa": "teste automatizado",
        "tracadoManual": [{"latitude": -16.632, "longitude": -49.221}, {"latitude": -16.686, "longitude": -49.264}]})
    s, c = req("POST", f"/api/v1/entregas/{ef}/viagem/iniciar", m1, corpo={})
    checar("iniciar viagem sem retirada é recusado (400)", s == 400, (s, c))
    s, c = req("POST", f"/api/v1/entregas/{ef}/retirada", m1, formulario=[("latitude", "-16.6")])
    checar("retirada sem foto é recusada (400)", s == 400, (s, c))
    s, c = retirar(m2, ef)
    checar("outro motorista não registra a retirada (409)", s == 409, (s, c))
    s, c = retirar(m1, ef, avarias=2)
    checar("retirada com foto e 2 avarias é aceita", s == 201 and c.get("comLocalizacao") is True, (s, c))
    s, c = retirar(m1, ef)
    checar("segunda retirada na mesma tentativa é recusada (409)", s == 409, (s, c))
    checar("detalhe passa a mostrar a retirada feita", req("GET", f"/api/v1/entregas/{ef}/detalhe", m1)[1].get("retiradaRegistrada") is True)
    s, c = req("POST", f"/api/v1/entregas/{ef}/viagem/iniciar", m1, corpo={})
    checar("com a retirada, a viagem inicia", s in (200, 201), (s, c))
    base = [("foto", png()), ("dataHora", __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat().replace("+00:00", "Z")),
            ("latitude", "-16.686"), ("longitude", "-49.264"), ("idLocal", str(uuid.uuid4()))]
    s, c = req("POST", f"/api/v1/entregas/{ef}/comprovante", m1, formulario=base + [("tipoRecebedorId", mot_recebedor[0]["id"]), ("nomeRecebedor", "Ana")])
    checar("entrega sem a foto na porta é recusada", s in (400, 422) and "porta" in str(msg(c)).lower(), (s, c))
    s, c = req("POST", f"/api/v1/entregas/{ef}/comprovante", m1, formulario=base + [("fotoPorta", png())])
    checar("entrega sem quem assinou é recusada", s in (400, 422), (s, c))
    s, c = req("POST", f"/api/v1/entregas/{ef}/comprovante", m2, formulario=base + [
        ("fotoPorta", png()), ("tipoRecebedorId", mot_recebedor[0]["id"]), ("nomeRecebedor", "Ana Souza")])
    checar("outro motorista nao registra a entrega de um colega (403)", s == 403, (s, c))
    s, c = req("POST", f"/api/v1/entregas/{ef}/comprovante", adm, formulario=base + [
        ("fotoPorta", png()), ("tipoRecebedorId", mot_recebedor[0]["id"]), ("nomeRecebedor", "Ana Souza")])
    checar("administrador nao registra a entrega no lugar do motorista (403)", s == 403, (s, c))
    s, c = req("POST", f"/api/v1/entregas/{ef}/comprovante", m1, formulario=base + [
        ("fotoPorta", png()), ("tipoRecebedorId", mot_recebedor[0]["id"]), ("nomeRecebedor", "Ana Souza"),
        ("avarias", png()), ("observacaoAvaria", "caixa amassada")])
    checar("entrega completa é registrada e encerrada", s == 201 and c.get("entregaStatus") == "ENCERRADA_COM_SUCESSO", (s, c))
    receb = sql(f"SELECT identificacao_recebedor, nome_recebedor FROM comprovante_entrega WHERE entrega_id = '{ef}'")
    checar("comprovante guarda 'Tipo - Nome' e o nome", receb == f"{mot_recebedor[0]['descricao']} - Ana Souza|Ana Souza", receb)
    tipos = [f["tipo"] for f in req("GET", f"/api/v1/gestao/entregas/{ef}/fotos", adm)[1]]
    checar("empresa vê as 6 fotos (retirada, 2 avarias, porta, avaria, BDO assinado)",
           sorted(tipos) == sorted(["RETIRADA", "AVARIA_RETIRADA", "AVARIA_RETIRADA", "PORTA", "AVARIA_ENTREGA", "BDO_ASSINADO"]), tipos)
    fotos = req("GET", f"/api/v1/gestao/entregas/{ef}/fotos", adm)[1]
    s, _ = req("GET", f"/api/v1/gestao/entregas/{ef}/fotos/{fotos[0]['id']}", adm)
    checar("a empresa baixa o arquivo da foto", s == 200, s)
    s, _ = req("GET", f"/api/v1/gestao/entregas/{ef}/fotos/{fotos[0]['id']}", m1)
    checar("motorista não acessa as fotos da gestão (403)", s == 403, s)
    s, _ = req("GET", f"/api/v1/gestao/entregas/{ea}/fotos/{fotos[0]['id']}", adm)
    checar("foto de outra entrega não vaza (404)", s == 404, s)
    hist = historico(adm, ef)
    checar("histórico tem a retirada antes da viagem", "BAGAGEM_RETIRADA" in hist and hist.index("BAGAGEM_RETIRADA") < hist.index("VIAGEM_INICIADA"), hist)

    print("\n--- Inclusao do BDO pela empresa e fim da captura por foto ---")
    numero_telex = "GYNLA" + str(uuid.uuid4().int)[:5]
    telex = (f"WM BDO AHL {numero_telex}/0013GMT/16SEP26\nDS GYNLA03 - PACK AND GO - EXPRESSA\nLATAM AIRLINES GROUP....\n"
             "NM01 FICTICIA\nGN01 MARIA\nPA AV EXEMPLO 100 APT 1\nYP GOIANIA\nST GO\nCO BR\nZP 74000100 .DD 15SEP .DW .CS D/BRL132\n"
             "PN01 55 62 9 0000 0001\nEA01 MARIA/U/TESTE/A/EXEMPLO/D/COM\nLD01 LA3266 GYN 11:35 - 13:15\n"
             "TN01 LA000001 .TN02 LA000002\nCT01 GN22 .CT02 BK22\nRT GRU/GYN\n/RECHARGE -/SIGNATURE FOR RECEIPT OF 2 BAG")
    s, _ = req("POST", "/api/v1/gestao/bdos/leitura", m1, corpo={"texto": telex})
    checar("motorista nao le nem inclui BDO pela gestao (403)", s == 403, s)
    s, lido = req("POST", "/api/v1/gestao/bdos/leitura", adm, corpo={"texto": telex})
    checar("telex colado preenche os campos (numero, passageiro, endereco, aeroporto, voo, 2 malas, e-mail)",
           s == 200 and lido["numero"] == numero_telex and lido["passageiroNome"] == "MARIA FICTICIA"
           and lido["enderecoEntrega"] == "AV EXEMPLO 100 APT 1" and lido["cep"] == "74000-100" and lido["aeroportoRetirada"] == "GYN"
           and lido["vooChegada"] == "LA3266" and lido["quantidadeMalas"] == 2 and lido["emailPassageiro"] == "maria_teste@exemplo.com",
           (s, lido))
    s, c = req("POST", "/api/v1/gestao/bdos/leitura", adm, corpo={"texto": "   "})
    checar("texto vazio e recusado (400)", s == 400, (s, c))
    s, c = req("POST", "/api/v1/gestao/bdos", adm, corpo={"campos": campos_bdo("TSTSEMNOME", None), "textoOriginal": None})
    checar("inclusao sem passageiro e recusada (400)", s == 400 and "nome do passageiro" in msg(c), (s, c))
    s, c = req("POST", "/api/v1/gestao/bdos", adm, corpo={"campos": campos_bdo("TSTUF", "P", uf="GOIAS"), "textoOriginal": None})
    checar("UF por extenso e recusada (400)", s == 400, (s, c))
    s, incl = req("POST", "/api/v1/gestao/bdos", adm, corpo={"campos": lido, "textoOriginal": telex})
    checar("BDO lido e incluido pela empresa (201, origem EMPRESA)", s == 201 and incl["origem"] == "EMPRESA", (s, incl))
    checar("endereco completo montado com cidade, UF e CEP",
           incl["campos"]["enderecoEntrega"] == "AV EXEMPLO 100 APT 1, GOIANIA - GO, 74000-100", incl["campos"]["enderecoEntrega"])
    checar("BDO incluido aparece nos disponiveis do motorista", incl["id"] in disponiveis(m1))
    guardado = sql(f"SELECT origem, status_conferencia, quantidade_malas, aeroporto_retirada, (texto_original IS NOT NULL), "
                   f"(incluido_por IS NOT NULL) FROM bdo WHERE id = '{incl['id']}'")
    checar("banco guarda origem, malas, aeroporto, telex e quem incluiu", guardado == "EMPRESA|CONFIRMADO|2|GYN|t|t", guardado)
    s, iguais = req("GET", f"/api/v1/gestao/bdos?numero={numero_telex.lower()}", adm)
    checar("numero repetido e encontrado antes de incluir de novo", s == 200 and len(iguais) == 1, (s, iguais))
    # BDO antigo gravado antes da normalizacao (minusculas e espacos) tambem conta como repetido.
    sql(f"UPDATE bdo SET numero = lower(substr(numero, 1, 5)) || ' ' || substr(numero, 6) WHERE id = '{incl['id']}'")
    s, iguais = req("GET", f"/api/v1/gestao/bdos?numero={numero_telex}", adm)
    checar("numero gravado em minusculas e com espaco tambem e achado", s == 200 and len(iguais) == 1, (s, iguais))
    sql(f"UPDATE bdo SET numero = '{numero_telex}' WHERE id = '{incl['id']}'")
    s, _ = req("POST", "/api/v1/bdos", m1, multipart=("bdo.png", png()))
    checar("captura por foto do motorista nao existe mais", s in (403, 404, 405), s)
    s, lote = req("POST", "/api/v1/sync/eventos", m1, corpo={"eventos": [{
        "idLocal": str(uuid.uuid4()), "sequenciaLocal": 1, "tipoEvento": "BDO_CAPTURADO",
        "timestampCriacaoLocal": "2026-11-21T10:00:00Z", "payload": {"imagemBase64": "", "nomeArquivo": "bdo.png"}}]})
    r = lote["resultados"][0] if s == 200 else {}
    checar("foto de BDO antiga na fila do celular volta com o motivo",
           r.get("resultado") == "ERRO" and "desativada" in (r.get("motivo") or ""), (s, lote))
    hist_bdo = sql(f"SELECT count(*) FROM bdo WHERE numero = '{numero_telex}'")
    checar("um so BDO com o numero do telex", hist_bdo == "1", hist_bdo)

    print("\n--- Segunda via do BDO (PDF e e-mail) ---")
    g, _ = novo_bdo(adm, "G")
    s, eg = assumir(m1, g)
    assert s in (200, 201), (s, eg)
    s, pdf = req("GET", f"/api/v1/entregas/{eg['id']}/segunda-via-bdo", m1)
    checar("motorista responsavel baixa a segunda via em PDF", s == 200 and isinstance(pdf, bytes) and pdf.startswith(b"%PDF"), s)
    s, _ = req("GET", f"/api/v1/entregas/{eg['id']}/segunda-via-bdo", m2)
    checar("outro motorista nao baixa a segunda via (403)", s == 403, s)
    s, _ = req("GET", f"/api/v1/entregas/{ef}/segunda-via-bdo", m1)
    checar("entrega ja entregue nao emite segunda via para o motorista (409)", s == 409, s)
    s, pdf = req("GET", f"/api/v1/gestao/bdos/{g}/segunda-via", adm)
    checar("empresa baixa a segunda via de qualquer BDO", s == 200 and isinstance(pdf, bytes) and pdf.startswith(b"%PDF"), s)
    s, _ = req("GET", f"/api/v1/gestao/bdos/{g}/segunda-via", m1)
    checar("motorista nao usa a segunda via da gestao (403)", s == 403, s)
    s, c = req("POST", f"/api/v1/entregas/{eg['id']}/segunda-via-bdo/email", m1, corpo={"email": "nao-e-email"})
    checar("e-mail invalido e recusado (400)", s == 400, (s, c))
    s, c = req("POST", f"/api/v1/gestao/bdos/{g}/segunda-via/email", adm, corpo={"email": "grafica@exemplo.com"})
    checar("na homologacao (SMTP desligado) o envio avisa que esta desativado (503)", s == 503 and "desativado" in msg(c), (s, c))
    envios = sql(f"SELECT count(*) FROM envio_segunda_via_bdo WHERE bdo_id = '{g}'")
    checar("envio que nao saiu nao fica registrado", envios == "0", envios)

    print("\n--- Item 6: voltar para alterar com motivo (auditoria) ---")
    mot_corr = motivos(m1, "CORRECAO")
    checar("motorista le a lista de motivos de correcao (5 padrao)", len(mot_corr) == 5, len(mot_corr))
    h, _ = novo_bdo(adm, "H")
    eh = assumir(m1, h)[1]["id"]
    s, c = retirar(m1, eh)
    assert s == 201, (s, c)
    s, c = req("POST", f"/api/v1/entregas/{eh}/retirada/correcao", m1, formulario=[("foto", png())])
    checar("corrigir a retirada sem motivo e recusado (400)", s == 400, (s, c))
    s, c = req("POST", f"/api/v1/entregas/{eh}/retirada/correcao", m2, formulario=[("foto", png()), ("motivoId", mot_corr[0]["id"])])
    checar("outro motorista nao corrige a retirada (409)", s == 409, (s, c))
    s, c = req("POST", f"/api/v1/entregas/{eh}/retirada/correcao", m1, formulario=[
        ("foto", png()), ("motivoId", mot_corr[0]["id"]), ("complemento", "foto tremida")])
    checar("retirada corrigida com motivo antes de iniciar a viagem", s == 200, (s, c))
    fotos_h = req("GET", f"/api/v1/gestao/entregas/{eh}/fotos", adm)[1]
    checar("foto antiga da retirada fica guardada como substituida",
           sorted((f["tipo"], f["substituida"]) for f in fotos_h) == [("RETIRADA", False), ("RETIRADA", True)], fotos_h)
    req("POST", f"/api/v1/entregas/{eh}/rotas/selecionar", m1, corpo={
        "tipoSelecao": "PROPRIA", "alternativaId": None, "justificativa": "teste automatizado",
        "tracadoManual": [{"latitude": -16.632, "longitude": -49.221}, {"latitude": -16.686, "longitude": -49.264}]})
    s, c = req("POST", f"/api/v1/entregas/{eh}/viagem/iniciar", m1, corpo={})
    assert s in (200, 201), (s, c)
    s, c = req("POST", f"/api/v1/entregas/{eh}/retirada/correcao", m1, formulario=[("foto", png()), ("motivoId", mot_corr[0]["id"])])
    checar("depois de iniciar a viagem a retirada nao e mais corrigida (409)", s == 409, (s, c))
    agora_iso = __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat().replace("+00:00", "Z")
    correcoes = json.dumps([{"etapa": "FOTO_PORTA", "motivoId": mot_corr[0]["id"], "complemento": None,
                             "antes": "foto anterior", "depois": "foto nova", "dataHora": agora_iso}])
    s, c = req("POST", f"/api/v1/entregas/{eh}/comprovante", m1, formulario=[
        ("foto", png()), ("dataHora", agora_iso), ("latitude", "-16.686"), ("longitude", "-49.264"), ("idLocal", str(uuid.uuid4())),
        ("fotoPorta", png()), ("tipoRecebedorId", mot_recebedor[0]["id"]), ("nomeRecebedor", "Ana"), ("correcoes", correcoes)])
    checar("entrega com correcao feita antes de finalizar e registrada", s == 201, (s, c))
    detalhe = req("GET", f"/api/v1/entregas/{eh}/detalhe", m1)[1]
    checar("entrega finalizada mostra ate quando pode ser corrigida", detalhe.get("corrigivelAte") is not None, detalhe.get("corrigivelAte"))
    corrigiveis = [e["entregaId"] for e in req("GET", "/api/v1/motorista/entregas-corrigiveis", m1)[1]]
    checar("painel lista a entrega entre as que ainda podem ser corrigidas", eh in corrigiveis, corrigiveis)
    s, c = req("POST", f"/api/v1/entregas/{eh}/comprovante/correcao", m2, formulario=[("motivoId", mot_corr[3]["id"]),
                                                                                     ("tipoRecebedorId", mot_recebedor[1]["id"]), ("nomeRecebedor", "Rui")])
    checar("outro motorista nao corrige a entrega finalizada (409)", s == 409, (s, c))
    s, c = req("POST", f"/api/v1/entregas/{eh}/comprovante/correcao", m1, formulario=[
        ("motivoId", mot_corr[3]["id"]), ("tipoRecebedorId", mot_recebedor[1]["id"]), ("nomeRecebedor", "Rui Vizinho"), ("fotoDocumento", png())])
    checar("motorista corrige quem assinou e a foto do BDO assinado (ate 24 h)", s == 200, (s, c))
    receb = sql(f"SELECT identificacao_recebedor FROM comprovante_entrega WHERE entrega_id = '{eh}'")
    checar("comprovante passa a ter o recebedor corrigido", receb == f"{mot_recebedor[1]['descricao']} - Rui Vizinho", receb)
    fotos_h = req("GET", f"/api/v1/gestao/entregas/{eh}/fotos", adm)[1]
    checar("foto do BDO assinado anterior fica guardada como substituida",
           any(f["tipo"] == "BDO_ASSINADO" and f["substituida"] for f in fotos_h) and any(f["tipo"] == "BDO_ASSINADO" and not f["substituida"] for f in fotos_h),
           fotos_h)
    hist = req("GET", f"/api/v1/gestao/entregas/{eh}/historico", adm)[1]["eventos"]
    etapas = sorted(e["descricao"] for e in hist if e["tipo"] == "CORRECAO")
    checar("historico tem cada correcao com a etapa (retirada, porta no fluxo, recebedor e BDO)",
           etapas == ["FOTO_BDO_ASSINADO", "FOTO_PORTA", "FOTO_RETIRADA", "RECEBEDOR"], etapas)
    checar("historico mostra o antes e o depois do recebedor",
           any("Antes: " + mot_recebedor[0]["descricao"] + " - Ana" in (e["detalhe"] or "") for e in hist if e["descricao"] == "RECEBEDOR"), hist)
    linha = [e for e in req("GET", "/api/v1/gestao/entregas", adm)[1] if e["entregaId"] == eh]
    checar("lista da empresa mostra o selo Corrigida", linha and linha[0]["corrigida"] is True, linha)
    sql(f"UPDATE comprovante_entrega SET criado_em = now() - interval '25 hours' WHERE entrega_id = '{eh}'")
    s, c = req("POST", f"/api/v1/entregas/{eh}/comprovante/correcao", m1, formulario=[("motivoId", mot_corr[0]["id"]), ("fotoPorta", png())])
    checar("depois de 24 h a correcao e bloqueada (409)", s == 409 and "24 horas" in msg(c), (s, c))

    print("\n--- Item 7: viagem calculada a partir do aeroporto ---")
    gyn = [b for b in req("GET", "/api/v1/configuracoes/bases-aeroportuarias", adm)[1] if b["codigoIata"] == "GYN"][0]
    checar("base GYN principal, com a cidade do aeroporto", gyn["principal"] is True and gyn["cidade"] == "Goiânia", gyn)
    s, c = req("POST", "/api/v1/configuracoes/bases-aeroportuarias", adm, corpo={"codigoIata": "XXX", "nome": "Inexistente"})
    checar("base com aeroporto fora do cadastro e recusada (400)", s == 400, (s, c))

    def entregar_completo(token, entrega_id):
        s, c = retirar(token, entrega_id)
        assert s == 201, ("retirada", s, c)
        s, c = req("POST", f"/api/v1/entregas/{entrega_id}/rotas/calcular", token,
                   corpo={"origemAtual": {"latitude": -16.632, "longitude": -49.2207}, "destinoManual": None})
        assert s == 200, ("calcular", s, c)
        alt = c["alternativas"][0]["id"]
        s, c = req("POST", f"/api/v1/entregas/{entrega_id}/rotas/selecionar", token,
                   corpo={"tipoSelecao": "SUGERIDA", "alternativaId": alt, "justificativa": None, "tracadoManual": None})
        assert s == 200, ("selecionar", s, c)
        s, c = req("POST", f"/api/v1/entregas/{entrega_id}/viagem/iniciar", token, corpo={"lat": -16.632, "lng": -49.2207})
        assert s in (200, 201), ("iniciar", s, c)
        agora = __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat().replace("+00:00", "Z")
        s, c = req("POST", f"/api/v1/entregas/{entrega_id}/comprovante", token, formulario=[
            ("foto", png()), ("dataHora", agora), ("latitude", "-16.686"), ("longitude", "-49.264"), ("idLocal", str(uuid.uuid4())),
            ("fotoPorta", png()), ("tipoRecebedorId", mot_recebedor[0]["id"]), ("nomeRecebedor", "Ana"),
            ("justificativaDivergencia", "teste automatizado")])
        assert s == 201, ("comprovante", s, c)

    def bdo_em(cidade, endereco, cep):
        numero = "TST" + uuid.uuid4().hex[:7].upper()
        s, b = req("POST", "/api/v1/gestao/bdos", adm, corpo={"campos": campos_bdo(
            numero, "Passageiro Cobranca", enderecoEntrega=endereco, cidade=cidade, uf="GO", cep=cep, aeroportoRetirada="GYN"),
            "textoOriginal": None})
        assert s == 201, (s, b)
        return b["id"]

    na_base = assumir(m1, bdo_em("Goiânia", "Av. Goiás, 100", "74005-010"))[1]["id"]
    entregar_completo(m1, na_base)
    regra = sql(f"SELECT base_cobranca, regra_cobranca FROM trajeto WHERE entrega_id = '{na_base}'")
    checar("entrega em Goiania (cidade da base) fica com valor fixo", regra == "GYN|FIXO_CIDADE_BASE", regra)

    fora = assumir(m1, bdo_em("Anápolis", "Av. Brasil, 1000", "75110-000"))[1]["id"]
    entregar_completo(m1, fora)
    regra = sql(f"SELECT base_cobranca || '|' || regra_cobranca FROM trajeto WHERE entrega_id = '{fora}'")
    km_ida, km_volta = sql(f"SELECT km_ida_final || '|' || km_volta_final FROM trajeto WHERE entrega_id = '{fora}'").split("|")
    checar("entrega em Anapolis (fora da cidade da base) paga por km", regra == "GYN|POR_KM", regra)
    checar("ida e volta calculadas a partir do aeroporto (dezenas de km ate Anapolis)",
           float(km_ida) > 40 and float(km_volta) > 40, (km_ida, km_volta))

    print("\n--- Encaminhamento do BDO pela base ---")
    s, c = req("POST", "/api/v1/motoristas", adm, corpo={"nome": "Sem Base", "login": "sem.base." + uuid.uuid4().hex[:6], "senha": "senha-teste-123"})
    checar("cadastrar motorista sem base e recusado (400)", s == 400 and "base" in msg(c).lower(), (s, c))
    mover("MILEBAG_TESTE_MOTORISTA2", base_bsb)
    try:
        j_gyn, _ = novo_bdo(adm, "J")
        checar("motorista de outra base nao ve o BDO de GYN", j_gyn not in disponiveis(m2))
        checar("motorista da base ve o BDO de GYN", j_gyn in disponiveis(m1))
        s, c = assumir(m2, j_gyn)
        checar("motorista de outra base nao assume o BDO (409)", s == 409 and "outra base" in msg(c), (s, c))
        s, c = req("POST", f"/api/v1/gestao/bdos/{j_gyn}/base", adm, corpo={"baseId": base_bsb["id"], "motivo": " "})
        checar("trocar a base sem motivo e recusado (400)", s == 400, (s, c))
        s, c = req("POST", f"/api/v1/gestao/bdos/{j_gyn}/base", adm, corpo={"baseId": base_bsb["id"], "motivo": "aeroporto errado no texto"})
        checar("empresa troca a base do BDO com motivo", s == 204, (s, c))
        checar("depois da troca o BDO aparece para a base nova", j_gyn in disponiveis(m2) and j_gyn not in disponiveis(m1))
        linha = [e for e in req("GET", "/api/v1/gestao/entregas", adm)[1] if e["bdoId"] == j_gyn]
        checar("lista da empresa mostra a base do BDO", linha and linha[0]["baseCodigo"] == "BSB", linha)
        ej = assumir(m2, j_gyn)[1]["id"]
        s, c = req("POST", f"/api/v1/gestao/bdos/{j_gyn}/base", adm, corpo={"baseId": base_gyn["id"], "motivo": "teste"})
        checar("BDO ja assumido nao troca de base (409)", s == 409, (s, c))
        hist = [e for e in req("GET", f"/api/v1/gestao/entregas/{ej}/historico", adm)[1]["eventos"] if e["tipo"] == "BASE_ALTERADA"]
        checar("historico mostra a troca de base com o motivo", hist and hist[0]["descricao"] == "GYN -> BSB"
               and hist[0]["detalhe"] == "aeroporto errado no texto", hist)
        s, c = req("DELETE", f"/api/v1/configuracoes/bases-aeroportuarias/{base_bsb['id']}", adm)
        checar("base com motoristas ou BDOs nao pode ser removida (409)", s == 409, (s, c))
    finally:
        mover("MILEBAG_TESTE_MOTORISTA2", base_gyn)

    print("\n--- Busca de companhia aerea pelo nome e de base pela cidade ---")
    catalogo = req("GET", "/api/v1/catalogo/companhias-aereas", adm)[1]
    gol = [c for c in catalogo if c["codigoIata"] == "G3"]
    checar("lista de companhias traz a Gol (G3 / GLO)", gol and gol[0]["codigoIcao"] == "GLO" and "Gol" in gol[0]["nome"], gol)
    aeroportos = req("GET", "/api/v1/aeroportos", adm)
    checar("administrador busca o aeroporto pela cidade (Goiania -> GYN)", aeroportos[0] == 200
           and any(a["codigo"] == "GYN" and a["cidade"] == "Goiânia" for a in aeroportos[1]), aeroportos[0])
    s, c = req("POST", "/api/v1/configuracoes/companhias-aereas", adm, corpo={"codigoIata": "XX", "nome": "Inventada"})
    checar("companhia fora da lista e recusada (400)", s == 400, (s, c))
    # Companhia e aeroporto que a empresa de teste ainda nao tem: nada existente e apagado, e o criado sai no finally.
    ja_cias = {a["codigoIata"] for a in req("GET", "/api/v1/configuracoes/companhias-aereas", adm)[1]}
    ja_bases = {b["codigoIata"] for b in req("GET", "/api/v1/configuracoes/bases-aeroportuarias", adm)[1]}
    cia = next((c for c in catalogo if c["codigoIata"] not in ja_cias), None)
    livre = next((a for a in aeroportos[1] if a["codigo"] not in ja_bases), None) if aeroportos[0] == 200 else None
    criadas = []
    try:
        if cia:
            s, c = req("POST", "/api/v1/configuracoes/companhias-aereas", adm, corpo={"codigoIata": cia["codigoIcao"].lower(), "nome": ""})
            if s in (200, 201):
                criadas.append(f"/api/v1/configuracoes/companhias-aereas/{c['id']}")
            checar("codigo ICAO vira o IATA e o nome vem da lista", s in (200, 201) and c["codigoIata"] == cia["codigoIata"]
                   and c["nome"] == cia["nome"], (s, c))
        else:
            checar("codigo ICAO vira o IATA e o nome vem da lista", False, "sem companhia livre na lista")
        if livre:
            s, c = req("POST", "/api/v1/configuracoes/bases-aeroportuarias", adm, corpo={"codigoIata": livre["codigo"].lower(), "nome": ""})
            if s in (200, 201):
                criadas.append(f"/api/v1/configuracoes/bases-aeroportuarias/{c['id']}")
            checar("base sem nome recebe o nome do aeroporto", s in (200, 201) and c["codigoIata"] == livre["codigo"]
                   and c["nome"] == livre["nome"], (s, c))
        else:
            checar("base sem nome recebe o nome do aeroporto", False, "sem aeroporto livre")
    finally:
        for caminho in criadas:
            req("DELETE", caminho, adm)

    falhas = [r for r in resultados if not r[1]]
    print(f"\n{len(resultados) - len(falhas)} de {len(resultados)} verificações passaram.")
    return 1 if falhas else 0


if __name__ == "__main__":
    sys.exit(main())
