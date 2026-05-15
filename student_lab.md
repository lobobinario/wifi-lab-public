# Práctica de Laboratorio — Enterprise WiFi Security

> "¿Puedes confiar en la red a la que te conectas?"

---

> **Reglas del laboratorio**
>
> - Usa solo dispositivos asignados para la práctica o tu propio dispositivo si aceptas las condiciones
> - No introduzcas contraseñas, credenciales ni datos personales reales
> - No instales el certificado de laboratorio en dispositivos personales que vayas a seguir usando fuera
> - Todo el tráfico que generes puede ser visible para el instructor. Es parte del ejercicio.

---

## Escenario 1 — Conectarse y entender qué expones

### Paso 1: Conectar al SSID del laboratorio

- Red: `CorpNet-Enterprise`
- No tiene contraseña (red abierta — como muchas WiFis públicas)
- Verifica que tienes IP: debe ser `192.168.50.X`

### Paso 2: Navegar en HTTP

1. Abre el navegador y ve a `http://neverssl.com`
2. Después prueba `http://example.com`

**El instructor está ejecutando esto en el servidor:**

```bash
sudo tcpdump -i wlan0 -A 'tcp port 80' | grep "Host:\|GET \|Cookie:"
```

**Pregunta para reflexionar:**

- ¿Qué información sobre tu navegación puede ver el operador de la red en HTTP?
- ¿Qué pasaría si ese sitio HTTP fuera el portal de login de tu empresa?

---

## Escenario 1b — Formulario real: HTTP vs HTTPS en directo

El Pi tiene un servidor web con un formulario de prueba disponible en dos versiones:
una por HTTP y otra por HTTPS. El objetivo es que **compruebes con tus propios ojos**
qué ocurre en cada caso.

### Paso 1: Envía un mensaje por HTTP

Abre en el navegador:

```text
http://192.168.50.1/send
```

Observa el **banner rojo** en la página. Escribe un usuario y un mensaje
(puedes inventarlos, no uses datos reales).

Mientras envías el formulario, el instructor proyecta:

```bash
sudo tcpdump -i wlan0 -A -s 0 'tcp port 80 and dst host 192.168.50.1' 2>/dev/null \
  | grep -E "POST|user=|message="
```

**¿Qué ves en la captura del instructor?**

```text
_____________________________________________
_____________________________________________
```

### Paso 2: Envía el mismo mensaje por HTTPS

Haz clic en el enlace "→ Enviar via HTTPS" de la misma página, o abre directamente:

```text
https://192.168.50.1/send
```

El navegador mostrará un aviso de certificado no confiado — es esperado (el cert
es autofirmado para el laboratorio). Acepta la excepción y envía el mismo formulario.

El instructor proyecta el mismo `tcpdump` con filtro en puerto 443.

**¿Qué ves ahora en la captura?**

```text
_____________________________________________
_____________________________________________
```

### Paso 3: Compara los dos envíos

Abre la tabla de resultados:

```text
http://192.168.50.1/visualize
```

Verás tus dos envíos. La columna **Proto** distingue en rojo (HTTP) y verde (HTTPS).

Completa la tabla:

| | HTTP | HTTPS |
| --- | --- | --- |
| ¿El campo `user=` es visible con tcpdump? | | |
| ¿El campo `message=` es visible con tcpdump? | | |
| ¿El navegador muestra aviso de seguridad? | | |
| ¿El servidor recibe el mensaje igualmente? | | |

**Conclusión:**

> HTTPS protege los datos **en tránsito**. El servidor los recibe igual,
> pero nadie en la red puede leerlos mientras viajan.

---

## Escenario 2 — HTTPS: lo que se oculta y lo que no

### Paso 1: Visita sitios HTTPS

- `https://example.com`
- `https://wikipedia.org`
- Cualquier sitio con candado que uses habitualmente

### Paso 2: ¿Qué puede ver el instructor aunque uses HTTPS?

El instructor ejecuta:

```bash
sudo tcpdump -i wlan0 'tcp port 443' | strings | grep -oE '[a-z0-9.-]+\.[a-z]{2,}'
```

**Aunque el contenido esté cifrado, los dominios que visitas aparecen en el log.**

Esto es posible porque el nombre del servidor viaja sin cifrar en el campo **SNI** (Server Name Indication) del handshake TLS.

**Completa la tabla:**

| Dato | ¿Visible para el operador en HTTPS? |
| --- | --- |
| Dominio visitado (ej. wikipedia.org) | |
| URL exacta (ej. /wiki/Contraseña) | |
| Contenido de la página | |
| Tus credenciales si el sitio usa HTTPS | |
| Con qué frecuencia visitas un sitio | |
| Cuántos datos transferiste | |

---

## Escenario 3 — Detección de proxy: la alerta del navegador

### Paso 1: Visita `https://example.com`

¿Qué ves? Anota exactamente el mensaje del navegador:

```text
_____________________________________________
_____________________________________________
```

### Paso 2: Inspecciona el certificado

En el navegador:

- Chrome/Edge: Haz clic en el icono ⚠️ o 🔒 → "Certificado no válido" → "Certificado"
- Firefox: Haz clic en "Avanzado" → "Ver certificado"
- Safari: Haz clic en "Mostrar detalles" → "Ver certificado"

Busca y anota:

| Campo | Valor que ves |
| --- | --- |
| **Emitido para (Subject)** | |
| **Emitido por (Issuer)** | |
| **Válido desde** | |
| **Válido hasta** | |
| **¿Es el issuer una CA conocida?** | Sí / No |

**Si el Issuer no es una CA raíz conocida (DigiCert, Let's Encrypt, Comodo, etc.) → hay un proxy en la red.**

### Paso 3: Detectar el proxy desde terminal (si tienes acceso)

```bash
# En macOS o Linux:
openssl s_client -connect example.com:443 -servername example.com 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

Resultado esperado con proxy activo:

```text
issuer=O=mitmproxy, CN=mitmproxy
subject=CN=example.com
```

Resultado en red limpia:

```text
issuer=C=US, O=DigiCert Inc, CN=DigiCert Global G2 TLS RSA SHA256 2020 CA1
subject=CN=www.example.org
```

---

## Escenario 4 — Certificate pinning: por qué las apps no avisan

### Paso 1: Prueba tus apps

Mientras tienes el móvil conectado al laboratorio, abre:

- WhatsApp / Telegram
- Instagram / Twitter
- Tu app del banco

¿Funcionan? ¿Dan algún aviso?

### Paso 2: Observa el log del instructor

El instructor muestra:

```text
Client TLS handshake failed. The client disconnected during the handshake.
If this happens consistently for api.instagram.com, this may indicate that
the client does not trust the proxy's certificate.
```

**El proxy intentó interceptar la conexión. La app lo rechazó silenciosamente.**

**Pregunta:**

- Si una app silencia estos errores en lugar de avisar al usuario, ¿es eso mejor o peor desde el punto de vista de la seguridad?

---

## Escenario 5 — Entorno corporativo: CA confiada (Demo B)

> **Solo en el dispositivo de laboratorio asignado por el instructor.**

### Paso 1: Instalar la CA del proxy

Descarga el certificado desde:

```text
http://192.168.50.1:8181/mitmproxy-ca-cert.pem
```

Instálalo según tu sistema operativo (el instructor te guiará).

### Paso 2: Repetir los mismos sitios HTTPS

¿Qué ves ahora?

| Comportamiento | Demo A (sin CA) | Demo B (con CA) |
| --- | --- | --- |
| Aviso del navegador | | |
| Campo Issuer del cert | | |
| ¿El sitio carga? | | |
| ¿El proxy puede leer el contenido? | | |

### Paso 3: Reflexión

- En este escenario, el proxy puede leer todo el tráfico HTTPS. ¿Cuándo es esto legítimo?
- ¿Qué diferencia a la empresa que hace esto de un atacante?
- Si usas un dispositivo personal en una red corporativa con este tipo de proxy, ¿qué datos personales estarían expuestos?

---

## Escenario 6 — WiFi Abierta vs WPA

El instructor configurará momentáneamente la red con WPA2 (`LAB_MODE=wpa2`).

Conectaos con la contraseña que os facilite.

**Pregunta clave:**

> ¿Ha cambiado algo en los escenarios anteriores? ¿Sigue el proxy pudiendo interceptar?

**Respuesta esperada:** No cambia nada para el operador de la red. WPA protege el enlace de radio frente a otros usuarios, pero no frente al AP ni al proxy.

**Completa la tabla:**

| Amenaza | WiFi Abierta | WPA2-PSK (contraseña compartida) | WPA2-Enterprise |
| --- | --- | --- | --- |
| Vecino con Wireshark ve tu tráfico HTTP | | | |
| Vecino ve tu tráfico HTTPS descifrado | | | |
| Operador del AP ve tu tráfico HTTP | | | |
| Proxy MITM en el AP intercepta HTTPS | | | |

---

## Escenario 7 — Modificación activa de contenido (Fase C)

> **Solo en el dispositivo de laboratorio con la CA instalada (Fase B activa).**
> Esta demo requiere que el instructor haya activado el addon de modificación.

### Contexto

En los escenarios anteriores hemos visto que un proxy con CA confiada puede
**leer** el tráfico HTTPS sin que el usuario lo note. Ahora vamos un paso más
allá: el proxy también puede **modificar** el contenido antes de que llegue
a tu pantalla, sin que el navegador muestre ninguna alerta.

### Paso 1: Navegar a Bing con la modificación activa

1. En el dispositivo de laboratorio (CA instalada), abre el navegador
2. Ve a `https://www.bing.com`
3. Observa el título de la página y el texto del buscador

**¿Qué ves?** Anota:

```text
Texto en el título del navegador: ____________________
Texto en el buscador:             ____________________
```

El instructor mostrará en pantalla el log del proxy:

```text
[modify] www.bing.com — rewrote response (XXXXX → XXXXX bytes)
```

### Paso 2: Verificar que el navegador no muestra ninguna alerta

- [ ] ¿Hay algún aviso de seguridad en el navegador?
- [ ] ¿El candado aparece normal?
- [ ] ¿Algo en la interfaz del navegador indica que el contenido fue modificado?

**Respuesta esperada:** No. El navegador confía en la CA, valida el certificado
correctamente, y no tiene forma de saber que el contenido fue alterado en
tránsito.

### Paso 3: Comparar en red sin proxy

El instructor desconectará el proxy momentáneamente o apuntará el navegador
a `https://www.bing.com` desde una red sin interceptar.

| | Con proxy y modificación | Sin proxy |
| --- | --- | --- |
| Texto del título | | |
| Texto del buscador | | |
| Aviso en el navegador | | |
| Campo Issuer del cert | | |

### Paso 4: ¿Qué más podría modificarse?

El proxy puede cambiar **cualquier contenido** que el servidor envíe. Piensa
en escenarios más graves y anótalos:

1. En un formulario de login, el proxy podría _______________
2. En una página de transferencia bancaria, el proxy podría _______________
3. En una descarga de software, el proxy podría _______________
4. En una página de noticias, el proxy podría _______________

### Paso 5: Reflexión

- ¿Qué tendría que ocurrir para que un atacante real pudiera hacer esto?
  (pista: piensa en los dos requisitos que hemos visto en clase)
- ¿Qué mecanismos de defensa existen contra la modificación de contenido
  incluso cuando hay un proxy con CA confiada?
  (pista: busca "Subresource Integrity" y "Content Security Policy")
- ¿Es posible detectar este tipo de modificación sin comparar con otra fuente?

---

## Checklist de aprendizaje

Al terminar la práctica, deberías poder responder:

- [ ] ¿Qué información expone HTTP que no expone HTTPS?
- [ ] ¿Qué información expone HTTPS aunque el contenido esté cifrado?
- [ ] ¿Cómo detectas en el navegador si hay un proxy interceptando tu HTTPS?
- [ ] ¿Qué campo del certificado te indica si hay inspección TLS?
- [ ] ¿Por qué las apps no muestran aviso aunque el proxy intente interceptar?
- [ ] ¿En qué se diferencia WPA de estar en red abierta respecto al operador del AP?
- [ ] ¿Cuándo es legítima la inspección TLS y cuándo es un ataque?
- [ ] ¿Puede un proxy con CA confiada modificar contenido sin que el navegador avise?
- [ ] ¿Qué dos condiciones necesita un atacante para realizar una modificación silenciosa?

---

## Señales de red no confiable: resumen

Aprende estas señales. Son tu primera línea de defensa.

| Señal | Significado |
| --- | --- |
| Aviso de certificado en el navegador | Posible proxy/MITM activo |
| Issuer del cert es una CA desconocida | Inspección TLS activa |
| Te piden instalar un certificado para acceder | **Señal de alarma máxima** |
| DNS resuelve sitios externos a IPs internas | DNS spoofing posible |
| `traceroute` muestra un hop inesperado | Posible proxy en ruta |
| Apps no cargan pero el navegador sí | Certificate pinning activo en las apps |
| WiFi abierta sin portal cautivo, sin contraseña | Todo tu tráfico HTTP es visible |

---

## ¿Qué hacer en la vida real?

1. **En WiFi pública:** activa tu VPN antes de conectar
2. **Ves un aviso de certificado:** para. No hagas clic en "continuar"
3. **Red te pide instalar certificado:** rechaza y usa datos móviles
4. **Red corporativa nueva:** pregunta a IT qué inspeccionan antes de usar dispositivos personales
5. **Tienes dudas sobre un certificado:** `openssl s_client -connect sitio.com:443 -servername sitio.com`
