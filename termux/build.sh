#!/bin/bash
# build.sh — Termux package build script for webser
# Usage: cd termux && ./build.sh

set -e

# ===== Package Metadata =====
TERMUX_PKG_HOMEPAGE="https://github.com/cyansire/webser"
TERMUX_PKG_DESCRIPTION="Local web server manager for Termux — multi-backend, multi-server, developer-friendly"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@cyansire"
TERMUX_PKG_VERSION="1.1.0"
TERMUX_PKG_REVISION=1
TERMUX_PKG_DEPENDS="bash"
TERMUX_PKG_SKIP_SRC_EXTRACT=true
TERMUX_PKG_PLATFORM_INDEPENDENT=true

# ===== Directories =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
PREFIX="/data/data/com.termux/files/usr"

# Cleanup on exit
trap 'rm -rf "$BUILD_DIR"' EXIT

# ===== Main Install Function =====
termux_step_make_install() {
    local src="${PROJECT_ROOT}/webser.sh"

    # Verify webser.sh exists
    if [ ! -f "$src" ]; then
        echo "Error: webser.sh not found at $src"
        echo "Make sure you're running this from the termux/ directory"
        exit 1
    fi

    # Create DEBIAN directory
    mkdir -p "${BUILD_DIR}/DEBIAN"

    # ===== Generate control file =====
    cat > "${BUILD_DIR}/DEBIAN/control" <<EOF
Package: webser
Version: ${TERMUX_PKG_VERSION}-${TERMUX_PKG_REVISION}
Section: utils
Priority: optional
Architecture: all
Depends: ${TERMUX_PKG_DEPENDS}
Maintainer: ${TERMUX_PKG_MAINTAINER}
Homepage: ${TERMUX_PKG_HOMEPAGE}
License: ${TERMUX_PKG_LICENSE}
Description: ${TERMUX_PKG_DESCRIPTION}
EOF

    # ===== Generate postinst =====
    cat > "${BUILD_DIR}/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e
echo ""
echo "webser installed successfully!"
echo ""
echo "  Quick start:"
echo "    webstart 8080        serve current directory on port 8080"
echo "    weblist              see all running servers"
echo "    webhelp              full command reference"
echo ""
echo "  Recommended backends:"
echo "    pkg install python   (auto-selected, priority 1)"
echo "    pkg install busybox  (fallback, priority 3)"
echo ""
EOF
    chmod 755 "${BUILD_DIR}/DEBIAN/postinst"

    # ===== Generate prerm =====
    cat > "${BUILD_DIR}/DEBIAN/prerm" <<'EOF'
#!/bin/bash
set -e

# Remove runtime state and logs created by webser
rm -rf "$HOME/.config/webserver" 2>/dev/null || true
rm -rf "$HOME/.local/share/webserver" 2>/dev/null || true
rm -rf "$HOME/.local/share/webser" 2>/dev/null || true
EOF
    chmod 755 "${BUILD_DIR}/DEBIAN/prerm"

    # ===== Install the script =====
    mkdir -p "${BUILD_DIR}/${PREFIX}/bin"
    install -Dm 755 "$src" "${BUILD_DIR}/${PREFIX}/bin/webser"

    # ===== Create symlinks =====
    for cmd in webstart webmulti webstop weblist webstatus \
               webshow webhide weblogs webclearlogs \
               webclear webhelp webver; do
        ln -sf "${PREFIX}/bin/webser" "${BUILD_DIR}/${PREFIX}/bin/${cmd}"
    done

    # ===== Install README =====
    mkdir -p "${BUILD_DIR}/${PREFIX}/share/doc/webser"
    install -Dm 644 "${PROJECT_ROOT}/README.md" \
        "${BUILD_DIR}/${PREFIX}/share/doc/webser/README.md"

    echo "Package contents prepared"
}

# ===== Build the .deb =====
termux_step_make_install

echo "Building .deb package..."
dpkg-deb --build "${BUILD_DIR}" "${SCRIPT_DIR}/webser.deb"

echo ""
echo "Package built: ${SCRIPT_DIR}/webser.deb"
echo ""
echo "Install with:"
echo "   apt install ./webser.deb"
echo ""
echo "Or install from source:"
echo "   cd .. && bash install.sh"