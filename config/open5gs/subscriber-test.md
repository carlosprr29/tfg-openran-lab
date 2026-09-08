# Suscriptor de prueba - Open5GS Core (TFG OpenRAN Lab)

Estos son los datos del suscriptor de prueba dado de alta en MongoDB
(colección `subscribers`, base de datos `open5gs`). Se necesitarán tal cual
al configurar el UE simulado (srsUE) más adelante — deben coincidir EXACTAMENTE.

| Campo | Valor |
|---|---|
| IMSI  | `999700000000001` |
| K     | `465B5CE8B199B49FAA5F0A2EE238A6BC` |
| OPc   | `E8ED289DEBA952E4283B54E88E6183CA` |
| PLMN  | MCC 999 / MNC 70 |
| DNN/APN | `internet` |
| Slice | SST 1 (sin SD) |

## Verificar en cualquier momento

```bash
docker exec -it core-mongodb mongosh open5gs --eval \
  'db.subscribers.find({imsi:"999700000000001"}).pretty()'
```
