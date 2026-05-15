# Soluciones — Práctica de Laboratorio Enterprise WiFi Security

> Documento de uso exclusivo del instructor. No distribuir a los alumnos antes de completar la práctica.

---

## Escenario 1 — Conectarse y entender qué expones

### ¿Qué información puede ver el operador en HTTP?

En HTTP todo el tráfico viaja sin cifrar. El operador de la red puede ver:

- **El dominio y la URL completa**: `GET /login?user=alice HTTP/1.1 Host: intranet.empresa.com`
- **Las cabeceras**: `Cookie:`, `Authorization:`, `User-Agent:`, `Referer:`
- **El cuerpo de las peticiones**: formularios de login con usuario y contraseña en texto claro
- **El contenido de las respuestas**: el HTML completo de las páginas que visitas

Ejemplo real capturado con tcpdump:
```
Host: neverssl.com
GET / HTTP/1.1
Cookie: session=abc123; user=alice
```

### ¿Qué pasaría si fuera el portal de login de tu empresa?

El operador (o cualquier atacante con acceso a la red) capturaría las credenciales en texto plano en el momento del envío del formulario. No necesita descifrar nada: el propio protocolo HTTP entrega el contenido sin protección.

---

## Escenario 2 — HTTPS: lo que se oculta y lo que no

### Tabla completa de visibilidad

| Dato | ¿Visible para el operador en HTTPS? | Explicación |
|---|---|---|
| Dominio visitado (ej. wikipedia.org) | **Sí** | El campo SNI (*Server Name Indication*) del handshake TLS viaja sin cifrar. El servidor necesita saber a qué dominio conectarse antes de que se establezca el cifrado. |
| URL exacta (ej. /wiki/Contraseña) | **No** | La ruta y los parámetros van cifrados dentro del túnel TLS. Solo el cliente y el servidor los conocen. |
| Contenido de la página | **No** | El cuerpo de la respuesta (HTML, imágenes, etc.) va cifrado. |
| Credenciales si el sitio usa HTTPS | **No** (en red limpia) / **Sí** (con proxy MITM y CA confiada) | Sin proxy: cifradas. Con proxy MITM y CA instalada: el proxy descifra, lee las credenciales y re-cifra hacia el servidor. |
| Con qué frecuencia visitas un sitio | **Sí** | Los metadatos de tiempo y frecuencia de conexión son visibles aunque el contenido esté cifrado. |
| Cuántos datos transferiste | **Sí** | El tamaño de los paquetes y el volumen total de datos son visibles en los encabezados IP/TCP. |

### Punto clave

> HTTPS protege el **contenido**. No protege los **metadatos**: con quién hablas, cuándo, con qué frecuencia y cuánto datos intercambias siguen siendo visibles para el operador de la red.

---

## Escenario 3 — Detección de proxy: la alerta del navegador

### Mensaje del navegador esperado

- **Chrome / Edge**: `Tu conexión no es privada — NET::ERR_CERT_AUTHORITY_INVALID`
- **Firefox**: `Advertencia: riesgo de seguridad potencial — El certificado no es de confianza porque no ha sido verificado por ninguna autoridad reconocida`
- **Safari**: `Esta conexión no es privada`

### Tabla del certificado (valores en el lab)

| Campo | Valor esperado en el laboratorio |
|---|---|
| **Emitido para (Subject)** | `CN=example.com` |
| **Emitido por (Issuer)** | `O=mitmproxy, CN=mitmproxy` |
| **Válido desde** | Fecha reciente (generado al iniciar el proxy) |
| **Válido hasta** | ~1 año desde la fecha de inicio |
| **¿Es el issuer una CA conocida?** | **No** — mitmproxy no es una CA raíz de confianza pública |

### Resultado del comando openssl con proxy activo

```
issuer=O=mitmproxy, CN=mitmproxy
subject=CN=example.com
notBefore=Apr 17 08:54:11 2026 GMT
notAfter=Apr 19 08:54:11 2027 GMT
```

### Resultado en red limpia (sin proxy)

```
issuer=C=US, O=DigiCert Inc, CN=DigiCert Global G2 TLS RSA SHA256 2020 CA1
subject=CN=www.example.org
notBefore=Jan 12 00:00:00 2024 GMT
notAfter=Jan 12 23:59:59 2025 GMT
```

### Regla de detección

Si el campo **Issuer** no corresponde a una CA raíz pública reconocida (DigiCert, Let's Encrypt, Comodo, GlobalSign, Sectigo, ISRG…) → hay un proxy de inspección TLS en la red.

En entornos corporativos legítimos verás issuers como:
- `Zscaler Root CA`
- `Cisco Umbrella`
- `Forcepoint SSL CA`
- `BlueCoat ProxySG`
- `NombreDeTuEmpresa Corporate CA`

---

## Escenario 4 — Certificate pinning: por qué las apps no avisan

### ¿Funcionan las apps? ¿Dan aviso?

| App | Comportamiento esperado | Motivo |
|---|---|---|
| WhatsApp | Falla silenciosamente (sin mensajes) | Certificate pinning: tiene la CA de Meta hardcodeada |
| Instagram | Falla silenciosamente | Certificate pinning |
| Telegram | Falla silenciosamente | Certificate pinning + su propio protocolo MTProto |
| App bancaria | Falla silenciosamente | Certificate pinning + a veces raíces propias |
| Navegador (Chrome/Firefox) | Muestra aviso con opción de continuar | Usa el almacén de CAs del sistema, sin pinning propio |

### ¿Qué se ve en el log del proxy?

```
Client TLS handshake failed. The client does not trust the proxy's certificate
for api.instagram.com (ssl/tls alert bad certificate)
```

El proxy intentó interceptar. La app rechazó el certificado porque no coincidía con el certificado esperado hardcodeado en el código de la app.

### Respuesta a la pregunta de reflexión

**¿Fallar silenciosamente es mejor o peor?**

Es una decisión de diseño con consecuencias opuestas:

- **Desde la perspectiva de seguridad**: es más seguro. El usuario no puede hacer clic en "continuar de todos modos" y exponerse. La app simplemente no se conecta si detecta un MITM.
- **Desde la perspectiva del usuario**: es peor en experiencia. El usuario no recibe ninguna explicación y puede pensar que la app tiene un bug o que no tiene cobertura.
- **Conclusión práctica**: para aplicaciones de alta seguridad (banca, mensajería privada), el fallo silencioso es la opción correcta. Para aplicaciones generales, un aviso informativo es preferible.

---

## Escenario 5 — Entorno corporativo: CA confiada (Demo B)

### Tabla comparativa Demo A vs Demo B

| Comportamiento | Demo A (sin CA instalada) | Demo B (CA instalada y confiada) |
|---|---|---|
| Aviso del navegador | Sí — certificado no válido | No — el navegador confía en la CA |
| Campo Issuer del cert | `O=mitmproxy, CN=mitmproxy` | `O=mitmproxy, CN=mitmproxy` (igual, pero ahora confiada) |
| ¿El sitio carga? | No (el usuario debe aceptar la excepción) | Sí, con normalidad |
| ¿El proxy puede leer el contenido? | No (la conexión se corta en el handshake) | **Sí, completamente** |

### Reflexión: preguntas y respuestas

**¿Cuándo es legítima la inspección TLS corporativa?**

Es legítima cuando:
- El empleado ha firmado una política de uso aceptable que menciona explícitamente la inspección TLS
- El dispositivo es propiedad de la empresa (no personal)
- Existe una justificación de seguridad documentada (detección de malware, prevención de fuga de datos)
- El sistema está auditado y sujeto a control interno

En muchos países (incluyendo España), la inspección TLS en dispositivos corporativos con consentimiento informado es legal bajo la normativa laboral.

**¿Qué diferencia a la empresa de un atacante?**

| | Empresa legítima | Atacante |
|---|---|---|
| CA instalada | Por política corporativa, con consentimiento | Mediante engaño o portal cautivo malicioso |
| Datos | Analizados para seguridad, sujetos a auditoría | Robados y explotados |
| Transparencia | El empleado fue informado | El usuario no lo sabe |
| Base legal | Política de uso firmada | Ninguna — es un delito |

**¿Qué datos personales estarían expuestos en red corporativa con dispositivo personal?**

Todo el tráfico HTTPS del dispositivo: correo personal (Gmail, Outlook), redes sociales, banca online, servicios de salud, conversaciones privadas que no usen certificate pinning. Por esto la recomendación es no usar dispositivos personales en redes corporativas con inspección TLS, o usar VPN propia en modo split tunnel para el tráfico personal.

---

## Escenario 6 — WiFi Abierta vs WPA

### Respuesta a la pregunta clave

**¿Ha cambiado algo al activar WPA2?**

Para el operador de la red: **no cambia absolutamente nada**. El proxy sigue interceptando exactamente igual. WPA cifra el canal de radio entre el dispositivo y el punto de acceso — pero el AP es precisamente quien opera el proxy.

> WPA es como poner una puerta con llave entre tú y el portero del edificio. El portero sigue viendo todo lo que haces dentro.

### Tabla completa de amenazas por tipo de red

| Amenaza | WiFi Abierta | WPA2-PSK (contraseña compartida) | WPA2-Enterprise (usuario/contraseña individual) |
|---|---|---|---|
| Vecino con Wireshark ve tu tráfico HTTP | **Sí** — captura directa en el aire | **No** — el cifrado de radio protege | **No** — claves de sesión individuales |
| Vecino ve tu tráfico HTTPS descifrado | **No** (TLS cifra el contenido) | **No** | **No** |
| Vecino descifra tu tráfico si tiene la contraseña WPA2 | N/A | **Sí** — PSK compartida permite descifrar capturas previas | **No** — claves de sesión únicas por usuario |
| Operador del AP ve tu tráfico HTTP | **Sí** | **Sí** | **Sí** |
| Proxy MITM en el AP intercepta HTTPS | **Sí** (con CA confiada) | **Sí** (con CA confiada) | **Sí** (con CA confiada) |

### Conclusión

WPA-Enterprise es la mejor opción frente a ataques de **otros usuarios** de la misma red. Pero **ningún tipo de WPA protege frente al operador del AP**. La única protección frente al operador es la VPN propia o el certificate pinning de las apps.

---

## Escenario 7 — Modificación activa de contenido (Fase C)

### Paso 1: ¿Qué se ve en el navegador?

| Campo | Con proxy y addon de modificación activo |
|---|---|
| Título del navegador | `Gooogle` (o `B1ng` para bing.com) |
| Texto del botón de búsqueda | `Buscar con Gooogle` / `Gooogle Search` |
| Log del proxy | `[modify] www.bing.com — rewrote response (163230 → 163231 bytes)` |

### Paso 2: ¿Muestra algo el navegador?

- [ ] Aviso de seguridad: **No**
- [ ] El candado aparece normal: **Sí**
- [ ] Algún indicador de contenido modificado: **No**

El navegador valida que el certificado está firmado por una CA de confianza. No tiene mecanismo para detectar que el **contenido** fue alterado en tránsito una vez que confía en la CA. El cifrado TLS garantiza que nadie *fuera del proxy* modificó los datos — pero si el proxy mismo es el interceptor, el cifrado no protege.

### Tabla comparativa con/sin proxy

| | Con proxy y modificación activa | Sin proxy (red limpia) |
|---|---|---|
| Texto del título | `Gooogle` / `B1ng` | `Google` / `Bing` |
| Botón de búsqueda | `Gooogle Search` | `Google Search` |
| Aviso en el navegador | Ninguno | Ninguno |
| Campo Issuer del cert | `O=mitmproxy, CN=mitmproxy` | CA pública legítima (DigiCert, etc.) |

### Paso 4: Escenarios de modificación más graves

1. **En un formulario de login**, el proxy podría **redirigir el envío del formulario a un servidor atacante, capturar las credenciales y reenviarlas al servidor original** sin que el usuario note nada (el login funciona con normalidad).

2. **En una página de transferencia bancaria**, el proxy podría **sustituir silenciosamente el número de cuenta de destino por el del atacante** — el usuario ve el número correcto antes de confirmar, pero el campo enviado al banco es diferente.

3. **En una descarga de software**, el proxy podría **reemplazar el binario legítimo por uno con malware** — el usuario descarga lo que parece el instalador oficial con el mismo nombre y tamaño aproximado.

4. **En una página de noticias**, el proxy podría **modificar titulares, inyectar desinformación o alterar artículos** — el usuario lee contenido falso convencido de que está en un sitio legítimo.

### Paso 5: Reflexión — preguntas y respuestas

**¿Qué necesita un atacante para realizar este ataque?**

Dos condiciones:
1. **Control del AP o del flujo de red** (estar en posición MITM): el atacante controla el punto de acceso WiFi, o tiene acceso al router, o está en la misma red con capacidad de ARP spoofing.
2. **CA confiada en el dispositivo víctima**: el dispositivo debe haber instalado y confiado en el certificado del proxy. Sin esto, el navegador muestra el aviso de certificado inválido y el ataque es detectable.

**¿Qué mecanismos de defensa existen?**

| Mecanismo | Cómo protege |
|---|---|
| **Subresource Integrity (SRI)** | El navegador verifica el hash de cada recurso externo (JS, CSS) antes de ejecutarlo. Si el proxy modifica el archivo, el hash no coincide y el navegador rechaza el recurso. |
| **Content Security Policy (CSP)** | La cabecera CSP define desde qué orígenes puede cargar recursos el sitio. Limita la capacidad de inyectar scripts o recursos externos modificados. |
| **Certificate Transparency (CT)** | Todos los certificados emitidos por CAs públicas deben estar registrados en logs públicos auditables. Detecta CAs que emiten certificados fraudulentos. |
| **HSTS Preload** | El navegador tiene hardcodeado que ciertos dominios (google.com, etc.) deben usar solo CAs de confianza pública, ignorando CAs corporativas o instaladas manualmente. |
| **Certificate Pinning** | Las apps rechazan cualquier certificado que no sea el esperado, independientemente de la CA instalada. |

**¿Es posible detectar la modificación sin comparar con otra fuente?**

En general, **no** — no desde dentro de la misma sesión. El usuario solo puede detectarlo:
- Comparando con otra conexión que no pase por el proxy (datos móviles, VPN)
- Usando SRI: si el recurso modificado tiene un hash SRI declarado, el navegador detectará la discrepancia y bloqueará la carga (con un error visible en la consola del desarrollador)
- Revisando el Issuer del certificado y reconociendo que es un proxy

---

## Checklist de aprendizaje — Respuestas

| Pregunta | Respuesta resumida |
|---|---|
| ¿Qué expone HTTP que no expone HTTPS? | URL completa, cuerpo de peticiones y respuestas, credenciales en formularios, cookies |
| ¿Qué expone HTTPS aunque el contenido esté cifrado? | Dominio (SNI), frecuencia, volumen de datos, timing |
| ¿Cómo detectas un proxy en el navegador? | Aviso de certificado + campo Issuer no reconocido |
| ¿Qué campo del cert indica inspección TLS? | **Issuer / Emitido por** |
| ¿Por qué las apps no avisan? | Certificate pinning: rechazan el cert del proxy silenciosamente |
| ¿En qué se diferencia WPA del operador del AP? | WPA protege de *otros usuarios*, no del operador del AP que controla el proxy |
| ¿Cuándo es legítima la inspección TLS? | Con consentimiento informado, en dispositivos corporativos, con base legal documentada |
| ¿Puede un proxy con CA confiada modificar contenido sin aviso? | **Sí** — el navegador no tiene forma de detectarlo una vez que confía en la CA |
| ¿Qué dos condiciones necesita el atacante? | 1) Posición MITM (control del AP/red) + 2) CA confiada en el dispositivo víctima |
