# Sourced by bin/*. The same layout works from the git checkout and from an install
# ($PREFIX/share/apt-layer, with $PREFIX/bin/* symlinked to its bin/).

_self=$(readlink -f "$0")
TREE=$(cd "$(dirname "$_self")/.." && pwd)
QS_CFG="$TREE/quickshell"
SHIM_SO="$TREE/lib/libqs-webengine-shim.so"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/apt-layer/config"

die() { echo "apt-layer: $*" >&2; command -v notify-send >/dev/null && notify-send "apt-layer" "$*" 2>/dev/null; exit 1; }

# conf KEY DEFAULT: $APT_LAYER_<KEY>, else KEY=value from the config file, else DEFAULT.
conf() {
    eval "_v=\${APT_LAYER_$1:-}"
    if [ -z "$_v" ] && [ -f "$CONFIG_FILE" ]; then
        _v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONFIG_FILE" | tail -n1 |
            sed 's/[[:space:]]*$//; s/^"\(.*\)"$/\1/')
    fi
    printf '%s' "${_v:-$2}"
}

# niri lookups (lib/niri-query.py; prints nothing without niri).
poe_output()     { python3 "$TREE/lib/niri-query.py" poe-output 2>/dev/null || true; }
focused_output() { python3 "$TREE/lib/niri-query.py" focused-output 2>/dev/null || true; }
output_geometry() { python3 "$TREE/lib/niri-query.py" geometry "$1" 2>/dev/null || true; }

# OUTPUT=auto (default): PoE's output, else the focused output.
resolve_output() {
    _o=$(conf OUTPUT auto)
    if [ "$_o" = auto ]; then
        _o=$(poe_output)
        [ -n "$_o" ] || _o=$(focused_output)
    fi
    printf '%s' "$_o"
}

# APT's UI URL from its listening socket (random port per run).
apt_url() {
    _p=$(ss -ltnpH 2>/dev/null | grep -i 'awakened' | grep -oE ':[0-9]+ ' | head -n1 | tr -d ': ')
    [ -n "$_p" ] && printf 'http://localhost:%s/index.html' "$_p"
}

# APT executable to start (lib/ctl.py find-apt: setting, AppImage managers' menu entries and folders, PATH).
find_apt() { python3 "$TREE/lib/ctl.py" find-apt 2>/dev/null || true; }

# none | ok (APT runs with --no-overlay) | wrong (started by something else, e.g. an AppImage manager's entry)
apt_state() { python3 "$TREE/lib/ctl.py" apt-state 2>/dev/null || echo none; }

overlay_running() { qs -p "$QS_CFG" ipc call overlay status >/dev/null 2>&1; }

# We're often started from inside APT (via the xdg-open shim): drop its AppImage / X11 environment.
clean_env() {
    PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vE '^/tmp/\.mount_|/xdg-open-shim/?$' | paste -sd: -)
    unset APPDIR APPIMAGE ARGV0 OWD LD_LIBRARY_PATH QS_APP_ID   # QS_APP_ID: e.g. a desktop shell's own
    export PATH XDG_SESSION_TYPE=wayland QT_QPA_PLATFORM=wayland
}

# The preload shim is built by `make`; from a checkout, build it on first use.
ensure_shim() {
    [ -f "$SHIM_SO" ] && return 0
    [ -f "$TREE/Makefile" ] || die "missing $SHIM_SO (reinstall with make install)"
    make -s -C "$TREE" shim >&2 || die "building the QtWebEngine preload shim failed (see apt-layer doctor)"
}

# spawn_detached NAME CMD...: start CMD outside our own process tree.
# Preferably as a transient service of the systemd user manager (unit NAME-<time>, in app.slice): the process
# is then a child of systemd, not of whoever ran us - so it doesn't inherit per-app rules matched on the parent
# process (the terminal or app it was started from), nor the caller's cgroup. KillMode=process: anything it starts (a browser opened from a link) survives it.
# Falls back to setsid. APT_LAYER_NO_SYSTEMD=1 forces the fallback.
spawn_detached() {
    _name=$1; shift
    if [ -z "${APT_LAYER_NO_SYSTEMD:-}" ] && command -v systemd-run >/dev/null 2>&1 &&
        systemctl --user show-environment >/dev/null 2>&1; then
        _envs=""
        for _v in PATH DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP NIRI_SOCKET QT_QPA_PLATFORM \
            QT_QUICK_CONTROLS_STYLE QT_QPA_PLATFORMTHEME LD_PRELOAD $(env | sed -n 's/^\(APT_LAYER_[A-Z_]*\)=.*/\1/p'); do
            eval "_isset=\${$_v+x}"
            [ -n "$_isset" ] && _envs="$_envs --setenv=$_v"
        done
        # shellcheck disable=SC2086  # $_envs is a list of --setenv=NAME words
        if systemd-run --user --quiet --collect --no-block --slice=app.slice \
            --unit="$_name-$(date +%s%N | cut -c1-13)" -p KillMode=process $_envs -- "$@"; then
            return 0
        fi
    fi
    setsid -f "$@" >/dev/null 2>&1 </dev/null
}
