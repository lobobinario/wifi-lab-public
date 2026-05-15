# Troubleshooting - Enterprise WiFi Lab

## 1) hostapd no levanta

```bash
sudo journalctl -u hostapd -n 100 --no-pager
```

Causas habituales:
- **hostapd enmascarado**: Pi OS lo enmascara por defecto. El script ya ejecuta `systemctl unmask hostapd`, pero si se instaló manualmente: `sudo systemctl unmask hostapd`.
- Interfaz incorrecta (`wlan0` por defecto).
- El adaptador WiFi no soporta modo AP (el chipset integrado del Pi 3 sí lo soporta).
- `country_code` incorrecto — ajusta `LAB_COUNTRY=XX` antes de lanzar el script.

---

## 2) Clientes se conectan pero no obtienen IP / no tienen internet

Verificar que wlan0 tiene la IP del gateway asignada:

```bash
ip a show wlan0
# Debe mostrar 192.168.50.1/24
```

Si no tiene IP, asignarla manualmente:

```bash
sudo ip addr add 192.168.50.1/24 dev wlan0
sudo ip link set wlan0 up
sudo systemctl restart dnsmasq
```

Comprobar uplink (router 4G en eth1):

```bash
ip a show eth1      # debe mostrar 192.168.8.x/24
ping -c 3 1.1.1.1
```

Si usas red cableada DHCP en lugar del router 4G, reinstala indicando la interfaz:

```bash
sudo UPLINK_IFACE=eth0 ./enterprise_lab.sh
```

---

## 3) HTTPS falla en todos los sitios

Puede ser esperado en **Fase A** (sin CA confiada) — los clientes verán alertas de certificado.
Esto es parte de la demo.

Si falla también **después** de instalar la CA, comprobar que mitmproxy está en ejecución:

```bash
sudo systemctl status enterprise.service --no-pager
sudo journalctl -u enterprise.service -n 50 --no-pager
```

---

## 4) dnsmasq no arranca

Buscar conflictos con systemd-resolved (puerto 53 en uso):

```bash
sudo ss -ltnup | grep :53
sudo systemctl disable --now systemd-resolved
sudo systemctl restart dnsmasq
```

---

## 5) Ver estado general de servicios y reglas NAT

```bash
sudo systemctl status hostapd dnsmasq enterprise.service --no-pager
sudo iptables -t nat -S
sudo iptables -S FORWARD
```

---

## 6) Certificado CA de mitmproxy

```bash
ls -lh /root/.mitmproxy/
# mitmproxy-ca-cert.pem  ← instalar en el dispositivo del alumno (solo lab)
```

Para distribuirlo por HTTP desde el propio Pi (si hay apache/nginx instalado):

```bash
cp /root/.mitmproxy/mitmproxy-ca-cert.pem /var/www/html/
# Alumnos: http://192.168.50.1/mitmproxy-ca-cert.pem
```

---

## 7) Captura de tráfico para análisis

```bash
sudo IFACE=wlan0 DURATION_SEC=180 ./soc_monitor.sh
ls -lh /var/log/enterprise
```
