"""Mostra o estado dos builds e dos grupos de teste do TestFlight para o BUNDLE_ID.

Lê do ambiente: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, BUNDLE_ID.
Não imprime a chave, o token nem emails completos.
"""
import os
import urllib.parse

from garantir_bundle import pedido


def mascarar(email: str) -> str:
    nome, _, dominio = email.partition("@")
    return f"{nome[:2]}…@{dominio}" if dominio else "…"


def main() -> None:
    bundle = os.environ["BUNDLE_ID"]
    apps = pedido("GET", "/apps?" + urllib.parse.urlencode({"filter[bundleId]": bundle}))["data"]
    if not apps:
        print(f"::error::Não há app no App Store Connect com o bundle {bundle}")
        return
    app = apps[0]
    print(f"App: {app['attributes']['name']} ({bundle})")

    builds = pedido("GET", "/builds?" + urllib.parse.urlencode({
        "filter[app]": app["id"], "sort": "-uploadedDate", "limit": "5",
        "fields[builds]": "version,processingState,uploadedDate,expired,usesNonExemptEncryption",
    }))["data"]
    print(f"Builds ({len(builds)}):")
    for b in builds:
        a = b["attributes"]
        print(f"  build {a['version']}: {a['processingState']} · enviado {a['uploadedDate']} · "
              f"expirado={a['expired']} · encriptação={a.get('usesNonExemptEncryption')}")
        detalhe = pedido("GET", f"/builds/{b['id']}/buildBetaDetail")["data"]["attributes"]
        print(f"    TestFlight interno: {detalhe.get('internalBuildState')} · externo: {detalhe.get('externalBuildState')}")

    grupos = pedido("GET", f"/apps/{app['id']}/betaGroups")["data"]
    print(f"Grupos de teste ({len(grupos)}):")
    for g in grupos:
        a = g["attributes"]
        testers = pedido("GET", f"/betaGroups/{g['id']}/betaTesters")["data"]
        emails = ", ".join(mascarar(t["attributes"].get("email") or "") for t in testers) or "nenhum"
        print(f"  {a['name']} · interno={a['isInternalGroup']} · todos os builds={a.get('hasAccessToAllBuilds')} · testadores: {emails}")


if __name__ == "__main__":
    main()
