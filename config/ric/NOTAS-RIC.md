# Notas operativas — Near-RT RIC (O-RAN SC, i-release)

Repositorio: `oran-sc-ric` (github.com/srsran/oran-sc-ric), clonado en
`~/tfg-openran-lab/oran-sc-ric/`. Se mantiene como despliegue **separado** del
`docker-compose.yaml` del laboratorio: son 7 contenedores con sus propias
variables y versiones fijadas, y fusionarlos complicaría el mantenimiento. La
integración entre ambos se hace por red (ver apartado "Redes").

> **AVISO PARA QUIEN CLONE ESTE PROYECTO**
> `oran-sc-ric/` está excluido del control de versiones (`.gitignore`) por ser
> un repositorio de terceros. Tras clonarlo hay que aplicarle el parche del
> laboratorio:
> ```bash
> cd ~/tfg-openran-lab
> git clone https://github.com/srsran/oran-sc-ric.git
> python3 patch_ric_compose.py
> ```
> Sin ese parche, el RIC arranca con una condición de carrera que impide que
> los agentes E2 completen el procedimiento E2 Setup (ver más abajo).

## Componentes

| Contenedor | IP | Función |
|---|---|---|
| `ric_e2term` | 10.0.2.10 | Terminación E2 — **punto de conexión del gNB** (SCTP 36421) |
| `ric_e2mgr` | 10.0.2.11 | Gestor E2 — registra el estado de los nodos E2 en Redis |
| `ric_dbaas` | 10.0.2.12 | Redis — Shared Data Layer / R-NIB de la plataforma |
| `ric_submgr` | 10.0.2.13 | Gestor de suscripciones de las xApps |
| `ric_appmgr` | 10.0.2.14 | Gestor de xApps |
| `ric_rtmgr_sim` | 10.0.2.15 | Simulador del Routing Manager (tabla RMR estática) |
| `python_xapp_runner` | 10.0.2.20 | Entorno de ejecución de xApps en Python |

---

## EL PROBLEMA PRINCIPAL: carrera de arranque en cascada

Este fue, con diferencia, el fallo que más tiempo costó diagnosticar del
bloque. Conviene entenderlo bien porque los síntomas son engañosos.

### La cadena de dependencias

```
dbaas (Redis)  →  e2mgr  →  e2term  →  agentes E2 (CU-CP, DU)
```

Cada eslabón necesita que el anterior esté **operativo**, no solo arrancado.
Y ninguno de los dos primeros reintenta si falla:

1. **`e2mgr` necesita Redis.** Intenta conectar nada más arrancar. Si Redis aún
   no acepta conexiones → `dial tcp 10.0.2.12:6379: connect: connection refused`
   → o muere (código 1) o **queda vivo pero degradado**, sin poder escribir en
   la base de datos donde se registran los nodos E2.
2. **`e2term` necesita a `e2mgr`.** Al arrancar envía un mensaje `E2_TERM_INIT`
   para registrarse en la mensajería interna RMR. Si `e2mgr` no está operativo
   → `RMR_ERR_NOENDPT` → `e2term` **queda escuchando el socket SCTP pero
   desconectado del resto del RIC**.
3. **Los agentes E2 llegan** y establecen la asociación SCTP correctamente,
   pero el procedimiento **E2 Setup nunca se completa**, porque los dos
   componentes que deben procesarlo están rotos por dentro.

### Por qué el diagnóstico es engañoso

- **`docker compose ps` muestra todo `Up`.** Los contenedores no mueren, quedan
  degradados. El estado del contenedor no refleja el estado del servicio.
- **La asociación SCTP sí se establece.** `cat /proc/net/sctp/assocs` dentro de
  `ric_e2term` muestra la conexión en estado ESTABLISHED, lo que hace pensar
  que la red funciona (y funciona: el problema está una capa por encima).
- **El nodo aparece como `DISCONNECTED`**, no ausente, porque el RIC recuerda
  intentos anteriores.
- **El log de la CU-CP parece atascado** en `Trying to establish...`. En
  realidad la CU-CP **sí reintenta** (tiene una "RIC Connection Setup Routine"),
  pero los resultados van por **stdout**, no al fichero de log. Hay que mirar
  `docker compose logs ocudu-cu-cp`, no solo `logs/ran/cu_cp/cu_cp.log`.

### Hipótesis descartadas durante el diagnóstico

Se documentan porque consumieron tiempo y conviene no repetirlas:

- **Estado residual en Redis.** Se hizo `FLUSHALL` y el problema persistió.
  El estado residual existe (claves `RAN:gnb_999_070_...`) pero no es la causa.
- **Bug `free(): invalid pointer` en `e2term`.** Se observó una vez, pero en
  los intentos posteriores `RestartCount` era 0: `e2term` no crasheaba.
- **Incompatibilidad de PLMN.** El RIC se identifica con MCC 001 / MNC 01 y el
  laboratorio usa 999/70. Se comprobó que **no se validan entre sí**: el RIC
  registra los nodos con el PLMN propio de estos (`99F907` en BCD).
- **Time-to-wait de 60 s.** Existe (documentado por el propio repositorio: tras
  desconectarse un agente E2, hay que esperar 60 s antes de reintentar), pero
  no explicaba los fallos observados.

### La secuencia que SÍ funciona

```bash
cd ~/tfg-openran-lab/oran-sc-ric

docker compose up -d
sleep 20

# 1. Verificar que e2mgr conecto a Redis de verdad
docker compose logs --since 2m e2mgr | grep -E "refused|redis: got"
#    OK   -> "redis: got 7 elements in COMMAND reply"
#    MAL  -> "connection refused"  => docker compose restart e2mgr

# 2. Reiniciar e2term SIEMPRE despues, con e2mgr ya sano
docker compose restart e2term
sleep 20
docker compose logs --since 2m e2term | grep RMR_ERR_NOENDPT
#    No debe devolver nada

# 3. Comprobar que escucha (ss no existe en esa imagen; usar /proc)
docker exec ric_e2term cat /proc/net/sctp/eps      # debe listar LPORT 36421

# 4. Ya se pueden arrancar los agentes E2 (CU-CP y DU)
```

Esta secuencia está automatizada en `start_lab.sh` (sección 2), que verifica
el estado real de cada componente en lugar de limitarse a comprobar `Up`.

### Cuidado al leer los logs de `e2term` y `e2mgr`

`docker compose logs` **conserva la salida de arranques anteriores**. Un
`RMR_ERR_NOENDPT` visible en el log puede ser del arranque previo y no reflejar
el estado actual — es habitual verlo si el componente arrancó antes que `e2mgr`
y luego se reinició correctamente.

Comprobar siempre el **timestamp** del error frente al del último arranque:

```bash
docker inspect ric_e2term --format '{{.State.StartedAt}}'
docker compose logs --since "$(docker inspect ric_e2term --format '{{.State.StartedAt}}')" e2term
```

La prueba definitiva no es el log, sino el registro de nodos E2 (más abajo):
si aparecen `CONNECTED`, `e2term` está operativo por mucho que haya errores
antiguos en su log.

### Verificación final del registro E2

```bash
docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states
```

Salida esperada con la CU-CP y la DU conectadas:

```json
[{"inventoryName":"gnb_999_070_00019b", ...,"connectionStatus":"CONNECTED"},
 {"inventoryName":"gnbd_999_070_00019b_0", ...,"connectionStatus":"CONNECTED"}]
```

`gnb_...` es la CU-CP; `gnbd_..._0` es la DU (el sufijo `gnbd` indica gNB-DU).

---

## Redes

- RIC: `10.0.2.0/24`  ·  Laboratorio: `10.0.0.0/24` → **sin solapamiento**.
- Los agentes E2 (CU-CP y DU) se conectan a **ambas** redes. La del RIC se
  declara como externa en nuestro `docker-compose.yaml`:
  ```yaml
  ric_net:
    external: true
    name: oran-sc-ric_ric_network
  ```
- **Consecuencia importante:** el RIC debe levantarse **antes** que la CU-CP y
  la DU. Si la red `oran-sc-ric_ric_network` no existe, esos contenedores
  fallan al crearse.
- **Al bajar todo**, el orden es el inverso: primero `docker compose down` del
  laboratorio (libera la red) y después el del RIC. Si se hace al revés,
  Docker avisa con `Network ... Resource is still in use` y la red no se
  elimina, quedando en un estado que provoca `Connection timed out`.

Nota: esta integración por red es una **desviación consciente** respecto a la
documentación de `oran-sc-ric`, que contempla exponer el puerto SCTP 36421 en
el anfitrión para un gNB nativo. Conectando por red Docker el tráfico E2 no
sale al host.

---

## Otros avisos

- **Fallo conocido de las xApps** (documentado por el repositorio): a veces
  necesitan reiniciarse para mostrar correctamente el contenido de las
  `RIC_INDICATION`, aunque la suscripción se haya realizado bien.
- **La xApp de ejemplo trae el nodo E2 codificado por defecto** como
  `gnbd_001_001_00019b_0` (PLMN del tutorial). Hay que pasarle el nuestro:
  `--e2_node_id=gnbd_999_070_00019b_0`. Si no, falla con HTTP 503.
- **`ss` no está instalado** en la imagen de `e2term`; usar
  `cat /proc/net/sctp/eps` y `/proc/net/sctp/assocs`.
- El aviso `the attribute 'version' is obsolete` es cosmético (su compose usa
  una directiva obsoleta de Docker Compose); puede ignorarse.

## Parámetros E2 confirmados en NUESTRA imagen de OCUDU

Extraídos del propio binario (`odu e2 --help` / `ocucp e2 --help`):

- `enable_du_e2` / `enable_cu_cp_e2` (bool, por defecto `false`)
- `addrs` / `addr`, `port` (por defecto `36421`), `bind_addrs` / `bind_addr`
- `e2sm_kpm_enabled` (métricas) ← el que usamos
- `e2sm_rc_enabled` (RAN Control), `e2sm_ccc_enabled` (CCC)
- Varios `sctp_*` de ajuste fino del transporte

Además, la DU necesita la sección `metrics:` habilitada para que E2SM-KPM
tenga contadores reales que reportar (`enable_rlc` está a `false` por defecto).

