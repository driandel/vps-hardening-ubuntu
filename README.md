# Montar y securizar un VPS para una aplicación móvil

Documentación del servidor que da servicio a **DexClub**, una aplicación de
colección de cartas publicada en Google Play y en la App Store. El
servidor guarda las cuentas y sincroniza la colección entre
dispositivos.

No es un tutorial copiado: es lo que hice, en el orden en que lo hice, con
las comprobaciones que demuestran que cada cosa funciona y **los cinco
tropiezos de configuración** que me encontré por el camino, que
probablemente sea lo más útil de todo el documento.

> En todo el texto, `<IP>` es la dirección pública del servidor y
> `<usuario>` la cuenta de administración. Los valores reales no se
> publican. Las direcciones de los bots que salen en los registros van
> recortadas (`45.148.x.x`): suelen ser equipos ajenos comprometidos, no
> del atacante.

```mermaid
flowchart LR
  net([Internet])

  subgraph vps["VPS — ufw: solo 22, 80 y 443 abiertos"]
    ssh["SSH<br/>solo clave, root bloqueado<br/>fail2ban: 3 intentos, 1 h"]
    ngx["nginx<br/>HTTPS + cabeceras de seguridad<br/>5 peticiones/min en las rutas de cuenta"]
    api["API FastAPI<br/>servicio systemd aislado<br/>escucha en 127.0.0.1:8000<br/>8 fallos de login / 15 min"]
    db[("PostgreSQL<br/>escucha en 127.0.0.1:5432")]
    bak["Copia diaria<br/>14 días, restauración probada"]
  end

  pc["Equipo externo<br/>60 días, suma de control verificada"]

  net -->|"443 · 80 redirige"| ngx
  net -->|22| ssh
  ngx --> api
  api --> db
  db --> bak
  bak -.->|"se descarga a diario"| pc
```

---

## Índice

1. [Punto de partida](#1-punto-de-partida)
2. [Estado inicial](#2-estado-inicial)
3. [Usuario y acceso por clave](#3-usuario-y-acceso-por-clave)
4. [Endurecer SSH](#4-endurecer-ssh)
5. [Cortafuegos: dos capas](#5-cortafuegos-dos-capas)
6. [fail2ban](#6-fail2ban)
7. [PostgreSQL](#7-postgresql)
8. [La API como servicio](#8-la-api-como-servicio)
9. [HTTPS con nginx y Let's Encrypt](#9-https-con-nginx-y-lets-encrypt)
10. [Copias de seguridad](#10-copias-de-seguridad)
11. [Incidencias](#11-incidencias)
12. [Antes y después](#12-antes-y-después)

---

## 1. Punto de partida

| | |
|---|---|
| Fecha | Septiembre de 2026 |
| Proveedor | VPS con 2 vCPU, 4 GB de RAM y 120 GB de disco |
| Sistema | Ubuntu 26.04 LTS, imagen del proveedor |
| Servicios | PostgreSQL, API en FastAPI, nginx como proxy |
| Acceso inicial | root con contraseña, facilitado por el panel |

El objetivo no era solo "que funcione", sino que **funcione sin
vigilancia**: que arranque solo, que se renueve el certificado solo, que
haga copias solo y que el ruido de internet no llegue a molestar.

Antes de esto, todo el montaje se había ensayado en una máquina virtual
local. Fue tiempo bien invertido: los dos problemas más raros ya los
conocía.

---

## 2. Estado inicial

Lo primero, antes de tocar nada, es **guardar cómo venía la máquina**. Es
la única forma de demostrar después qué se cerró.

```bash
{ echo "== SISTEMA =="; lsb_release -a;
  echo "== HORA =="; timedatectl;
  echo "== PUERTOS A LA ESCUCHA =="; ss -tulpn;
  echo "== SERVICIOS ACTIVOS =="; systemctl list-units --type=service --state=running --no-pager;
} > ~/estado-inicial.txt 2>&1
```

Lo que salió:

| Puerto | Escucha en | Qué es |
|---|---|---|
| 22 | `0.0.0.0` y `[::]` | SSH, **el único abierto a internet** |
| 53 | `127.0.0.54` / `127.0.0.53` | Resolución DNS interna |
| 323 | `127.0.0.1` / `[::1]` | Sincronización de hora |
| 68 | la interfaz | Cliente DHCP |

La imagen venía razonablemente limpia: reloj sincronizado,
`unattended-upgrades` ya activo y nada de más escuchando hacia fuera.

**Dos servicios que sobran en un VPS** y se desactivaron:

```bash
systemctl disable --now ModemManager fwupd
```

`ModemManager` gestiona módems que no existen en una máquina virtual, y
`fwupd` actualiza firmware de hardware físico. Ninguno aporta nada aquí, y
todo servicio que no se usa es superficie de ataque gratis.

`multipathd` y `udisks2` se dejaron: tocan almacenamiento y el riesgo de
romper algo supera lo que se gana.

**La zona horaria se dejó en UTC** a propósito: los registros quedan sin
saltos de horario de verano y son comparables con los de cualquier otro
sistema.

---

## 3. Usuario y acceso por clave

**Por qué.** Trabajar como root es el fallo de base: cualquier error o
cualquier proceso comprometido tiene control total, y además no queda
rastro de quién hizo qué.

```bash
adduser <usuario>
usermod -aG sudo <usuario>
```

**La clave, nueva y solo para este servidor.** Reutilizar una clave que ya
usas en otros sitios significa que, si se compromete, se compromete todo:

```powershell
ssh-keygen -t ed25519 -C "dexclub-vps" -f $env:USERPROFILE\.ssh\dexclub_vps
type $env:USERPROFILE\.ssh\dexclub_vps.pub | ssh <usuario>@<IP> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

`ed25519` en vez de RSA: claves más cortas, más rápidas y sin los tamaños
de RSA que hay que ir subiendo con los años. Y **con frase de paso**, que
es lo que evita que quien copie el archivo pueda usarlo tal cual.

**Comprobación.** Entrar con la clave **desde otra terminal, antes de
cerrar nada**. Este es el paso que la gente se salta y por el que acaba
encerrada fuera de su propio servidor.

```bash
ls -la ~/.ssh
# drwx------  .ssh
# -rw-------  authorized_keys
```

Permisos estrictos porque **SSH ignora las claves de archivos que puedan
leer otros**: es una protección del propio protocolo, no una manía.

---

## 4. Endurecer SSH

**Por qué.** Un servidor con SSH abierto recibe miles de intentos diarios
de bots probando usuarios y contraseñas comunes. Con claves, esos intentos
dejan de tener sentido.

Lo que se aplicó, en `/etc/ssh/sshd_config.d/01-dexclub.conf`:

```
PasswordAuthentication no      # sin contraseñas que adivinar
KbdInteractiveAuthentication no
PermitRootLogin no             # obliga a entrar como usuario y escalar con sudo
PubkeyAuthentication yes
AllowUsers <usuario>           # aunque exista otra cuenta, no entra por SSH
MaxAuthTries 3
LoginGraceTime 30              # menos tiempo con conexiones a medio abrir
```

**El número del archivo importa, y no como uno espera.** Ver
[Incidencias](#11-incidencias).

**Comprobación.** No vale leer el archivo: hay que preguntarle al programa
qué configuración tiene de verdad.

```bash
sudo sshd -T | grep -E "^(passwordauthentication|permitrootlogin|allowusers|maxauthtries)"
# passwordauthentication no
# permitrootlogin no
# allowusers <usuario>
# maxauthtries 3
```

Y desde fuera:

```
$ ssh root@<IP>
root@<IP>: Permission denied (publickey).
```

---

## 5. Cortafuegos: dos capas

Hay **dos cortafuegos distintos**, y esto confunde al principio:

**El del panel del proveedor** filtra antes de llegar a la máquina. Un
puerto cerrado ahí no se abre desde dentro por mucho que se configure.

**El de la máquina (ufw)** filtra lo que ya llegó.

Las dos capas tienen que permitir el tráfico. No es redundante: si mañana
instalo algo que se pone a escuchar, ufw lo tapa aunque el puerto siga
abierto en el panel.

**En el panel** venían abiertos 22, 80, 443 y además **8443 y 8447**, los
del panel de administración Plesk, que no se instaló. Se borraron: una
regla abierta que no se usa es superficie de ataque sin contrapartida.

**En la máquina:**

```bash
sudo ufw default deny incoming     # lo que no se abre, no entra
sudo ufw default allow outgoing    # el servidor sí necesita salir
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

Denegar por defecto y abrir lo justo, en vez de ir cerrando puertos uno a
uno: así lo que se instale mañana no queda expuesto por accidente.

El 80 se abre aunque todo el tráfico acabe siendo HTTPS, porque Let's
Encrypt lo necesita para validar el dominio.

**Comprobación:**

```
Status: active
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
22/tcp (OpenSSH)           ALLOW IN    Anywhere
80/tcp                     ALLOW IN    Anywhere
443/tcp                    ALLOW IN    Anywhere
```

En `estados/estado-final.txt` ese mismo listado sale con varias reglas
`REJECT IN` por encima. No están en la configuración: las escribe
fail2ban sobre la marcha y desaparecen solas cuando caduca el bloqueo.

---

## 6. fail2ban

**Por qué.** El 22 tiene que estar abierto sí o sí. fail2ban mira quién
falla al entrar y lo bloquea un rato.

Con las contraseñas ya desactivadas, **no está tapando un agujero: está
quitando ruido**. Cada intento consume proceso, llena el registro y esconde
lo que sí importa. Es defensa en capas.

`/etc/fail2ban/jail.d/99-dexclub.local`:

```
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
banaction = ufw    # que el bloqueo lo aplique el mismo cortafuegos

[sshd]
enabled = true
```

`banaction = ufw` para no tener dos cortafuegos distintos escribiendo
reglas sobre la misma máquina.

**Comprobación:**

```bash
sudo fail2ban-client get sshd bantime    # 3600
sudo fail2ban-client get sshd maxretry   # 3
sudo fail2ban-client status sshd
```

### Lo que recibe un servidor recién encendido

Medido en las **dos primeras horas** de vida de la máquina:

```bash
sudo journalctl -u ssh --since "2 hours ago" | grep -oP "from \K[0-9.]+" | sort | uniq -c | sort -rn | head
#    618 103.174.x.x
#     14 2.57.x.x
#     10 27.72.x.x
```

Y los usuarios que probaban:

```
5 admin
2 ftpuser
2 aleisha
1 frappe
1 1
```

Ninguno podía entrar: no existen, y el acceso por contraseña ya estaba
desactivado. Pero **618 peticiones desde una sola dirección en dos horas**
explica mejor que cualquier argumento por qué no se deja un servidor con
la configuración de fábrica.

### Tres semanas después

Lo de arriba son las dos primeras horas. Con la máquina ya en producción,
esto es lo que llevaba acumulado la cárcel de sshd:

```
Currently failed:    2
Total failed:     2037
Currently banned:    6
Total banned:      267
```

Ninguno habría entrado de todas formas: no hay contraseñas que probar.
Pero son **2037 conexiones que ya no llegan** al daemon ni al registro,
y seis direcciones bloqueadas en este mismo momento. Una configuración
que parece correcta y una que se ve trabajando no son lo mismo.

---

## 7. PostgreSQL

**Lo más importante es dónde escucha:**

```bash
sudo ss -tulpn | grep 5432
# tcp LISTEN 127.0.0.1:5432
```

La API vive en la misma máquina, así que la base de datos no necesita
salir a la red. En local significa que, aunque alguien acertara la
contraseña, no tendría por dónde entrar. Por eso el 5432 no se abre en
ningún cortafuegos.

**Usuario propio para la aplicación**, sin superusuario, y con nombre
distinto del de la base de datos para que no se confundan:

```sql
CREATE USER <usuario_bd>;
\password <usuario_bd>          -- ver Incidencias
CREATE DATABASE dexclub OWNER <usuario_bd>;
\c dexclub
GRANT ALL ON SCHEMA public TO <usuario_bd>;
```

**Esa última línea es obligatoria desde PostgreSQL 15**: ser dueño de la
base de datos ya no da permisos sobre el esquema `public`. Es un cambio
que rompe casi todos los tutoriales anteriores a esa versión.

**Comprobación:**

```bash
psql -h 127.0.0.1 -U <usuario_bd> -d dexclub -c "\dn+"
# public | pg_database_owner | ... <usuario_bd>=UC/pg_database_owner
```

### El esquema

Seis archivos que se aplican en orden, cada uno idempotente para poder
relanzarlo sin romper nada. 13 tablas: cuentas, colección, certificadas,
álbumes, listas de deseados, barajas, torneos, partidas y etiquetas.

Dos decisiones que condicionan todo lo demás:

**Las bajas se marcan, no se borran.** Si una fila desapareciera sin dejar
rastro, un dispositivo que no se hubiera sincronizado la volvería a subir
creyendo que al servidor le faltaba. Marcarla deja constancia de que fue
una decisión.

**La fecha de modificación la pone el servidor**, con un trigger, nunca el
cliente. Si cada móvil mandara la suya, bastaría con tener el reloj mal
para que sus cambios ganaran siempre. Y los relojes de los móviles se
desajustan solos.

---

## 8. La API como servicio

**Por qué.** Arrancarla a mano significa que se cae al cerrar la sesión y
no vuelve sola tras un reinicio.

`/etc/systemd/system/dexclub-api.service`, con la parte interesante:

```ini
Restart=always
RestartSec=5

NoNewPrivileges=true         # no puede ganar privilegios ni con binarios setuid
PrivateTmp=true              # su /tmp es suyo, no ve el del resto
ProtectSystem=strict         # todo el disco en solo lectura...
ReadWritePaths=/home/<usuario>/api   # ...salvo su propia carpeta
ProtectHome=read-only
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
```

Ese bloque es el que convierte el servicio en algo acotado: **si algún día
alguien consigue ejecutar código a través de la API, se encuentra un disco
de solo lectura y sin forma de escalar privilegios.**

Las credenciales van en un `.env` con permisos `600`, fuera del
repositorio. El entorno de Python es un *venv*: Ubuntu 26.04 ya no deja
instalar paquetes en el sistema, y además así las versiones de la
aplicación no dependen de las del sistema operativo.

**La API escucha solo en `127.0.0.1`**: quien habla con ella desde fuera es
nginx. Nunca está expuesta directamente.

**Comprobación de verdad:** reiniciar la máquina entera.

```bash
sudo reboot
# ...
systemctl is-active dexclub-api     # active
curl -s http://127.0.0.1:8000/estado # {"ok":true}
sudo ufw status | head -3            # Status: active
```

---

## 9. HTTPS con nginx y Let's Encrypt

**Por qué un proxy delante.** La API no gestiona certificados ni límites de
peticiones, y no debería: nginx hace eso mucho mejor y deja a la API
dedicarse a lo suyo. Además, así la aplicación nunca toca internet
directamente.

**El subdominio** `api.<dominio>` se crea con un registro A apuntando a la
IP. Conviene hacerlo con antelación: hasta que no propaga, Let's Encrypt no
puede validar y cada intento fallido consume cuota.

```bash
dig +short api.<dominio>    # debe devolver <IP>
```

**El certificado:**

```bash
sudo certbot --nginx -d api.<dominio>
```

Deja configurada la renovación automática. La comprobación que importa no
es que el certificado exista, sino que **se renovará solo dentro de tres
meses**:

```bash
sudo certbot renew --dry-run
# Congratulations, all simulated renewals succeeded
```

**Cabeceras de seguridad**, dentro del bloque del 443:

```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "no-referrer" always;
add_header X-Frame-Options "DENY" always;
server_tokens off;
```

`server_tokens off` también en la configuración global: si solo se pone en
el sitio, **las páginas de error que genera nginx fuera del bloque siguen
enseñando la versión**, que es justo lo que busca quien rastrea fallos
conocidos.

**Límite de peticiones** en las rutas de cuenta, que es donde alguien
probaría contraseñas a lo bruto. Esto fail2ban no lo ve: es tráfico HTTP
normal.

```nginx
# en nginx.conf, dentro de http
limit_req_zone $binary_remote_addr zone=cuentas:10m rate=5r/m;

# 429 en vez del 503 que nginx devuelve por defecto. Un 503 significa "el
# servidor está roto" e invita al cliente a reintentar; 429 es "vas muy
# rápido", que es lo que pasa de verdad.
limit_req_status 429;

# en el sitio, en /login, /registro y /recuperar
limit_req zone=cuentas burst=3 nodelay;
```

Cinco por minuto con margen de tres. Una persona que se equivoca de
contraseña nunca llega ahí; un ataque por fuerza bruta, a la primera.

**La IP real tiene que llegar a la API**, o el límite que lleva ella por
dentro contaría todas las peticiones como si vinieran del mismo sitio:

```nginx
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

Esa cabecera solo es de fiar porque la pone este nginx y la API escucha en
`127.0.0.1`. Si se pudiera llegar a ella directamente, cualquiera se la
inventaría y se saltaría el límite poniendo una IP distinta en cada
intento.

### Dos límites, y no sobra ninguno

nginx frena el **ritmo**: corta una ráfaga, pero se reabre en cuanto bajas
a una petición cada doce segundos. Eso deja pasar al que prueba despacio,
que es justo el patrón que roba cuentas.

Por eso la API lleva el suyo, que cuenta **volumen**: ocho fallos en
quince minutos, por cuenta y por IP. Los fallos se apuntan exista o no la
cuenta — si solo contaran los de cuentas reales, el 429 revelaría qué
correos están registrados, que es lo que evita el mensaje común del login.

Las dos devuelven 429, así que la aplicación las trata igual venga de
donde venga.

**Comprobación de la capa de nginx.** Sin cuerpo en la petición la API
responde 422 antes de mirar nada, así que aquí solo se está probando
nginx:

```bash
for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code} " -X POST https://api.<dominio>/login; done
# 422 422 422 422 429 429 429 429 429 429
```

Pasan cuatro —la primera más las tres del `burst`— y el resto se corta.

**Y la de la API**, con cuerpo válido y despacio, para que las peticiones
lleguen a atravesar nginx:

```bash
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "%{http_code} " -X POST https://api.<dominio>/login \
    -H 'Content-Type: application/json' \
    -d '{"correo":"prueba@ejemplo.com","clave":"malamalamala"}'
  sleep 13
done
# 401 401 401 401 401 401 401 401 429 429
```

> Cada ráfaga deja el cubo de nginx vacío unos minutos: 5r/m repone un
> hueco cada doce segundos. Dos pruebas seguidas dan resultados distintos
> sin que nada esté mal, y conviene usar un correo que no se haya usado
> antes o responderá el contador de la API por el de nginx.

Y las cabeceras:

```bash
curl -s -D - -o /dev/null https://api.<dominio>/estado
# HTTP/1.1 200 OK
# Server: nginx
# Strict-Transport-Security: max-age=31536000; includeSubDomains
# X-Content-Type-Options: nosniff
# Referrer-Policy: no-referrer
# X-Frame-Options: DENY
```

> Detalle: `curl -I` envía una petición HEAD y la API responde `405`. Hay
> que usar `-D -` para ver las cabeceras de una respuesta normal.

---

## 10. Copias de seguridad

Un volcado diario, rotación de 14 días y **restauración probada**.

La contraseña no va dentro del script: se lee de `~/.pgpass`, que
PostgreSQL **ignora si no tiene permisos `600`**. Así el script se puede
leer, copiar o publicar sin filtrar nada.

```bash
umask 077     # las copias llevan datos de usuarios: solo las lee su dueño

pg_dump -h 127.0.0.1 -U <usuario_bd> -d dexclub --clean --if-exists \
  | gzip > "$ARCHIVO"

# Un archivo vacío es peor que ninguno: parece que hay copia.
[ -s "$ARCHIVO" ] || { echo "La copia salió vacía" >&2; exit 1; }

find "$DESTINO" -name 'dexclub_*.sql.gz' -mtime +14 -delete
```

Catorce días porque, si un fallo no se ha notado en dos semanas, tampoco se
va a arreglar volviendo a esa fecha.

Programado con cron a las 4:30, cuando nadie usa la aplicación.

**La comprobación que casi nadie hace**, y la única que demuestra que la
copia sirve:

```bash
sudo -u postgres psql -c "CREATE DATABASE prueba_restaura OWNER <usuario_bd>;"
gunzip -c ~/copias/dexclub_*.sql.gz | psql -h 127.0.0.1 -U <usuario_bd> -d prueba_restaura
psql -h 127.0.0.1 -U <usuario_bd> -d prueba_restaura -c "\dt"   # 13 tablas
sudo -u postgres psql -c "DROP DATABASE prueba_restaura;"
```

### Fuera del servidor

Lo anterior deja las copias en el mismo disco que la base de datos, y una
copia que solo existe en la máquina que puede fallar no es una copia. Se
descargan a diario a un equipo propio.

**El equipo tira; el servidor no empuja.** Al revés, ese equipo tendría que
aceptar conexiones entrantes y habría que abrirle un puerto al router: se
ampliaría la superficie de ataque de una red doméstica para proteger un
servidor. Tirando desde fuera, el servidor no guarda ninguna credencial del
destino, y quien lo comprometa no alcanza las copias ya descargadas ni
puede borrarlas.

**Una clave sin frase de paso, pero que solo sabe hacer una cosa.** Una
tarea programada no puede escribir una frase de paso, así que la clave que
usa va sin ella. Eso solo es aceptable si quien la robe no puede hacer nada
con ella, y de eso se encarga un comando forzado en `authorized_keys`:

```
command="/usr/bin/tar -czf - -C /home/<usuario>/copias --exclude='*.sh' .",restrict ssh-ed25519 AAAA... copias
```

Con esa línea, quien se conecte con esa clave **no obtiene una sesión**:
pida lo que pida, el servidor ejecuta ese `tar` y devuelve el contenido de
la carpeta de copias. `restrict` apaga el resto — sin terminal, sin reenvío
de puertos, sin agente.

**La comprobación es pedirle otra cosa:**

```bash
ssh copias-dexclub "ls -la /etc"
# devuelve el mismo tar, no un listado de /etc
```

**Del lado del equipo** (`ejemplos/traer-copias.ps1`): descarga, extrae y
**descomprime cada copia entera para validar su suma de control** — mirar
los dos primeros bytes solo diría que *parece* un `.gz`. Guarda 60 días,
más que los 14 del servidor, así que el equipo externo es además el archivo
largo: conserva copias que allí ya se borraron.

Y si la copia más reciente tiene más de dos días, **falla a propósito**. El
riesgo real no es que esto reviente, es que deje de funcionar en silencio y
no se note hasta el día que haya que restaurar.

**Lo que sigue pendiente:** todo esto vive en un solo equipo. Falta una
tercera ubicación fuera de casa, y entonces habrá que cifrarlas antes de
que salgan: llevan correos y hashes de contraseña de usuarios.

---

## 11. Incidencias

La parte más útil del documento. Cinco tropiezos, y **una lección
común**.

### 1. La configuración de SSH que no se aplicaba

**Qué pasó.** La imagen del proveedor trae
`/etc/ssh/sshd_config.d/50-cloud-init.conf` con `PasswordAuthentication
yes`, que anula lo que diga `sshd_config`. Puse mi configuración en un
archivo `99-` pensando que ganaba el último en leerse.

No fue así: **SSH se queda con el primer valor que encuentra**. Como los
archivos se procesan en orden alfabético, el `yes` del `50-` ya estaba
fijado cuando llegaba mi `no`.

Lo curioso es que el resto de mis ajustes **sí** se aplicaron —
`PermitRootLogin`, `AllowUsers`— porque nadie los había fijado antes. Un
archivo a medias funcionando es más difícil de detectar que uno que no
funciona en absoluto.

**Cómo se detectó.** `sudo sshd -T` muestra la configuración efectiva.
Ahí seguía apareciendo `passwordauthentication yes` mientras el archivo
decía lo contrario.

**Solución.** Renombrar a `01-dexclub.conf`, para que se lea antes.

### 2. fail2ban, exactamente al revés

**Qué pasó.** Configuré `jail.local` con una hora de bloqueo y tres
intentos. Al comprobarlo, el baneo había expirado a los diez minutos.

```bash
sudo fail2ban-client get sshd bantime    # 600  (el valor por defecto)
sudo fail2ban-client get sshd maxretry   # 5
```

`/etc/fail2ban/jail.d/defaults-debian.conf` se lee **después** de
`jail.local` y lo pisa. Aquí **gana el último**, justo al contrario que en
SSH.

**Solución.** Poner la configuración en `jail.d/99-dexclub.local`.

### 3. La contraseña que rompía la conexión

**Qué pasó.** Creé el usuario de PostgreSQL con `CREATE USER ... WITH
PASSWORD 'x'` y la contraseña acabó guardada con texto mezclado. Además
llevaba `@`, `ñ` y `!`, y eso rompe la cadena de conexión: **la `@` es el
separador entre credenciales y servidor** en una URL, y el `!` lo
interpreta la propia terminal.

```
psql: error: unexpected spaces found in "...", use percent-encoded spaces (%20) instead
```

**Solución.** Fijar la contraseña con `\password`, que la pide sin
mostrarla y sin pasar por comillas, y conectar con parámetros
(`-h -U -d`) en vez de con una URL. Así los caracteres especiales dejan de
importar.

### 4. El SSH que figuraba desactivado

**Qué pasó.** Al repasar el estado final, `systemctl is-enabled ssh`
devolvía `disabled` mientras el servicio estaba `active`. Leído tal cual:
SSH funciona ahora pero no arrancaría en el próximo reinicio, que en una
máquina remota significa quedarse fuera.

**Por qué era así.** Ubuntu arranca SSH por *socket*. Quien escucha en el
22 y levanta el daemon cuando entra una conexión es `ssh.socket`, no
`ssh.service`; el servicio figura desactivado porque no es él quien tiene
que arrancar solo.

```bash
systemctl is-enabled ssh.socket   # enabled
systemctl is-active  ssh.socket   # active
```

**Por qué lo cuento aunque no rompiera nada.** Es el único que no me
costó tiempo, y es el que más me podría haber costado: la
reacción natural ante un `disabled` es habilitar `ssh.service`, y se
acaba con dos unidades peleándose por el mismo puerto. La comprobación de
verdad ya estaba hecha sin saberlo, en el reinicio del punto 8: SSH
volvió solo.

**Solución.** Ninguna, estaba bien. Lo que cambió fue la captura del
estado, que ahora pregunta por las dos unidades para que la diferencia se
vea en vez de confundir.

### 5. Las cabeceras que no llegaban a una ruta

**Qué pasó.** Las cuatro cabeceras de seguridad están declaradas a nivel de
`server`, así que las hereda todo el sitio. Al añadir una caché al archivo
de precios —una sola línea, `add_header Cache-Control ...` dentro de su
`location`— esa ruta dejó de enviarlas.

**Por qué.** En nginx, `add_header` **no se acumula**: un bloque hereda las
cabeceras del nivel de arriba *solo si no declara ninguna propia*. En
cuanto declara una, pierde todas las heredadas. Está documentado, pero es
lo contrario de lo que uno espera de una directiva que se llama "add".

El resultado: `/precios.json` se servía sin HSTS, sin `nosniff`, sin
`Referrer-Policy` y sin `X-Frame-Options`, mientras el resto del sitio sí
las llevaba. Y es la ruta con más tráfico de todas: la piden todas las
instalaciones de la aplicación, una vez al día.

**Cómo se detectó.** Mirando la respuesta, no la configuración. Dos rutas
del mismo sitio contestando distinto:

```bash
curl -s -D - -o /dev/null https://api.<dominio>/precios.json
# Cache-Control: public, max-age=3600
# (y nada más)

curl -s -D - -o /dev/null https://api.<dominio>/estado
# Strict-Transport-Security: max-age=31536000; includeSubDomains
# X-Content-Type-Options: nosniff
# Referrer-Policy: no-referrer
# X-Frame-Options: DENY
```

**Solución.** Repetir las cuatro dentro del `location`. Es duplicación, y
es la que hay: lo único que evita repetirlas es un módulo que no viene
compilado de serie.

**Lo que lo hacía difícil de ver.** `nginx -t` pasa. No hay ningún aviso en
el registro. Y el archivo leído de arriba abajo parece correcto, porque las
cabeceras están ahí, en el bloque de más arriba. Nada falla: simplemente
una ruta responde distinto al resto, y eso no se ve si no se pregunta por
esa ruta en concreto.

### La lección común

Las cinco veces lo que yo creía y lo que hacía la máquina no coincidían.
Las cuatro primeras se destaparon igual: **preguntándole al programa qué
configuración tiene, en vez de leer el archivo.**

```bash
sudo sshd -T                      # SSH
sudo fail2ban-client get <cárcel> # fail2ban
systemctl is-enabled <unidad>     # qué arranca solo, y cuál
sudo ss -tulpn                    # qué escucha de verdad
sudo ufw status verbose           # qué filtra de verdad
```

**La quinta no habría salido así.** `nginx -T` muestra la configuración
efectiva, y ahí las cabeceras aparecen, correctamente, en el bloque
`server`. Lo que no dice es que una ruta concreta no las vaya a enviar. Esa
no es una pregunta sobre la configuración: es una pregunta sobre la
respuesta.

```bash
curl -s -D - -o /dev/null https://api.<dominio>/<ruta>
```

Y tres conclusiones. Para cualquier servicio con directorios `.d`, **no des
por hecho quién gana**: en SSH, el primero; en fail2ban, el último.
Compruébalo siempre. Antes de eso, **no des por hecho cómo se llama lo que
quieres comprobar**: preguntarle a la unidad equivocada devuelve una
respuesta correcta a otra pregunta. Y cuando lo que importa es lo que sale
por el cable, **la configuración efectiva tampoco basta**: hay que pedirle
al servidor lo mismo que le va a pedir un cliente y mirar lo que
contesta.

---

## 12. Antes y después

| | Al empezar | Al terminar |
|---|---|---|
| Acceso | root con contraseña | Usuario normal, solo clave, root bloqueado |
| Usuarios por SSH | Todos | Uno (`AllowUsers`) |
| Intentos fallidos | Sin límite | 3, luego una hora de bloqueo |
| Bloqueos reales | — | 267 direcciones en tres semanas |
| Puertos abiertos | 22, 80, 443, 8443, 8447 (panel) | 22, 80, 443 |
| Base de datos | — | Solo en local, usuario sin privilegios |
| Aplicación | — | Servicio aislado, arranca sola |
| Tráfico | — | HTTPS obligatorio, renovación automática |
| Fuerza bruta web | — | 5 intentos/minuto en nginx y 8 fallos cada 15 min en la API |
| Copias | Ninguna | Diarias, rotadas, con restauración probada y descargadas fuera |

### Lo que queda pendiente

- Una tercera copia fuera de casa, cifrada antes de salir del equipo.
- Cárceles de fail2ban para nginx, cuando haya tráfico real que analizar.
- Revisar los registros a los pocos días: qué llega, qué se bloquea y si
  algo legítimo está cayendo por error.

---

## Cómo está organizado esto

```
vps-hardening-ubuntu/
├── README.md                 este documento
├── ejemplos/
│   ├── sshd_01-dexclub.conf
│   ├── jail.d_99-dexclub.local
│   ├── nginx-dexclub-api.conf
│   ├── dexclub-api.service
│   ├── copia.sh
│   ├── traer-copias.ps1      descarga al equipo externo
│   └── env.ejemplo           con valores falsos
└── estados/
    ├── estado-inicial.txt
    └── estado-final.txt
```

**Nada de lo que hay aquí incluye la IP real, el nombre de usuario, claves
ni contraseñas.** Los números de configuración sí: no son secretos y son lo que hace útil este documento.
