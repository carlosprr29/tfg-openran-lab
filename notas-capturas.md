# Capturas PCAP: qué se captura y cómo leerlo

El laboratorio genera capturas de forma automática en `logs/`. No hay que
activar nada durante la ejecución: basta con parar los componentes al terminar
el experimento, porque los ficheros se vuelcan al cerrarse el proceso.

---

## Qué se captura y dónde

| Fichero | Contiene | Tamaño típico |
|---|---|---|
| `logs/ue/ue1_mac_nr.pcap` | Tráfico 5G del terminal 1 | ~125 KB / 30 s |
| `logs/ue/ue2_mac_nr.pcap` | Ídem, terminal 2 | ~125 KB |
| `logs/ue/ue3_mac_nr.pcap` | Ídem, terminal 3 | ~125 KB |
| `logs/ue/ueN_nas.pcap` | Señalización NAS de cada terminal | ~578 B |
| `logs/ran/du/du_mac.pcap` | **Tráfico agregado de todos los terminales** | ~383 KB |
| `logs/ran/cu_cp/cu_cp_f1ap.pcap` | Señalización CU-CP ↔ DU | ~17 KB |
| `logs/ue/ueN_mac.pcap` | *(vacío: es de LTE, no se usa)* | 24 B |
| `logs/ran/cu_cp/cu_cp_ngap.pcap` | *(pendiente: no captura)* | 0 B |
| `logs/ran/cu_cp/cu_cp_e1ap.pcap` | *(pendiente: no captura)* | 0 B |

La más útil para estudiar contención entre terminales es la de la DU, porque
contiene el tráfico de los tres junto.

---

## Configurar Wireshark (una sola vez)

srsRAN escribe estas capturas con el tipo de enlace **USER 2 (DLT=149)**, un
formato propio que Wireshark no reconoce por defecto: las interpreta como
«PKTAP» con cabeceras absurdas de millones de bytes.

Hay que indicarle que ese contenido es UDP, y dejar que el disector heurístico
de MAC-NR haga el resto.

**Desde la interfaz gráfica:**

1. `Edit → Preferences → Protocols → DLT_USER → Encapsulations Table`
2. Añadir una entrada: `User 2 (DLT=149)` con carga útil `udp`
3. `Analyze → Enabled Protocols`: comprobar que `mac_nr_udp` está marcado

La configuración queda guardada en `~/.config/wireshark/user_dlts`:

```
"User 2 (DLT=149)","udp","0","","0",""
```

**Desde la terminal**, sin configuración previa:

```bash
tshark -r logs/ue/ue2_mac_nr.pcap \
  -o 'uat:user_dlts:"User 2 (DLT=149)","udp","0","","0",""'
```

---

## Qué se ve una vez configurado

La secuencia completa de conexión de un terminal:

```
MAC-NR  RAR (RA-RNTI=57) (RAPID=0 TA=0 Temp C-RNTI=17921)
NR RRC  RRC Setup Request  (Short BSR LCG ID=0 BS=1)
MAC-NR  DL-SCH (Contention Resolution)
NR RRC  RRC Setup
NR RRC/NAS-5GS  RRC Setup Complete, Registration request
RLC-NR  [DL] [AM] SRB:1 [CONTROL] ACK_SN=1
```

Con tres terminales aparecen tres identificadores distintos (`C-RNTI` 17921,
17922 y 17923) y pueden verse reintentos de acceso aleatorio, señal de
contienda real entre ellos.

---

## Consultas útiles

```bash
UDLT='uat:user_dlts:"User 2 (DLT=149)","udp","0","","0",""'

# Cuantos accesos aleatorios hubo
tshark -r logs/ran/du/du_mac.pcap -o "$UDLT" 2>/dev/null | grep -c "RAR"

# Que terminales aparecen
tshark -r logs/ran/du/du_mac.pcap -o "$UDLT" 2>/dev/null \
  | grep -oE "C-RNTI=[0-9]+" | sort -u

# Numero total de paquetes
tshark -r logs/ran/du/du_mac.pcap -o "$UDLT" 2>/dev/null | wc -l
```

---

## Cómo tomar una captura limpia

```bash
# 1. Vaciar las capturas anteriores
sudo rm -f logs/ue/*.pcap logs/ran/du/*.pcap logs/ran/cu_cp/*.pcap

# 2. Levantar el escenario
./start-lab.sh && ./lab-multiue.sh

# 3. Generar el tráfico del experimento
for c in ue-srsue ue-srsue2 ue-srsue3; do
  docker exec -d $c ping -i 0.5 -c 60 10.45.0.1
done
sleep 35

# 4. Parar los terminales: aqui es cuando se escriben los ficheros
docker compose -f docker-compose.yaml -f docker-compose.multiue.yml \
  stop ue-simulado ue2 ue3
sleep 5
ls -lh logs/ue/*.pcap
```

**Importante:** mientras los procesos están en marcha los ficheros aparecen
vacíos o con solo la cabecera (24 bytes). Eso no significa que no se esté
capturando: el volcado se produce al cerrar el proceso.

---

## Nivel de registro: cuidado con el disco

Los ficheros `.log` de los terminales y de la DU crecen muy rápido con el
nivel en `info`. En una sesión de depuración, `logs/ue/ue1.log` llegó a
**1,76 GB**.

Para el uso normal, `all_level = warning` en los tres ficheros de
configuración. Subir a `info` solo para depurar, y volver a bajarlo después.

```bash
du -sh logs/                      # vigilar el tamaño
sudo truncate -s 0 logs/ue/*.log  # vaciar sin borrar los ficheros
```

---

## Pendiente

- **NGAP y E1AP no capturan** (0 bytes). Son señalización del plano de
  control: NGAP lleva el registro del terminal, la autenticación y el
  establecimiento de sesión con el núcleo, así que hará falta para estudiar
  ataques sobre la señalización. El F1AP sí funciona.
- Las capturas de MAC de LTE (`ueN_mac.pcap`) generan ficheros de 24 bytes
  inútiles, porque el laboratorio es 5G puro. Podrían desactivarse quitando
  `mac` de la línea `enable` en los ficheros de configuración.
