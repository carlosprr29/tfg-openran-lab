#!/usr/bin/env python3
"""
Parche para oran-sc-ric/docker-compose.yml
==========================================

Problema que resuelve
---------------------
El despliegue original de oran-sc-ric arranca todos sus servicios en paralelo.
`e2mgr` intenta conectarse a Redis (`dbaas`) nada mas iniciar y, si Redis
todavia no acepta conexiones, falla con:

    dial tcp 10.0.2.12:6379: connect: connection refused

`e2mgr` NO reintenta: o muere con codigo 1, o queda en estado degradado (vivo
pero sin acceso a la base de datos donde debe registrar los nodos E2).

Esto provoca, en cascada, que `e2term` tampoco pueda registrarse en la
mensajeria interna RMR (error RMR_ERR_NOENDPT) y quede escuchando el socket
SCTP pero desconectado del resto del RIC. El sintoma final es que un agente E2
establece la asociacion SCTP correctamente pero el procedimiento E2 Setup
nunca se completa, y el nodo aparece como DISCONNECTED indefinidamente.

Que hace este parche
--------------------
1. Anade un healthcheck a `dbaas` que comprueba con `redis-cli ping` que Redis
   responde de verdad, no solo que el contenedor ha arrancado.
2. Anade a `e2mgr` una dependencia `condition: service_healthy` sobre `dbaas`,
   de modo que Docker no lo arranque hasta que Redis este operativo.

Limitacion conocida
-------------------
Este parche elimina la carrera Redis -> e2mgr, pero NO la carrera
e2mgr -> e2term (e2term puede seguir arrancando antes de que e2mgr este
plenamente operativo). Esa segunda dependencia se resuelve en el script de
arranque del laboratorio (start_lab.sh), que reinicia e2term despues de
verificar que e2mgr ha conectado a Redis.

Uso
---
    cd ~/tfg-openran-lab
    python3 patch_ric_compose.py

Es idempotente: si el parche ya esta aplicado, avisa y no hace nada.

NOTA: oran-sc-ric es un repositorio de terceros y esta excluido del control de
versiones (.gitignore). Si se vuelve a clonar el repositorio, hay que volver a
ejecutar este script.
"""

import sys

PATH = "oran-sc-ric/docker-compose.yml"

OLD_DBAAS = """  dbaas:
    container_name: ric_dbaas
    hostname: dbaas
    image: nexus3.o-ran-sc.org:10002/o-ran-sc/ric-plt-dbaas:${DBAAS_VER}
    command: redis-server --loadmodule /usr/local/libexec/redismodule/libredismodule.so
    networks:
      ric_network:
        ipv4_address: ${DBAAS_IP:-10.0.2.12}"""

NEW_DBAAS = """  dbaas:
    container_name: ric_dbaas
    hostname: dbaas
    image: nexus3.o-ran-sc.org:10002/o-ran-sc/ric-plt-dbaas:${DBAAS_VER}
    command: redis-server --loadmodule /usr/local/libexec/redismodule/libredismodule.so
    # TFG lab: healthcheck anadido. Sin el, e2mgr arranca antes de que Redis
    # acepte conexiones, falla con "connection refused" y no reintenta.
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 5s
    networks:
      ric_network:
        ipv4_address: ${DBAAS_IP:-10.0.2.12}"""

OLD_E2MGR = """    command: ./main -port=3800 -f /opt/E2Manager/resources/configuration.yaml
    volumes:
      - type: bind
        source: ./ric/configs/routes.rtg
        target: /opt/E2Manager/router.txt"""

NEW_E2MGR = """    command: ./main -port=3800 -f /opt/E2Manager/resources/configuration.yaml
    # TFG lab: espera a que Redis este realmente listo (ver healthcheck en dbaas)
    depends_on:
      dbaas:
        condition: service_healthy
    volumes:
      - type: bind
        source: ./ric/configs/routes.rtg
        target: /opt/E2Manager/router.txt"""


def main():
    try:
        with open(PATH) as f:
            content = f.read()
    except FileNotFoundError:
        print(f"ERROR: no se encuentra {PATH}")
        print("Ejecuta este script desde la raiz del proyecto (~/tfg-openran-lab)")
        sys.exit(1)

    if "TFG lab: healthcheck anadido" in content:
        print("El parche ya estaba aplicado. No se hace nada.")
        sys.exit(0)

    if OLD_DBAAS not in content:
        print("ERROR: no se encontro el bloque 'dbaas' esperado.")
        print("El docker-compose.yml del RIC no coincide con la version prevista.")
        print("Revisalo manualmente antes de continuar.")
        sys.exit(1)

    if OLD_E2MGR not in content:
        print("ERROR: no se encontro el bloque 'e2mgr' esperado.")
        print("El docker-compose.yml del RIC no coincide con la version prevista.")
        print("Revisalo manualmente antes de continuar.")
        sys.exit(1)

    content = content.replace(OLD_DBAAS, NEW_DBAAS, 1)
    content = content.replace(OLD_E2MGR, NEW_E2MGR, 1)

    with open(PATH, "w") as f:
        f.write(content)

    print("Parche aplicado correctamente:")
    print("  - healthcheck anadido a 'dbaas'")
    print("  - depends_on (service_healthy) anadido a 'e2mgr'")


if __name__ == "__main__":
    main()
