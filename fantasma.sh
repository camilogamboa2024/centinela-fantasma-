#!/bin/bash
#
# fantasma.sh - Modo privacidad: cambio de MAC y endurecimiento de firewall
#
# Este script permite activar o desactivar un "modo fantasma" en el que se
# altera la dirección MAC de una interfaz de red, se configura un conjunto de
# reglas básicas de firewall mediante UFW (bloquear entrantes y permitir
# salientes) y se reinicia NetworkManager para aplicar los cambios. También
# permite restaurar la MAC de fábrica cuando el modo se desactiva. Está
# pensado para ejecutarse con privilegios de superusuario y en sistemas
# basados en systemd.
#
# Uso:
#   sudo ./fantasma.sh on [--interface IFACE]    # Activa el modo fantasma
#   sudo ./fantasma.sh off [--interface IFACE]   # Desactiva el modo fantasma
#   sudo ./fantasma.sh --help                    # Muestra la ayuda
#
# Dependencias: network-manager, ufw, macchanger, iproute2

set -euo pipefail

INTERFACE=""
COMMAND=""

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat <<EOF
Uso: sudo \$0 <on|off|start|stop> [--interface IFACE]

Acciones:
  on, start    Activa el modo fantasma (cambia MAC y activa firewall)
  off, stop    Desactiva el modo fantasma (restaura MAC original)

Opciones:
  -i, --interface IFACE  Especifica la interfaz de red a modificar. Si se
                         omite, se intentará autodetectar la interfaz
                         activa (la primera interfaz inalámbrica o cableada)
  -h, --help             Muestra esta ayuda y sale

Dependencias: network-manager, ufw, macchanger, iproute2
EOF
}

# Detectar la primera interfaz activa no loopback
detect_interface() {
    # Interfaz conectada con dirección enrutada
    local iface
    iface=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
    if [[ -n "$iface" ]]; then
        echo "$iface"
        return
    fi
    # Fallback: primer interfaz no loopback ni virtual
    iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -Ev 'lo|vir|docker' | head -n1)
    echo "$iface"
}

# Validar dependencias
check_dependencies() {
    local missing=0
    for cmd in systemctl ufw macchanger ip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}[!] Dependencia faltante: $cmd${NC}" >&2
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
}

# Activar modo fantasma
activar_modo() {
    local iface="$1"
    echo -e "${GREEN}[*] ACTIVANDO MODO FANTASMA en interfaz $iface...${NC}"
    # Detener NetworkManager
    echo -e "${BLUE}    -> Deteniendo NetworkManager...${NC}"
    systemctl stop NetworkManager || true
    # Configurar firewall básico
    echo -e "${BLUE}    -> Configurando UFW (deny incoming / allow outgoing)...${NC}"
    ufw --force default deny incoming >/dev/null
    ufw --force default allow outgoing >/dev/null
    ufw --force enable >/dev/null
    # Cambiar MAC a aleatoria
    echo -e "${BLUE}    -> Generando identidad MAC aleatoria...${NC}"
    ip link set "$iface" down
    macchanger -r "$iface" | grep -E "New MAC" || true
    ip link set "$iface" up
    # Reiniciar NetworkManager
    echo -e "${BLUE}    -> Reiniciando NetworkManager...${NC}"
    systemctl start NetworkManager || true
    echo -e "${GREEN}[✔] Modo fantasma activado. MAC aleatoria aplicada.${NC}"
}

# Desactivar modo fantasma
desactivar_modo() {
    local iface="$1"
    echo -e "${YELLOW}[*] DESACTIVANDO MODO FANTASMA en interfaz $iface...${NC}"
    # Detener NetworkManager
    echo -e "${BLUE}    -> Deteniendo NetworkManager...${NC}"
    systemctl stop NetworkManager || true
    # Restaurar MAC permanente
    echo -e "${BLUE}    -> Restaurando MAC permanente...${NC}"
    ip link set "$iface" down
    macchanger -p "$iface" | grep -E "Permanent" || true
    ip link set "$iface" up
    # Reiniciar NetworkManager
    echo -e "${BLUE}    -> Reiniciando NetworkManager...${NC}"
    systemctl start NetworkManager || true
    echo -e "${YELLOW}[i] Nota: UFW permanece activo para tu seguridad. Puedes desactivarlo manualmente con 'sudo ufw disable' si lo deseas.${NC}"
    echo -e "${GREEN}[✔] Modo fantasma desactivado. MAC restaurada.${NC}"
}

# Procesar argumentos
ARGS=("$@")
if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        on|start|off|stop)
            COMMAND="$1"
            shift
            ;;
        -i|--interface)
            INTERFACE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}[!] Opción o comando no reconocido: $1${NC}" >&2
            usage
            exit 1
            ;;
    esac
done

# Verificar ejecución como root
# Usamos id -u en lugar de EUID por compatibilidad
if [[ $(id -u) -ne 0 ]]; then
    echo -e "${RED}[!] Debes ejecutar este script con sudo${NC}" >&2
    exit 1
fi

# Verificar dependencias
check_dependencies

# Autodetectar interfaz si no se especificó
if [[ -z "$INTERFACE" ]]; then
    INTERFACE=$(detect_interface)
    [[ -n "$INTERFACE" ]] || { echo -e "${RED}[!] No se pudo detectar una interfaz de red válida. Usa --interface para especificar una." >&2; exit 1; }
fi

# Asegurarse de que la interfaz exista
if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo -e "${RED}[!] La interfaz $INTERFACE no existe${NC}" >&2
    exit 1
fi

# Ejecutar comando
case "$COMMAND" in
    on|start)
        activar_modo "$INTERFACE"
        ;;
    off|stop)
        desactivar_modo "$INTERFACE"
        ;;
    *)
        echo -e "${RED}[!] Comando desconocido: $COMMAND${NC}" >&2
        usage
        exit 1
        ;;
esac