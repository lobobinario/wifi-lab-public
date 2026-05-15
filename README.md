# Enterprise WiFi Security Lab — Raspberry Pi 3

Laboratorio docente para demostrar en vivo los riesgos de conectarse a redes
WiFi no confiables, cómo se captura e intercepta tráfico, la diferencia real
entre WiFi abierta y WPA, y cómo detectar si tu tráfico está siendo
inspeccionado.

> **Solo para uso en entornos controlados con consentimiento explícito de
> los participantes.** Informa a los alumnos antes de empezar y prohíbe
> credenciales personales reales en el laboratorio.

---

## Índice

1. [Requisitos de hardware](#1-requisitos-de-hardware)
2. [Topología](#2-topología)
3. [Instalación y primer arranque](#3-instalación-y-primer-arranque)
4. [Variables de configuración](#4-variables-de-configuración)
5. [Modos de demostración](#5-modos-de-demostración)
6. [Servidor web HTTP/HTTPS de demostración](#6-servidor-web-httphttps-de-demostración)
7. [Scripts operativos](#7-scripts-operativos)
8. [Flujo de clase recomendado](#8-flujo-de-clase-recomendado)
9. [Filtrado selectivo del proxy](#9-filtrado-selectivo-del-proxy)
10. [Demo de modificación de contenido](#10-demo-de-modificación-de-contenido)
11. [Distribución del certificado CA](#11-distribución-del-certificado-ca)
12. [Verificación rápida](#12-verificación-rápida)
13. [Resolución de problemas](#13-resolución-de-problemas)

---

## 1. Requisitos de hardware

| Componente | Detalle |
|---|---|
| Raspberry Pi 3B / 3B+ | El chip WiFi integrado soporta modo AP |
| Raspberry Pi OS Lite | Bullseye (Debian 11), Bookworm (12) o Trixie (13) |
| Tarjeta microSD | ≥ 8 GB |
| Router 4G Huawei E3372 | `eth1` — uplink a internet (192.168.8.1/24) |
| Cable Ethernet (admin) | `eth0` — red de gestión estática 192.168.0.1/24 |
| Alimentación | 5V / 2.5A mínimo |

> **Alternativa sin router 4G:** conectar `eth0` directamente a un router de aula
> con DHCP y lanzar con `sudo UPLINK_IFACE=eth0 ./enterprise_lab.sh`.

El script ha sido probado sobre **Debian 13 (trixie)**, kernel 6.12.75, con
NetworkManager activo.

---

## 2. Topología

```
4G Internet
     |
[E3372 router] ── eth1 (192.168.8.100) ──┐
                                     [Raspberry Pi 3]
[Portátil instructor] ── eth0 (192.168.0.1) ──┘
   (192.168.0.2)                         |
                                       wlan0 (AP)
                                     CorpNet-Enterprise
                                     192.168.50.1/24
                                    /        \
                              Móvil A      Portátil B
                           192.168.50.10  192.168.50.11
```

- **eth1** — uplink a internet, IP `192.168.8.100` por DHCP del router 4G E3372
- **eth0** — interfaz de administración, IP estática `192.168.0.1/24` (acceso SSH del instructor)
- **wlan0** — Access Point para alumnos, IP estática `192.168.50.1/24`
- Todo el tráfico HTTP/HTTPS de los alumnos pasa por **mitmproxy** (puerto 8080)
  antes de salir por eth1

---

## 3. Instalación y primer arranque

```bash
# Clonar el repositorio en el Pi
git clone https://github.com/lobobinario/wifi-lab-public.git
cd wifi-lab-public

# Hacer ejecutables todos los scripts
chmod +x *.sh

# Lanzar el setup principal (requiere root)
sudo ./enterprise_lab.sh

# Instalar el servidor web HTTP/HTTPS de demostración
sudo ./setup_webserver.sh
```

El script hace automáticamente:

1. Instala los paquetes necesarios (`hostapd`, `dnsmasq`, `mitmproxy` vía pipx si
   no está disponible en apt, `tcpdump`, `iptables-persistent`, `iw`, etc.)
2. Dice a NetworkManager que no gestione `wlan0`
3. Asigna la IP estática `192.168.50.1/24` a `wlan0` (inmediato + persistente)
4. Escribe la configuración de `hostapd` y `dnsmasq`
5. Activa el reenvío IP y configura las reglas iptables (NAT + redirect al proxy)
6. Crea y activa el servicio systemd `enterprise.service` (mitmdump transparente)
7. Espera a que se genere el certificado CA de mitmproxy y muestra su ruta

Al terminar, verás:

```
[+] Setup complete!
[i] SSID       : CorpNet-Enterprise (open)
[i] Gateway    : 192.168.50.1
[i] DHCP range : 192.168.50.10 – 192.168.50.200
[i] Proxy port : 8080
[i] CA cert    : /root/.mitmproxy/mitmproxy-ca-cert.pem
[i] Next step  : sudo ./lab_precheck.sh
```

Ejecuta el precheck para confirmar que todo está verde:

```bash
sudo ./lab_precheck.sh
```

---

## 4. Variables de configuración

Todas tienen valores por defecto. Se pasan como variables de entorno antes del
script.

### Red y AP

| Variable | Por defecto | Descripción |
|---|---|---|
| `AP_IFACE` | `wlan0` | Interfaz WiFi para el Access Point |
| `UPLINK_IFACE` | `eth1` | Interfaz de salida a internet (router 4G); usar `eth0` con red cableada |
| `LAB_GATEWAY` | `192.168.50.1` | IP del Pi en la red del laboratorio |
| `LAB_NETMASK` | `255.255.255.0` | Máscara de red |
| `LAB_DHCP_RANGE_START` | `192.168.50.10` | Inicio del rango DHCP |
| `LAB_DHCP_RANGE_END` | `192.168.50.200` | Fin del rango DHCP |
| `LAB_SSID` | `CorpNet-Enterprise` | Nombre de la red WiFi |
| `LAB_CHANNEL` | `6` | Canal WiFi (1–13) |
| `LAB_COUNTRY` | `ES` | Código de país para regulación WiFi |
| `LAB_MODE` | `open` | `open` o `wpa2` |
| `LAB_WPA2_PASSPHRASE` | `ChangeMe123!` | Contraseña si `LAB_MODE=wpa2` |

### Proxy

| Variable | Por defecto | Descripción |
|---|---|---|
| `PROXY_PORT` | `8080` | Puerto donde escucha mitmproxy |
| `MITMPROXY_BIN` | `mitmdump` | Binario de mitmproxy a usar |
| `PROXY_IGNORE_HOSTS` | Apple + Facebook | Regex de hosts que pasan sin interceptar |
| `PROXY_ALLOW_HOSTS` | _(vacío = todos)_ | Si se define, intercepta SOLO estos hosts |
| `PROXY_DEMO_MODIFY` | `0` | `1` activa el addon de modificación de contenido |
| `PROXY_MODIFY_SCRIPT` | `./mitm_demo_modify.py` | Ruta al script de modificación |

### Ejemplos de uso

```bash
# Red WPA2 con contraseña personalizada
sudo LAB_MODE=wpa2 LAB_WPA2_PASSPHRASE='Clase2025!' ./enterprise_lab.sh

# Solo interceptar los dominios de demostración (resto pasa limpio)
sudo PROXY_ALLOW_HOSTS='(example\.com|badssl\.com)' ./enterprise_lab.sh

# Interceptar todo excepto Apple
sudo PROXY_IGNORE_HOSTS='(.+\.apple\.com|.+\.icloud\.com)' ./enterprise_lab.sh

# Activar modificación de contenido (Demo C, requiere CA confiada en cliente)
sudo PROXY_DEMO_MODIFY=1 ./enterprise_lab.sh

# País distinto (ajusta potencia y canales permitidos)
sudo LAB_COUNTRY=DE ./enterprise_lab.sh
```

---

## 5. Modos de demostración

### Fase A — Detección: proxy activo, CA no confiada

Configuración por defecto al ejecutar `enterprise_lab.sh`.

- El proxy intercepta todo el tráfico HTTP y HTTPS
- Los navegadores muestran **"Tu conexión no es privada"** al visitar HTTPS
- Las apps con certificate pinning fallan silenciosamente (no muestran aviso)
- El instructor puede ver todos los intentos en el log en tiempo real

```bash
sudo journalctl -u enterprise.service -f --no-pager
```

**Objetivo pedagógico:** aprender a leer alertas de certificado y reconocer
señales de inspección activa.

---

### Fase B — Inspección corporativa: CA confiada

Solo en dispositivos de laboratorio designados. Nunca en dispositivos personales.

1. Distribuir el certificado CA:
   ```bash
   # Servir el cert por HTTP desde el Pi
   sudo python3 -m http.server 80 --directory /root/.mitmproxy &
   # Alumnos descargan: http://192.168.50.1/mitmproxy-ca-cert.pem
   ```

2. Instalar la CA en el dispositivo de laboratorio (ver
   [sección 11](#11-distribución-del-certificado-ca))

3. Navegar por los mismos sitios HTTPS — el navegador muestra candado normal,
   mitmproxy registra el contenido completo

**Objetivo pedagógico:** comprender qué visibilidad tiene una empresa sobre el
tráfico de dispositivos gestionados, y distinguirlo de un ataque.

---

### Fase C — Modificación activa de contenido

Requiere Fase B activa (CA confiada en el cliente).

```bash
sudo PROXY_DEMO_MODIFY=1 ./enterprise_lab.sh
```

O activar en caliente sin re-ejecutar el setup:

```bash
sudo cp mitm_demo_modify.py /usr/local/bin/
# Editar /usr/local/bin/start_proxy.sh, añadir: -s /usr/local/bin/mitm_demo_modify.py
sudo systemctl restart enterprise.service
```

Por defecto sustituye `Google` → `Gooogle` en respuestas HTML/JS/SVG.
Personalizable editando `REPLACEMENTS` en `mitm_demo_modify.py`.

**Objetivo pedagógico:** demostrar que un MITM con CA confiada no solo observa,
sino que puede **modificar** cualquier contenido en tránsito sin que el usuario
reciba ninguna señal de alerta.

---

## 6. Servidor web HTTP/HTTPS de demostración

El laboratorio incluye un servidor web ligero (`lab_webserver.py`) que expone el
mismo formulario en HTTP y en HTTPS de forma simultánea. El objetivo es hacer
visible de forma inmediata y concreta la diferencia entre ambos protocolos:
los alumnos envían datos y el instructor proyecta el tráfico capturado con
`tcpdump` en tiempo real.

### Instalación (una sola vez)

```bash
sudo ./setup_webserver.sh
```

El script instala el servidor en `/opt/lab-webserver/`, genera un certificado
autofirmado para `192.168.50.1` y registra el servicio systemd `lab-webserver`.

### Endpoints

| URL | Protocolo | Descripción |
| --- | --- | --- |
| `http://192.168.50.1/send` | HTTP :80 | Formulario con banner rojo — datos en claro |
| `https://192.168.50.1/send` | HTTPS :443 | Formulario con banner verde — datos cifrados |
| `http://192.168.50.1/visualize` | HTTP :80 | Tabla de todos los envíos (IP, proto, usuario, mensaje) |

Cada página incluye un enlace directo para cambiar de protocolo, lo que
facilita la comparación instantánea. La tabla `/visualize` colorea en rojo
las filas enviadas por HTTP y en verde las de HTTPS.

### Nota técnica: coexistencia con mitmproxy

El proxy transparente (`enterprise.service`) redirige el tráfico de los
clientes en los puertos 80 y 443 hacia mitmproxy. La regla iptables
excluye explícitamente la IP del propio Pi (`! -d 192.168.50.1`), por lo
que el tráfico al servidor web llega directamente al proceso Python sin
pasar por el proxy. El resto del tráfico de los alumnos sigue siendo
interceptado con normalidad.

### Gestión del servicio

```bash
# Estado
systemctl status lab-webserver

# Log de envíos en tiempo real
tail -f /var/log/lab_webserver.log

# Reiniciar
sudo systemctl restart lab-webserver
```

### Uso durante la clase

Proyectar `tcpdump` mientras los alumnos envían el formulario por HTTP:

```bash
sudo tcpdump -i wlan0 -A -s 0 'tcp port 80 and dst host 192.168.50.1' 2>/dev/null \
  | grep -E --line-buffered "POST|user=|message="
```

El tráfico HTTPS al mismo destino aparece cifrado e ilegible bajo el mismo
filtro. Abrir `/visualize` en el proyector para mostrar ambas entradas
lado a lado con sus etiquetas HTTP/HTTPS.

---

## 7. Scripts operativos

| Script | Función |
| --- | --- |
| `enterprise_lab.sh` | Setup completo del laboratorio (AP, proxy, iptables) |
| `setup_webserver.sh` | Instala el servidor web HTTP/HTTPS de demostración |
| `lab_precheck.sh` | Verifica todos los servicios, reglas y conectividad antes de clase |
| `lab_addon_toggle.sh` | Activa/desactiva addons de mitmproxy en caliente |
| `teacher_mode.sh` | Un comando para precheck + estado + captura opcional |
| `soc_monitor.sh` | Captura PCAP con duración y rotación configurables |
| `lab_teardown.sh` | Deshace toda la configuración (incluido el servidor web) y restaura el sistema |
| `mitm_demo_modify.py` | Addon mitmproxy para modificación activa de contenido |
| `mitm_credential_logger.py` | Addon mitmproxy para captura de credenciales en formularios |

### teacher_mode.sh

Pensado para ejecutar justo antes de que lleguen los alumnos:

```bash
# Solo precheck y captura (sin re-ejecutar setup)
sudo RUN_SETUP=0 RUN_CAPTURE=1 CAPTURE_DURATION=3600 ./teacher_mode.sh

# Setup completo + precheck + captura
sudo RUN_SETUP=1 RUN_CAPTURE=1 ./teacher_mode.sh
```

### soc_monitor.sh

```bash
# Captura 30 minutos en wlan0
sudo IFACE=wlan0 DURATION_SEC=1800 LOG_DIR=/var/log/enterprise ./soc_monitor.sh

# Ver capturas guardadas
ls -lh /var/log/enterprise/
```

### lab_teardown.sh

Elimina toda la configuración del laboratorio: servicios, reglas iptables,
drop-ins de dnsmasq/hostapd/NetworkManager/interfaces.d, dhcpcd.conf blocks,
y restaura NetworkManager sobre `wlan0`.

```bash
sudo ./lab_teardown.sh
sudo reboot   # recomendado para limpiar estado de red completamente
```

---

## 8. Flujo de clase recomendado

```
 0–15 min  Contexto: modelo de amenaza, WiFi abierta vs WPA
15–30 min  Sniffing en vivo: HTTP expuesto, metadatos HTTPS visibles
30–40 min  Demo web: formulario HTTP vs HTTPS — comparación directa con tcpdump
40–60 min  Demo A: MITM activo, alertas de certificado, cómo detectar proxy
60–70 min  Demo B: CA confiada, inspección silenciosa, log en tiempo real
70–80 min  Demo C (opcional): modificación de contenido en tránsito
80–90 min  Análisis PCAP + debate + buenas prácticas
```

Ver `enterprise_wifi_course_material/guion_instructor.md` para el guion
detallado de cada bloque con los comandos exactos a ejecutar.

---

## 9. Filtrado selectivo del proxy

Por defecto el proxy intercepta todo el tráfico HTTP/HTTPS procedente de `wlan0`
excepto los dominios de Apple y Facebook (para que las apps del móvil sigan
funcionando durante la demo).

### Solo interceptar sitios concretos

```bash
sudo PROXY_ALLOW_HOSTS='(example\.com|badssl\.com|wikipedia\.org)' ./enterprise_lab.sh
```

Todo lo demás (Google, redes sociales, apps) pasa sin interceptar. Ideal para
una demo focalizada.

### Excluir dominios adicionales

```bash
sudo PROXY_IGNORE_HOSTS='(.+\.apple\.com|.+\.icloud\.com|.+\.google\.com|.+\.whatsapp\.net)' \
  ./enterprise_lab.sh
```

### Interceptar absolutamente todo

```bash
sudo PROXY_IGNORE_HOSTS='' ./enterprise_lab.sh
```

### Cambiar en caliente (sin re-ejecutar setup)

Editar `/usr/local/bin/start_proxy.sh` y luego:

```bash
sudo systemctl restart enterprise.service
```

---

## 10. Demo de modificación de contenido

El archivo `mitm_demo_modify.py` es un addon Python para mitmproxy que reescribe
respuestas en tránsito. Funciona sobre HTML, JavaScript y SVG, y gestiona
automáticamente la compresión gzip/brotli.

### Personalizar las sustituciones

Editar la lista `REPLACEMENTS` al inicio del archivo:

```python
REPLACEMENTS: list[tuple[bytes, bytes]] = [
    (b"Google",  b"Gooogle"),     # Demo clásico: 3 'o'
    (b"Search",  b"Snoop"),       # Mostrar intención del atacante
    (b"Secure",  b"COMPROMETIDO"),# Efecto dramático
    # Añadir las que quieras
]
```

### Tipos de respuesta modificados

- `text/html` — páginas web
- `text/javascript` / `application/javascript` — scripts
- `image/svg+xml` — logos e iconos vectoriales

### Activar / desactivar en caliente

```bash
# Activar
sudo sed -i 's|--set tls_version_client_min|-s /usr/local/bin/mitm_demo_modify.py \\\n  --set tls_version_client_min|' \
  /usr/local/bin/start_proxy.sh
sudo systemctl restart enterprise.service

# Desactivar
sudo sed -i '/-s \/usr\/local\/bin\/mitm_demo_modify/d' /usr/local/bin/start_proxy.sh
sudo systemctl restart enterprise.service
```

O simplemente editar `/usr/local/bin/start_proxy.sh` a mano.

### Verificar que el addon está cargado

```bash
# Ver args del proceso mitmdump
cat /proc/$(systemctl show -p MainPID enterprise.service | cut -d= -f2)/cmdline \
  | tr '\0' ' '
# Debe incluir: -s /usr/local/bin/mitm_demo_modify.py
```

---

## 11. Distribución del certificado CA

El certificado de mitmproxy se genera en el primer arranque del servicio:

```
/root/.mitmproxy/mitmproxy-ca-cert.pem
```

Para distribuirlo a los dispositivos de laboratorio:

```bash
# Opción A: servidor HTTP temporal
sudo python3 -m http.server 80 --directory /root/.mitmproxy &
# Alumnos: http://192.168.50.1/mitmproxy-ca-cert.pem
```

### Instalación por plataforma

**Android:**
1. Descargar el `.pem` desde el navegador
2. Ajustes → Seguridad → Instalar certificado → CA
3. Nombre: `Lab mitmproxy`

**iOS / iPadOS:**
1. Abrir la URL — iOS lo reconoce como perfil
2. Ajustes → General → VPN y gestión del dispositivo → Instalar
3. Ajustes → General → Información → Ajustes de confianza de certificado → Activar la CA

**macOS:**
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain mitmproxy-ca-cert.pem
```

**Linux:**
```bash
sudo cp mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
sudo update-ca-certificates
```

**Firefox (cualquier SO):**
Preferencias → Privacidad y seguridad → Ver certificados → Importar → marcar
"Confiar para identificar sitios web"

> **Importante:** desinstalar siempre al terminar la práctica.

---

## 12. Verificación rápida

```bash
# Precheck completo (recomendado antes de clase)
sudo ./lab_precheck.sh

# Estado de los cuatro servicios clave
sudo systemctl status hostapd dnsmasq enterprise.service lab-webserver --no-pager

# Verificar servidor web
systemctl is-active lab-webserver
curl -so /dev/null -w "%{http_code}" http://192.168.50.1/send

# IP de wlan0 (debe mostrar 192.168.50.1/24)
ip a show wlan0

# Reglas NAT activas
sudo iptables -t nat -S

# Log del proxy en tiempo real
sudo journalctl -u enterprise.service -f --no-pager

# Clientes conectados al AP
arp -an | grep "192.168.50\."
```

---

## 13. Resolución de problemas

### El SSID no aparece

```bash
sudo journalctl -u hostapd -n 50 --no-pager
```

Causas habituales:
- `hostapd` enmascarado: `sudo systemctl unmask hostapd`
- `country_code` incorrecto: relanzar con `LAB_COUNTRY=XX`
- NetworkManager todavía controla `wlan0`:
  `sudo nmcli device set wlan0 managed no`

### Los clientes se conectan pero no obtienen IP

```bash
ip a show wlan0   # debe mostrar 192.168.50.1/24
sudo systemctl status dnsmasq --no-pager
```

Si `wlan0` no tiene IP:
```bash
sudo ip addr add 192.168.50.1/24 dev wlan0
sudo ip link set wlan0 up
sudo systemctl restart dnsmasq
```

### HTTPS falla en todos los sitios (Fase A)

Esperado. El proxy está activo y el cliente no confía la CA.
Las apps con certificate pinning fallan silenciosamente; los navegadores
muestran "Tu conexión no es privada". Esto es la demo.

### dnsmasq no arranca (puerto 53 en uso)

```bash
sudo ss -ltnup | grep :53
sudo systemctl disable --now systemd-resolved
sudo systemctl restart dnsmasq
```

### mitmproxy no arranca

```bash
sudo journalctl -u enterprise.service -n 30 --no-pager
# Verificar que el binario existe:
which mitmdump || ls /usr/local/bin/mitmdump
```

### Rendimiento bajo en Pi 3

- Limitar alumnos simultáneos a ≤ 10 dispositivos
- Evitar streaming de video durante la demo
- La modificación de contenido (Fase C) añade carga de CPU por la
  des/recompresión brotli; desactivarla si hay problemas
