#!/bin/bash

# ═══════════════════════════════════════════════════════════════
#   ARIX THEME INSTALLER  —  by BytexDev (dsc.gg/bytexdev)
# ═══════════════════════════════════════════════════════════════

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────
ok()   { echo -e "  ${GREEN}✓${RESET}  $1"; }
fail() { echo -e "  ${RED}✗${RESET}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
info() { echo -e "  ${CYAN}ℹ${RESET}  $1"; }
step() { echo -e "\n  ${PURPLE}${BOLD}$1${RESET}\n"; }
line() { echo -e "  ${DIM}────────────────────────────────────────────${RESET}"; }

# ── Check running as root ────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo ""
    fail "This script must be run as root."
    echo ""
    echo -e "  Run:  ${BOLD}sudo bash install.sh${RESET}"
    echo ""
    exit 1
fi

# ── Log everything to file ───────────────────────────────────────
LOG_FILE="/var/log/arix_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Cleanup on unexpected failure ────────────────────────────────
# EXTRACT_TMP is set later in extract_arix(); trap reads it at exit time.
EXTRACT_TMP=""
_cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        warn "Script exited with error (code $exit_code). Running cleanup..."
        # Remove any half-extracted temp files
        [ -n "$EXTRACT_TMP" ] && [ -d "$EXTRACT_TMP" ] && rm -rf "$EXTRACT_TMP" && info "Removed temp dir: $EXTRACT_TMP"
        # Bring panel back up if it was put in maintenance during install/uninstall
        if [ -n "$PANEL_DIR" ] && [ -f "$PANEL_DIR/artisan" ]; then
            php artisan up --quiet 2>/dev/null && info "Panel maintenance mode lifted."
        fi
        echo ""
        fail "Arix install did NOT complete cleanly. Check log: $LOG_FILE"
    fi
}
trap '_cleanup' EXIT ERR

# ── Detect panel path ────────────────────────────────────────────
PANEL_DIR=""
for path in "/var/www/pterodactyl" "/var/www/html/pterodactyl" "/var/www/panel"; do
    if [ -f "$path/artisan" ]; then
        PANEL_DIR="$path"
        break
    fi
done

# If script is run from inside the panel folder itself
if [ -z "$PANEL_DIR" ] && [ -f "$(pwd)/artisan" ]; then
    PANEL_DIR="$(pwd)"
fi

# ── Banner ───────────────────────────────────────────────────────
clear
echo ""
info "Full log being saved to: $LOG_FILE"
echo ""
echo -e "${PURPLE}${BOLD}"
echo "        ░█████╗░██████╗░██╗██╗░░██╗"
echo "        ██╔══██╗██╔══██╗██║╚██╗██╔╝"
echo "        ███████║██████╔╝██║░╚███╔╝░"
echo "        ██╔══██║██╔══██╗██║░██╔██╗░"
echo "        ██║░░██║██║░░██║██║██╔╝╚██╗"
echo "        ╚═╝░░╚═╝╚═╝░░╚═╝╚═╝╚═╝░░╚═╝"
echo -e "${RESET}"
echo -e "        ${DIM}Pterodactyl Theme Installer  •  BytexDev${RESET}"
echo ""
line
echo ""

# ── Panel path confirm / ask ─────────────────────────────────────
if [ -n "$PANEL_DIR" ]; then
    ok "Panel detected at: ${BOLD}$PANEL_DIR${RESET}"
else
    warn "Could not auto-detect panel directory."
    echo ""
    echo -ne "  ${BOLD}Enter panel path${RESET} [default: /var/www/pterodactyl]: "
    read -r USER_PATH
    PANEL_DIR="${USER_PATH:-/var/www/pterodactyl}"
    if [ ! -f "$PANEL_DIR/artisan" ]; then
        fail "artisan not found in: $PANEL_DIR"
        echo ""
        echo "  Make sure you are pointing to the correct Pterodactyl folder."
        exit 1
    fi
    ok "Panel path set: ${BOLD}$PANEL_DIR${RESET}"
fi

echo ""
line

# ════════════════════════════════════════════════════════════════
#   MAIN MENU
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}What do you want to do?${RESET}"
echo ""
echo -e "  ${CYAN}[1]${RESET}  Install Arix Theme"
echo -e "  ${CYAN}[2]${RESET}  Uninstall Arix  ${DIM}(restore default Pterodactyl)${RESET}"
echo -e "  ${CYAN}[3]${RESET}  Backup Panel"
echo -e "  ${CYAN}[0]${RESET}  Exit"
echo ""
echo -ne "  ${BOLD}Select option:${RESET} "
read -r CHOICE
echo ""

case "$CHOICE" in
    1) ACTION="install" ;;
    2) ACTION="uninstall" ;;
    3) ACTION="backup" ;;
    0) echo "  Exiting."; echo ""; exit 0 ;;
    *) fail "Invalid option."; echo ""; exit 1 ;;
esac

# ════════════════════════════════════════════════════════════════
#   FUNCTIONS
# ════════════════════════════════════════════════════════════════

# ── Check & install system dependencies ─────────────────────────
check_dependencies() {
    step "[STEP 1/6]  Checking dependencies..."

    MISSING_APT=()
    MISSING_NPM=()

    # rsync
    if command -v rsync &>/dev/null; then
        ok "rsync: $(rsync --version | head -1 | awk '{print $3}')"
    else
        fail "rsync: Not found"
        MISSING_APT+=("rsync")
    fi

    # curl
    if command -v curl &>/dev/null; then
        ok "curl: $(curl --version | head -1 | awk '{print $2}')"
    else
        fail "curl: Not found"
        MISSING_APT+=("curl")
    fi

    # unzip
    if command -v unzip &>/dev/null; then
        ok "unzip: found"
    else
        fail "unzip: Not found"
        MISSING_APT+=("unzip")
    fi

    # PHP
    if command -v php &>/dev/null; then
        PHP_VER=$(php -r "echo PHP_VERSION;")
        PHP_MAJOR=$(php -r "echo PHP_MAJOR_VERSION;")
        if [ "$PHP_MAJOR" -ge 8 ]; then
            ok "PHP: $PHP_VER  ✓ (8.0+ required)"
        else
            fail "PHP: $PHP_VER  ✗ (8.0+ required)"
            MISSING_APT+=("php8.1")
        fi
    else
        fail "PHP: Not found"
        MISSING_APT+=("php8.1")
    fi

    # Composer
    if command -v composer &>/dev/null; then
        COMP_VER=$(composer --version 2>/dev/null | awk '{print $3}')
        ok "Composer: $COMP_VER"
    else
        fail "Composer: Not found"
        MISSING_APT+=("composer")
    fi

    # Node.js
    if command -v node &>/dev/null; then
        NODE_VER=$(node -v)
        NODE_MAJOR=$(node -v | sed 's/v//' | cut -d. -f1)
        if [ "$NODE_MAJOR" -ge 16 ]; then
            ok "Node.js: $NODE_VER  ✓"
        else
            fail "Node.js: $NODE_VER  ✗ (16+ required)"
            MISSING_NPM+=("node")
        fi
    else
        fail "Node.js: Not found"
        MISSING_NPM+=("node")
    fi

    # Yarn
    if command -v yarn &>/dev/null; then
        YARN_VER=$(yarn --version 2>/dev/null)
        ok "Yarn: $YARN_VER"
    else
        fail "Yarn: Not found  (will install via npm)"
        MISSING_NPM+=("yarn")
    fi

    # Disk space (500MB min)
    FREE_KB=$(df --output=avail "$PANEL_DIR" 2>/dev/null | tail -1)
    FREE_MB=$((FREE_KB / 1024))
    if [ "$FREE_MB" -ge 500 ]; then
        ok "Disk space: ${FREE_MB}MB free  ✓"
    else
        warn "Disk space: ${FREE_MB}MB free  ⚠ (500MB+ recommended)"
    fi

    # ── Auto install missing apt packages ────────────────────
    if [ ${#MISSING_APT[@]} -gt 0 ]; then
        echo ""
        warn "Missing packages: ${MISSING_APT[*]}"
        info "Auto-installing via apt..."
        echo ""
        apt-get update -qq
        for pkg in "${MISSING_APT[@]}"; do
            echo -ne "  Installing ${pkg}... "
            apt-get install -y -qq "$pkg" &>/dev/null && echo -e "${GREEN}done${RESET}" || echo -e "${RED}FAILED${RESET}"
        done
    fi

    # ── Auto install Node / Yarn ──────────────────────────────
    if [[ " ${MISSING_NPM[*]} " == *"node"* ]]; then
        echo ""
        info "Installing Node.js 18 via NodeSource..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash - &>/dev/null
        apt-get install -y nodejs &>/dev/null && ok "Node.js installed" || fail "Node.js install failed"
    fi

    if [[ " ${MISSING_NPM[*]} " == *"yarn"* ]]; then
        info "Installing Yarn..."
        npm install -g yarn &>/dev/null && ok "Yarn installed" || fail "Yarn install failed"
    fi

    echo ""
    ok "Dependency check complete."
}

# ── Extract Arix ZIP ──────────────────────────────────────────────
extract_arix() {
    step "[STEP 2/6]  Extracting Arix theme files..."

    # Look for the ZIP in script's directory or panel directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ZIP_FILE=""

    # FIX: Added parentheses around -o conditions to prevent operator precedence bug
    for search_dir in "$SCRIPT_DIR" "$PANEL_DIR" "$(pwd)"; do
        found=$(find "$search_dir" -maxdepth 1 \( -name "arix_*.zip" -o -name "arix*.zip" \) 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            ZIP_FILE="$found"
            break
        fi
    done

    if [ -z "$ZIP_FILE" ]; then
        fail "No Arix ZIP file found. Place arix_*.zip next to install.sh"
        exit 1
    fi

    ok "Found ZIP: $ZIP_FILE"
    info "Extracting..."

    EXTRACT_TMP="/tmp/arix_extract_$$"
    mkdir -p "$EXTRACT_TMP"
    unzip -q "$ZIP_FILE" -d "$EXTRACT_TMP"

    # Find the v1.2 folder inside extracted content
    ARIX_SOURCE=$(find "$EXTRACT_TMP" -type d -name "v1.2" | head -1)
    if [ -z "$ARIX_SOURCE" ]; then
        # fallback: find arix folder
        ARIX_PARENT=$(find "$EXTRACT_TMP" -maxdepth 4 -type d -name "arix" | head -1)
        # FIX: Only build path if ARIX_PARENT was found, prevents bad path like "/v1.2"
        if [ -n "$ARIX_PARENT" ]; then
            ARIX_SOURCE="$ARIX_PARENT/v1.2"
        fi
    fi

    if [ -z "$ARIX_SOURCE" ] || [ ! -d "$ARIX_SOURCE" ]; then
        fail "Could not find theme folder inside ZIP."
        rm -rf "$EXTRACT_TMP"
        exit 1
    fi

    ok "Theme folder found: $ARIX_SOURCE"

    # Copy arix folder to panel (for artisan command)
    mkdir -p "$PANEL_DIR/arix"
    cp -r "$ARIX_SOURCE" "$PANEL_DIR/arix/"
    ok "Copied to $PANEL_DIR/arix/"

    # Copy Arix.php artisan command
    ARIX_CMD=$(find "$EXTRACT_TMP" -name "Arix.php" -path "*/Commands/*" | head -1)
    if [ -n "$ARIX_CMD" ]; then
        mkdir -p "$PANEL_DIR/app/Console/Commands"
        cp "$ARIX_CMD" "$PANEL_DIR/app/Console/Commands/Arix.php"
        ok "Arix artisan command installed"
    fi

    rm -rf "$EXTRACT_TMP"
}

# ── Install npm packages ──────────────────────────────────────────
install_npm_packages() {
    step "[STEP 3/6]  Installing npm packages..."

    cd "$PANEL_DIR" || exit 1

    # Node version check for openssl legacy
    NODE_MAJOR=$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1)
    if [ "$NODE_MAJOR" -ge 17 ]; then
        export NODE_OPTIONS="--openssl-legacy-provider"
        info "Node $NODE_MAJOR detected — using --openssl-legacy-provider"
    fi

    info "This may take 1–3 minutes..."

    # Install Arix required packages
    # FIX: Added path-browserify for webpack 5 Node.js core module polyfill (fixes "path module missing" build error)
    # FIX: Pin bbcode-to-react to 1.x (2.x breaks the default export used in Alert.tsx)
    # FIX: Pin react-icons to 4.x for compatibility with this webpack/React setup
    yarn add \
        @types/md5 \
        md5 \
        react-icons@4.12.0 \
        @types/bbcode-to-react \
        bbcode-to-react@1.1.4 \
        i18next-browser-languagedetector@7.2.1 \
        path-browserify

    echo ""
    ok "npm packages installed."
}

# ── Copy theme files to panel ─────────────────────────────────────
copy_theme_files() {
    step "[STEP 4/6]  Copying theme files to panel..."

    cd "$PANEL_DIR" || exit 1

    ARIX_VERSION_DIR="$PANEL_DIR/arix/v1.2"
    if [ ! -d "$ARIX_VERSION_DIR" ]; then
        fail "Theme files not found at $ARIX_VERSION_DIR"
        exit 1
    fi

    rsync -a "$ARIX_VERSION_DIR/" "$PANEL_DIR/"
    ok "Theme files copied"

    # Ensure Admin Arix controller directory exists
    mkdir -p "$PANEL_DIR/app/Http/Controllers/Admin/Arix"
    ok "Controller directory ready"

    # Run migrations
    info "Running database migrations..."
    php artisan migrate --force
    ok "Database migrated"
}

# ── Build assets ──────────────────────────────────────────────────
build_assets() {
    step "[STEP 5/6]  Building panel assets..."

    cd "$PANEL_DIR" || exit 1

    NODE_MAJOR=$(node -v 2>/dev/null | sed 's/v//' | cut -d. -f1)
    if [ "$NODE_MAJOR" -ge 17 ]; then
        export NODE_OPTIONS="--openssl-legacy-provider"
    fi

    # FIX: Patch webpack.mix.js to add path polyfill for webpack 5
    # This fixes: "BREAKING CHANGE: webpack < 5 used to include polyfills for node.js core modules"
    WEBPACK_MIX="$PANEL_DIR/webpack.mix.js"
    if [ -f "$WEBPACK_MIX" ] && ! grep -q "path-browserify" "$WEBPACK_MIX"; then
        python3 - "$WEBPACK_MIX" <<'WPEOF'
import sys
path = sys.argv[1]
content = open(path).read()
polyfill_block = """
mix.webpackConfig({
    resolve: {
        fallback: {
            path: require.resolve("path-browserify"),
            fs: false,
            os: false,
        },
    },
});
"""
# Only add if not already present
if "path-browserify" not in content:
    content = content.rstrip() + "\n" + polyfill_block + "\n"
    open(path, "w").write(content)
    print("  ✓  webpack.mix.js patched with path polyfill")
else:
    print("  ✓  webpack.mix.js already has path polyfill")
WPEOF
    fi

    info "Building... this may take 2–5 minutes."
    yarn build:production

    BUILD_EXIT=$?
    if [ $BUILD_EXIT -ne 0 ]; then
        fail "yarn build:production FAILED (exit code $BUILD_EXIT)."
        fail "Frontend was NOT rebuilt — theme will not appear on homepage."
        fail "Check the output above for webpack errors."
        exit 1
    fi

    # FIX: Verify assets were actually written (catches silent build failures)
    if [ ! -f "$PANEL_DIR/public/assets/manifest.json" ] &&        [ -z "$(ls -A "$PANEL_DIR/public/assets/" 2>/dev/null)" ]; then
        warn "Build completed but no assets found in public/assets/"
        warn "Theme may not render correctly. Check webpack output above."
    else
        ok "Build artifacts verified in public/assets/"
    fi

    echo ""
    ok "Assets built successfully."
}

# ── Set permissions ───────────────────────────────────────────────
set_permissions() {
    step "[STEP 6/6]  Setting permissions & optimizing..."

    cd "$PANEL_DIR" || exit 1

    chmod -R 755 storage/* bootstrap/cache
    ok "chmod 755 on storage & bootstrap/cache"

    # chown to correct web user
    for user in www-data nginx apache; do
        if id "$user" &>/dev/null; then
            chown -R "$user:$user" "$PANEL_DIR"
            ok "chown: $user"
            break
        fi
    done

    # Optimize Laravel
    php artisan optimize:clear
    php artisan optimize
    ok "Laravel cache optimized"

    # Register Arix command in Kernel.php if not already
    # FIX: Used Python for safe multi-line sed replacement instead of fragile sed regex
    KERNEL="$PANEL_DIR/app/Console/Kernel.php"
    if [ -f "$KERNEL" ] && ! grep -q "Commands\\\\Arix" "$KERNEL"; then
        python3 - "$KERNEL" <<'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()
entry = '        \\Pterodactyl\\Console\\Commands\\Arix::class,'
updated = re.sub(r'(\$commands\s*=\s*\[)', r'\1\n' + entry, content, count=1)
if updated != content:
    open(path, 'w').write(updated)
    print("  ✓  Arix command registered in Kernel.php")
PYEOF
    fi
}

# ════════════════════════════════════════════════════════════════
#   OPTION 1 — INSTALL
# ════════════════════════════════════════════════════════════════
do_install() {
    echo -e "  ${PURPLE}${BOLD}━━━━━━━━  ARIX THEME INSTALLER  ━━━━━━━━${RESET}"
    echo ""

    check_dependencies
    extract_arix
    install_npm_packages
    copy_theme_files
    build_assets
    set_permissions

    echo ""
    echo -e "  ${PURPLE}${BOLD}╭─────────────────────────────────────────╮${RESET}"
    echo -e "  ${PURPLE}${BOLD}│                                         │${RESET}"
    echo -e "  ${PURPLE}${BOLD}│   ✓  Arix installed successfully!  🎉   │${RESET}"
    echo -e "  ${PURPLE}${BOLD}│                                         │${RESET}"
    echo -e "  ${PURPLE}${BOLD}╰─────────────────────────────────────────╯${RESET}"
    echo ""
    ok "Reload your panel — go to Admin > ${BOLD}/admin/arix${RESET} to configure."
    echo ""
    echo -e "  ${DIM}Discord: dsc.gg/bytexdev${RESET}"
    echo ""
}

# ════════════════════════════════════════════════════════════════
#   OPTION 2 — UNINSTALL
# ════════════════════════════════════════════════════════════════
do_uninstall() {
    echo -e "  ${PURPLE}${BOLD}━━━━━━━━  ARIX UNINSTALLER  ━━━━━━━━${RESET}"
    echo ""
    warn "This will remove Arix and restore default Pterodactyl panel."
    warn "All your Arix customizations will be lost."
    echo ""
    echo -ne "  ${BOLD}Are you sure? (yes/no):${RESET} "
    read -r CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        info "Cancelled."
        echo ""
        exit 0
    fi

    echo ""
    cd "$PANEL_DIR" || exit 1

    step "Putting panel in maintenance mode..."
    php artisan down
    ok "Maintenance mode ON"

    step "Downloading default Pterodactyl panel..."
    PANEL_TGZ="/tmp/pterodactyl_panel_restore_$$.tar.gz"
    PANEL_CHECKSUM_URL="https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz.sha256sum"

    info "Downloading panel archive..."
    if ! curl -fsSL "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" -o "$PANEL_TGZ"; then
        fail "Download failed. Check your internet connection."
        rm -f "$PANEL_TGZ"
        exit 1
    fi
    ok "Download complete: $PANEL_TGZ"

    # Verify checksum if GitHub provides one
    info "Verifying checksum..."
    EXPECTED_SUM=$(curl -fsSL "$PANEL_CHECKSUM_URL" 2>/dev/null | awk '{print $1}')
    if [ -n "$EXPECTED_SUM" ]; then
        ACTUAL_SUM=$(sha256sum "$PANEL_TGZ" | awk '{print $1}')
        if [ "$ACTUAL_SUM" != "$EXPECTED_SUM" ]; then
            fail "Checksum mismatch! Archive may be corrupted or tampered."
            fail "Expected: $EXPECTED_SUM"
            fail "Got:      $ACTUAL_SUM"
            rm -f "$PANEL_TGZ"
            exit 1
        fi
        ok "Checksum verified ✓"
    else
        warn "Checksum file not available — skipping verification."
    fi

    info "Extracting..."
    tar -xzf "$PANEL_TGZ" --overwrite
    rm -f "$PANEL_TGZ"
    ok "Default panel extracted"

    step "Installing composer packages..."
    # FIX: cd already done above, composer runs in correct PANEL_DIR
    composer install --no-dev --optimize-autoloader
    ok "Composer done"

    step "Clearing caches..."
    php artisan view:clear
    php artisan config:clear
    ok "Caches cleared"

    step "Running migrations..."
    # FIX: Removed --seed flag — seed would re-insert default data and can
    #      conflict with existing production users/roles in the database.
    php artisan migrate --force
    ok "Database migrated"

    set_permissions

    step "Bringing panel back online..."
    php artisan queue:restart
    php artisan up
    ok "Panel is back online"

    echo ""
    echo -e "  ${GREEN}${BOLD}╭─────────────────────────────────────────╮${RESET}"
    echo -e "  ${GREEN}${BOLD}│                                         │${RESET}"
    echo -e "  ${GREEN}${BOLD}│   ✓  Arix removed. Panel restored.      │${RESET}"
    echo -e "  ${GREEN}${BOLD}│                                         │${RESET}"
    echo -e "  ${GREEN}${BOLD}╰─────────────────────────────────────────╯${RESET}"
    echo ""
}

# ════════════════════════════════════════════════════════════════
#   OPTION 3 — BACKUP
# ════════════════════════════════════════════════════════════════
do_backup() {
    echo -e "  ${PURPLE}${BOLD}━━━━━━━━  PANEL BACKUP  ━━━━━━━━${RESET}"
    echo ""

    step "Putting panel in maintenance mode..."
    cd "$PANEL_DIR" || exit 1
    php artisan down
    ok "Maintenance mode ON"

    BACKUP_DIR="/var/backups/pterodactyl"
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_FILE="$BACKUP_DIR/panel_backup_$TIMESTAMP.tar.gz"

    mkdir -p "$BACKUP_DIR"
    ok "Backup directory: $BACKUP_DIR"

    info "Creating backup... this may take a minute."
    echo ""

    # Exclude node_modules and vendor to keep backup small
    tar --exclude="$PANEL_DIR/node_modules" \
        --exclude="$PANEL_DIR/vendor" \
        -czf "$BACKUP_FILE" \
        -C "$(dirname "$PANEL_DIR")" \
        "$(basename "$PANEL_DIR")"

    # FIX: Check tar exit code — if backup failed, report it instead of silently continuing
    if [ $? -ne 0 ]; then
        fail "Backup FAILED. Check disk space at $BACKUP_DIR"
        exit 1
    fi

    BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)

    echo ""
    echo -e "  ${GREEN}${BOLD}╭─────────────────────────────────────────╮${RESET}"
    echo -e "  ${GREEN}${BOLD}│                                         │${RESET}"
    echo -e "  ${GREEN}${BOLD}│   ✓  Backup created successfully!       │${RESET}"
    echo -e "  ${GREEN}${BOLD}│                                         │${RESET}"
    echo -e "  ${GREEN}${BOLD}╰─────────────────────────────────────────╯${RESET}"
    echo ""
    ok "File: ${BOLD}$BACKUP_FILE${RESET}"
    ok "Size: ${BOLD}$BACKUP_SIZE${RESET}"
    echo ""
    info "To restore: tar -xzf $BACKUP_FILE -C $(dirname "$PANEL_DIR")"
    echo ""

    step "Bringing panel back online..."
    php artisan up
    ok "Panel is back online"
    echo ""
}

# ════════════════════════════════════════════════════════════════
#   RUN SELECTED ACTION
# ════════════════════════════════════════════════════════════════
case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    backup)    do_backup ;;
esac
