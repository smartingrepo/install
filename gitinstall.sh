#!/bin/bash
################################################################################
# Git Repository Installer for gitup.sh
# 
# Instalador automático de repositorios Git que utilizan gitup.sh como wrapper.
# Gestiona llaves SSH, clonación de repositorios y configuración de crontab.
#
# Uso básico:
#   curl -sSL https://url/gitinstall.sh | sudo bash -s -- \
#       --ssh-key-b64 "$(cat key | base64 -w0)" \
#       --repo-url git@github.com:org/repo.git \
#       --target-script script.sh
#
# Uso con desinstalación:
#   sudo ./gitinstall.sh --uninstall --repo-name inventory
#
################################################################################

set -e

# Colores para mensajes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Valores por defecto
DEFAULT_KEY_NAME="deploy"
DEFAULT_INSTALL_DIR="/usr/local/bin"
DEFAULT_LOG_DIR="/var/log"

# Variables globales
SSH_KEY=""
SSH_KEY_B64=""
REPO_URL=""
TARGET_SCRIPT=""
KEY_NAME=""
INSTALL_DIR=""
CRON_SCHEDULE=""
REQUIRED_PARAMS=""
LOG_DIR=""
UNINSTALL=false
REPO_NAME=""
EXTRA_PARAMS=()
COLLECTED_PARAMS=()

################################################################################
# FUNCIONES DE UTILIDAD
################################################################################

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}${BOLD}▶ $1${NC}"
}

log_success() {
    echo -e "${GREEN}${BOLD}✓ $1${NC}"
}

prompt_user() {
    local prompt="$1"
    local default="$2"
    local result
    
    if [ -n "$default" ]; then
        read -p "$(echo -e "${CYAN}$prompt${NC} [${default}]: ")" result
        echo "${result:-$default}"
    else
        read -p "$(echo -e "${CYAN}$prompt${NC}: ")" result
        echo "$result"
    fi
}

################################################################################
# AYUDA Y PARSING DE ARGUMENTOS
################################################################################

show_help() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                    GIT REPOSITORY INSTALLER - gitinstall.sh                  ║
╚══════════════════════════════════════════════════════════════════════════════╝

DESCRIPCIÓN:
  Instalador automático de repositorios Git que utilizan gitup.sh como wrapper.
  Gestiona llaves SSH, clonación de repositorios y configuración de crontab.

USO:
  gitinstall.sh [opciones] [-- parámetros_extra_para_script]

PARÁMETROS OBLIGATORIOS:
  --ssh-key-b64 <key>     Llave SSH privada codificada en Base64
                          Ejemplo: --ssh-key-b64 "$(cat key | base64 -w0)"
  
  --repo-url <url>        URL SSH del repositorio Git
                          Ejemplo: --repo-url git@github.com:org/repo.git
  
  --target-script <name>  Nombre del script que ejecutará gitup.sh
                          Ejemplo: --target-script sysinv.sh

PARÁMETROS OPCIONALES:
  --key-name <name>       Nombre del archivo de llave SSH (default: deploy)
  --install-dir <path>    Directorio de instalación (default: /usr/local/bin)
  --log-dir <path>        Directorio de logs (default: /var/log)
  --cron-schedule <cron>  Programación cron (si no se indica, se pregunta)
                          Ejemplo: --cron-schedule "0 */6 * * *"
  
  --required-params <p>   Lista de parámetros obligatorios separados por coma
                          Ejemplo: --required-params "youtrack-base,youtrack-infra"
  
  --<param> <valor>       Valor para un parámetro definido en --required-params
                          Ejemplo: --youtrack-base BDC-A-729

DESINSTALACIÓN:
  --uninstall             Modo desinstalación
  --repo-name <name>      Nombre del repositorio a desinstalar (requerido con --uninstall)

OTROS:
  -h, --help              Mostrar esta ayuda
  --                      Separador para parámetros extra del script target

EJEMPLOS:

  1. Instalación interactiva (pregunta parámetros y cron):
     curl -sSL https://url/gitinstall.sh | sudo bash -s -- \
         --ssh-key-b64 "$(cat ~/.ssh/deploy | base64 -w0)" \
         --repo-url git@github.com:smarting/inventory.git \
         --target-script sysinv.sh \
         --required-params "youtrack-base,youtrack-infra"

  2. Instalación no-interactiva completa:
     sudo ./gitinstall.sh \
         --ssh-key-b64 "$(cat ~/.ssh/deploy | base64 -w0)" \
         --repo-url git@github.com:smarting/inventory.git \
         --target-script sysinv.sh \
         --key-name inventory-deploy \
         --cron-schedule "0 6,12,18 * * *" \
         --required-params "youtrack-base,youtrack-infra" \
         --youtrack-base BDC-A-729 \
         --youtrack-infra V2 \
         -- --no-warnings

  3. Desinstalación:
     sudo ./gitinstall.sh --uninstall --repo-name inventory

PROGRAMACIÓN CRON (ejemplos para --cron-schedule):
  "*/5 * * * *"       Cada 5 minutos
  "0 * * * *"         Cada hora (en punto)
  "0 */2 * * *"       Cada 2 horas
  "0 */6 * * *"       Cada 6 horas
  "0 6 * * *"         Diariamente a las 6:00
  "0 6,12,18 * * *"   A las 6:00, 12:00 y 18:00
  "30 7 * * *"        Diariamente a las 7:30
  "0 8 * * 1-5"       Lunes a viernes a las 8:00
  "0 6 * * 1"         Cada lunes a las 6:00
  "0 0 1 * *"         El día 1 de cada mes a medianoche

  Formato: MIN HORA DIA MES DIA_SEMANA
  - MIN:        0-59
  - HORA:       0-23
  - DIA:        1-31
  - MES:        1-12
  - DIA_SEMANA: 0-7 (0 y 7 = domingo, 1 = lunes...)
  
  Comodines: * (cualquier valor), */N (cada N), N,M (lista), N-M (rango)

EOF
}

parse_arguments() {
    local extra_mode=false
    declare -A provided_params
    
    while [[ $# -gt 0 ]]; do
        if $extra_mode; then
            EXTRA_PARAMS+=("$1")
            shift
            continue
        fi
        
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --ssh-key-b64)
                SSH_KEY_B64="$2"
                shift 2
                ;;
            --repo-url)
                REPO_URL="$2"
                shift 2
                ;;
            --target-script)
                TARGET_SCRIPT="$2"
                shift 2
                ;;
            --key-name)
                KEY_NAME="$2"
                shift 2
                ;;
            --install-dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --log-dir)
                LOG_DIR="$2"
                shift 2
                ;;
            --cron-schedule)
                CRON_SCHEDULE="$2"
                shift 2
                ;;
            --required-params)
                REQUIRED_PARAMS="$2"
                shift 2
                ;;
            --uninstall)
                UNINSTALL=true
                shift
                ;;
            --repo-name)
                REPO_NAME="$2"
                shift 2
                ;;
            --)
                extra_mode=true
                shift
                ;;
            --*)
                # Parámetro personalizado para el script target
                local param_name="${1#--}"
                local param_value="$2"
                provided_params["$param_name"]="$param_value"
                shift 2
                ;;
            *)
                log_error "Argumento desconocido: $1"
                echo "Use --help para ver la ayuda"
                exit 1
                ;;
        esac
    done
    
    # Guardar parámetros proporcionados para uso posterior
    for key in "${!provided_params[@]}"; do
        # Convertir guiones a guiones bajos para nombres de variables válidos
        local safe_key=$(echo "$key" | tr '-' '_')
        eval "PARAM_$safe_key=\"${provided_params[$key]}\""
    done
    
    # Establecer valores por defecto
    KEY_NAME="${KEY_NAME:-$DEFAULT_KEY_NAME}"
    INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
}

validate_install_arguments() {
    local errors=0
    
    if [ -z "$SSH_KEY_B64" ]; then
        log_error "Falta parámetro obligatorio: --ssh-key-b64"
        errors=$((errors + 1))
    fi
    
    if [ -z "$REPO_URL" ]; then
        log_error "Falta parámetro obligatorio: --repo-url"
        errors=$((errors + 1))
    fi
    
    if [ -z "$TARGET_SCRIPT" ]; then
        log_error "Falta parámetro obligatorio: --target-script"
        errors=$((errors + 1))
    fi
    
    if [ $errors -gt 0 ]; then
        echo ""
        echo "Use --help para ver la ayuda completa"
        exit 1
    fi
    
    # Decodificar llave SSH
    SSH_KEY=$(echo "$SSH_KEY_B64" | base64 -d 2>/dev/null)
    if [ -z "$SSH_KEY" ]; then
        log_error "No se pudo decodificar la llave SSH. Verifique que esté en Base64 válido."
        exit 1
    fi
    
    # Extraer nombre del repositorio del URL
    if [ -z "$REPO_NAME" ]; then
        REPO_NAME=$(basename "$REPO_URL" .git)
    fi
}

validate_uninstall_arguments() {
    if [ -z "$REPO_NAME" ]; then
        log_error "Falta parámetro obligatorio para desinstalar: --repo-name"
        exit 1
    fi
}

################################################################################
# GESTIÓN DE LLAVE SSH
################################################################################

setup_ssh_key() {
    log_step "Configurando llave SSH..."
    
    local ssh_dir="$HOME/.ssh"
    local key_file="$ssh_dir/$KEY_NAME"
    
    # Crear directorio .ssh si no existe
    if [ ! -d "$ssh_dir" ]; then
        log_info "Creando directorio $ssh_dir..."
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
    fi
    
    # Verificar si la llave ya existe
    if [ -f "$key_file" ]; then
        local existing_key=$(cat "$key_file")
        
        if [ "$existing_key" = "$SSH_KEY" ]; then
            log_success "La llave SSH '$KEY_NAME' ya existe y es idéntica"
            return 0
        else
            log_error "La llave SSH '$KEY_NAME' ya existe pero es DIFERENTE"
            log_error "Archivo existente: $key_file"
            log_error "Use --key-name para especificar un nombre diferente"
            exit 1
        fi
    fi
    
    # Crear la llave
    log_info "Creando llave SSH: $key_file"
    echo "$SSH_KEY" > "$key_file"
    chmod 600 "$key_file"
    
    log_success "Llave SSH creada correctamente"
}

update_ssh_config() {
    log_step "Configurando SSH config..."
    
    local ssh_config="$HOME/.ssh/config"
    local key_file="$HOME/.ssh/$KEY_NAME"
    
    # Extraer el host del URL del repositorio
    # Formato: git@github.com:org/repo.git -> github.com
    local git_host=$(echo "$REPO_URL" | sed -n 's/.*@\([^:]*\):.*/\1/p')
    
    if [ -z "$git_host" ]; then
        log_error "No se pudo extraer el host del URL: $REPO_URL"
        exit 1
    fi
    
    # Alias para el host (para poder tener múltiples llaves para el mismo host)
    local host_alias="${git_host}-${KEY_NAME}"
    
    # Verificar si ya existe la configuración
    if [ -f "$ssh_config" ] && grep -q "Host $host_alias" "$ssh_config" 2>/dev/null; then
        log_success "Configuración SSH para '$host_alias' ya existe"
    else
        # Añadir configuración
        log_info "Añadiendo entrada a $ssh_config..."
        
        cat >> "$ssh_config" << EOF

# Añadido por gitinstall.sh - $(date '+%Y-%m-%d %H:%M:%S') - $REPO_NAME
Host $host_alias
    HostName $git_host
    User git
    IdentityFile $key_file
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
        
        chmod 600 "$ssh_config"
        log_success "Configuración SSH actualizada"
    fi
    
    # Modificar el REPO_URL para usar el alias (SIEMPRE, incluso si ya existía la config)
    REPO_URL=$(echo "$REPO_URL" | sed "s/@$git_host:/@$host_alias:/")
    log_info "Usando URL con alias: $REPO_URL"
}

################################################################################
# CLONACIÓN DEL REPOSITORIO
################################################################################

clone_repository() {
    log_step "Clonando repositorio..."
    
    local repo_path="$INSTALL_DIR/$REPO_NAME"
    
    # Verificar que git esté instalado
    if ! command -v git &>/dev/null; then
        log_error "Git no está instalado. Por favor, instale git primero."
        exit 1
    fi
    
    # Crear directorio de instalación si no existe
    if [ ! -d "$INSTALL_DIR" ]; then
        log_info "Creando directorio: $INSTALL_DIR"
        mkdir -p "$INSTALL_DIR"
    fi
    
    # Si el repositorio ya existe, hacer backup
    if [ -d "$repo_path" ]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local backup_path="${repo_path}.backup.${timestamp}"
        
        log_warn "El repositorio ya existe: $repo_path"
        log_info "Creando backup: $backup_path"
        
        mv "$repo_path" "$backup_path"
        log_success "Backup creado correctamente"
    fi
    
    # Clonar el repositorio
    log_info "Clonando desde: $REPO_URL"
    log_info "Destino: $repo_path"
    
    if ! git clone "$REPO_URL" "$repo_path" 2>&1; then
        log_error "Error al clonar el repositorio"
        exit 1
    fi
    
    # Dar permisos de ejecución a scripts
    log_info "Estableciendo permisos de ejecución..."
    find "$repo_path" -maxdepth 2 -type f \( -name "*.sh" -o -name "*.bash" \) -exec chmod +x {} \; 2>/dev/null
    find "$repo_path" -maxdepth 2 -type f -name "*.py" -exec chmod +x {} \; 2>/dev/null
    
    # Verificar que gitup.sh existe
    if [ ! -f "$repo_path/gitup.sh" ]; then
        log_error "No se encontró gitup.sh en el repositorio"
        log_error "Este instalador requiere que el repositorio contenga gitup.sh"
        exit 1
    fi
    
    # Verificar que el script target existe
    if [ ! -f "$repo_path/$TARGET_SCRIPT" ]; then
        log_error "No se encontró el script target: $TARGET_SCRIPT"
        log_error "Archivos disponibles en el repositorio:"
        ls -la "$repo_path"/*.sh 2>/dev/null || echo "  (ningún archivo .sh encontrado)"
        exit 1
    fi
    
    log_success "Repositorio clonado correctamente en: $repo_path"
}

################################################################################
# RECOLECCIÓN DE PARÁMETROS
################################################################################

collect_target_params() {
    log_step "Configurando parámetros del script target..."
    
    if [ -z "$REQUIRED_PARAMS" ]; then
        log_info "No hay parámetros obligatorios definidos"
        return 0
    fi
    
    # Convertir lista separada por comas en array
    IFS=',' read -ra params <<< "$REQUIRED_PARAMS"
    
    for param in "${params[@]}"; do
        # Limpiar espacios
        param=$(echo "$param" | xargs)
        
        # Verificar si el parámetro fue proporcionado en la línea de comandos
        local var_name="PARAM_$param"
        # Reemplazar guiones por guiones bajos para nombres de variables válidos
        var_name=$(echo "$var_name" | tr '-' '_')
        local provided_value="${!var_name}"
        
        if [ -n "$provided_value" ]; then
            log_info "Parámetro --$param: $provided_value (proporcionado)"
            COLLECTED_PARAMS+=("--$param" "$provided_value")
        else
            # Preguntar al usuario
            local value=$(prompt_user "Ingrese valor para --$param")
            if [ -z "$value" ]; then
                log_error "El parámetro --$param es obligatorio"
                exit 1
            fi
            COLLECTED_PARAMS+=("--$param" "$value")
        fi
    done
    
    log_success "Parámetros configurados correctamente"
}

################################################################################
# CONFIGURACIÓN DE CRONTAB
################################################################################

get_cron_schedule() {
    if [ -n "$CRON_SCHEDULE" ]; then
        return 0
    fi
    
    log_step "Configurando programación cron..."
    
    echo ""
    echo -e "${CYAN}Ejemplos de programación cron:${NC}"
    echo "  */5 * * * *     = Cada 5 minutos"
    echo "  0 * * * *       = Cada hora"
    echo "  0 */6 * * *     = Cada 6 horas"
    echo "  0 8,14,20 * * * = A las 8:00, 14:00 y 20:00"
    echo "  0 6 * * *       = Diariamente a las 6:00"
    echo "  0 6 * * 1       = Cada lunes a las 6:00"
    echo ""
    
    CRON_SCHEDULE=$(prompt_user "Introduzca la programación cron" "0 */6 * * *")
    
    # Validar formato básico (5 campos)
    local field_count=$(echo "$CRON_SCHEDULE" | wc -w)
    if [ "$field_count" -ne 5 ]; then
        log_error "Formato cron inválido. Debe tener 5 campos separados por espacios."
        exit 1
    fi
}

setup_crontab() {
    log_step "Configurando crontab..."
    
    get_cron_schedule
    
    local repo_path="$INSTALL_DIR/$REPO_NAME"
    local gitup_path="$repo_path/gitup.sh"
    local script_basename="${TARGET_SCRIPT%.*}"  # Quitar extensión
    local log_file="$LOG_DIR/${script_basename}.log"
    
    # Construir la línea de cron
    local cron_params=""
    
    # Añadir parámetros recolectados
    for param in "${COLLECTED_PARAMS[@]}"; do
        cron_params="$cron_params $param"
    done
    
    # Añadir parámetros extra
    for param in "${EXTRA_PARAMS[@]}"; do
        cron_params="$cron_params $param"
    done
    
    local cron_line="$CRON_SCHEDULE $gitup_path ./$TARGET_SCRIPT$cron_params >> $log_file 2>&1"
    local cron_comment="# gitinstall.sh - $REPO_NAME/$TARGET_SCRIPT - $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Obtener crontab actual
    local temp_cron=$(mktemp)
    crontab -l > "$temp_cron" 2>/dev/null || true
    
    # Buscar y comentar entradas anteriores del mismo script target
    # Buscamos cualquier línea que ejecute gitup.sh con el mismo script target
    local search_pattern="gitup.sh.*[/.]${TARGET_SCRIPT}"
    
    if grep -q "$search_pattern" "$temp_cron" 2>/dev/null; then
        log_warn "Se encontró una entrada anterior para $TARGET_SCRIPT"
        log_info "Comentando entrada anterior..."
        
        # Comentar las líneas que coinciden (que no están ya comentadas)
        sed -i "/$search_pattern/s/^[^#]/# OLD: &/" "$temp_cron"
    fi
    
    # Añadir nueva entrada
    echo "" >> "$temp_cron"
    echo "$cron_comment" >> "$temp_cron"
    echo "$cron_line" >> "$temp_cron"
    
    # Instalar nuevo crontab
    if crontab "$temp_cron"; then
        log_success "Crontab actualizado correctamente"
    else
        log_error "Error al actualizar crontab"
        rm -f "$temp_cron"
        exit 1
    fi
    
    rm -f "$temp_cron"
    
    # Crear directorio de logs si no existe
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
    fi
    
    # Crear archivo de log vacío si no existe
    touch "$log_file"
    
    echo ""
    echo -e "${GREEN}${BOLD}Línea añadida al crontab:${NC}"
    echo -e "${CYAN}$cron_line${NC}"
    echo ""
    echo -e "Logs disponibles en: ${BLUE}$log_file${NC}"
}

################################################################################
# DESINSTALACIÓN
################################################################################

do_uninstall() {
    log_step "Desinstalando $REPO_NAME..."
    
    local repo_path="$INSTALL_DIR/$REPO_NAME"
    
    # Verificar que existe
    if [ ! -d "$repo_path" ]; then
        log_warn "El directorio $repo_path no existe"
    else
        # Hacer backup antes de eliminar
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local backup_path="${repo_path}.uninstall.${timestamp}"
        
        log_info "Creando backup de seguridad: $backup_path"
        mv "$repo_path" "$backup_path"
        log_success "Repositorio movido a backup"
    fi
    
    # Comentar entradas en crontab
    log_info "Comentando entradas en crontab..."
    
    local temp_cron=$(mktemp)
    crontab -l > "$temp_cron" 2>/dev/null || true
    
    local search_pattern="$REPO_NAME.*gitup.sh"
    
    if grep -q "$search_pattern" "$temp_cron" 2>/dev/null; then
        sed -i "/$search_pattern/s/^[^#]/# UNINSTALLED: &/" "$temp_cron"
        crontab "$temp_cron"
        log_success "Entradas de crontab comentadas"
    else
        log_info "No se encontraron entradas en crontab para $REPO_NAME"
    fi
    
    rm -f "$temp_cron"
    
    echo ""
    log_warn "La llave SSH y configuración SSH no se han eliminado."
    log_info "Si desea eliminarlos manualmente:"
    echo "  - Llave SSH: ~/.ssh/$KEY_NAME"
    echo "  - Config SSH: Editar ~/.ssh/config"
    echo ""
    
    log_success "Desinstalación completada"
}

################################################################################
# RESUMEN FINAL
################################################################################

show_summary() {
    local repo_path="$INSTALL_DIR/$REPO_NAME"
    local script_basename="${TARGET_SCRIPT%.*}"
    local log_file="$LOG_DIR/${script_basename}.log"
    
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                        INSTALACIÓN COMPLETADA                                ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${BOLD}Resumen:${NC}"
    echo -e "  Repositorio:    ${CYAN}$repo_path${NC}"
    echo -e "  Script Wrapper: ${CYAN}$repo_path/gitup.sh${NC}"
    echo -e "  Script Target:  ${CYAN}$repo_path/$TARGET_SCRIPT${NC}"
    echo -e "  Llave SSH:      ${CYAN}$HOME/.ssh/$KEY_NAME${NC}"
    echo -e "  Log File:       ${CYAN}$log_file${NC}"
    echo -e "  Programación:   ${CYAN}$CRON_SCHEDULE${NC}"
    echo ""
    
    echo -e "${BOLD}Comandos útiles:${NC}"
    echo -e "  Ver crontab:    ${BLUE}crontab -l${NC}"
    echo -e "  Ver logs:       ${BLUE}tail -f $log_file${NC}"
    echo -e "  Ejecutar ahora: ${BLUE}$repo_path/gitup.sh ./$TARGET_SCRIPT${NC}"
    echo ""
    
    echo -e "${BOLD}Para desinstalar:${NC}"
    echo -e "  ${BLUE}sudo ./gitinstall.sh --uninstall --repo-name $REPO_NAME${NC}"
    echo ""
}

################################################################################
# MAIN
################################################################################

main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                    GIT REPOSITORY INSTALLER v1.0                             ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    parse_arguments "$@"
    
    # Verificar root
    if [ "$(id -u)" -ne 0 ]; then
        log_warn "Este script normalmente requiere privilegios root para instalar en $DEFAULT_INSTALL_DIR"
        log_warn "Si falla, ejecute con sudo"
    fi
    
    if $UNINSTALL; then
        validate_uninstall_arguments
        do_uninstall
    else
        validate_install_arguments
        setup_ssh_key
        update_ssh_config
        clone_repository
        collect_target_params
        setup_crontab
        show_summary
    fi
}

# Ejecutar
main "$@"
