"""Notificações push da Akili (APNs), enviadas a partir do ProDesk.

A app regista o seu token e, a cada pedido, diz que run vigiar. Um fio de fundo consulta o Hermes
(`GET /v1/runs/{id}` em localhost) e avisa o iPhone quando o run pede aprovação ou acaba.

Configuração em `<perfil>/push/`:
  AuthKey_<KEYID>.p8   chave APNs da equipa (nunca sai daqui)
  equipa.txt           Team ID da conta Apple
  estado.json          dispositivos e runs vigiados (criado aqui)

O envio usa o `curl` do sistema (HTTP/2) com os cabeçalhos passados por stdin, para o token JWT
não aparecer na lista de processos.
"""
import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import jwt  # PyJWT, já instalado com o Hermes

BUNDLE = os.environ.get("APNS_TOPIC", "com.example.hermesvoice")  # bundle ID da app
HOSTS = {"producao": "api.push.apple.com", "sandbox": "api.sandbox.push.apple.com"}
INTERVALO = 2.0
VALIDADE_RUN = 6 * 3600


def motivo_legivel(motivo: str) -> str:
    m = motivo.lower()
    if "delete" in m or "rm " in m:
        return "Apaga ficheiros"
    if "sudo" in m or "root" in m:
        return "Mexe no sistema"
    if "force" in m and "push" in m:
        return "Reescreve o histórico do git"
    if "curl" in m or "pipe" in m or "download" in m:
        return "Corre código descarregado"
    if "kill" in m:
        return "Termina processos"
    if "chmod" in m or "chown" in m or "permission" in m:
        return "Muda permissões"
    return motivo[:1].upper() + motivo[1:]


def primeira_frase(texto: str) -> str:
    fala = texto.split("\nLigações:")[0].split("\nLigacoes:")[0].strip()
    linha = fala.splitlines()[0] if fala else "Acabou."
    return linha[:180]


class Avisos:
    def __init__(self, perfil: Path, chave_api: str, porta_hermes: int = 8642):
        self.pasta = perfil / "push"
        self.chave_api = chave_api
        self.hermes = f"http://127.0.0.1:{porta_hermes}"
        self._bloqueio = threading.Lock()
        self._jwt: tuple[str, float] | None = None
        self.estado = self._ler_estado()

    # ---------- configuração ----------

    @property
    def configurado(self) -> bool:
        return self._chave_apns() is not None and (self.pasta / "equipa.txt").exists()

    def _chave_apns(self) -> Path | None:
        chaves = sorted(self.pasta.glob("AuthKey_*.p8"))
        return chaves[0] if chaves else None

    def _token_jwt(self) -> str:
        agora = time.time()
        if self._jwt and agora - self._jwt[1] < 40 * 60:  # a Apple aceita até 60 min
            return self._jwt[0]
        chave = self._chave_apns()
        key_id = chave.stem.removeprefix("AuthKey_")
        equipa = (self.pasta / "equipa.txt").read_text().strip()
        token = jwt.encode({"iss": equipa, "iat": int(agora)}, chave.read_text(), algorithm="ES256",
                           headers={"kid": key_id})
        self._jwt = (token, agora)
        return token

    # ---------- estado ----------

    def _ler_estado(self) -> dict:
        try:
            return json.loads((self.pasta / "estado.json").read_text())
        except (OSError, json.JSONDecodeError):
            return {"dispositivos": {}, "runs": {}, "permitidos": {}}

    def _guardar_estado(self):
        self.pasta.mkdir(parents=True, exist_ok=True)
        destino = self.pasta / "estado.json"
        temporario = destino.with_suffix(".tmp")
        temporario.write_text(json.dumps(self.estado, ensure_ascii=False, indent=1))
        temporario.chmod(0o600)
        temporario.replace(destino)

    def registar(self, token: str, ambiente: str):
        if ambiente not in HOSTS or not token.isalnum():
            raise ValueError("token ou ambiente inválido")
        with self._bloqueio:
            self.estado["dispositivos"][token] = ambiente
            self._guardar_estado()

    def permitir(self, assunto: str, padroes: list[str]):
        """Lembra tipos de comando que o utilizador permitiu para sempre neste assunto."""
        padroes = [p for p in padroes if p]
        if not assunto or not padroes:
            raise ValueError("falta o assunto ou os padrões")
        with self._bloqueio:
            atuais = set(self.estado.setdefault("permitidos", {}).get(assunto, []))
            self.estado["permitidos"][assunto] = sorted(atuais | set(padroes))
            self._guardar_estado()

    def permitidos(self) -> dict:
        return dict(self.estado.get("permitidos", {}))

    def retirar(self, assunto: str, padrao: str | None = None):
        """Esquece uma permissão lembrada (ou todas as do assunto, sem `padrao`)."""
        with self._bloqueio:
            atuais = self.estado.setdefault("permitidos", {})
            if padrao:
                restantes = [p for p in atuais.get(assunto, []) if p != padrao]
                if restantes:
                    atuais[assunto] = restantes
                else:
                    atuais.pop(assunto, None)
            else:
                atuais.pop(assunto, None)
            self._guardar_estado()

    def _aprovar_sozinho(self, run: str, pedido: str) -> bool:
        corpo = json.dumps({"choice": "once", "request_id": pedido}).encode()
        r = urllib.request.Request(f"{self.hermes}/v1/runs/{run}/approval", data=corpo, method="POST",
                                   headers={"Authorization": f"Bearer {self.chave_api}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(r, timeout=10):
                return True
        except (OSError, urllib.error.HTTPError) as erro:
            print(f"[avisos] não consegui aprovar sozinho: {erro}", flush=True)
            return False

    def vigiar(self, run: str, assunto: str, titulo: str, entrada: str):
        with self._bloqueio:
            self.estado["runs"][run] = {"assunto": assunto, "titulo": titulo[:80], "entrada": entrada,
                                        "pedido_visto": None, "desde": time.time()}
            self._guardar_estado()

    # ---------- envio ----------

    def enviar(self, carga: dict, colapso: str | None = None):
        if not self.configurado:
            return
        token_jwt = self._token_jwt()
        corpo = json.dumps(carga, ensure_ascii=False)
        for dispositivo, ambiente in list(self.estado["dispositivos"].items()):
            cabecalhos = "\n".join([
                f'header = "authorization: bearer {token_jwt}"',
                f'header = "apns-topic: {BUNDLE}"',
                'header = "apns-push-type: alert"',
                'header = "apns-priority: 10"',
                *([f'header = "apns-collapse-id: {colapso[:60]}"'] if colapso else []),
            ])
            r = subprocess.run(
                ["curl", "--http2", "-s", "-K", "-", "-o", "-", "-w", "\n%{http_code}",
                 "--data-binary", corpo, f"https://{HOSTS[ambiente]}/3/device/{dispositivo}"],
                input=cabecalhos, capture_output=True, text=True, timeout=20)
            *resposta, codigo = (r.stdout or "\n000").rsplit("\n", 1)
            if codigo != "200":
                print(f"[avisos] APNs {codigo} {''.join(resposta)[:200]}", flush=True)
                if codigo == "410" or "BadDeviceToken" in "".join(resposta):
                    with self._bloqueio:
                        self.estado["dispositivos"].pop(dispositivo, None)
                        self._guardar_estado()

    # ---------- vigia ----------

    def _estado_run(self, run: str) -> dict | None:
        pedido = urllib.request.Request(f"{self.hermes}/v1/runs/{run}",
                                        headers={"Authorization": f"Bearer {self.chave_api}"})
        try:
            with urllib.request.urlopen(pedido, timeout=10) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            return {"status": "desaparecido"} if e.code == 404 else None
        except (OSError, json.JSONDecodeError):
            return None

    def _uma_volta(self):
        for run, info in list(self.estado["runs"].items()):
            if time.time() - info["desde"] > VALIDADE_RUN:
                self._esquecer(run)
                continue
            d = self._estado_run(run)
            if d is None:
                continue
            status = d.get("status")
            if status == "waiting_for_approval":
                a = d.get("approval") or {}
                padroes = a.get("pattern_keys") or [a.get("pattern_key")]
                permitidos = set(self.estado.get("permitidos", {}).get(info["assunto"], []))
                if (a.get("request_id") and a["request_id"] != info.get("pedido_visto")
                        and padroes and all(p in permitidos for p in padroes)
                        and self._aprovar_sozinho(run, a["request_id"])):
                    print(f"[avisos] aprovado sozinho ({', '.join(padroes)}) em {info['assunto']}", flush=True)
                    with self._bloqueio:
                        info["pedido_visto"] = a["request_id"]
                        self._guardar_estado()
                elif a.get("request_id") and a["request_id"] != info.get("pedido_visto"):
                    self.enviar({
                        "aps": {"alert": {"title": info["titulo"], "subtitle": "Precisa da tua aprovação",
                                          "body": f"{motivo_legivel(a.get('description', ''))}: {a.get('command', '')[:140]}"},
                                "sound": "default", "category": "APROVACAO", "thread-id": info["assunto"]},
                        "assunto": info["assunto"], "run": run, "pedido": a["request_id"], "padroes": padroes,
                    }, colapso=f"aprov-{run}")
                    with self._bloqueio:
                        info["pedido_visto"] = a["request_id"]
                        self._guardar_estado()
            elif status in ("completed", "failed", "cancelled", "interrupted"):
                corpo = {"completed": primeira_frase(d.get("output") or ""),
                         "failed": "Não conseguiu acabar.",
                         "cancelled": "Parou a meio.",
                         "interrupted": "O ProDesk reiniciou a meio."}[status]
                self.enviar({
                    "aps": {"alert": {"title": info["titulo"], "body": corpo}, "sound": "default",
                            "thread-id": info["assunto"]},
                    "assunto": info["assunto"], "entrada": info["entrada"],
                }, colapso=f"fim-{run}")
                self._esquecer(run)
            elif status == "desaparecido":
                self._esquecer(run)

    def _esquecer(self, run: str):
        with self._bloqueio:
            self.estado["runs"].pop(run, None)
            self._guardar_estado()

    def arrancar(self):
        def ciclo():
            while True:
                try:
                    if self.estado["runs"]:
                        self._uma_volta()
                except Exception as erro:  # nunca deixar o fio morrer
                    print(f"[avisos] erro: {erro}", flush=True)
                time.sleep(INTERVALO)

        threading.Thread(target=ciclo, name="avisos", daemon=True).start()
