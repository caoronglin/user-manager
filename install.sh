#!/bin/bash
# install.sh - User Manager Installation Script v1.0
# Supports system-wide installation with global command entry

set -uo pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Installation paths
readonly INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
readonly BIN_DIR="$INSTALL_PREFIX/bin"
readonly LIB_DIR="$INSTALL_PREFIX/lib/user-manager"
readonly SHARE_DIR="$INSTALL_PREFIX/share/user-manager"
readonly ETC_DIR="${USER_MANAGER_ETC:-/etc/user-manager}"

# Colors
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_CYAN='\033[0;36m'

# Logging
log_info() { echo -e "${C_GREEN}[INFO]${C_RESET} $*"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_err() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_step() { echo -e "${C_CYAN}[STEP]${C_RESET} $*"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "Root privileges required for system installation"
        log_info "Usage: sudo $0"
        return 1
    fi
    return 0
}

create_directories() {
    log_step "Creating directory structure..."
    
    local dirs=("$LIB_DIR" "$SHARE_DIR" "$SHARE_DIR/templates" "$SHARE_DIR/data" "$ETC_DIR")
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || { log_err "Failed to create directory: $dir"; return 1; }
        fi
    done
    
    log_info "Directory structure created"
    return 0
}

copy_files() {
    log_step "Copying files..."
    
    # Copy library files
    if [[ -d "$SCRIPT_DIR/lib" ]]; then
        cp -r "$SCRIPT_DIR/lib/"* "$LIB_DIR/" || { log_err "Failed to copy library files"; return 1; }
    fi
    
    # Copy main script
    cp "$SCRIPT_DIR/user_manager.sh" "$LIB_DIR/" || { log_err "Failed to copy main script"; return 1; }
    
    # Copy templates and data
    if [[ -d "$SCRIPT_DIR/templates" ]]; then
        cp -r "$SCRIPT_DIR/templates/"* "$SHARE_DIR/templates/" 2>/dev/null || true
    fi
    
    if [[ -d "$SCRIPT_DIR/data" ]]; then
        cp -r "$SCRIPT_DIR/data/"* "$SHARE_DIR/data/" 2>/dev/null || true
    fi
    
    log_info "Files copied successfully"
    return 0
}

create_wrapper() {
    log_step "Creating wrapper script..."
    
    cat > "$BIN_DIR/umgr" << 'EOF'
#!/bin/bash
# umgr - User Manager Global Entry Point

set -uo pipefail

readonly LIB_DIR="/usr/local/lib/user-manager"
readonly ETC_DIR="/etc/user-manager"

# Load system config
[[ -f "$ETC_DIR/user-manager.conf" ]] && source "$ETC_DIR/user-manager.conf"

show_help() {
    cat << 'HELP'
User Manager - Linux Multi-User System Manager

Usage: umgr [OPTIONS] [COMMAND]

Options:
  -h, --help          Show help message
  -v, --version       Show version
  -i, --interactive   Start interactive TUI (default)

Commands:
  user create <username>     Create user
  user delete <username>     Delete user
  user list                  List users
  user passwd <username>     Change password
  quota show <user>          Show quota
  backup create <user>       Create backup
  system info                System information

Examples:
  umgr                       # Start TUI
  umgr user list             # List users
  umgr quota show alice      # Show user quota

HELP
}

show_version() {
    echo "User Manager v0.2.1"
}

# Parse and execute
main() {
    case "${1:-}" in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            show_version
            exit 0
            ;;
        -i|--interactive|"")
            exec bash "$LIB_DIR/user_manager.sh"
            ;;
        *)
            # Pass to main script with quick mode
            export USER_MANAGER_QUICK_MODE=1
            export USER_MANAGER_QUICK_CMD="$*"
            exec bash "$LIB_DIR/user_manager.sh"
            ;;
    esac
}

main "$@"
EOF
    
    chmod +x "$BIN_DIR/umgr"
    log_info "Wrapper script created: $BIN_DIR/umgr"
    return 0
}

# Main installation
main() {
    echo -e "${C_BOLD}User Manager Installation Script v${VERSION}${C_RESET}"
    echo ""
    
    case "${1:-}" in
        -h|--help)
            echo "Usage: $0 [OPTION]"
            echo ""
            echo "Options:"
            echo "  install     Install to system (default)"
            echo "  -h, --help  Show this help"
            echo ""
            echo "Environment Variables:"
            echo "  INSTALL_PREFIX    Install prefix (default: /usr/local)"
            exit 0
            ;;
    esac
    
    # Check root
    check_root || exit 1
    
    # Create directories
    create_directories || exit 1
    
    # Copy files
    copy_files || exit 1
    
    # Create wrapper
    create_wrapper || exit 1
    
    echo ""
    log_info "Installation completed successfully!"
    echo ""
    echo "Usage:"
    echo "  umgr           # Start interactive TUI"
    echo "  umgr --help    # Show help"
    echo ""
}

main "$@"
