"""Garante que o Bundle ID existe na conta Apple, via App Store Connect API.

Lê do ambiente: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID, BUNDLE_NAME.
Não imprime a chave nem o token.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    with open(os.environ["ASC_KEY_PATH"]) as f:
        chave = f.read()
    agora = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": agora, "exp": agora + 600, "aud": "appstoreconnect-v1"},
        chave,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def pedido(metodo: str, caminho: str, corpo: dict | None = None) -> dict:
    req = urllib.request.Request(
        API + caminho,
        method=metodo,
        data=json.dumps(corpo).encode() if corpo else None,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as r:
            corpo = r.read()
            return json.loads(corpo) if corpo else {}
    except urllib.error.HTTPError as e:
        detalhe = e.read().decode(errors="replace")[:600]
        print(f"::error::{metodo} {caminho} -> {e.code}: {detalhe}")
        sys.exit(1)


def main() -> None:
    bundle = os.environ["BUNDLE_ID"]
    nome = os.environ.get("BUNDLE_NAME", "Pessoal")
    filtro = urllib.parse.urlencode({"filter[identifier]": bundle, "fields[bundleIds]": "identifier,name,platform"})
    existentes = [
        b for b in pedido("GET", f"/bundleIds?{filtro}")["data"]
        if b["attributes"]["identifier"] == bundle
    ]
    if existentes:
        registo = existentes[0]
        a = registo["attributes"]
        print(f"Já existe: {a['identifier']} ({a['name']}, {a['platform']})")
    else:
        registo = pedido("POST", "/bundleIds", {
            "data": {"type": "bundleIds", "attributes": {"identifier": bundle, "name": nome, "platform": "IOS"}}
        })["data"]
        print(f"Registado: {registo['attributes']['identifier']}")
    garantir_capacidades(registo["id"], os.environ.get("BUNDLE_CAPACIDADES", "").split())


def garantir_capacidades(bundle_id: str, pedidas: list[str]) -> None:
    """Liga capacidades no App ID (ex.: PUSH_NOTIFICATIONS) se ainda não estiverem ligadas."""
    if not pedidas:
        return
    atuais = {c["attributes"]["capabilityType"] for c in pedido("GET", f"/bundleIds/{bundle_id}/bundleIdCapabilities")["data"]}
    for cap in pedidas:
        if cap in atuais:
            print(f"Capacidade já ligada: {cap}")
            continue
        pedido("POST", "/bundleIdCapabilities", {"data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": cap},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}}},
        }})
        print(f"Capacidade ligada: {cap}")


if __name__ == "__main__":
    main()
