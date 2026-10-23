# Despliegue en Oracle Cloud Always Free (beta, una región)

Estado: **preparado, sin ejecutar**. Los archivos (`deploy/`, `.github/workflows/`) están escritos y validados en lo posible sin la máquina (el `Caddyfile` con `caddy validate`, los YAML con un analizador); **no se han construido imágenes Docker ni se ha tocado Oracle ni Steam**. Esta guía sigue `SPEC_ONLINE.md` §16.6 (Oracle Always Free ARM64, una región; API en Go, PostgreSQL, Caddy y servidor de juego en una sola máquina) y `backend/README.md`.

Todo lo marcado **[TAREA TUYA]** necesita algo que solo tienes tú: una cuenta, una tarjeta, un dominio, una clave. El resto lo puede hacer un agente o un script.

## 0. Qué se despliega

```
 Internet ─► Caddy (80/443, TLS automático)
              ├─ /            web del juego (exportación Godot sin hilos, de /srv/web, Brotli precomprimido)
              ├─ /api/*   ──► API en Go (api:8080) ──► PostgreSQL
              └─ /ws/1, /ws/2 ► servidores de juego Godot (gameserver1:9080, gameserver2:9080), wss
```

- Una máquina Ampere A1 (ARM64) con hasta **4 OCPU y 24 GB** gratis. Capacidad estimada **450 a 900 jugadores simultáneos** (límite: CPU, luego tráfico), por confirmar en M2.
- Un proceso de servidor de juego por vCPU (§16.1.10): el compose trae dos (`gameserver1`, `gameserver2`); se añaden más copiando el bloque.
- Solo Caddy publica puertos. PostgreSQL y la API quedan en la red privada de Docker.

## 1. Cuenta de Oracle Cloud **[TAREA TUYA]**

1. Crea la cuenta en <https://www.oracle.com/cloud/free/>. Pide **tarjeta** (solo verificación; Always Free no cobra, pero la alta con tarjeta es el paso donde más cuentas se rechazan: usa datos reales y la misma tarjeta que el titular).
2. Elige la **región de origen** con cuidado: **no se puede cambiar después** y los recursos Always Free solo existen en ella. Para jugadores de Europa y América, Fráncfort o Ámsterdam; para solo América, Ashburn. Mira antes que haya capacidad A1 (a veces sale "Out of host capacity": reintentar más tarde o en otro dominio de disponibilidad).
3. Riesgo conocido: Oracle **reclama instancias inactivas** de Always Free (uso de CPU, red y memoria muy bajo durante días). Pasar la cuenta a "Pay As You Go" (sin gastar mientras uses solo recursos Always Free) suele evitarlo; compruébalo en la documentación actual de Oracle y decide. Activa avisos de presupuesto a 1 USD.

## 2. Crear la instancia **[TAREA TUYA]**

Menú: *Compute > Instances > Create instance*.

| Campo | Valor |
|---|---|
| Imagen | Canonical Ubuntu 24.04 (aarch64) |
| Forma | `VM.Standard.A1.Flex`, 4 OCPU, 24 GB (el máximo gratis; si falla por capacidad, prueba 2 OCPU y 12 GB y amplía luego) |
| Red | VCN nueva con subred **pública** y **dirección IPv4 pública** |
| SSH | sube tu clave pública (`ssh-keygen -t ed25519` si no tienes) |
| Volumen de arranque | 100 GB (el gratis llega a 200 GB entre todos los volúmenes) |

Después: *Networking > IP addresses > Reserved public IPs*: **reserva una IP** y asígnala a la instancia, para que no cambie si la recreas.

## 3. Cortafuegos **[TAREA TUYA]**

Hay dos capas y hay que abrir las dos.

**3.1 Red de Oracle** (VCN > Security List de la subred pública, o un Network Security Group). Reglas de entrada (*Ingress*), origen `0.0.0.0/0` salvo SSH:

| Protocolo | Puerto | Para qué |
|---|---|---|
| TCP | 22 | SSH. Mejor limitado a tu IP (`TU.IP/32`) |
| TCP | 80 | Certificados (Let's Encrypt) y redirección a HTTPS |
| TCP | 443 | Web, API y wss |
| UDP | 443 | HTTP/3 (opcional) |

No abras 5432 (PostgreSQL), 8080 (API) ni 9080 (servidores de juego): no deben ser accesibles desde fuera.

**3.2 Cortafuegos de la máquina.** Las imágenes de Ubuntu de Oracle traen reglas `iptables` que rechazan todo salvo SSH. En la máquina:

```sh
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p udp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

(El número `6` es la posición antes de la regla `REJECT`; comprueba con `sudo iptables -L INPUT --line-numbers`.) Docker añade sus propias reglas para los puertos publicados.

## 4. Dominio **[TAREA TUYA]**

Compra o usa un dominio y crea un registro **A** `play.tudominio.com` → la IP reservada (y un **AAAA** si activas IPv6). Espera a que resuelva (`dig +short play.tudominio.com`) antes de arrancar Caddy: si no, Let's Encrypt falla y limita los reintentos.

## 5. Preparar la máquina

```sh
ssh ubuntu@IP
# Docker Engine y el plugin compose, del repositorio oficial de Docker
sudo apt-get update && sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin brotli
sudo usermod -aG docker ubuntu
sudo mkdir -p /opt/fuelrivals/web && sudo chown -R ubuntu:ubuntu /opt/fuelrivals
```

Cierra y vuelve a abrir la sesión para que valga el grupo `docker`. Activa también las actualizaciones de seguridad automáticas (`sudo apt-get install -y unattended-upgrades`) y que NTP esté activo (`timedatectl`): los billetes de partida caducan a los 60 s y dependen del reloj.

## 6. Configuración y secretos

Copia `deploy/.env.example` a `/opt/fuelrivals/.env` y rellénalo:

```sh
cd /opt/fuelrivals && cp .env.example .env && chmod 600 .env
for v in POSTGRES_PASSWORD MASTER_KEY ADMIN_TOKEN SERVER_REGISTER_TOKEN; do echo "$v=$(openssl rand -hex 32)"; done
echo "BAN_SALT=$(openssl rand -hex 16)"
```

Pega esos valores en `.env`. **[TAREA TUYA]**: `DOMAIN`, `ACME_EMAIL`, `GHCR_OWNER` y, más adelante, las claves de Steam (§10). **Guarda una copia de `.env` en un gestor de contraseñas**: si pierdes `MASTER_KEY` hay que registrar de nuevo todos los servidores de juego, y si pierdes `BAN_SALT` se olvidan los baneos.

## 7. Imágenes en GitHub Container Registry

El flujo `.github/workflows/deploy.yml` construye la imagen de la API para **arm64 y amd64** y la sube a `ghcr.io/<propietario>/fuelrivals-api`. **[TAREA TUYA]**, una vez:

1. En GitHub: *Settings > Actions > General > Workflow permissions*: "Read and write permissions".
2. Tras el primer envío, en el paquete (*Packages > fuelrivals-api > Package settings*) ponlo **público**, o deja que la máquina inicie sesión: `echo TOKEN | docker login ghcr.io -u USUARIO --password-stdin` con un token clásico con solo `read:packages`.
3. Los nombres de imagen salen en minúsculas del propietario del repositorio; pon el mismo valor en `GHCR_OWNER`.

## 8. Despliegue desde GitHub Actions **[TAREA TUYA]**

1. Crea una clave solo para esto: `ssh-keygen -t ed25519 -f deploy_key -C fuelrivals-deploy -N ""`. Añade `deploy_key.pub` a `~/.ssh/authorized_keys` del usuario `ubuntu` en la máquina y borra los dos archivos locales después de copiarlos al paso siguiente.
2. En GitHub: *Settings > Environments > New environment* `production` (puedes exigir tu aprobación). Crea sus secretos:

| Secreto | Valor |
|---|---|
| `DEPLOY_HOST` | IP reservada o el dominio |
| `DEPLOY_USER` | `ubuntu` |
| `DEPLOY_SSH_KEY` | contenido de `deploy_key` (la privada) |
| `DEPLOY_KNOWN_HOSTS` | salida de `ssh-keyscan -t ed25519 IP` (compárala con la huella que muestra la consola de Oracle) |

3. Despliega con una etiqueta: `git tag v0.1.0 && git push origin v0.1.0`, o *Actions > Deploy > Run workflow*. El flujo copia `docker-compose.yml` y `Caddyfile` a `/opt/fuelrivals`, actualiza `API_TAG` en `.env`, hace `docker compose pull`, reinicia **solo la API**, recarga Caddy sin cortar los WebSocket abiertos y espera a que la API esté sana.

El flujo `backend-ci.yml` corre con cada cambio en `backend/`: gofmt, vet, `go mod tidy`, las pruebas con PostgreSQL real y `-race` (ninguna puede saltarse), la construcción de la imagen para las dos arquitecturas y `caddy validate`. Además falla si cambian las tablas de `scripts/sim/ranking.gd` sin actualizar Go.

## 9. Primer arranque

Si aún no has usado el flujo, copia a mano `deploy/docker-compose.yml` y `deploy/Caddyfile` a `/opt/fuelrivals/` y:

```sh
cd /opt/fuelrivals
docker compose pull && docker compose up -d      # postgres, api, caddy (los servidores de juego están en el perfil "game")
docker compose ps                                 # api "healthy"
curl -s https://play.tudominio.com/api/healthz    # {"status":"ok"}
curl -s https://play.tudominio.com/api/readyz     # {"status":"ready"}
docker compose logs --tail=30 api                 # logs JSON
```

Caddy pide el certificado al primer acceso; mira `docker compose logs caddy` si tarda.

**La web del juego.** Exporta el preset "Web" de Godot (`build/web/`), precomprímela y súbela:

```sh
cd build/web && for f in *.wasm *.pck *.js *.html; do brotli -kf -q 11 "$f"; gzip -kf -9 "$f"; done
scp -r build/web/* ubuntu@IP:/opt/fuelrivals/web/
```

Caddy sirve el `.br` a los navegadores que lo aceptan (`precompressed br zstd gzip`). No hacen falta cabeceras COOP/COEP: la exportación es sin hilos.

## 10. Steam **[TAREA TUYA]** (cuando la tengas)

- **App ID y clave de editor.** La clave de la Web API *de editor* depende de tener un App ID propio (Steam Direct, `SPEC_ONLINE.md` §16.5). Hasta entonces `STEAM_APP_ID=480` (Spacewar) y `STEAM_PARTNER_API_KEY` vacío: el inicio de sesión de escritorio responde 503 y solo funcionan los invitados y OpenID.
- **`STEAM_PARTNER_API_KEY`**: clave de editor de Steamworks (Users & Permissions > Manage Groups > Create WebAPI Key). Verifica los billetes de `getAuthTicketForWebApi` con identidad `fuelrivals` (debe coincidir con `STEAM_TICKET_IDENTITY` y con lo que pide el cliente).
- **`STEAM_WEB_API_KEY`**: clave normal de <https://steamcommunity.com/dev/apikey> (exige una cuenta de Steam con compras), para pedir el nombre de perfil. Sin ella los nombres son `P` + 4 cifras.
- OpenID no necesita clave; su URL de retorno es `https://DOMINIO/api/auth/openid/return`.

## 11. Registrar el servidor de juego

Cuando exista la exportación del servidor (otro agente; ver `deploy/Dockerfile.gameserver`), por cada proceso:

```sh
curl -s -X POST https://play.tudominio.com/api/servers/register \
  -H "Authorization: Bearer $SERVER_REGISTER_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"eu-1","region":"eu","url":"wss://play.tudominio.com/ws/1","capacity":40}'
```

Responde `{"server_id":"1","key":"<64 hex>"}`: **la clave se muestra una sola vez**. Ponlos en `.env` como `GAME1_ID` y `GAME1_KEY` (y `GAME2_*` para `/ws/2`, con `"name":"eu-2"` y `"url":".../ws/2"`). Registrar el mismo nombre otra vez rota la clave. Luego `docker compose --profile game up -d`.

Hasta que exista el emparejador (M4), una partida se crea a mano (administrador):

```sh
curl -s -X POST https://play.tudominio.com/api/admin/matches -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"server_id":"1","seats":[{"player_id":"1","seat":0},{"player_id":"2","seat":1}]}'
```

Devuelve el ID, la semilla y un billete firmado por jugador. Anular una partida (revierte exactamente los puntos aplicados): `POST /api/admin/matches/{id}/annul` con `{"reason":"..."}`.

## 12. Operación

| Tarea | Comando |
|---|---|
| Ver logs | `docker compose logs -f api` (JSON; no llevan direcciones IP) |
| Estado | `docker compose ps`; `curl https://DOMINIO/api/readyz` |
| Actualizar la API | etiqueta nueva → flujo `Deploy`; o a mano `docker compose pull api && docker compose up -d api` (segundos de corte; las sesiones están en PostgreSQL) |
| Volver atrás | pon el `API_TAG` anterior en `.env` y `docker compose up -d api` |
| Actualizar un servidor de juego sin cortar partidas | `docker compose stop gameserver1` (SIGTERM: drena, termina las salas y sale; `stop_grace_period` de 20 min) y luego `up -d gameserver1` con la imagen nueva. Mientras uno drena, el otro recibe las partidas nuevas |
| Cambiar el Caddyfile | `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile` (los WebSocket siguen abiertos hasta 30 min por `stream_close_delay`) |
| Ver alertas de resultados contradictorios | `docker compose exec postgres psql -U fuelrivals -c "select at, kind, match_id, actor from audit where severity='alert' order by at desc limit 20"` |

**Copias de seguridad [TAREA TUYA, decidir dónde]**: un volcado diario fuera de la máquina (Oracle Object Storage tiene un nivel gratuito de 20 GB, u otro proveedor). Ejemplo para `cron`:

```sh
0 4 * * * cd /opt/fuelrivals && docker compose exec -T postgres pg_dump -U fuelrivals -Fc fuelrivals | gzip > /opt/backups/fuel-$(date +\%F).sql.gz
```

y copia esa carpeta fuera con `rclone`. **Prueba una restauración** en una máquina limpia antes del primer probador externo (`pg_restore`). Para cumplir §16.6 ("WAL-G con restauración probada o Postgres gestionado") hay que pasar más adelante a WAL-G o a un servicio gestionado; el volcado diario es el mínimo de la beta. Las repeticiones están en la misma base (`bytea`), así que entran en la copia.

**Vigilancia**: pon una sonda externa (UptimeRobot u otra) a `https://DOMINIO/api/readyz`. La telemetría de Grafana Cloud (§16.6) no está conectada todavía: la API escribe logs JSON y los servidores de juego mandan métricas en el latido (tabla `servers.metrics`).

## 13. Lo que falta o no está verificado

- **No se ha construido ninguna imagen** (no había Docker): el `Dockerfile` de la API es estándar (Go con `CGO_ENABLED=0`, distroless) y el CI lo construye para ambas arquitecturas en cuanto se suba. `Dockerfile.gameserver` es solo un marcador con los pasos: depende de la exportación del servidor (M2).
- **No hay límite de conexiones por IP en el proxy** (§16.2): Caddy estándar no trae limitador de tasa. Las opciones son `ufw`/`iptables` con `hashlimit` en la máquina o compilar Caddy con el módulo `caddy-ratelimit`; la API sí limita por IP y por cuenta en inicio de sesión e invitados.
- **No se ha probado con Steam real**: la verificación de billetes y OpenID tienen pruebas con dobles (cada comprobación de §16.3 tiene su caso negativo), pero hay que probar una vez con una cuenta real y la clave de editor.
- Brotli dinámico no está en el Caddy estándar: por eso se sirve precomprimido (§9).
- El cortafuegos de Oracle y la reclamación de instancias inactivas dependen de la política vigente de Oracle: revísalo en su documentación.
