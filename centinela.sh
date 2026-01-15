#!/bin/bash
#
# centinela.sh - Vigilancia del gateway para detectar suplantación ARP
#
# Este script monitoriza continuamente la dirección MAC del gateway por defecto
# con el fin de detectar ataques de suplantación ARP (MITM) en redes locales.
# Incorpora mejoras respecto a la versión anterior: autodetección de interfaz y
# gateway, almacenamiento persistente de la MAC esperada, opciones de log,
# intervalo configurable, modo "panic" y salida silenciosa. Está pensado para
# ejecutarse con privilegios de superusuario (sudo) y en entornos basados en
# GNU/Linux con herramientas estándar (iproute2, iputils).
#
# Uso básico:
#   sudo ./centinela.sh             # vigila el gateway detectado automáticamente
#
# Opciones:
#   -i, --interface IFACE    Interfaz de red a vigilar (por defecto se detecta)
#   -g, --gateway IP         IP del gateway a vigilar (por defecto se detecta)
#   -b, --baseline FILE      Ruta del fichero de baseline (MAC esperada).
#                            Por defecto: ~/.centinela_baseline_<GW>
#   -t, --interval SEGUNDOS  Intervalo entre comprobaciones (por defecto 5)
#   -p, --panic              Modo pánico: baja la interfaz al detectar ataque
#   -l, --log FILE           Escribe eventos en el fichero indicado
#   -q, --quiet              No muestra puntos cuando todo está normal
#   --reset-baseline         Fuerza la regeneración del baseline
#   -h, --help               Muestra esta ayuda y sale
#
# Ejemplo:
#   sudo ./centinela.sh --interface wlo1 --interval 2 --log /var/log/centinela.log
#

set -euo pipefail

##############################
# Variables por defecto
INTERFACE=""
GATEWAY=""
BASELINE_FILE=""
INTERVAL=5
PANIC_MODE=0
LOG_FILE=""
QUIET=0
RESET_BASELINE=0

# Colores para salida
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Reset

# Mostrar ayuda y salir
usage() {
    cat <<EOF
Uso: sudo \$0 [opciones]

Opciones:
  -i, --interface IFACE    Interfaz de red a vigilar (por defecto autodetectada)
  -g, --gateway IP         IP del gateway a vigilar (por defecto autodetectada)
  -b, --baseline FILE      Ruta del fichero baseline con MAC esperada
  -t, --interval SEGUNDOS  Intervalo entre comprobaciones (por defecto 5)
  -p, --panic              Baja la interfaz al detectar ataque
  -l, --log FILE           Registra eventos en el fichero indicado
  -q, --quiet              No imprime puntos cuando todo está normal
      --reset-baseline     Regenera el baseline ignorando el guardado
  -h, --help               Muestra esta ayuda
EOF
}

# Escribe log si LOG_FILE está definido
log_msg() {
    local msg="$1"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s - %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE"
    fi
}

# Salida de error y finaliza
die() {
    echo -e "${RED}[!] $*${NC}" >&2
    exit 1
}

# Parseo sencillo de argumentos
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--interface)
            INTERFACE="$2"
            shift 2
            ;;
        -g|--gateway)
            GATEWAY="$2"
            shift 2
            ;;
        -b|--baseline)
            BASELINE_FILE="$2"
            shift 2
            ;;
        -t|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -p|--panic)
            PANIC_MODE=1
            shift
            ;;
        -l|--log)
            LOG_FILE="$2"
            shift 2
            ;;
        -q|--quiet)
            QUIET=1
            shift
            ;;
        --reset-baseline)
            RESET_BASELINE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Opción desconocida: $1. Use --help para ver las opciones"
            ;;
    esac
done

# Verificación de superusuario
# Es preferible usar id -u ya que la variable EUID puede no estar definida en algunos entornos
if [[ $(id -u) -ne 0 ]]; then
    die "Debes ejecutar este script como root (sudo)"
fi

# Verificar dependencias mínimas
for cmd in ip awk ping; do
    command -v "$cmd" >/dev/null 2>&1 || die "Dependencia faltante: $cmd"
done

# Autodetectar gateway si no se especificó
if [[ -z "$GATEWAY" ]]; then
    GATEWAY=$(ip route | awk '/^default/ {print $3; exit}')
    [[ -n "$GATEWAY" ]] || die "No se pudo detectar el gateway por defecto. Usa --gateway para especificarlo."
fi

# Autodetectar interfaz si no se especificó
if [[ -z "$INTERFACE" ]]; then
    # Obtener el dispositivo asociado a la ruta por defecto
    INTERFACE=$(ip route | awk -v gw="$GATEWAY" '$0 ~ gw { for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit} }')
    # Fallback por si no coincide: toma cualquier dev de default
    if [[ -z "$INTERFACE" ]]; then
        INTERFACE=$(ip route | awk '/^default/ {print $5; exit}')
    fi
    [[ -n "$INTERFACE" ]] || die "No se pudo autodetectar la interfaz. Usa --interface."
fi

# Asegurarse de que la interfaz exista
if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
    die "La interfaz $INTERFACE no existe"
fi

# Baseline file: si no se especificó, usar un nombre basado en gateway
if [[ -z "$BASELINE_FILE" ]]; then
    # Expandir HOME correctamente incluso en sudo
    local_home="${SUDO_USER:-root}"
    HOME_DIR=$(getent passwd "$local_home" | cut -d: -f6 || echo "/root")
    BASELINE_FILE="$HOME_DIR/.centinela_baseline_${GATEWAY//./_}"
fi

# Función para obtener MAC y estado actual del gateway
get_neighbor_info() {
    local ip="$1"
    local dev="$2"
    # Forzar actualización de la entrada de neighbor con ping
    ping -c 1 -W 1 "$ip" >/dev/null 2>&1 || true
    # Leer entrada de neighbor (dev opcional)
    local entry
    entry=$(ip neigh show "$ip" dev "$dev" 2>/dev/null | head -n1)
    local mac=""
    local state=""
    if [[ -n "$entry" ]]; then
        # Formato típico: <IP> dev <iface> lladdr <MAC> <state>
        mac=$(echo "$entry" | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") {print $(i+1); break}}')
        state=$(echo "$entry" | awk '{print $NF}')
    fi
    echo "$mac $state"
}

# Leer o generar baseline
EXPECTED_MAC=""
if [[ $RESET_BASELINE -eq 1 ]]; then
    rm -f "$BASELINE_FILE"
fi
if [[ -s "$BASELINE_FILE" ]]; then
    EXPECTED_MAC=$(cat "$BASELINE_FILE" | tr -d '\n')
else
    # Obtener MAC inicial
    read -r mac state <<< "$(get_neighbor_info "$GATEWAY" "$INTERFACE")"
    if [[ -z "$mac" ]]; then
        die "No se pudo obtener la MAC del gateway ($GATEWAY) en la interfaz $INTERFACE. Comprueba la conectividad."
    fi
    EXPECTED_MAC="$mac"
    echo "$EXPECTED_MAC" > "$BASELINE_FILE"
    echo -e "${YELLOW}[i] Baseline creado: MAC esperada $EXPECTED_MAC almacenada en $BASELINE_FILE${NC}"
fi

echo -e "${GREEN}[+] Gateway monitoreado: $GATEWAY${NC}"
echo -e "${GREEN}[+] Interfaz usada: $INTERFACE${NC}"
echo -e "${GREEN}[+] MAC esperada: $EXPECTED_MAC${NC}"
if [[ $PANIC_MODE -eq 1 ]]; then
    echo -e "${YELLOW}[!] Modo pánico activado. Se bajará la interfaz al detectar ataque.${NC}"
fi

log_msg "Inicio de vigilancia. Gateway=$GATEWAY, Interfaz=$INTERFACE, BaselineMAC=$EXPECTED_MAC, Intervalo=${INTERVAL}s"

trap 'echo -e "\n${YELLOW}[i] Saliendo...${NC}"; log_msg "Vigilancia finalizada"; exit 0' SIGINT SIGTERM

# Bucle principal
while true; do
    read -r current_mac state <<< "$(get_neighbor_info "$GATEWAY" "$INTERFACE")"
    # Comprobar estado
    if [[ -z "$current_mac" || "$state" == "INCOMPLETE" || "$state" == "FAILED" ]]; then
        [[ $QUIET -eq 0 ]] && echo -e "${YELLOW}[!] Señal perdida o sin entrada válida... buscando router...${NC}"
        log_msg "Señal perdida o estado $state"
    elif [[ "$current_mac" != "$EXPECTED_MAC" ]]; then
        echo -e "${RED}[ALERTA MÁXIMA] ¡Ataque detectado! La MAC del gateway ha cambiado.${NC}"
        echo -e "${RED}[!] MAC esperada: $EXPECTED_MAC${NC}"
        echo -e "${RED}[!] MAC actual:    $current_mac${NC}"
        log_msg "ATAQUE DETECTADO - MAC esperada=$EXPECTED_MAC, MAC actual=$current_mac"
        # Modo pánico: bajar interfaz
        if [[ $PANIC_MODE -eq 1 ]]; then
            echo -e "${RED}[!] Activando modo pánico. Bajando la interfaz $INTERFACE...${NC}"
            ip link set "$INTERFACE" down || true
            log_msg "Interfaz $INTERFACE desactivada por pánico"
        fi
        # beep sonoro
        printf '\a'
        # Para evitar alertas constantes, actualizar baseline solo si el usuario lo desea con --reset-baseline
    else
        # Todo normal
        if [[ $QUIET -eq 0 ]]; then
            printf '.'
        fi
    fi
    sleep "$INTERVAL"
done