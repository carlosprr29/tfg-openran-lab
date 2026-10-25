# Escenario 01 — Terminal comprometido

## Qué es

Un terminal legítimo que empieza a comportarse de forma maliciosa: genera un
patrón de tráfico que no corresponde a su uso normal. Es el caso de un
dispositivo infectado que pasa a formar parte de una red de bots, o de un
usuario que abusa de los recursos.

A diferencia de un ataque externo, aquí el atacante **ya está dentro**: es un
terminal autenticado y con sesión válida. Lo que lo delata no es que acceda,
sino *cómo* usa la red.

## Por qué es el primer candidato

- **La anomalía es individual.** Se define respecto a la línea base del propio
  terminal, no respecto a los demás. Encaja con el hallazgo de que cada
  terminal tiene su comportamiento normal.
- **No necesita herramientas externas.** Basta con cambiar el patrón de
  tráfico del generador que ya usamos.
- **Es observable con las métricas disponibles**: caudal y volumen.

## Cómo se reproduce

Partiendo del escenario holgado (los tres terminales con tráfico suave,
100/100/50 Kbps), uno de ellos —UE3, el de peor señal, para que el contraste
sea más exigente— pasa a generar una **ráfaga intensa y sostenida** muy por
encima de su patrón habitual.

El resto de terminales siguen con su tráfico normal, de modo que el escenario
es idéntico a la línea base salvo por el comportamiento de un único terminal.

## Qué esperamos observar

| Métrica | Terminal comprometido (UE3) | UE1 y UE2 |
|---|---|---|
| Caudal de subida | Salto brusco muy por encima de su normal | Posible caída leve por contención |
| Volumen transmitido | Aumento acusado | Estable |
| Retardo | Posible aumento por saturación propia | Estable o leve subida |
| Muestras reportadas | Más actividad | Estable |

La clave del experimento: **UE3 normalmente entrega ~123 Kbps**. Si de repente
entrega mucho más que eso, es una desviación de *su propia* línea base, aunque
en valor absoluto siga por debajo de UE1. Un detector que compare cada terminal
consigo mismo debería verlo; uno que compare terminales entre sí, no.

## Cómo se ejecuta

```bash
./start-lab.sh
./escenarios/01-ue-comprometido/ataque.sh
```

Genera una carpeta con fecha en `data/escenarios/`.
