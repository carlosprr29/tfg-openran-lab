# Notas operativas — Near-RT RIC (O-RAN SC, i-release)

Repositorio: `oran-sc-ric` (github.com/srsran/oran-sc-ric), clonado en
`~/tfg-openran-lab/oran-sc-ric/`. Se mantiene como despliegue **separado** del
`docker-compose.yaml` del laboratorio (son 7 contenedores con sus propias
variables y versiones fijadas; fusionarlos complicaría el mantenimiento).

## Componentes

| Contenedor | IP | Función |
|---|---|---|
| `ric_dbaas` | 10.0.2.12 | Redis — backend del Shared Data Layer |
| `ric_e2term` | 10.0.2.10 | Terminación E2 — **punto de conexión del gNB** (SCTP 36421) |
| `ric_e2mgr` | 10.0.2.11 | Gestor E2 — mantiene el estado de los nodos E2 conectados |
| `ric_submgr` | 10.0.2.13 | Gestor de suscripciones de las xApps al nodo E2 |
| `ric_appmgr` | 10.0.2.14 | Gestor de xApps |
| `ric_rtmgr_sim` | 10.0.2.15 | Simulador del Routing Manager (tabla de rutas RMR estática) |
| `python_xapp_runner` | 10.0.2.20 | Contenedor con el framework Python para ejecutar xApps |

## IMPORTANTE — orden de arranque

**`docker compose up -d` a secas NO levanta bien el RIC.** Hay una condición de
carrera: `e2mgr` intenta conectarse a Redis nada más arrancar, y si `dbaas`
todavía no acepta conexiones, falla con
`dial tcp 10.0.2.12:6379: connect: connection refused` y **sale con código 1**
(no reintenta). El `depends_on` del compose solo garantiza que el contenedor de
Redis se haya iniciado, no que el servicio esté listo.

Secuencia correcta:

```bash
cd ~/tfg-openran-lab/oran-sc-ric

docker compose up -d
sleep 20

# Verificar que Redis responde de verdad
docker exec ric_dbaas redis-cli ping        # -> PONG

# Relanzar e2mgr (habra muerto en el primer intento)
docker compose up -d e2mgr
sleep 15

# Relanzar e2term para que reintente registrarse ahora que e2mgr existe
docker compose restart e2term
sleep 15

docker compose ps                            # los 7 deben estar Up
docker compose logs --since 2m e2term        # sin RMR_ERR_NOENDPT nuevo
```

### Errores esperables (y cómo interpretarlos)

- **`RMR_ERR_NOENDPT` en `e2term`**: significa que no encuentra destino para su
  mensaje `E2_TERM_INIT`. Normal si `e2mgr` no está levantado todavía. Ojo con
  los logs mezclados: comprobar siempre el **timestamp**, suele ser un error
  antiguo de un arranque previo, no el estado actual. Usar
  `docker compose logs --since 2m` en vez de `-n N`.
- **`redis: got 7 elements in COMMAND reply, wanted 6`**: aviso inofensivo de
  incompatibilidad menor de versión del cliente Redis. No impide el arranque.

## PLMN — posible incompatibilidad pendiente de verificar

En el log de `e2mgr` aparece:

```
globalRicId: { ricId: AACCE, mcc: 001, mnc: 01 }
```

El RIC viene configurado con **PLMN 001/01**, mientras que nuestro laboratorio
usa **999/70** (Core Open5GS, CU-CP, DU y UE, todos coherentes entre sí).

Todavía **no está confirmado** si el procedimiento E2 Setup valida que ambos
coincidan. Dos escenarios:

- Si el gNB se conecta y todo funciona → no hacía falta tocar nada.
- Si el RIC rechaza el E2 Setup sin motivo aparente → **este es el primer sitio
  donde mirar**. Se puede alinear cambiando el PLMN del RIC en
  `ric/configs/` (más limpio que cambiar el de todo nuestro laboratorio, que
  implicaría rehacer suscriptor, CU-CP, DU y UE).

## Otros avisos documentados por el propio repositorio

- **Time-to-wait de 60 s**: si un agente E2 se desconecta del RIC, debe esperar
  60 segundos antes de reintentar. Si no, el RIC responde `E2 SETUP FAILURE`.
  Relevante para nosotros: evitar reinicios encadenados rápidos de la DU/CU-CP
  cuando estén conectadas al RIC.
- **Fallo conocido de las xApps**: a veces necesitan reiniciarse para mostrar
  correctamente el contenido de los `RIC_INDICATION`, aunque la suscripción se
  haya realizado correctamente.
- El aviso `the attribute 'version' is obsolete` al ejecutar sus comandos es
  cosmético (su compose usa una directiva obsoleta); se puede ignorar.

## Redes

- RIC: `10.0.2.0/24`  ·  Laboratorio: `10.0.0.0/24` → **sin solapamiento**,
  ambos despliegues conviven sin conflicto.
- Punto de contacto para el agente E2 del gNB: `10.0.2.10:36421/sctp`.

## Parámetros E2 confirmados en NUESTRA imagen de OCUDU

Extraídos del propio binario (`odu e2 --help` / `ocucp e2 --help`), no de la
documentación de srsRAN:

- `enable_du_e2` / `enable_cu_cp_e2` (bool, por defecto `false`)
- `addrs` / `addr` — dirección(es) del RIC
- `port` — puerto del RIC (por defecto `36421`)
- `bind_addrs` / `bind_addr` — dirección local propia (**conviene fijarla**;
  sin ella hace un bind implícito)
- `e2sm_kpm_enabled` — modelo de servicio KPM (métricas) ← el que nos interesa
- `e2sm_rc_enabled` — modelo RAN Control
- `e2sm_ccc_enabled` — modelo CCC (presente en OCUDU, no documentado en srsRAN)
- Varios parámetros `sctp_*` de ajuste fino del transporte
