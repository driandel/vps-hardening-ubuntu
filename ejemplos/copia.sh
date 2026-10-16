#!/bin/bash
# Copia diaria de la base de datos de DexClub.
#
# La contraseña no va aquí: la lee de ~/.pgpass, que solo puede abrir el
# propio usuario. Así el script se puede leer, copiar o publicar sin
# filtrar nada.
set -euo pipefail

# Las copias llevan datos de usuarios: solo las lee su dueño.
umask 077

DESTINO="$HOME/copias"
FECHA=$(date +%F_%H%M)
ARCHIVO="$DESTINO/dexclub_$FECHA.sql.gz"

# --clean deja el volcado listo para restaurar sobre una base con datos.
pg_dump -h 127.0.0.1 -U <usuario_bd> -d dexclub --clean --if-exists \
  | gzip > "$ARCHIVO"

# Que no se quede a medias sin avisar: un archivo vacío es peor que
# ninguno, porque parece que hay copia.
if [ ! -s "$ARCHIVO" ]; then
  echo "La copia salió vacía: $ARCHIVO" >&2
  exit 1
fi

# Se guardan 14 días. Más atrás no aporta: si un fallo no se ha notado en
# dos semanas, tampoco se va a arreglar volviendo a esa fecha.
find "$DESTINO" -name 'dexclub_*.sql.gz' -mtime +14 -delete

echo "Copia hecha: $ARCHIVO ($(du -h "$ARCHIVO" | cut -f1))"
