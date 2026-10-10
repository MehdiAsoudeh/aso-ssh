#!/usr/bin/env bash
set -euo pipefail
SSH_HOST=""
SSH_USER=""
SSH_PASS=""
SSH_PORT=""
SSH_KEY=""
SSH_EXTRA_OPTS=""
USER_CONF="${HOME}/Library/Application Support/ASO VPN/vpn.conf"
if [[ -n "${ASO_VPN_CONFIG:-}" && -f "${ASO_VPN_CONFIG}" ]]; then
  CONFIG_FILE="${ASO_VPN_CONFIG}"
elif [[ -f "$USER_CONF" ]]; then
  CONFIG_FILE="$USER_CONF"
else
  CONFIG_FILE=""
fi
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi
[[ -n "${SSH_PORT:-}" ]] || SSH_PORT="22"
case "${TMPDIR:-}" in
  *PKInstallSandbox*|*com.apple.installer*|*InstallAssistant*) unset TMPDIR ;;
esac
RUNTIME_TMP="/tmp"
PID_FILE="${RUNTIME_TMP}/aso-ssh-vpn.pid"
HELPER_DIR="${RUNTIME_TMP}/aso-ssh-vpn-helpers"
STATE_MARKER="${RUNTIME_TMP}/aso-ssh-vpn.mode"
PFCTL_BIN="$(command -v pfctl 2>/dev/null || true)"
[[ -x "$PFCTL_BIN" ]] || PFCTL_BIN="/sbin/pfctl"
KILL_BIN="$(command -v kill 2>/dev/null || true)"
[[ -x "$KILL_BIN" ]] || KILL_BIN="/bin/kill"
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
notify() {
  local title="$1" msg="$2"
  osascript -e "display notification \"${msg}\" with title \"${title}\"" 2>/dev/null || true
}
need_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || { red "macOS only"; exit 1; }
}
check_config() {
  [[ -n "$SSH_HOST" && -n "$SSH_USER" ]] || {
    red "No config yet. Open Config, enter Host/User, then Save."
    echo "STATE=OFF"
    exit 1
  }
}
find_sshuttle() {
  local p
  for p in "$(command -v sshuttle 2>/dev/null || true)" /opt/homebrew/bin/sshuttle /usr/local/bin/sshuttle; do
    [[ -n "$p" && -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}
ensure_sshuttle() {
  local bin
  if bin="$(find_sshuttle)"; then SSHUTTLE_BIN="$bin"; return 0; fi
  yellow "Installing sshuttle via Homebrew..."
  if ! install_deps_for_user "$(id -un)"; then
    red "Could not install sshuttle (Homebrew required: https://brew.sh)"
    echo "STATE=OFF"
    exit 1
  fi
  bin="$(find_sshuttle)" || { red "sshuttle install failed"; echo "STATE=OFF"; exit 1; }
  SSHUTTLE_BIN="$bin"
}
real_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
    return 0
  fi
  local cu
  cu="$(stat -f%Su /dev/console 2>/dev/null || true)"
  if [[ -n "$cu" && "$cu" != "root" ]]; then
    printf '%s\n' "$cu"
    return 0
  fi
  id -un
}
user_home() {
  local user="$1"
  if [[ "$(id -un)" == "$user" && "$(id -u)" -ne 0 ]]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  local home=""
  home="$(sudo -u "$user" -H sh -c 'printf %s "$HOME"' 2>/dev/null || true)"
  [[ -n "$home" ]] && { printf '%s\n' "$home"; return 0; }
  printf '/Users/%s\n' "$user"
}
launch_script_path_for() {
  printf '%s/.aso-vpn/launch-sshuttle.sh\n' "$(user_home "$1")"
}
brew_prefix_for_arch() {
  if [[ "$(uname -m)" == "arm64" ]]; then
    printf '/opt/homebrew\n'
  else
    printf '/usr/local\n'
  fi
}
ensure_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    return 0
  fi
  yellow "Installing Apple Command Line Tools (needed for Homebrew)..."
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  local prod=""
  prod="$(softwareupdate -l 2>/dev/null | awk -F: '/Label:.*Command Line Tools/{gsub(/^ /,"",$2); print $2; exit}')"
  if [[ -z "$prod" ]]; then
    prod="$(softwareupdate -l 2>/dev/null | sed -n 's/^[[:space:]]*\*[[:space:]]*Label:[[:space:]]*//p' | grep -i 'Command Line Tools' | head -n1 || true)"
  fi
  if [[ -n "$prod" ]]; then
    softwareupdate -i "$prod" --agree-to-license || true
  else
    /usr/bin/xcode-select --install 2>/dev/null || true
    sleep 2
  fi
  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  xcode-select -p >/dev/null 2>&1
}
ensure_homebrew_for_user() {
  local user="$1"
  local home brew_prefix brew_bin
  home="$(user_home "$user")"
  brew_prefix="$(brew_prefix_for_arch)"
  brew_bin="${brew_prefix}/bin/brew"
  if [[ -x "$brew_bin" ]]; then
    green "Homebrew: OK (${brew_bin})"
    return 0
  fi
  if sudo -u "$user" -H bash -lc 'command -v brew >/dev/null 2>&1'; then
    green "Homebrew: OK (in PATH)"
    return 0
  fi
  yellow "Homebrew not found — installing automatically for ${user}..."
  ensure_xcode_clt || yellow "CLT check incomplete; continuing Homebrew install..."
  mkdir -p "${brew_prefix}"
  chown -R "${user}:admin" "${brew_prefix}" 2>/dev/null || chown -R "${user}:staff" "${brew_prefix}"
  if [[ "$(uname -m)" != "arm64" ]]; then
    mkdir -p /usr/local/{bin,Cellar,Frameworks,Homebrew,etc,include,lib,opt,sbin,share,var}
    chown -R "${user}:admin" /usr/local/{bin,Cellar,Frameworks,Homebrew,etc,include,lib,opt,sbin,share,var} 2>/dev/null || true
  fi
  local installer="/tmp/aso-homebrew-install.sh"
  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"
  chmod 755 "$installer"
  if ! sudo -u "$user" -H env \
      NONINTERACTIVE=1 \
      CI=1 \
      HOME="$home" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:${brew_prefix}/bin" \
      /bin/bash "$installer"; then
    red "Automatic Homebrew install failed."
    rm -f "$installer"
    return 1
  fi
  rm -f "$installer"
  if [[ ! -x "$brew_bin" ]]; then
    red "Homebrew installed but brew binary not found at ${brew_bin}"
    return 1
  fi
  local profile="${home}/.zprofile"
  if ! grep -q 'brew shellenv' "$profile" 2>/dev/null; then
    sudo -u "$user" -H tee -a "$profile" >/dev/null <<EOF

eval "\$(${brew_bin} shellenv)"
EOF
  fi
  green "Homebrew installed at ${brew_prefix}"
  return 0
}
install_deps_for_user() {
  local user="$1" brew_bin brew_prefix
  yellow "Checking / installing dependencies for ${user}..."
  if sudo -u "$user" -H bash -lc 'command -v sshuttle >/dev/null 2>&1' \
     || [[ -x /opt/homebrew/bin/sshuttle ]] \
     || [[ -x /usr/local/bin/sshuttle ]]; then
    green "sshuttle: OK"
    return 0
  fi
  ensure_homebrew_for_user "$user" || return 1
  brew_prefix="$(brew_prefix_for_arch)"
  brew_bin="${brew_prefix}/bin/brew"
  [[ -x "$brew_bin" ]] || brew_bin="$(sudo -u "$user" -H bash -lc 'command -v brew' 2>/dev/null || true)"
  [[ -n "$brew_bin" && -x "$brew_bin" ]] || { red "brew still missing after install"; return 1; }
  yellow "Installing sshuttle..."
  if sudo -u "$user" -H env HOMEBREW_NO_AUTO_UPDATE=1 PATH="$(dirname "$brew_bin"):/usr/bin:/bin" \
      "$brew_bin" install sshuttle; then
    green "sshuttle installed"
    return 0
  fi
  red "Failed to install sshuttle"
  return 1
}
sshuttle_path_for_user() {
  local user="$1" bin=""
  bin="$(sudo -u "$user" -H bash -lc 'command -v sshuttle' 2>/dev/null || true)"
  [[ -n "$bin" && -x "$bin" ]] && { printf '%s\n' "$bin"; return 0; }
  find_sshuttle
}
write_launch_script_for_user() {
  local user="$1"
  local launch home session
  home="$(user_home "$user")"
  launch="${home}/.aso-vpn/launch-sshuttle.sh"
  session="${home}/.aso-vpn/session.env"
  if [[ "$(id -un)" == "$user" && "$(id -u)" -ne 0 ]]; then
    mkdir -p "${home}/.aso-vpn"
    cat > "$launch" <<LAUNCH
#!/bin/bash
set -euo pipefail
SESSION="${session}"
[[ -f "\$SESSION" ]] || { echo "ASO VPN: missing session.env"; exit 1; }
source "\$SESSION"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}"
if [[ -n "\${ASO_SSH_PASS:-}" ]]; then
  export ASO_SSH_PASS SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY
fi
/sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || /usr/sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
exec "\$SSHUTTLE_BIN" -D --pidfile="\$PID_FILE" --dns --method auto --ssh-cmd "\$SSH_CMD" -r "\$REMOTE" -x "\$EXCLUDE_IP" 0/0
LAUNCH
    chmod 700 "$launch"
  else
    sudo -u "$user" -H mkdir -p "${home}/.aso-vpn"
    sudo -u "$user" -H tee "$launch" >/dev/null <<LAUNCH
#!/bin/bash
set -euo pipefail
SESSION="${session}"
[[ -f "\$SESSION" ]] || { echo "ASO VPN: missing session.env"; exit 1; }
source "\$SESSION"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}"
if [[ -n "\${ASO_SSH_PASS:-}" ]]; then
  export ASO_SSH_PASS SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY
fi
/sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || /usr/sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
exec "\$SSHUTTLE_BIN" -D --pidfile="\$PID_FILE" --dns --method auto --ssh-cmd "\$SSH_CMD" -r "\$REMOTE" -x "\$EXCLUDE_IP" 0/0
LAUNCH
    sudo -u "$user" -H chmod 700 "$launch"
  fi
  printf '%s\n' "$launch"
}
has_nopasswd_sudo() {
  local bin launch
  bin="$(find_sshuttle)" || return 1
  launch="$(launch_script_path_for "$(id -un)")"
  [[ -x "$launch" ]] || return 1
  sudo -n "$bin" --version >/dev/null 2>&1 || return 1
  sudo -n "$PFCTL_BIN" -s info >/dev/null 2>&1 || return 1
  return 0
}
require_privilege() {
  if has_nopasswd_sudo; then
    return 0
  fi
  red "Admin access not granted yet."
  echo "STATE=NEED_AUTH"
  exit 78
}
sudo_run() {
  require_privilege
  sudo -n "$@"
}
all_network_services() {
  local service
  while IFS= read -r service; do
    [[ -z "$service" || "$service" == *"*"* ]] && continue
    printf '%s\n' "$service"
  done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
}
clear_all_system_proxies() {
  local service
  while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    networksetup -setsocksfirewallproxystate "$service" off >/dev/null 2>&1 || true
    networksetup -setwebproxystate "$service" off >/dev/null 2>&1 || true
    networksetup -setsecurewebproxystate "$service" off >/dev/null 2>&1 || true
    networksetup -setftpproxystate "$service" off >/dev/null 2>&1 || true
    networksetup -setautoproxystate "$service" off >/dev/null 2>&1 || true
  done < <(all_network_services)
  dscacheutil -flushcache >/dev/null 2>&1 || true
  killall -HUP mDNSResponder >/dev/null 2>&1 || true
}
pid_alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}
is_tunnel_up() {
  local pid=""
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if pid_alive "$pid"; then return 0; fi
    rm -f "$PID_FILE"
  fi
  pgrep -f "sshuttle.*${SSH_HOST}" >/dev/null 2>&1
}
resolve_host_ip() {
  local ip
  ip="$(dscacheutil -q host -a name "$SSH_HOST" 2>/dev/null | awk '/^ip_address:/{print $2; exit}')"
  [[ -z "$ip" ]] && ip="$(dig +short "$SSH_HOST" A 2>/dev/null | awk 'NR==1 && $1 ~ /^[0-9.]+$/{print; exit}')"
  [[ -z "$ip" ]] && ip="$(python3 -c "import socket; print(socket.gethostbyname('${SSH_HOST}'))" 2>/dev/null || true)"
  printf '%s\n' "$ip"
}
make_askpass() {
  mkdir -p "$HELPER_DIR"
  local askpass="${HELPER_DIR}/askpass.sh"
  cat > "$askpass" <<'ASK'
#!/bin/bash
printf '%s\n' "${ASO_SSH_PASS}"
ASK
  chmod 700 "$askpass"
  printf '%s\n' "$askpass"
}
build_ssh_cmd() {
  local parts=(ssh -p "$SSH_PORT"
    -o ExitOnForwardFailure=yes
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o TCPKeepAlive=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
  )
  if [[ -n "$SSH_KEY" ]]; then
    parts+=(-i "$SSH_KEY")
  elif [[ -n "${SSH_PASS:-}" ]]; then
    parts+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
  fi
  if [[ -n "$SSH_EXTRA_OPTS" ]]; then
    parts+=($SSH_EXTRA_OPTS)
  fi
  printf '%q ' "${parts[@]}"
}
kill_tunnel() {
  local pid="" orphan
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  fi
  if [[ -n "$pid" ]] && pid_alive "$pid"; then
    sudo_run /bin/kill "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      pid_alive "$pid" || break
      sleep 0.2
    done
    if pid_alive "$pid"; then
      sudo_run /bin/kill -9 "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  while IFS= read -r orphan; do
    [[ -z "$orphan" ]] && continue
    sudo_run /bin/kill -9 "$orphan" 2>/dev/null || kill -9 "$orphan" 2>/dev/null || true
  done < <(pgrep -f "sshuttle.*${SSH_HOST}" 2>/dev/null || true)
  sudo_run /bin/rm -f "$PID_FILE" "$STATE_MARKER" 2>/dev/null || rm -f "$PID_FILE" "$STATE_MARKER" 2>/dev/null || true
  sudo_run "$PFCTL_BIN" -f /etc/pf.conf 2>/dev/null || true
}
install_privileges() {
  need_macos
  local user bin launch home tmp conf pfctl killb
  user="$(real_user)"
  [[ "$user" != "root" ]] || user="$(stat -f%Su /dev/console)"
  yellow "Setting up ASO VPN for user: ${user}"
  install_deps_for_user "$user" || exit 1
  bin="$(sshuttle_path_for_user "$user")"
  [[ -n "$bin" && -x "$bin" ]] || { red "sshuttle not found after install"; exit 1; }
  launch="$(write_launch_script_for_user "$user")"
  home="$(user_home "$user")"
  pfctl="$(command -v pfctl 2>/dev/null || true)"
  [[ -x "$pfctl" ]] || pfctl="/sbin/pfctl"
  killb="$(command -v kill 2>/dev/null || true)"
  [[ -x "$killb" ]] || killb="/bin/kill"
  tmp="$(mktemp /tmp/aso-sudoers.XXXXXX)"
  conf="/etc/sudoers.d/aso-vpn"
  cat > "$tmp" <<EOF
Defaults!${bin} !requiretty
Defaults!${launch} !requiretty
Defaults!${pfctl} !requiretty
${user} ALL=(root) NOPASSWD: ${bin}
${user} ALL=(root) NOPASSWD: ${launch}
${user} ALL=(root) NOPASSWD: ${pfctl}
${user} ALL=(root) NOPASSWD: /sbin/pfctl
${user} ALL=(root) NOPASSWD: /usr/sbin/pfctl
${user} ALL=(root) NOPASSWD: ${killb}
${user} ALL=(root) NOPASSWD: /bin/kill
EOF
  chmod 440 "$tmp"
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    red "Invalid sudoers content"
    cat "$tmp" >&2 || true
    rm -f "$tmp"
    exit 1
  fi
  cp "$tmp" "$conf"
  chmod 440 "$conf"
  chown root:wheel "$conf"
  rm -f "$tmp"
  if ! sudo -u "$user" -H sudo -n "$bin" --version >/dev/null 2>&1; then
    red "Sudo verify failed for ${user} (sshuttle)"
    exit 1
  fi
  if ! sudo -u "$user" -H sudo -n "$pfctl" -s info >/dev/null 2>&1; then
    red "Sudo verify failed for ${user} (pfctl at ${pfctl})"
    exit 1
  fi
  sudo -u "$user" -H mkdir -p "${home}/Library/Application Support/ASO VPN"
  sudo -u "$user" -H sh -c "date > '${home}/Library/Application Support/ASO VPN/.sudoers-ok'"
  green "Privileges + dependencies OK for ${user}"
  echo "STATE=AUTH_OK"
}
auth_status() {
  need_macos
  if has_nopasswd_sudo; then
    echo "STATE=AUTH_OK"
    green "Admin: granted (no password needed)"
  else
    echo "STATE=NEED_AUTH"
    yellow "Admin: not granted yet"
  fi
}
reset_privileges() {
  need_macos
  local user home
  user="$(real_user)"
  [[ "$user" != "root" ]] || user="$(stat -f%Su /dev/console)"
  home="$(user_home "$user")"
  yellow "Resetting ASO VPN permission for ${user}..."
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  pkill -f "sshuttle.*${SSH_HOST}" 2>/dev/null || true
  rm -f "$STATE_MARKER"
  rm -f /etc/sudoers.d/aso-vpn
  sudo -u "$user" -H rm -f "${home}/Library/Application Support/ASO VPN/.sudoers-ok" 2>/dev/null || true
  rm -f "${home}/Library/Application Support/ASO VPN/.sudoers-ok" 2>/dev/null || true
  sudo -u "$user" -H rm -f "${home}/.aso-vpn/session.env" 2>/dev/null || true
  clear_all_system_proxies 2>/dev/null || true
  "$PFCTL_BIN" -f /etc/pf.conf >/dev/null 2>&1 || true
  green "Permission reset. Click Connect and Allow again."
  echo "STATE=NEED_AUTH"
}
start_tunnel() {
  need_macos
  check_config
  ensure_sshuttle
  require_privilege
  clear_all_system_proxies
  if is_tunnel_up; then
    yellow "Already connected."
    echo "tunnel" > "$STATE_MARKER"
    echo "STATE=ON"
    green "VPN ON"
    notify "VPN" "ON — ${SSH_HOST}"
    exit 0
  fi
  kill_tunnel || true
  clear_all_system_proxies
  local host_ip askpass="" ssh_cmd
  host_ip="$(resolve_host_ip)"
  [[ -n "$host_ip" ]] || { red "Could not resolve ${SSH_HOST}"; echo "STATE=OFF"; exit 1; }
  dim "Remote IP: $host_ip"
  ssh_cmd="$(build_ssh_cmd)"
  ssh_cmd="${ssh_cmd% }"
  if [[ -n "${SSH_PASS:-}" && -z "${SSH_KEY:-}" ]]; then
    askpass="$(make_askpass)"
  fi
  local aso_dir="${HOME}/.aso-vpn"
  local session="${aso_dir}/session.env"
  local launch="${aso_dir}/launch-sshuttle.sh"
  mkdir -p "$aso_dir"
  {
    printf 'SSHUTTLE_BIN=%q\n' "$SSHUTTLE_BIN"
    printf 'PID_FILE=%q\n' "$PID_FILE"
    printf 'SSH_CMD=%q\n' "$ssh_cmd"
    printf 'REMOTE=%q\n' "${SSH_USER}@${SSH_HOST}"
    printf 'EXCLUDE_IP=%q\n' "$host_ip"
    if [[ -n "$askpass" ]]; then
      printf 'ASO_SSH_PASS=%q\n' "$SSH_PASS"
      printf 'SSH_ASKPASS=%q\n' "$askpass"
      printf 'SSH_ASKPASS_REQUIRE=%q\n' "force"
      printf 'DISPLAY=%q\n' "${DISPLAY:-:0}"
    fi
  } > "$session"
  chmod 600 "$session"
  write_launch_script_for_user "$(id -un)" >/dev/null
  green "Starting system tunnel..."
  local launch_err
  launch_err="$(mktemp "${RUNTIME_TMP}/aso-ssh-launch.XXXXXX")"
  if ! sudo -n "$launch" >"$launch_err" 2>&1; then
    red "Failed to start sshuttle (sudo/launch)."
    [[ -s "$launch_err" ]] && cat "$launch_err" >&2 || true
    rm -f "$launch_err"
    echo "STATE=OFF"
    exit 1
  fi
  rm -f "$launch_err"
  local i
  for i in $(seq 1 40); do
    if is_tunnel_up; then
      break
    fi
    sleep 0.5
  done
  if ! is_tunnel_up; then
    red "Tunnel did not stay up within timeout. Check SSH credentials / remote Python."
    kill_tunnel || true
    echo "STATE=OFF"
    exit 1
  fi
  echo "tunnel" > "$STATE_MARKER"
  echo "STATE=ON"
  green "VPN ON — all TCP + DNS via ${SSH_HOST}"
  notify "VPN" "ON — full tunnel ${SSH_HOST}"
}
stop_tunnel() {
  need_macos
  if is_tunnel_up || [[ -f "$PID_FILE" ]] || pgrep -f "sshuttle.*${SSH_HOST}" >/dev/null 2>&1; then
    yellow "Disconnecting..."
    if has_nopasswd_sudo; then
      kill_tunnel
    else
      local pid orphan
      pid="$(cat "$PID_FILE" 2>/dev/null || true)"
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
      while IFS= read -r orphan; do
        [[ -z "$orphan" ]] && continue
        kill -9 "$orphan" 2>/dev/null || true
      done < <(pgrep -f "sshuttle.*${SSH_HOST}" 2>/dev/null || true)
      rm -f "$PID_FILE" "$STATE_MARKER"
    fi
    green "Tunnel stopped."
  else
    yellow "No active tunnel."
    rm -f "$PID_FILE" "$STATE_MARKER"
  fi
  clear_all_system_proxies
  if is_tunnel_up; then
    red "Could not fully stop tunnel."
    echo "STATE=ON"
    exit 1
  fi
  echo "STATE=OFF"
  green "VPN OFF"
  notify "VPN" "OFF"
}
show_status() {
  need_macos
  local state="OFF" pid=""
  if is_tunnel_up; then
    state="ON"
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -z "$pid" ]] && pid="$(pgrep -f "sshuttle.*${SSH_HOST}" 2>/dev/null | head -n1 || true)"
  fi
  echo "STATE=${state}"
  if has_nopasswd_sudo; then
    echo "AUTH=OK"
  else
    echo "AUTH=NEED"
  fi
  if [[ "$state" == "ON" ]]; then
    green "Tunnel: RUNNING (pid ${pid:-?})"
    green "Mode  : system-wide (all apps)"
  else
    yellow "Tunnel: STOPPED"
  fi
  if [[ -n "${SSH_HOST:-}" && -n "${SSH_USER:-}" ]]; then
    echo "Target: ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
  else
    echo "Target: (not configured)"
  fi
  echo "Engine: sshuttle"
}
restart_tunnel() { stop_tunnel || true; start_tunnel; }
toggle_tunnel() {
  if is_tunnel_up; then stop_tunnel; else start_tunnel; fi
}
main() {
  case "${1:-}" in
    ""|toggle|t)     toggle_tunnel ;;
    on|start|1)      start_tunnel ;;
    off|stop|0)      stop_tunnel ;;
    status|s)        show_status ;;
    restart)         restart_tunnel ;;
    auth-status)     auth_status ;;
    install-priv)    install_privileges ;;
    reset-priv)      reset_privileges ;;
    -h|--help|help)
      echo "Usage: vpn.sh on|off|status|auth-status|install-priv|reset-priv"
      ;;
    *) red "Unknown: $1"; exit 1 ;;
  esac
}
main "$@"
