"""Lista os certificados da conta Apple (só leitura): tipo, nome, criação e validade."""
import collections

from garantir_bundle import pedido


def main() -> None:
    certs = pedido("GET", "/certificates?limit=200&fields[certificates]=certificateType,displayName,name,expirationDate")["data"]
    por_tipo = collections.Counter(c["attributes"]["certificateType"] for c in certs)
    print("Por tipo:", dict(por_tipo))
    for c in sorted(certs, key=lambda c: (c["attributes"]["certificateType"], c["attributes"]["expirationDate"])):
        a = c["attributes"]
        print(f"  {a['certificateType']:<24} {a.get('displayName') or a.get('name')!s:<40} expira {a['expirationDate'][:10]}  id={c['id'][:6]}…")


if __name__ == "__main__":
    main()
