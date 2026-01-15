# Centinela & Fantasma —  vigilancia de red y privacidad

Este repositorio contiene **dos scripts Bash** que te ayudan a mejorar la seguridad en redes locales y tu privacidad al conectarte a redes inseguras. Están pensados para sistemas GNU/Linux basados en Debian (Parrot OS, Kali, Ubuntu, etc.), aunque pueden adaptarse a otros entornos que dispongan de `iproute2`, `ping`, `systemd`, `ufw` y `macchanger`.

## ⚠️ Aviso de uso responsable

Estos scripts se proporcionan con fines **educativos, defensivos y de auditoría autorizada**. No los utilices para suplantar identidades, evadir controles de acceso ni para actividades no autorizadas en redes ajenas. Ejecútalos siempre en entornos de laboratorio o redes sobre las que tengas permiso de administración.

---

## Contenido

- **`centinela.sh`** – Vigila la dirección MAC del gateway por defecto para detectar ataques de suplantación ARP (MITM). Incluye
  autodetección de interfaz y gateway, almacenamiento persistente de la MAC esperada, intervalos configurables, modo pánico y registro de eventos.
- **`fantasma.sh`** – Activa y desactiva un “modo fantasma” que cambia la dirección MAC de tu interfaz por una aleatoria y configura reglas básicas de firewall (UFW) para limitar entradas y permitir salidas. Útil para aumentar privacidad en redes públicas.

La estructura recomendada del repositorio es la siguiente:

```txt
centinela-fantasma/
├─ centinela.sh     # vigilante de suplantación ARP (versión mejorada)
├─ fantasma.sh      # modo fantasma con cambio de MAC y firewall
└─ README.md        # esta documentación
```

---

## Requisitos y dependencias

Antes de usar cualquiera de los scripts, verifica que tu sistema cumple estos requisitos:

- **Sistema operativo**: Debian, Ubuntu, Parrot, Kali u otra distribución con `systemd` y herramientas estándar.
- **Python**: No es necesario. Son scripts Bash.
- **Herramientas necesarias**:
  - `ip` y `ip neigh` (proveídos por el paquete `iproute2`)
  - `ping` (`iputils-ping`)
  - `awk`
  - `systemctl` (parte de `systemd`) → para reiniciar NetworkManager
  - `ufw` (Uncomplicated Firewall) → configuración de firewall en `fantasma.sh`
  - `macchanger` → para modificar direcciones MAC

Para instalar las dependencias en Debian/Ubuntu/Parrot, ejecuta:

```bash
sudo apt update
sudo apt install -y iproute2 iputils-ping network-manager ufw macchanger
```

> En Parrot OS y Kali es posible que algunas de estas herramientas ya estén instaladas. De todos modos, se recomienda asegurar su presencia.

---

## Instalación del repositorio

1. **Clonar o copiar** este repositorio:

   ```bash
   git clone https://github.com/camilogamboa2024/centinela-fantasma-
   cd centinela-fantasma
   ```

2. **Asignar permisos de ejecución** a los scripts:

   ```bash
   chmod +x centinela.sh fantasma.sh
   ```

3. (Opcional) **Instalación global** para poder ejecutarlos como comandos `centinela` y `fantasma` desde cualquier ubicación:

   ```bash
   sudo cp centinela.sh /usr/local/sbin/centinela
   sudo cp fantasma.sh /usr/local/sbin/fantasma
   sudo chmod +x /usr/local/sbin/centinela /usr/local/sbin/fantasma
   ```

   Con esta instalación podrás invocar los scripts directamente como `sudo centinela` y `sudo fantasma on`.

---

## Uso de `centinela.sh`

Este script vigila la dirección MAC del gateway (router) asociado a tu ruta por defecto para detectar cambios inesperados que podrían indicar un ataque de suplantación ARP (Man-in-the-Middle). Se ejecuta en un bucle y muestra puntos (`.`) cuando todo va bien; en caso de error o suplantación muestra mensajes de advertencia.

### Ejecución básica

```bash
sudo ./centinela.sh
```

Sin argumentos, `centinela.sh` autodetecta la interfaz y el gateway por defecto, guarda la MAC esperada en un fichero de baseline en tu directorio `~` y comienza a vigilar cada 5 segundos. Si es la primera vez que lo ejecutas, creará el baseline automáticamente.

### Opciones disponibles

| Opción | Descripción |
|------|-------------|
| `-i, --interface IFACE` | Especifica la interfaz de red a vigilar (por ejemplo `wlan0`, `eth0`). Por defecto se autodetecta. |
| `-g, --gateway IP` | Especifica manualmente la IP del gateway a vigilar. Por defecto se detecta la ruta por defecto. |
| `-b, --baseline FILE` | Fichero donde se almacena la MAC esperada del gateway. Por defecto: `~/.centinela_baseline_<GW>`. |
| `-t, --interval SEGUNDOS` | Intervalo en segundos entre comprobaciones (por defecto `5`). |
| `-p, --panic` | Activa modo pánico: si se detecta suplantación, se baja la interfaz de red inmediatamente. |
| `-l, --log FILE` | Registra eventos y alertas en el fichero indicado. |
| `-q, --quiet` | No muestra puntos (salida limpia). Solo se muestran alertas o advertencias. |
| `--reset-baseline` | Fuerza la regeneración del baseline MAC (útil si el router cambió de forma legítima). |
| `-h, --help` | Muestra la ayuda y sale. |

### Ejemplo avanzado

```bash
sudo ./centinela.sh \
    --interface wlo1 \
    --interval 2 \
    --log /var/log/centinela.log \
    --panic
```

En este ejemplo se vigila específicamente la interfaz `wlo1` cada 2 segundos, se registran los eventos en `/var/log/centinela.log` y, si se detecta suplantación, se baja la interfaz para cortar la conexión.

### Consideraciones y limitaciones

- `centinela.sh` detecta suplantación de ARP **solo en el gateway** (router) asociado a la ruta por defecto. No detecta otros tipos de MITM (DNS spoofing, proxies maliciosos, etc.) ni suplantaciones a nivel IPv6.
- Redes con mecanismos de alta disponibilidad (VRRP/HSRP), AP mesh, cambios legítimos de router o roaming pueden generar **falsos positivos**. Ajusta el baseline o intervalo según tus necesidades.
- El modo pánico baja la interfaz para evitar tráfico; deberás reactivarla manualmente (`sudo ip link set <iface> up`) si es necesario.

---

## Uso de `fantasma.sh`

`fantasma.sh` automatiza un cambio temporal de la dirección MAC de una interfaz y configura reglas básicas de firewall (UFW) para minimizar la exposición de servicios cuando te conectas a redes públicas. Permite activar (“on”) y desactivar (“off”) este modo.

### Activar modo fantasma

```bash
sudo ./fantasma.sh on
```

El script realiza los siguientes pasos:

1. **Detiene NetworkManager** para poder alterar la interfaz sin interferencias.
2. **Configura UFW** para denegar conexiones entrantes y permitir salientes (`deny incoming`, `allow outgoing`) y lo habilita (`ufw enable`).
3. **Baja la interfaz**, genera una **MAC aleatoria** con `macchanger -r` y la vuelve a subir.
4. **Reinicia NetworkManager** para restablecer la conexión con la nueva MAC.

De forma predeterminada, `fantasma.sh` autodetecta la interfaz activa (la usada en la ruta por defecto). Puedes especificarla con `-i` si tienes varias interfaces:

```bash
sudo ./fantasma.sh on --interface eth0
```

### Desactivar modo fantasma

```bash
sudo ./fantasma.sh off
```

El script revierte los pasos anteriores:

1. Detiene NetworkManager.
2. Restaura la MAC permanente de la interfaz (`macchanger -p`).
3. Vuelve a subir la interfaz y reinicia NetworkManager.
4. **No desactiva UFW** por seguridad. Si deseas volver a tu configuración de firewall anterior, ejecútalo manualmente: `sudo ufw disable` o ajusta las reglas según tu entorno.

### Opciones de `fantasma.sh`

| Opción | Descripción |
|------|-------------|
| `on`, `start` | Activa el modo fantasma: cambia MAC, configura UFW y reinicia la red. |
| `off`, `stop` | Desactiva el modo fantasma: restaura MAC y reinicia la red. |
| `-i, --interface IFACE` | Especifica la interfaz de red a modificar. Si no se indica, se intentará autodetectar. |
| `-h, --help` | Muestra la ayuda. |

### Notas importantes

- Cambiar la MAC **no te hace invisible**; simplemente evita que terceros te identifiquen fácilmente por tu hardware. Algunas redes (hoteles, universidades) restringen el acceso por MAC, por lo que puedes perder la conexión temporalmente.
- UFW puede interferir con servicios locales que necesiten puertos entrantes (SSH, HTTP). Ajusta sus reglas si requieres exponer servicios.
- Si tu distribución no usa NetworkManager, adapta los comandos para detener y reiniciar la red.

---

## Consejos de uso conjunto

1. **Antes de conectarte a una red pública**, ejecuta `fantasma.sh on` para cambiar tu MAC y levantar un firewall restrictivo.
2. Una vez conectado, ejecuta `centinela.sh` para monitorizar que la dirección MAC del gateway no cambie repentinamente. Puedes dejarlo ejecutándose en segundo plano (`Ctrl+Z` + `bg`).
3. Si `centinela.sh` detecta suplantación, desconéctate de la red y utiliza el modo pánico (`centinela.sh --panic`) o baja manualmente la interfaz.
4. Cuando regreses a una red de confianza, ejecuta `fantasma.sh off` para restaurar tu MAC real (o reinicia la máquina) y ajusta UFW según tus necesidades.

---

## Roadmap y mejoras futuras

Se han implementado muchas de las recomendaciones iniciales para aumentar la puntuación del proyecto, pero aún existen áreas de mejora:

- [ ] Soporte para detección de suplantación en IPv6 (NDP).
- [ ] Persistencia de registros con rotación y formatos estándar (JSON/CSV).
- [ ] Exportación de eventos a servicios de notificación (Telegram, Discord, Syslog remoto).
- [ ] Autoajuste de intervalos y tiempos de espera según el estado de la red.
- [ ] Scripts de instalación y desinstalación dedicados (`make install`, `make uninstall`).

---

## Licencia

Puedes utilizar estos scripts bajo los términos de la licencia **MIT**. Consulta el fichero `LICENSE` si se incluye, o añade tu propia licencia preferida.
