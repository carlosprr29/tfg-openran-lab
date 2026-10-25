# Escenario 00 — Base (sin anomalías)

Es la referencia. Tres terminales conectados generando tráfico normal, sin
ningún ataque. Todo lo demás se compara contra este.

## Cómo se monta

```bash
./start-lab.sh
./captura.sh holgado      # o base, contencion, asimetrico
```

## Qué contiene la línea base

Cuatro perfiles de tráfico ya caracterizados, en `data/capturas/`:

| Perfil | Caudal | Qué representa |
|---|---|---|
| holgado | 100/100/50 Kbps | Red con margen (la referencia más limpia) |
| base | 500 Kbps los tres | Tráfico moderado |
| contencion | 5 Mbps los tres | Congestión legítima |
| asimetrico | 5M/300/300 Kbps | Un terminal dominante |

El perfil **contencion** es clave: representa carga elevada *legítima*. Un
ataque de denegación de servicio debe distinguirse de este, no solo de la
normalidad tranquila.

## Métricas de referencia (medias por terminal)

De la sesión holgada, que es la normalidad con margen:

| Terminal | Caudal UL | Retardo UL | Retardo DL |
|---|---|---|---|
| UE1 (0 dB) | ~246 | bajo | ~18 ms |
| UE2 (10 dB) | ~250 | medio | ~21 ms |
| UE3 (20 dB) | ~123 | alto | ~21 ms |

Cada terminal tiene su propio comportamiento normal por su atenuación. La
normalidad es individual, no común.
