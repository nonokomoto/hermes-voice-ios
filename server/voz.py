"""Serviço /voz da Akili: transforma a parte falada de uma resposta em áudio (MP3).

Corre no ProDesk com o Python do Hermes, atrás do `tailscale serve` (só visível na tailnet).
Usa a mesma chave de acesso da app (API_SERVER_KEY do perfil pessoal) e a GEMINI_API_KEY do
mesmo perfil, lidas pelo próprio serviço. Se a Gemini falhar, usa a voz Raquel (Edge, pt-PT).

POST /voz  {"texto": "..."}  ->  audio/mpeg
POST /anexos  (corpo: imagem JPEG/PNG/HEIC)  ->  {"caminho": "/…/workspace/anexos/<id>.jpg"}
POST /avisos/dispositivo  {"token": "...", "ambiente": "producao"|"sandbox"}
POST /avisos/vigiar       {"run": "...", "assunto": "...", "titulo": "...", "entrada": "..."}
POST /avisos/permitir     {"assunto": "...", "padroes": ["delete in root path", ...]}
POST /avisos/retirar      {"assunto": "...", "padrao": "..."}   (sem padrao: todas as do assunto)
GET  /avisos/permitidos   ->  {"<assunto>": ["padrão", ...]}
GET  /avisos/estado       ->  modelo principal, reserva e voz em uso
GET  /precos                 ->  tabela de preços (servidor/precos.json)
GET  /saude                  ->  "ok"

O `tailscale serve --set-path /voz` corta o prefixo (chega "/"); /anexos e /avisos são montados com o
caminho explícito (`http://127.0.0.1:8650/anexos`, `…/avisos`), por isso chegam completos.
"""
import asyncio
import hashlib
import hmac
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PERFIL = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes/profiles/pessoal"))
os.environ["HERMES_HOME"] = str(PERFIL)
sys.path.insert(0, str(Path.home() / ".hermes/hermes-agent"))

from tools.tts_tool_providers import _generate_gemini_tts  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from avisos import Avisos  # noqa: E402

PORTA = int(os.environ.get("AKILI_VOZ_PORTA", "8650"))
MODELO = os.environ.get("AKILI_VOZ_MODELO", "gemini-3.8-flash-tts")
VOZ = os.environ.get("AKILI_VOZ", "Aoede")
PERSONA = PERFIL / "voz" / "persona-pt.md"
RESERVA = "pt-PT-RaquelNeural"
CACHE = PERFIL / "cache" / "voz"
MAX_TEXTO = 2000
ANEXOS = PERFIL / "workspace" / "anexos"
MAX_ANEXO = 15 * 1024 * 1024
EXTENSOES = {"image/jpeg": ".jpg", "image/png": ".png", "image/heic": ".heic", "image/webp": ".webp"}

_bloqueio = threading.Lock()
CAMBIO = PERFIL / "cache" / "cambio.json"


def cambio() -> dict:
    """Euros por dólar, da taxa de referência diária do BCE (guardada um dia; se falhar, a última conhecida)."""
    import re
    import time
    import urllib.request

    try:
        guardado = json.loads(CAMBIO.read_text())
        if time.time() - guardado.get("obtido", 0) < 12 * 3600:
            return guardado
    except (OSError, json.JSONDecodeError):
        guardado = None
    try:
        with urllib.request.urlopen("https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml", timeout=10) as r:
            xml = r.read().decode()
        usd = float(re.search(r"currency='USD' rate='([0-9.]+)'", xml).group(1))
        data = re.search(r"time='([0-9-]+)'", xml).group(1)
        novo = {"eur_por_usd": round(1 / usd, 6), "data": data, "fonte": "BCE", "obtido": time.time()}
        CAMBIO.parent.mkdir(parents=True, exist_ok=True)
        CAMBIO.write_text(json.dumps(novo))
        return novo
    except Exception as erro:
        print(f"[voz] câmbio do BCE indisponível ({erro})", flush=True)
        return guardado or {"eur_por_usd": 0.88, "data": None, "fonte": "estimativa"}


def chave_da_app() -> str:
    for linha in (PERFIL / ".env").read_text().splitlines():
        if linha.startswith("API_SERVER_KEY="):
            return linha.split("=", 1)[1].strip()
    raise SystemExit("API_SERVER_KEY não encontrada no .env do perfil")


CHAVE = chave_da_app()
AVISOS = Avisos(PERFIL, CHAVE)


def estado_agente() -> dict:
    """Modelo principal e reserva, lidos da configuração do perfil (não inclui segredos)."""
    import yaml

    try:
        cfg = yaml.safe_load((PERFIL / "config.yaml").read_text()) or {}
    except (OSError, yaml.YAMLError):
        cfg = {}
    modelo = cfg.get("model") or {}
    reservas = [f"{r.get('model')}" for r in (cfg.get("fallback_providers") or []) if isinstance(r, dict)]
    return {
        "modelo": modelo.get("default") or modelo.get("model"),
        "fornecedor": modelo.get("provider"),
        "reservas": reservas,
        "voz": f"{VOZ} · Gemini",
        "push": AVISOS.configurado,
    }


def gerar(texto: str) -> tuple[Path, str]:
    """Devolve o MP3 (da cache se existir) e o nome da voz usada."""
    CACHE.mkdir(parents=True, exist_ok=True)
    base = hashlib.sha256(f"{MODELO}|{VOZ}|{texto}".encode()).hexdigest()[:32]
    for voz in (f"gemini-{VOZ}", RESERVA):
        feito = CACHE / f"{base}-{voz}.mp3"
        if feito.exists():
            return feito, voz

    destino = CACHE / f"{base}-gemini-{VOZ}.mp3"
    config = {"gemini": {"model": MODELO, "voice": VOZ}}
    if PERSONA.exists():
        config["gemini"]["persona_prompt_file"] = str(PERSONA)
    try:
        _generate_gemini_tts(texto, str(destino), config)
        return destino, f"gemini-{VOZ}"
    except Exception as erro:  # sem rede, limite da Google, etc.
        print(f"[voz] Gemini falhou ({str(erro)[:160]}); a usar {RESERVA}", flush=True)
        import edge_tts

        destino = CACHE / f"{base}-{RESERVA}.mp3"
        asyncio.run(edge_tts.Communicate(texto, RESERVA).save(str(destino)))
        return destino, RESERVA


class Pedido(BaseHTTPRequestHandler):
    def _responder(self, codigo: int, corpo: bytes, tipo: str = "application/json", extra: dict | None = None):
        self.send_response(codigo)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(corpo)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(corpo)

    def _erro(self, codigo: int, mensagem: str):
        self._responder(codigo, json.dumps({"error": {"message": mensagem}}).encode())

    def do_GET(self):
        if self.path.rstrip("/") in ("/saude", "/voz/saude"):
            return self._responder(200, b"ok", "text/plain")
        if self.path.rstrip("/") in ("/avisos/permitidos", "/avisos/estado"):
            if not hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {CHAVE}"):
                return self._erro(401, "chave de acesso inválida")
            if self.path.rstrip("/") == "/avisos/permitidos":
                return self._responder(200, json.dumps(AVISOS.permitidos(), ensure_ascii=False).encode())
            return self._responder(200, json.dumps(estado_agente(), ensure_ascii=False).encode())
        if self.path.rstrip("/") in ("/precos", "/avisos/precos"):
            if not hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {CHAVE}"):
                return self._erro(401, "chave de acesso inválida")
            tabela = json.loads((Path(__file__).resolve().parent / "precos.json").read_text())
            c = cambio()
            tabela["cambio"] = {"eur_por_usd": c["eur_por_usd"], "data": c.get("data"), "fonte": c.get("fonte")}
            return self._responder(200, json.dumps(tabela, ensure_ascii=False).encode())
        self._erro(404, "não existe")

    def do_POST(self):
        caminho = self.path.rstrip("/")
        if caminho not in ("", "/voz", "/anexos", "/avisos/dispositivo", "/avisos/vigiar", "/avisos/permitir", "/avisos/retirar"):
            return self._erro(404, "não existe")
        autorizacao = self.headers.get("Authorization", "")
        if not hmac.compare_digest(autorizacao, f"Bearer {CHAVE}"):
            return self._erro(401, "chave de acesso inválida")
        if caminho == "/anexos":
            return self._anexo()
        if caminho.startswith("/avisos/"):
            return self._avisos(caminho)
        try:
            tamanho = int(self.headers.get("Content-Length", "0"))
            texto = str(json.loads(self.rfile.read(tamanho) or b"{}").get("texto", "")).strip()
        except (ValueError, json.JSONDecodeError):
            return self._erro(400, "JSON inválido")
        if not texto:
            return self._erro(400, "falta o texto")
        texto = texto[:MAX_TEXTO]
        with _bloqueio:  # uma geração de cada vez; a cache serve as repetições
            ficheiro, voz = gerar(texto)
        self._responder(200, ficheiro.read_bytes(), "audio/mpeg", {"X-Voz": voz, "Cache-Control": "private, max-age=86400"})

    def _anexo(self):
        """Guarda uma foto enviada pela app na pasta de trabalho do agente e devolve o caminho."""
        tipo = self.headers.get("Content-Type", "").split(";")[0].strip().lower()
        if tipo not in EXTENSOES:
            return self._erro(415, "só imagens JPEG, PNG, HEIC ou WebP")
        tamanho = int(self.headers.get("Content-Length", "0") or 0)
        if not 0 < tamanho <= MAX_ANEXO:
            return self._erro(413, "imagem vazia ou maior do que 15 MB")
        dados = self.rfile.read(tamanho)
        ANEXOS.mkdir(parents=True, exist_ok=True)
        nome = hashlib.sha256(dados).hexdigest()[:24] + EXTENSOES[tipo]
        destino = ANEXOS / nome
        if not destino.exists():
            destino.write_bytes(dados)
        self._responder(200, json.dumps({"caminho": str(destino)}).encode())

    def _avisos(self, caminho: str):
        try:
            tamanho = int(self.headers.get("Content-Length", "0"))
            d = json.loads(self.rfile.read(min(tamanho, 8192)) or b"{}")
            if caminho == "/avisos/dispositivo":
                AVISOS.registar(str(d.get("token", "")), str(d.get("ambiente", "")))
            elif caminho == "/avisos/permitir":
                AVISOS.permitir(str(d.get("assunto", "")), [str(p) for p in d.get("padroes", [])])
            elif caminho == "/avisos/retirar":
                AVISOS.retirar(str(d.get("assunto", "")), d.get("padrao"))
            else:
                AVISOS.vigiar(str(d["run"]), str(d.get("assunto", "")), str(d.get("titulo", "Akili")), str(d.get("entrada", "")))
        except (ValueError, KeyError, json.JSONDecodeError) as erro:
            return self._erro(400, f"pedido inválido: {erro}")
        self._responder(200, json.dumps({"ok": True, "push": AVISOS.configurado}).encode())

    def log_message(self, formato, *args):
        print(f"[voz] {self.address_string()} {formato % args}", flush=True)


if __name__ == "__main__":
    print(f"[voz] a ouvir em 127.0.0.1:{PORTA} · {MODELO} · {VOZ} · push {'ligado' if AVISOS.configurado else 'por configurar'}", flush=True)
    AVISOS.arrancar()
    ThreadingHTTPServer(("127.0.0.1", PORTA), Pedido).serve_forever()
