# CLASS DAY CHECKLIST — Enterprise WiFi Security Lab

Ejecutar **10–20 minutos antes** de que lleguen los alumnos.

---

## 1) Hardware y topología

- [ ] Raspberry Pi 3 encendida y estable
- [ ] Router 4G Huawei E3372 conectado a `eth1` (proporciona 192.168.8.1/24 + internet)
- [ ] Portátil del instructor conectado por cable a `eth0` (red admin 192.168.0.x)
- [ ] Pi accesible por SSH desde el portátil del instructor: `ssh pi@192.168.0.1`
- [ ] Proyector o pantalla para mostrar el terminal del instructor

Topología objetivo (router 4G):

```text
4G ── E3372 (192.168.8.1) ── eth1 ── [Pi] ── wlan0 ── Dispositivos alumnos
                                      |               SSID: CorpNet-Enterprise
                              eth0 (192.168.0.1)      192.168.50.x
                                      |
                             Portátil instructor
                               (192.168.0.2)
```

> **Topología alternativa (red cableada DHCP):** conectar `eth0` al router de aula
> y lanzar con `sudo UPLINK_IFACE=eth0 ./enterprise_lab.sh`.

---

## 2) Arrancar y verificar el laboratorio

Desde la raíz del repo:

```bash
# Verificación rápida sin re-ejecutar setup
sudo ./teacher_mode.sh

# Si necesitas re-ejecutar el setup completo:
sudo RUN_SETUP=1 ./teacher_mode.sh

# Con modificación de contenido activa (Demo C):
sudo PROXY_DEMO_MODIFY=1 RUN_SETUP=1 ./teacher_mode.sh
```

Confirmar que el precheck muestra todo en verde:

- [ ] `hostapd` activo
- [ ] `dnsmasq` activo
- [ ] `enterprise.service` activo
- [ ] Proxy escuchando en `:8080`
- [ ] Regla NAT HTTP redirect presente
- [ ] Regla NAT HTTPS redirect presente
- [ ] MASQUERADE presente para `eth1`
- [ ] IP forwarding activo
- [ ] CA cert de mitmproxy generada

Verificar servidor web de demostración:

```bash
systemctl is-active lab-webserver   # debe responder: active
```

- [ ] `lab-webserver` activo
- [ ] `http://192.168.50.1/send` carga con banner rojo
- [ ] `https://192.168.50.1/send` carga con banner verde (aviso de cert autofirmado esperado)

---

## 3) Dry-run de experiencia alumno (2 min)

Con tu propio móvil o un dispositivo de prueba:

- [ ] Conectar a `CorpNet-Enterprise`
- [ ] Confirmar IP en rango `192.168.50.x`
- [ ] Abrir `http://neverssl.com` — debe cargar
- [ ] Abrir `https://example.com` — debe mostrar aviso de certificado (Fase A)
- [ ] Abrir `http://192.168.50.1/send` — debe cargar el formulario con **banner rojo**
- [ ] Enviar un mensaje de prueba por HTTP y comprobar que aparece en `/visualize`

Verificar el log del proxy:

```bash
sudo journalctl -u enterprise.service -n 5 --no-pager
```

Borrar la entrada de prueba del log antes de que lleguen los alumnos:

```bash
sudo truncate -s 0 /var/log/lab_webserver.log
```

---

## 4) Preparar las fases de demo

### Fase A — Detección (configuración por defecto)

- [ ] No instalar CA en ningún dispositivo
- [ ] Abrir terminal con log en tiempo real para proyectar:

```bash
sudo journalctl -u enterprise.service -f --no-pager
```

### Fase B — Inspección corporativa (CA confiada)

- [ ] Identificar el dispositivo de laboratorio designado (no personal)
- [ ] Servir el certificado CA:

```bash
sudo python3 -m http.server 8181 --directory /root/.mitmproxy &
# URL para alumnos: http://192.168.50.1:8181/mitmproxy-ca-cert.pem
```

- [ ] Instalar la CA en el dispositivo de laboratorio (guía en README §11)
- [ ] Verificar que el navegador accede a `https://example.com` sin aviso

### Fase C — Modificación de contenido (opcional, requiere Fase B)

- [ ] Activar el addon de modificación:

```bash
sudo ./lab_addon_toggle.sh modify on
```

- [ ] Verificar sustituciones editando `REPLACEMENTS` en `mitm_demo_modify.py`
- [ ] Prueba rápida: visitar `https://www.bing.com` desde el dispositivo de laboratorio (CA confiada) y confirmar que aparece "B1ng"

---

## 5) Monitorización durante la clase

```bash
# Log del proxy en tiempo real (proyectar en clase)
sudo journalctl -u enterprise.service -f --no-pager

# Ver qué dispositivos están conectados
watch -n5 'arp -an | grep "192.168.50\."'

# Tráfico HTTP en claro — sitios externos (Bloque 2)
sudo tcpdump -i wlan0 -A -s 0 'tcp port 80 and not dst host 192.168.50.1' 2>/dev/null \
  | grep -E --line-buffered "Host:|GET |POST |Cookie:"

# Tráfico HTTP al servidor web de demostración (Bloque 2b)
sudo tcpdump -i wlan0 -A -s 0 'tcp port 80 and dst host 192.168.50.1' 2>/dev/null \
  | grep -E --line-buffered "POST|user=|message="

# SNI de conexiones HTTPS externas (dominios aunque estén cifradas)
sudo tcpdump -i wlan0 -l 'tcp port 443 and not dst host 192.168.50.1' 2>/dev/null \
  | strings | grep -oE '[a-z0-9-]+\.[a-z0-9.-]+\.[a-z]{2,}' | sort -u

# Log de envíos del servidor web
tail -f /var/log/lab_webserver.log
```

---

## 6) Captura de evidencias (opcional)

```bash
sudo IFACE=wlan0 DURATION_SEC=3600 LOG_DIR=/var/log/enterprise ./soc_monitor.sh &
```

- [ ] PCAP guardado en `/var/log/enterprise/`
- [ ] Espacio en disco suficiente (`df -h /`)

---

## 7) Seguridad y ética — recordatorio pre-clase

- [ ] Informar a los alumnos de que todo su tráfico es visible para el instructor
- [ ] Prohibir introducir credenciales personales reales
- [ ] Prohibir instalar la CA en dispositivos personales
- [ ] Confirmar que la red de laboratorio está aislada de la red de producción

---

## 8) Objetivos de aprendizaje a verificar al final

Al terminar, el alumno debe poder responder:

- [ ] ¿Qué información expone HTTP que no expone HTTPS?
- [ ] ¿Qué información expone HTTPS aunque el contenido esté cifrado?
- [ ] ¿Qué diferencia hay entre WiFi abierta y WPA respecto al operador?
- [ ] ¿Cómo se detecta que hay un proxy inspeccionando el tráfico TLS?
- [ ] ¿En qué se diferencia la inspección corporativa legítima de un ataque MITM?
- [ ] ¿Qué puede hacer un atacante con CA confiada además de leer el tráfico?

---

## 9) Después de clase

Si continúas con el laboratorio activo:

- [ ] Dejar servicios en marcha para la siguiente sesión

Si reseteas el Pi:

```bash
sudo ./lab_teardown.sh
sudo reboot
```

Si el dispositivo de laboratorio tiene la CA instalada:

- [ ] Desinstalar la CA de mitmproxy del dispositivo de laboratorio
- [ ] Verificar en Ajustes que ya no aparece ninguna CA de `mitmproxy`
