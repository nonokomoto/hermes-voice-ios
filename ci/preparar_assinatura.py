"""Cria, uma única vez, o certificado de distribuição e o perfil App Store da app, e guarda-os
como segredos do GitHub. Assim os envios para o TestFlight deixam de criar certificados novos.

Corre numa máquina onde o `gh` tem sessão. A chave da App Store Connect entra por stdin e nunca é
escrita em disco nem mostrada:

    cat AuthKey_$KID.p8 | GITHUB_REPO=dono/repo APNS_TOPIC=com.example.hermesvoice \\
      ASC_KEY_ID=$KID ASC_ISSUER_ID=$ISS APPLE_TEAM_ID=$TEAM \\
      python ci/preparar_assinatura.py

Segredos criados: DIST_P12, DIST_P12_SENHA, PERFIL_APPSTORE, PERFIL_APPSTORE_NOME.
"""
import base64
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE = os.environ.get("APNS_TOPIC", "com.example.hermesvoice")  # bundle ID da app
REPO = os.environ["GITHUB_REPO"]  # dono/repositório onde guardar os segredos
NOME_PERFIL = "Hermes Voice App Store (CI)"

CHAVE_ASC = sys.stdin.read()
if "BEGIN PRIVATE KEY" not in CHAVE_ASC:
    sys.exit("A chave da App Store Connect não chegou por stdin.")


def token() -> str:
    agora = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": agora, "exp": agora + 600, "aud": "appstoreconnect-v1"},
                      CHAVE_ASC, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def pedido(metodo: str, caminho: str, corpo: dict | None = None) -> dict:
    r = urllib.request.Request(API + caminho, method=metodo, data=json.dumps(corpo).encode() if corpo else None,
                               headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r) as resposta:
            return json.load(resposta)
    except urllib.error.HTTPError as e:
        sys.exit(f"{metodo} {caminho} -> {e.code}: {e.read().decode(errors='replace')[:500]}")


def segredo(nome: str, valor: str) -> None:
    subprocess.run(["gh", "secret", "set", nome, "-R", REPO], input=valor, text=True, check=True,
                   stdout=subprocess.DEVNULL)
    print(f"segredo guardado: {nome}")


def main() -> None:
    # 1. Chave privada e pedido de certificado, gerados aqui.
    privada = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Hermes Voice CI"),
                                    x509.NameAttribute(NameOID.COUNTRY_NAME, "PT")]))
           .sign(privada, hashes.SHA256()))
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()

    # 2. Certificado de distribuição.
    cert = pedido("POST", "/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": csr_pem}}})["data"]
    der = base64.b64decode(cert["attributes"]["certificateContent"])
    certificado = x509.load_der_x509_certificate(der)
    print(f"certificado criado: {cert['attributes'].get('name')} · expira {cert['attributes']['expirationDate'][:10]}")

    # 3. Perfil App Store para o bundle, com esse certificado.
    bundles = pedido("GET", f"/bundleIds?filter[identifier]={BUNDLE}")["data"]
    bundle_id = next(b["id"] for b in bundles if b["attributes"]["identifier"] == BUNDLE)
    for antigo in pedido("GET", f"/profiles?filter[name]={urllib.parse.quote(NOME_PERFIL)}")["data"]:
        pedido("DELETE", f"/profiles/{antigo['id']}")
    perfil = pedido("POST", "/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": NOME_PERFIL, "profileType": "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
            "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]},
        },
    }})["data"]
    print(f"perfil criado: {perfil['attributes']['name']}")

    # 4. .p12 com senha aleatória, e segredos no GitHub.
    senha = secrets.token_urlsafe(24)
    # Formato antigo (3DES + SHA-1), o único que o `security` do macOS importa.
    cifra = (serialization.PrivateFormat.PKCS12.encryption_builder()
             .kdf_rounds(50000)
             .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
             .hmac_hash(hashes.SHA1())
             .build(senha.encode()))
    p12 = pkcs12.serialize_key_and_certificates(b"akili", privada, certificado, None, cifra)
    segredo("DIST_P12", base64.b64encode(p12).decode())
    segredo("DIST_P12_SENHA", senha)
    segredo("PERFIL_APPSTORE", perfil["attributes"]["profileContent"])
    segredo("PERFIL_APPSTORE_NOME", NOME_PERFIL)
    print("pronto")


if __name__ == "__main__":
    main()
