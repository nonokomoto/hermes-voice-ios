#!/usr/bin/env python3
"""Vigia do conductor agent-deck: avisa a Akili (APNs) quando ele precisa do utilizador.

Corrido pelo cron da Hermes (no_agent), a cada 2 minutos. Guarda o estado em
vigia-conductor.estado.json, ao lado deste script. Silêncio total quando nada mudou.

Avisa em três casos:
  menu   — o conductor parou num menu de permissão do Claude (precisa de um "Yes")
  erro   — credenciais/modelo em falha (auth-401, model-unavailable, erro)
  fim    — a frota ficou calma (nada a correr) durante ~16 min depois de ter havido trabalho

Reutiliza a chave APNs e o tópico da app (server/avisos.py): push/<ficheiros>.

Configuração por variáveis de ambiente:
  HERMES_HOME   perfil da Hermes (por omissão ~/.hermes/profiles/pessoal)
  CONDUCTOR     id da sessão do conductor no agent-deck (obrigatório)
  APNS_TOPIC    bundle ID da app
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

PERFIL = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes" / "profiles" / "pessoal"))
PASTA_PUSH = PERFIL / "push"
ESTADO = Path(__file__).with_name("vigia-conductor.estado.json")
VENV_PY = str(Path.home() / ".hermes" / "hermes-agent" / "venv" / "bin" / "python")

try:
    import jwt  # PyJWT, no venv da Hermes
except ImportError:
    os.execv(VENV_PY, [VENV_PY, __file__, *sys.argv[1:]])

AGENT_DECK = shutil.which("agent-deck") or str(Path.home() / ".local" / "bin" / "agent-deck")
TMUX = shutil.which("tmux") or "/usr/bin/tmux"
CURL = shutil.which("curl") or "/usr/bin/curl"
CONDUCTOR = os.environ.get("CONDUCTOR", "")
BUNDLE = os.environ.get("APNS_TOPIC", "com.example.hermesvoice")
HOSTS = {"producao": "api.push.apple.com", "sandbox": "api.sandbox.push.apple.com"}

TITULOS = {
    "menu": ["O construtor bate à porta", "O construtor prendeu-se à porta"],
    "erro": ["O construtor tropeçou", "O construtor parou a meio do passo"],
    "fim": ["O construtor guardou as ferramentas", "A oficina está em silêncio"],
}

TICKS_CALMO = 8  # ~16 min a 2 min/tick: frota inativa = trabalho terminado
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def ler_json(caminho: Path):
    try:
        return json.loads(caminho.read_text())
    except Exception:
        return {}


def guardar(estado: dict):
    ESTADO.write_text(json.dumps(estado, ensure_ascii=False, indent=1))


def mostrar_conductor() -> dict:
    r = subprocess.run([AGENT_DECK, "session", "show", CONDUCTOR, "--json"],
                       capture_output=True, text=True, timeout=90)
    if r.returncode != 0:
        raise RuntimeError(f"session show: {r.stderr.strip()[:150]}")
    return json.loads(r.stdout)


def conductor_ocupado(status: str, substate: str) -> bool:
    """O conductor está a meio de um turno? (a frota tem sempre sessões à espera)"""
    return status == "running" or substate == "running"


def painel(tmux_session: str) -> str:
    if not tmux_session:
        return ""
    r = subprocess.run([TMUX, "capture-pane", "-t", tmux_session, "-p"],
                       capture_output=True, text=True, timeout=15)
    return ANSI.sub("", r.stdout) if r.returncode == 0 else ""


def extrair_regra(painel_txt: str) -> str:
    for linha in painel_txt.splitlines():
        if "Permission rule" in linha or "requires confirmation" in linha:
            return linha.strip()[:160]
    linhas = [l.strip() for l in painel_txt.splitlines() if l.strip()]
    return " · ".join(linhas[-3:])[:160]


def classificar(status: str, substate: str, painel_txt: str):
    """Devolve (tipo, corpo) quando há novidade que mereça aviso; None em silêncio."""
    p = painel_txt
    tem_menu = "Do you want to proceed?" in p or "❯ 1." in p or "Yes / No" in p
    if tem_menu or substate == "interactive-menu":
        return ("menu", f"Quer que aprove: {extrair_regra(p)}")
    if substate == "auth-401" or "/login" in p or "API Error: 401" in p:
        return ("erro", "Parou por credenciais (401); precisa de novo login no claude.")
    if substate == "model-unavailable":
        return ("erro", "O modelo está indisponível; precisa de troca de modelo.")
    if substate == "error":
        return ("erro", f"Entrou em erro (subestado: {substate or 'desconhecido'}).")
    return None


def escolher(tipo: str) -> str:
    import hashlib
    opcoes = TITULOS[tipo]
    semente = int(hashlib.sha1(str(time.time() // 3600).encode()).hexdigest(), 16)
    return opcoes[semente % len(opcoes)]


def enviar_push(titulo: str, corpo: str, colapso: str):
    registo = ler_json(PASTA_PUSH / "estado.json")
    dispositivos = registo.get("dispositivos") or {}
    if not dispositivos:
        print("[vigia] sem dispositivos registados", file=sys.stderr)
        return
    equipa = (PASTA_PUSH / "equipa.txt").read_text().strip()
    chave_p8 = next(PASTA_PUSH.glob("AuthKey_*.p8"))
    kid = chave_p8.stem.replace("AuthKey_", "")
    agora = int(time.time())
    token = jwt.encode({"iss": equipa, "iat": agora, "exp": agora + 1800},
                       chave_p8.read_bytes(), algorithm="ES256", headers={"kid": kid})
    carga = {"aps": {"alert": {"title": titulo, "body": corpo}, "sound": "default",
                     "thread-id": "conductor"}}
    dados = json.dumps(carga, ensure_ascii=False)
    for dispositivo, ambiente in list(dispositivos.items()):
        host = HOSTS.get(ambiente, HOSTS["producao"])
        cabecas = "\n".join([
            f'header = "authorization: bearer {token}"',
            f'header = "apns-topic: {BUNDLE}"',
            'header = "apns-push-type: alert"',
            'header = "apns-priority: 10"',
            f'header = "apns-collapse-id: {colapso[:60]}"',
        ])
        r = subprocess.run(
            [CURL, "--http2", "-s", "-K", "-", "-o", "/dev/null", "-w", "%{http_code}",
             "--data-binary", dados, f"https://{host}/3/device/{dispositivo}"],
            input=cabecas, capture_output=True, text=True, timeout=30)
        codigo = (r.stdout or "").strip()
        print(f"[vigia] APNs {codigo or r.returncode}", file=sys.stderr)
        # Em 410/BadDeviceToken não mexemos no push/estado.json (é da app/avisos.py);
        # a app volta a registar-se sozinha no próximo arranque.


def main():
    if not CONDUCTOR:
        print("[vigia] falta CONDUCTOR (id da sessão no agent-deck)", file=sys.stderr)
        return 1
    estado = ler_json(ESTADO)
    agora = time.time()
    try:
        sessao = mostrar_conductor()
    except Exception as erro:
        print(f"[vigia] observação falhou: {erro}", file=sys.stderr)
        guardar(estado)
        return 0  # falha de observação não acorda o telefone

    status = sessao.get("status") or ""
    substate = sessao.get("substate") or ""
    texto_painel = painel(sessao.get("tmux_session") or "")

    if conductor_ocupado(status, substate):
        estado["calmo"] = 0
        estado["visto_trabalho"] = agora
        estado.pop("fim_dito", None)
        estado.pop("ultimo", None)  # rearmar: novo turno, novo aviso mesmo com texto igual
    else:
        bloqueado = substate in ("interactive-menu", "auth-401", "model-unavailable", "error")
        if not bloqueado and status in ("waiting", "idle"):
            estado["calmo"] = estado.get("calmo", 0) + 1
        else:
            estado["calmo"] = 0

    evento = classificar(status, substate, texto_painel)

    if evento is None:
        # fim: calma sustentada depois de trabalho recente, e ainda não anunciada
        if (estado.get("calmo", 0) >= TICKS_CALMO
                and agora - estado.get("visto_trabalho", 0) < 12 * 3600
                and not estado.get("fim_dito")):
            titulo = escolher("fim")
            enviar_push(titulo,
                        "Terminou o que tinha em mãos. A oficina espera ordens novas.",
                        "vigia-fim")
            estado["fim_dito"] = agora
            print(f"{titulo}: fim de trabalho", flush=True)
        guardar(estado)
        return 0

    tipo, corpo = evento
    chave = f"{tipo}/{corpo[:80]}"
    ultimo = estado.get("ultimo", {})
    if ultimo.get("evento") == chave:
        guardar(estado)  # mesma situação à espera: já foi avisado
        return 0
    titulo = escolher(tipo)
    enviar_push(titulo, corpo, f"vigia-{tipo}")
    estado["ultimo"] = {"evento": chave, "desde": agora}
    estado["calmo"] = 0
    estado.pop("fim_dito", None)
    guardar(estado)
    print(f"{titulo}: {corpo}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
