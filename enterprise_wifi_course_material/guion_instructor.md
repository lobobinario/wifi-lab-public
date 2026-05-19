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
Bloque 3          → dns-spoof.sh enable      (DNS spoof, Google falso, HTTPS hijack)
Bloque 4          → mitm-control.sh inject on  (el AP te habla + robo de sesión)
Bloque 5          → análisis de captura PCAP
Bloque 6          → debate y cierre
Apéndice (opt.)   → mitm-control.sh webserver on  (HTTP vs HTTPS, lab_webserver)
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
sudo ./mitm-control.sh inject  on|off   # addon: inyección de banner HTML + robo de cookies de sesión
sudo ./mitm-control.sh webserver on|off # lab_webserver en puerto 80 (apéndice opcional)
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

# Solo inyección de banner y captura de cookies de sesión (Bloque 4)
sudo journalctl -u enterprise.service -f --no-pager | grep -E "\[INJECT\]|\[SESSION\]"

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

**Objetivo:** Demostrar que el operador del AP controla el DNS y puede redirigir cualquier dominio a una página local, sin que el cliente cambie de red ni note nada extraño en la URL. Y mostrar — con el Bloque 2 ya hecho — que el ataque combinado (DNS spoof + CA confiable) rompe HTTPS sin warning.

> **Prerrequisito**: `mitm-control.sh enable` debe haberse corrido al menos una vez en la Pi (genera `/root/.mitmproxy/mitmproxy-ca.pem`). `dns-spoof.sh enable` detecta esa CA y firma automáticamente un cert para `*.elmundo.es`. Si la CA no existe todavía, el HTTP hijack funciona igual; el HTTPS hijack se activa automáticamente la próxima vez que se ejecute `enable` después de bootstrapear mitmproxy.

**El instructor activa el ejercicio:**

```bash
sudo ./dns-spoof.sh enable
```

Esto, en una sola orden:

1. Para `lab_webserver` si estuviera activo
2. Lanza nginx con la página falsa de El Mundo en puerto 80 (HTTP hijack)
3. Genera (o reusa) un cert `*.elmundo.es` firmado por la CA de mitmproxy
4. Configura nginx para servir ese cert vía SNI en puerto 443 (HTTPS hijack)
5. Añade la entrada de spoof en dnsmasq (A → 192.168.50.1, AAAA → :: para forzar fallback IPv4)

El comando termina mostrando el status con tres líneas verdes: `dnsmasq`, `nginx HTTP`, y `https hijack`. Si la línea HTTPS aparece amarilla con `no mitmproxy-signed cert`, el prerrequisito anterior no se cumplió.

> "Ahora abrid una ventana de incógnito y entrad a elmundo.es desde el navegador."

**¿Por qué incógnito?** Los navegadores cachean redirecciones HTTP→HTTPS de sesiones anteriores, y también la lista HSTS dinámica. La ventana de incógnito parte de un estado limpio y evita esos problemas.

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

**Verificar que nginx presenta el cert firmado por mitmproxy:**

```bash
openssl s_client -connect 192.168.50.1:443 -servername www.elmundo.es </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject
# Debe mostrar:
# issuer=CN=mitmproxy, O=mitmproxy
# subject=CN=*.elmundo.es, O=Lab MITM, C=ES
```

#### La demo

Pedir DOS pruebas, en orden:

**1. HTTP** — `http://elmundo.es` en incógnito:

- Página con aspecto de El Mundo (logo, secciones, noticias)
- **Banner rojo** arriba: *"DEMO — DNS SPOOFING ACTIVO"*
- Click en una noticia → modal con la URL interceptada
- URL en barra: `http://elmundo.es`

> "¿Qué veis en la barra de URL? `elmundo.es`. Sin embargo, nunca habéis salido de esta red. El operador del AP controla lo que veis."

**2. HTTPS** — `https://www.elmundo.es` en incógnito (mismo browser que tiene la CA de mitmproxy del Bloque 2):

- Misma página falsa cargando vía HTTPS
- **Candado verde** ✓
- Sin warning ✓
- URL en barra: `https://www.elmundo.es` ✓

> "Acaban de ver el endgame del operador hostil de red. DNS spoof + cert firmado por una CA que tu sistema confía = hijack TOTAL e INVISIBLE. Sin warnings, sin candado roto, sin nada que les sugiera que están mirando una página falsa."

#### Por qué funciona — el concepto clave que confunde a casi todos

Muchos alumnos asumen "tengo la CA instalada, todo HTTPS pasa transparente". **Es falso.** La CA solo valida certs FIRMADOS POR ella. Si el server presenta un cert firmado por otra CA o self-signed, instalar la mitmproxy CA no cambia nada — el browser lo rechaza igual.

Lo que hizo `dns-spoof.sh enable` automáticamente es:

1. Tomar la **clave privada** de la CA de mitmproxy (`/root/.mitmproxy/mitmproxy-ca.pem`).
2. Generar un cert `*.elmundo.es` y firmarlo con esa clave.
3. Configurar nginx para presentarlo vía SNI.

Ese cert tiene una cadena válida hacia la CA que el browser ya confía → no hay warning. Es exactamente lo que hace un proxy MITM corporativo legítimo (Zscaler, BlueCoat) o un atacante con acceso al trust store del cliente.

#### Discusión

- ¿Qué información se podría capturar si la página falsa tuviera un formulario de login? *(spoiler: TODO, incluido HTTPS — el operador puede ver el body de POST sin warning porque ELLE es el servidor)*
- ¿Cómo detectaríais que no estáis en el El Mundo real? *(IP de destino, certificate transparency check, fingerprinting del cert)*
- ¿Por qué no funciona este ataque con `google.com` o `github.com`? *(**HSTS preload** — el navegador hardcodea esos dominios como 'siempre TLS válido' y rechaza CUALQUIER cert que no esté en su CT logs públicos)*

**Las tres capas de defensa (en orden de fuerza), para cerrar el bloque:**

1. **HSTS preload** — el navegador hardcodea ciertos dominios. Ya lo vimos en el Bloque 2 con github.com. Para esos dominios NO hay forma de hacer este hijack, ni con CA instalada.
2. **Certificate pinning** (apps móviles) — la app sabe exactamente qué cert esperar, ignora el almacén del sistema. WhatsApp, banca, Instagram en móvil son inmunes.
3. **Certificate Transparency** — todos los certs de CAs públicas se publican en logs auditables. Pero **NO aplica acá**: la CA de mitmproxy es privada, no está en CT. Es defensa contra CAs públicas comprometidas, no contra atacantes con control del trust store.

> "Conclusión brutal: SI alguien convence a tu sistema de confiar en su CA — vía MDM corporativo, malware, o tú haciendo click sin pensar — tu HTTPS no vale nada para los dominios que no tengan HSTS preload o pinning. Esa es la importancia del Bloque 2 que ya hicimos: el momento en que aceptás 'continuar de todos modos' o instalás un cert es el momento en que perdés todo."

**Al terminar:**

```bash
sudo ./dns-spoof.sh disable
```

Los archivos del cert (`/etc/nginx/ssl/elmundo-mitm.crt` y `.key`) **persisten** entre disable/enable. La próxima vez que actives el spoof, el cert se reusa automáticamente. Para borrar el cert manualmente: `sudo rm /etc/nginx/ssl/elmundo-mitm.*`.

---

### BLOQUE 4 — El AP te habla: inyección y robo de sesión (65–80 min)

**Estado del lab al entrar:** MITM ON · DNS spoof OFF (recién desactivado en Bloque 3) · CA de mitmproxy instalada en el navegador del alumno.

**Objetivo:** Demostrar que cuando el cliente confía en la CA del operador, el AP no solo OBSERVA — también MODIFICA lo que el navegador renderiza y CAPTURA sesiones activas sin que nadie se dé cuenta. Doble golpe: lo visible (banner) y lo invisible (cookie hijack).

#### Parte A — Activar la inyección (65–67 min)

```bash
sudo ./mitm-control.sh inject on
sudo ./mitm-control.sh status
```

Debería mostrar:

```text
[ON]  inject — HTML banner + cookie hijack
```

Abrir en el terminal del instructor el log filtrado:

```bash
sudo journalctl -u enterprise.service -f --no-pager | grep -E "\[INJECT\]|\[SESSION\]"
```

> "He activado algo nuevo. No os digo qué todavía. Seguid navegando con normalidad."

#### Parte B — El banner inesperado (67–72 min)

**Instrucción a alumnos:**
> "Visitad cualquier sitio HTTPS que uséis a diario: Wikipedia, YouTube, Reddit, vuestro correo, lo que sea. Cualquiera que no esté en HSTS preload (evita por ahora `github.com`, `google.com`, `facebook.com`)."

**Sitios recomendados que NO están en HSTS preload y funcionan bien para el demo:**

- `https://es.wikipedia.org`
- `https://www.bbc.com`
- `https://news.ycombinator.com`
- `https://www.reddit.com`

**Qué van a ver:** un **banner rojo fijo en la parte superior** de cualquier web que carguen, con el mensaje:

> ⚠️ Este contenido fue MODIFICADO por el operador de `CorpNet-Enterprise` — tu navegador no te ha avisado.

Mientras tanto, en el log del instructor:

```text
[INJECT] es.wikipedia.org/wiki/Espa%C3%B1a — banner injected (84512 → 84932 bytes)
[INJECT] www.bbc.com/news — banner injected (192448 → 192868 bytes)
```

**Punto de discusión (proyectado en pantalla):**
> "El candado sigue verde. El certificado sigue diciendo *'conexión segura'*. Pero el HTML que renderiza vuestro navegador NO es el que mandó Wikipedia. Lo modifiqué yo, en tránsito, sin tocar el cifrado — porque vuestro navegador confía en mi CA."

**Pregunta retórica al grupo:**
> "Si en vez de un banner rojo hubiera inyectado un `<script>` invisible que lee vuestro `localStorage`, vuestros tokens de sesión, o un formulario falso encima del login real… ¿alguien lo habría notado?"

#### Parte C — El robo silencioso (72–78 min)

> "Lo del banner era lo VISIBLE. Ahora os enseño lo que NO habéis visto."

Pedir a un voluntario que se loggee en algo donde el robo sea aceptable demostrar. Opciones según contexto:

- **Recomendado (controlado):** un servicio dummy del lab — por ejemplo `http://192.168.50.1/send` con el `lab_webserver` (ver Apéndice). No requiere credenciales reales del alumno.
- **Si hay voluntario consentido:** un sitio HTTPS sin 2FA donde tenga una cuenta de prueba (NUNCA pedir credenciales reales sin consentimiento explícito y por escrito).

En cuanto el alumno haga login, el log del instructor mostrará:

```text
============================================================
[SESSION] NEW Set-Cookie from foro.example.com
[SESSION] Client IP : 192.168.50.102
[SESSION] Set-Cookie: sessionid=eyJ1aWQiOjQyfQ.aB3c...; Path=/; HttpOnly
============================================================
============================================================
[SESSION] GET https://foro.example.com/profile
[SESSION] Source IP : 192.168.50.102
[SESSION] Cookie    : sessionid=eyJ1aWQiOjQyfQ.aB3c...
[SESSION] Paste-able: document.cookie = 'sessionid=eyJ1aWQiOjQyfQ.aB3c...';
============================================================
```

**El punch final (impacto máximo):**

1. Instructor abre **un navegador limpio** (perfil nuevo, incognito) en el equipo de proyección.
2. Navega al mismo sitio sin loggearse.
3. Abre DevTools → Console → pega el comando `Paste-able` que muestra el log.
4. Recarga la página.

**Y aparece logueado como el alumno**, sin haber tecleado nunca su password.

> "Esto se llama *session hijacking*. La cookie es la sesión. Una vez la tengo, no necesito ni vuestro password ni vuestro 2FA — ya estoy DENTRO. Y vosotros no veis nada raro en vuestra pantalla."

#### Parte D — Discusión y defensas (78–80 min)

**Tres preguntas para abrir el debate:**

1. *¿Qué defensa habría parado el banner?*
   - **HSTS preload** (sitios como `github.com` no permiten excepciones de cert ni siquiera con CA instalada).
   - **Subresource Integrity (SRI)** + **Content Security Policy (CSP)** — pero solo protegen recursos, no el HTML principal.
   - **No instalar nunca CAs de terceros en el dispositivo.**

2. *¿Qué defensa habría parado el robo de sesión?*
   - **Cookie con flag `HttpOnly`** → no protege contra MITM, solo contra XSS. Aquí no aplica.
   - **Token binding / DPoP** → cookie ligada al canal TLS o a una clave del cliente. Aún poco desplegado.
   - **2FA en cada acción crítica** → no impide el hijack, pero limita el daño.
   - **La defensa real: que el cliente no acepte la CA del operador.**

3. *Si esto pasa en una WiFi pública de un aeropuerto y el aeropuerto te pide instalar su certificado raíz para "navegar mejor"… ¿qué haces?*
   - Datos móviles. Siempre.

#### Cleanup del bloque

```bash
sudo ./mitm-control.sh inject off
sudo ./mitm-control.sh status   # confirma [OFF] inject
```

> "Apago la inyección. A partir de ahora, lo que reciben vuestros navegadores vuelve a ser lo que manda el servidor original — pero la interceptación TLS sigue activa porque sigo siendo el operador."

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

## Apéndice A — Lab Webserver: HTTP vs HTTPS (opcional)

**Cuándo usarlo:** sustituto o complemento del Bloque 4 cuando el grupo necesita un demo más controlado y pedagógico (sin webs reales) para visualizar lado a lado qué ve el operador en HTTP frente a HTTPS, con un formulario enviado por los propios alumnos. También funciona como "víctima controlada" para el robo de sesión del Bloque 4 sin recurrir a credenciales reales.

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

## Apagado al finalizar la clase

```bash
sudo ./mitm-control.sh disable
sudo ./dns-spoof.sh disable
sudo ./mitm-control.sh webserver off
```
