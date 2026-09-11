# Notas operativas — orden de arranque y enlace ZMQ

## REGLA FUNDAMENTAL: si reinicias la DU, reinicia SIEMPRE el UE detrás

El enlace de radio virtual entre la DU y el UE es un par de sockets ZMQ:

- La **DU hace bind** (abre el puerto `2000` y espera conexiones).
- El **UE hace connect** (se conecta al `2000` de la DU y abre su `2001`).

Si uno de los dos extremos se reinicia y el otro no, **el emparejamiento no se
rehace solo**: ambos quedan esperándose mutuamente de forma indefinida, sin
ningún mensaje de error.

### Cómo se manifiesta el problema

En el log de la DU (`logs/ran/du/du.log`), repitiéndose cada segundo:

```
[zmq:rx:0:0] [I] Waiting for reading samples. Completed 0 of 23040 samples.
[zmq:tx:0:0] [I] Waiting for data.
```

En el log del UE (`docker compose logs ue-simulado`), atascado sin avanzar:

```
Attaching UE...
Closing stdin thread.
```

(sin llegar nunca a `Random Access Transmission`)

Y como consecuencia, en el UE:

```
$ docker exec ue-srsue ip addr show tun_srsue
Device "tun_srsue" does not exist.
```

**Sin sesión PDU no existe `tun_srsue`, y sin esa interfaz el ping falla al
100%.** Es fácil confundir esto con un fallo del plano de usuario (UPF, F1-U,
N3) cuando en realidad el UE nunca llegó a registrarse.

### Diagnóstico rápido: descartar antes de tocar nada

```bash
# 1. ¿La celda de la DU está realmente activa? (mirar el FICHERO, no stdout)
grep -i "F1 Setup\|Cell was activated" logs/ran/du/du.log | tail -3

# 2. ¿El UE tiene sesión?
docker exec ue-srsue ip addr show tun_srsue

# 3. ¿El UPF tiene su interfaz levantada?
docker exec core-upf ip addr show ogstun
```

Si (1) muestra `Cell was activated` reciente pero (2) dice "does not exist",
el problema es el emparejamiento ZMQ, no la RAN ni el Core.

### Solución

Reiniciar ambos extremos **en este orden** (primero quien hace bind):

```bash
cd ~/tfg-openran-lab

docker compose stop ue-simulado
docker compose restart ocudu-du
sleep 70                       # margen para el time-to-wait de 60s del RIC
grep -i "Cell was activated" logs/ran/du/du.log | tail -2

docker compose up -d ue-simulado
sleep 25
docker compose logs -n 20 ue-simulado | grep -i "random access\|pdu session"
docker exec ue-srsue ip addr show tun_srsue
```

## Orden general de arranque del laboratorio completo

1. **Near-RT RIC** (`oran-sc-ric/`) — debe estar primero: la CU-CP y la DU se
   conectan a su red Docker (`ric_net`, declarada como externa) y fallarían al
   arrancar si esa red no existe todavía.
2. **Core 5G** (Open5GS): mongodb → NFs → AMF/SMF/UPF.
3. **OCUDU**: CU-CP → CU-UP → DU (cada una esperando a que la anterior
   confirme estar sana).
4. **UE simulado**: siempre el último, después de que la DU confirme
   `Cell was activated`.

## Otras reglas aprendidas, relacionadas

- **`docker compose up -d` NO relee un archivo de configuración montado** si la
  definición del servicio no cambió en `docker-compose.yaml`. Para aplicar
  cambios en un `.yml` de configuración hay que usar `docker compose restart`
  (o `up -d --force-recreate` si además cambian redes/volúmenes/comando).
- **Time-to-wait de 60 s del RIC**: tras desconectarse un agente E2, el RIC
  rechaza la reconexión durante 60 segundos (`E2 SETUP FAILURE`). Por eso los
  `sleep 70` al reiniciar CU-CP o DU con E2 activo.
- **Dónde mirar cada log**: la DU escribe lo importante en el **fichero**
  (`logs/ran/du/du.log`); el UE lo escribe en **stdout**
  (`docker compose logs ue-simulado`), su fichero queda casi vacío por el
  filtro `all_level = warning`. Comprobar ambos antes de dar algo por roto.
- **Logs mezclados**: `docker compose logs` conserva la salida de arranques
  anteriores. Comprobar siempre los **timestamps** o usar `--since 2m` en vez
  de `-n N`, para no diagnosticar sobre un error ya resuelto.
