# AGENTS.md - User Manager Codebase Guide

## Project Overview

This is a Bash-based **User and System Manager** for Ubuntu/Debian systems. It provides comprehensive user management, quota management, backup/restore, firewall control, DNS management, symlink management, job statistics, reporting, password rotation, and Miniforge auto-installation.

**Key Technologies:**
- Bash (target: Ubuntu/Debian)
- Modular architecture with sourced libraries
- ShellCheck for static analysis
- JSON for configuration (jq required)

---

## Build/Lint/Test Commands

### Linting

```bash
# Lint all scripts
shellcheck -x *.sh lib/*.sh

# Lint a single file
shellcheck -x user_manager.sh
shellcheck -x lib/user_core.sh
```

**Note:** Always use `-x` flag to follow external sources.

### Running

```bash
# Run main program (interactive menu)
bash run.sh
# or
bash user_manager.sh

# Run standalone scripts
bash regenerate_password_pool.sh
```

### Testing

**No automated tests exist.** Manual testing workflow:

1. Create test user with Miniforge installation
2. Verify conda command availability: `conda --version`
3. Test network information display
4. Test user deletion with Miniforge cleanup
5. Check logs in `data/created_users.txt`

---

## Code Style Guidelines

### 1. File Structure

Every script must start with:

```bash
#!/bin/bash
# filename.sh - Brief description v1.0.0
# Detailed description if needed
# Requirements: dependencies, OS requirements

set -uo pipefail  # or set -euo pipefail for stricter error handling

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

**Rationale:** Ensures script portability and early error detection.

### 2. Imports and Module Loading

Load libraries in order of dependency:

```bash
# Core utilities first
source "$LIB_DIR/common.sh"
source "$LIB_DIR/config.sh"
source "$LIB_DIR/privilege.sh"

# Then feature modules
source "$LIB_DIR/user_core.sh"
source "$LIB_DIR/quota_core.sh"
# ... etc
```

**Always add shellcheck directive:**
```bash
# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"
```

### 3. Function Definition

**Naming:** Use `snake_case` for functions and variables.

**Format:**
```bash
# ============================================================
# Function Name - Brief description
# ============================================================
# Parameters:
#   $1 - parameter_name: description
#   $2 - parameter_name: description (optional)
# Returns:
#   0 on success, 1 on failure
# ============================================================
function_name() {
    local param1="$1"
    local param2="${2:-default_value}"
    
    # Validate inputs
    [[ -z "$param1" ]] && { msg_err "param1 is required"; return 1; }
    
    # Function logic
    # ...
    
    return 0
}
```

**Best Practices:**
- Always use `local` for function-scoped variables
- Validate inputs at the start
- Use meaningful return codes
- Add comment block above each function

### 4. Variable Naming

- **Constants:** UPPER_CASE (e.g., `SCRIPT_DIR`, `DATA_BASE`)
- **Local variables:** snake_case (e.g., `user_home`, `quota_bytes`)
- **Global variables:** Avoid when possible; document if necessary
- **Arrays:** plural noun (e.g., `all_managed_users`, `missing_deps`)

```bash
# Good
local user_home="/home/user"
local all_managed_users=()

# Avoid
local UserHome="..."
local arr=()
```

### 5. Error Handling

**Use `||` for error handling:**
```bash
# Good
priv_useradd -d "$home" -s /bin/bash -m "$username" || return 1

# Avoid
priv_useradd -d "$home" -s /bin/bash -m "$username"
if [[ $? -ne 0 ]]; then
    return 1
fi
```

**Error messages:**
```bash
# Use msg_err for errors
msg_err "Failed to create user: $username"

# Use msg_err_ctx for contextual errors
msg_err_ctx "create_user" "Invalid username: $username"

# Use msg_warn for warnings
msg_warn "User already exists: $username"
```

### 6. Message Functions

Always use built-in message functions (defined in `lib/common.sh`):

```bash
msg_info "Processing user: $username"     # Informational
msg_ok "User created successfully"        # Success
msg_warn "User already exists"            # Warning
msg_err "Failed to create user"           # Error
msg_step "Creating user..."               # Progress step
msg_debug "Variable value: $var"          # Debug (requires DEBUG=1)
```

**Never use `echo` directly for user messages.**

### 7. User Input

Use standardized input functions:

```bash
# Text input
read_input "Enter username"; local username="$REPLY_INPUT"

# Confirmation
if confirm_action "Delete user $username?"; then
    # ...
fi

# Username with validation
read_username "Enter username" || return 1
local username="$REPLY_INPUT"

# Existing username
read_existing_username "Enter user to delete" || return 1
local username="$REPLY_INPUT"
```

### 8. Privilege Management

**Never use `sudo` directly.** Use wrapper functions from `lib/privilege.sh`:

```bash
# Good
priv_useradd -d "$home" "$username"
priv_chown -R "$username:$username" "$home"

# Avoid
sudo useradd -d "$home" "$username"
sudo chown -R "$username:$username" "$home"
```

**Rationale:** Automatically handles root detection and sudo availability.

### 9. Locking and Concurrency

Use file locks for critical sections:

```bash
acquire_lock || return 1
# ... critical code ...
release_lock
```

**Always release lock before returning.**

### 10. UI Components

Use built-in UI functions:

```bash
draw_header "Section Title"
draw_info_card "Label:" "value" "$C_BGREEN"
draw_line 80
draw_menu_item 1 "Option label"
draw_menu_submenu 2 "Submenu label"
draw_menu_exit "Exit"
draw_prompt
```

### 11. ShellCheck Directives

Suppress warnings when necessary:

```bash
# Disable for unused variables (often configuration constants)
# shellcheck disable=SC2034
DATA_BASE="/mnt"

# Disable for external source files
# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"
```

**Never disable warnings globally.** Use inline directives.

---

## Project Structure

```
/home/crl/code/user/
├── user_manager.sh           # Main program (menu-driven)
├── run.sh                     # Entry point wrapper
├── regenerate_password_pool.sh # Password pool generator
├── Miniforge.sh              # Miniforge installer (~100MB)
├── lib/
│   ├── common.sh             # Core utilities (messages, UI, validation)
│   ├── config.sh             # Configuration constants
│   ├── privilege.sh          # Permission management
│   ├── user_core.sh          # User CRUD operations
│   ├── quota_core.sh         # Quota management
│   ├── resource_core.sh      # CPU/memory limits
│   ├── backup_core.sh        # Backup/restore
│   ├── firewall_core.sh      # UFW management
│   ├── dns_core.sh           # DNS restrictions
│   ├── symlink_core.sh       # Symlink management
│   ├── report_core.sh        # Reporting and statistics
│   ├── system_core.sh        # System maintenance
│   └── miniforge_core.sh     # Miniforge installation
├── data/
│   ├── user_config.json      # User configuration
│   ├── email_config.json     # Email settings
│   ├── condarc.template      # Conda config template
│   ├── password_pool.txt     # Password pool
│   └── created_users.txt     # Operation log
├── logs/                      # Log files
└── README.md                  # User documentation
```

---

## Best Practices

### Security

- **Input validation:** Always validate user input
- **Path safety:** Use quotes around variables to prevent word splitting
- **Privilege separation:** Use `priv_*` functions for privileged operations
- **Temporary files:** Use `mktemp` and `trap` for cleanup

```bash
local temp_file
temp_file=$(mktemp)
trap "rm -f '$temp_file'" EXIT
```

### Performance

- **Avoid subshells:** Use `[[ ]]` instead of `[ ]` for tests
- **Use built-ins:** Prefer `${var%/*}` over `dirname "$var"`
- **Minimize external commands:** Bash parameter expansion is faster

### Maintainability

- **Single responsibility:** Each function should do one thing
- **DRY:** Extract common patterns into functions
- **Comments:** Document complex logic, but write self-documenting code
- **Consistency:** Follow existing patterns in the codebase

---

## Common Patterns

### User Creation Pattern

```bash
create_user() {
    local username="$1"
    local password="$2"
    local home="$3"
    local install_miniforge="${4:-false}"
    
    # Create user
    priv_useradd -d "$home" -s /bin/bash -m "$username" || return 1
    echo "$username:$password" | priv_chpasswd || return 1
    
    # Optional features
    if [[ "$install_miniforge" == "true" ]]; then
        install_miniforge_for_user "$username" || {
            msg_warn "Miniforge installation failed"
        }
    fi
    
    # Log event
    record_user_event "$username" "create" "User"
    
    return 0
}
```

### Error Handling Pattern

```bash
acquire_lock || return 1

if ! some_command; then
    msg_err "Operation failed"
    release_lock
    return 1
fi

release_lock
return 0
```

### Configuration Pattern

```bash
# In lib/config.sh
readonly DATA_BASE="/mnt"
readonly QUOTA_DEFAULT=$((500 * 1024**3))

# In consuming code
local quota_bytes="${QUOTA_DEFAULT}"
```

---

## Dependencies

**Required:**
- Bash 4.0+
- jq (for JSON configuration)
- Standard Unix utilities: awk, sed, grep, id, useradd, usermod, etc.

**Optional:**
- rsnapshot (for backup functionality)
- ufw (for firewall management)
- msmtp/sendmail (for email notifications)
- htop (for monitoring)
- tailscale (for VPN IP detection)

---

## Important Notes for Agents

1. **Always test with `shellcheck`** before considering code complete
2. **Follow existing patterns** - consistency over novelty
3. **Use message functions** - never `echo` for user output
4. **Validate inputs** - fail fast with clear errors
5. **Handle locks properly** - always release locks before returning
6. **Log important events** - use `record_user_event()`
7. **Document complex logic** - but prefer self-documenting code
8. **Test manually** - no automated tests exist

---

## Quick Reference

```bash
# Lint all code
shellcheck -x *.sh lib/*.sh

# Run main program
bash run.sh

# Create user with Miniforge
# (Interactive menu option 1, then confirm Miniforge installation)

# View network info
# (System maintenance menu option 4)

# Check logs
cat data/created_users.txt
```
