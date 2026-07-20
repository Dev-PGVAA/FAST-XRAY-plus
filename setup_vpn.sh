#!/bin/bash
# ============================================================================
#  FastXray — быстрая установка VPN-сервера
#  Xray-core (VLESS+REALITY, Shadowsocks) + Telegram MTProto-прокси
# ============================================================================
set -euo pipefail
# ---------------------------------------------------------------------------
# Настройки — поменяй при необходимости
# ---------------------------------------------------------------------------
LOCATION_TAG="VPS"
LOG_FILE="/var/log/vpn-setup.log"
SCRIPT_DIR="/usr/local/etc/xray"
CLIENT_DIR="$SCRIPT_DIR/client_configs"
MTG_DIR="/usr/local/etc/mtg"
SERVER_IP_DEFAULT="62.171.228.97"
PORT_VLESS_MAIN=443
PORT_VLESS_BACKUP=8443
PORT_SS=2040
PORT_MTG=2096
MTG_FAKE_TLS_HOST="www.cloudflare.com"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
# ---------------------------------------------------------------------------
# Оформление
# ---------------------------------------------------------------------------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_BLUE='\033[1;34m'
C_MAGENTA='\033[1;35m'
C_WHITE='\033[1;37m'
LINE_THIN="────────────────────────────────────────────────────────────"
LINE_BOLD="════════════════════════════════════════════════════════════"
TOTAL_STEPS=8
CUR_STEP=0
step() {
  CUR_STEP=$((CUR_STEP + 1))
  echo
  echo -e "${C_DIM}${LINE_THIN}${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}[${CUR_STEP}/${TOTAL_STEPS}]${C_RESET} ${C_WHITE}$1${C_RESET}"
  echo -e "${C_DIM}${LINE_THIN}${C_RESET}"
}
info()  { echo -e "  ${C_BLUE}ℹ${C_RESET}  $1"; }
ok()    { echo -e "  ${C_GREEN}✓${C_RESET}  $1"; }
warn()  { echo -e "  ${C_YELLOW}⚠${C_RESET}  $1"; }
fail()  { echo -e "  ${C_RED}✗${C_RESET}  $1"; }
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -r -p "$(echo -e "  ${C_MAGENTA}?${C_RESET} ${prompt} ${C_DIM}[${default}]${C_RESET}: ")" reply </dev/tty
    echo "${reply:-$default}"
  else
    read -r -p "$(echo -e "  ${C_MAGENTA}?${C_RESET} ${prompt}: ")" reply </dev/tty
    echo "$reply"
  fi
}
ask_yn() {
  local prompt="$1" default="${2:-y}" hint="y/n" reply
  [[ "$default" == "y" ]] && hint="Y/n"
  [[ "$default" == "n" ]] && hint="y/N"
  read -r -p "$(echo -e "  ${C_MAGENTA}?${C_RESET} ${prompt} ${C_DIM}[${hint}]${C_RESET}: ")" reply </dev/tty
  reply="${reply:-$default}"
  [[ "$reply" =~ ^([yY][eE]?[sS]?|[дД][аА]?)$ ]]
}
trap 'echo -e "\n${C_RED}❌ Ошибка на строке $LINENO. Подробности в логе: $LOG_FILE${C_RESET}"; exit 1' ERR
need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${C_RED}Запусти от root: sudo bash setup_vpn.sh${C_RESET}"
    exit 1
  fi
}
print_banner() {
  clear
  echo -e "${C_CYAN}${C_BOLD}${LINE_BOLD}${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}"
  cat << 'BANNER'
    ███████╗ █████╗ ███████╗████████╗██╗  ██╗██████╗  █████╗ ██╗   ██╗
    ██╔════╝██╔══██╗██╔════╝╚══██╔══╝╚██╗██╔╝██╔══██╗██╔══██╗╚██╗ ██╔╝
    █████╗  ███████║███████╗   ██║    ╚███╔╝ ██████╔╝███████║ ╚████╔╝
    ██╔══╝  ██╔══██║╚════██║   ██║    ██╔██╗ ██╔══██╗██╔══██║  ╚██╔╝
    ██║     ██║  ██║███████║   ██║   ██╔╝ ██╗██║  ██║██║  ██║   ██║
    ╚═╝     ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝
BANNER
  echo -e "${C_RESET}"
  echo -e "${C_DIM}  VLESS+REALITY · Shadowsocks · Telegram MTProto${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}${LINE_BOLD}${C_RESET}"
  echo
}
# ---------------------------------------------------------------------------
# Опрос — всё спрашиваем до начала установки
# ---------------------------------------------------------------------------
ANSWER_CREATE_USER="n"
ANSWER_USERNAME=""
ANSWER_USER_PASSWORD=""
ANSWER_LOGIN_METHOD=""
ANSWER_WANT_MTPROTO="n"
ANSWER_DISABLE_ROOT_LOGIN="y"
collect_answers() {
  echo -e "${C_WHITE}${C_BOLD}Перед установкой — несколько вопросов.${C_RESET}"
  echo
  LOCATION_TAG="$(ask "Как назвать этот сервер (страна/описание)" "VPS")"
  echo
  if ask_yn "Создать нового пользователя на сервере (помимо root)?" "y"; then
    ANSWER_CREATE_USER="y"
    while true; do
      ANSWER_USERNAME="$(ask "Имя пользователя" "user")"
      [[ "$ANSWER_USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
      warn "Имя должно быть на латинице, начинаться с буквы или _, без пробелов."
    done
    echo
    echo -e "  ${C_DIM}Как пользователь будет заходить по SSH:${C_RESET}"
    echo -e "    ${C_WHITE}1${C_RESET} — только по паролю"
    echo -e "    ${C_WHITE}2${C_RESET} — только по SSH-ключу (без пароля для входа)"
    echo -e "    ${C_WHITE}3${C_RESET} — и пароль, и ключ (пароль нужен и для sudo)"
    local method_choice
    method_choice="$(ask "Выбор (1/2/3)" "3")"
    case "$method_choice" in
      1) ANSWER_LOGIN_METHOD="password" ;;
      2) ANSWER_LOGIN_METHOD="key" ;;
      *) ANSWER_LOGIN_METHOD="both" ;;
    esac
    if [[ "$ANSWER_LOGIN_METHOD" != "key" ]]; then
      while true; do
        local pw1 pw2
        read -r -s -p "$(echo -e "  ${C_MAGENTA}?${C_RESET} Пароль для ${ANSWER_USERNAME} (мин. 8 символов): ")" pw1 </dev/tty
        echo
        if [[ ${#pw1} -lt 8 ]]; then warn "Слишком короткий пароль, минимум 8 символов."; continue; fi
        read -r -s -p "$(echo -e "  ${C_MAGENTA}?${C_RESET} Повтори пароль: ")" pw2 </dev/tty
        echo
        if [[ "$pw1" != "$pw2" ]]; then warn "Пароли не совпадают, попробуй снова."; continue; fi
        ANSWER_USER_PASSWORD="$pw1"
        break
      done
    else
      ANSWER_USER_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
    fi
  fi
  echo
  if ask_yn "Отключить root login по SSH?" "y"; then
    ANSWER_DISABLE_ROOT_LOGIN="y"
  else
    ANSWER_DISABLE_ROOT_LOGIN="n"
  fi
  echo
  if ask_yn "Поднять ещё и Telegram MTProto-прокси?" "y"; then
    ANSWER_WANT_MTPROTO="y"
  fi
  echo
  ok "Настройки получены, начинаю установку."
}
# ---------------------------------------------------------------------------
# Системные шаги
# ---------------------------------------------------------------------------
get_server_ip() {
  local ip
  ip="$(curl -s -4 --max-time 5 https://api.ipify.org || true)"
  [[ -z "${ip:-}" ]] && ip="$(hostname -I | awk '{print $1}' || true)"
  [[ -z "${ip:-}" ]] && ip="$SERVER_IP_DEFAULT"
  echo "$ip"
}
make_dirs() {
  mkdir -p "$SCRIPT_DIR" "$CLIENT_DIR" "$MTG_DIR"
  ok "Директории готовы"
}
install_packages() {
  apt update -qq
  apt install -y -qq jq curl wget build-essential make git ufw gettext-base openssl qrencode > /dev/null
  ok "Системные пакеты установлены"
}
install_xray() {
  if command -v xray &>/dev/null; then
    ok "Xray уже установлен, пропускаю установку"
    return
  fi
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null
  ok "Xray-core установлен"
}
create_user() {
  if [[ "$ANSWER_CREATE_USER" != "y" ]]; then
    info "Создание пользователя пропущено (по выбору)"
    return
  fi
  local username="$ANSWER_USERNAME"
  if id "$username" &>/dev/null; then
    warn "Пользователь $username уже существует, обновляю пароль/доступ"
  else
    useradd -m -s /bin/bash "$username"
    usermod -aG sudo "$username"
    ok "Пользователь $username создан и добавлен в sudo"
  fi
  echo "${username}:${ANSWER_USER_PASSWORD}" | chpasswd
  ok "Пароль для $username установлен"
  if [[ "$ANSWER_LOGIN_METHOD" == "key" || "$ANSWER_LOGIN_METHOD" == "both" ]]; then
    mkdir -p "/home/$username/.ssh"
    chmod 700 "/home/$username/.ssh"
    touch "/home/$username/.ssh/authorized_keys"
    chmod 600 "/home/$username/.ssh/authorized_keys"
    chown -R "$username:$username" "/home/$username/.ssh"
  fi
}
generate_xray_data() {
  xray_uuid_vrv="$(xray uuid)"
  local domains=(
    www.theregister.com www.20minutes.fr www.dealabs.com www.manomano.fr
    www.caradisiac.com www.techadvisor.com www.computerworld.com
    www.bing.com github.com tradingview.com
  )
  xray_dest_vrv="${domains[$RANDOM % ${#domains[@]}]}"
  xray_dest_vrv222="${domains[$RANDOM % ${#domains[@]}]}"
  while [[ "$xray_dest_vrv222" == "$xray_dest_vrv" ]]; do
    xray_dest_vrv222="${domains[$RANDOM % ${#domains[@]}]}"
  done
  local key_output
  key_output="$(xray x25519)"
  xray_privateKey_vrv="$(awk -F': ' '/PrivateKey/ {print $2}' <<< "$key_output")"
  xray_publicKey_vrv="$(awk -F': ' '/PublicKey/ {print $2}' <<< "$key_output")"
  xray_shortIds_vrv="$(openssl rand -hex 8)"
  xray_sspasw_vrv="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)"
  ipserv="$(get_server_ip)"
  export xray_uuid_vrv xray_dest_vrv xray_dest_vrv222 xray_privateKey_vrv \
         xray_publicKey_vrv xray_shortIds_vrv xray_sspasw_vrv ipserv
  ok "Ключи и параметры сгенерированы"
}
write_xray_config() {
  export PORT_VLESS_MAIN PORT_VLESS_BACKUP PORT_SS
  cat << 'EOF' | envsubst > "$SCRIPT_DIR/config.json"
{
  "log": { "dnsLog": false, "loglevel": "none" },
  "dns": {
    "servers": [
      "https+local://8.8.4.4/dns-query",
      "https+local://8.8.8.8/dns-query",
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "VLESS_MAIN",
      "port": ${PORT_VLESS_MAIN},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [{ "flow": "xtls-rprx-vision", "id": "${xray_uuid_vrv}" }],
        "decryption": "none"
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "xver": 0,
          "target": "${xray_dest_vrv}:443",
          "spiderX": "/",
          "shortIds": ["${xray_shortIds_vrv}"],
          "privateKey": "${xray_privateKey_vrv}",
          "serverNames": ["${xray_dest_vrv}"]
        }
      }
    },
    {
      "tag": "VLESS_BACKUP",
      "port": ${PORT_VLESS_BACKUP},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [{ "flow": "xtls-rprx-vision", "id": "${xray_uuid_vrv}" }],
        "decryption": "none"
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "xver": 0,
          "target": "${xray_dest_vrv222}:443",
          "spiderX": "/",
          "shortIds": ["${xray_shortIds_vrv}"],
          "privateKey": "${xray_privateKey_vrv}",
          "serverNames": ["${xray_dest_vrv222}"]
        }
      }
    },
    {
      "tag": "SHADOWSOCKS",
      "port": ${PORT_SS},
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": {
        "clients": [{ "password": "${xray_sspasw_vrv}", "method": "chacha20-ietf-poly1305" }]
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
      "streamSettings": { "network": "raw" }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "ForceIPv4" } },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "domain": ["geosite:category-ads", "geosite:win-spy", "geosite:private"], "outboundTag": "block" },
      { "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF
  ok "Конфиг Xray записан"
}
start_xray() {
  systemctl enable xray --now > /dev/null 2>&1
  systemctl restart xray
  sleep 1
  if systemctl is-active --quiet xray; then
    ok "Служба xray запущена"
  else
    fail "Служба xray не стартовала, смотри: journalctl -u xray -n 50"
    exit 1
  fi
}
setup_ufw() {
  local busy_ports=() p
  for p in "$PORT_VLESS_MAIN" "$PORT_VLESS_BACKUP" "$PORT_SS"; do
    if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
      busy_ports+=("$p")
    fi
  done
  if [[ "$ANSWER_WANT_MTPROTO" == "y" ]]; then
    if ss -tlnp 2>/dev/null | grep -q ":${PORT_MTG} "; then
      busy_ports+=("$PORT_MTG")
    fi
  fi
  if [[ ${#busy_ports[@]} -gt 0 ]]; then
    warn "Заняты порты: ${busy_ports[*]}. Соответствующие службы могут не запуститься."
  fi
  ufw default deny incoming > /dev/null
  ufw default allow outgoing > /dev/null
  ufw allow 22/tcp comment 'ssh' > /dev/null
  ufw allow "${PORT_VLESS_MAIN}/tcp" comment 'xray vless reality' > /dev/null
  ufw allow "${PORT_VLESS_BACKUP}/tcp" comment 'xray vless reality backup' > /dev/null
  ufw allow "${PORT_SS}/tcp" comment 'xray shadowsocks' > /dev/null
  if [[ "$ANSWER_WANT_MTPROTO" == "y" ]]; then
    ufw allow "${PORT_MTG}/tcp" comment 'telegram mtproto' > /dev/null
  fi
  ufw --force enable > /dev/null
  ok "Firewall (ufw) настроен"
}
setup_ssh_hardening() {
  local ssh_service="ssh"
  systemctl list-unit-files | grep -q '^sshd\.service' && ssh_service="sshd"
  if [[ "$ANSWER_DISABLE_ROOT_LOGIN" == "y" ]]; then
    cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config || true
    grep -q '^PermitRootLogin ' /etc/ssh/sshd_config || echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
    sshd -t
    systemctl restart "$ssh_service"
    ok "SSH: root login отключён"
  else
    info "SSH: root login не отключаю (по выбору)"
  fi
}
install_mtproto() {
  if [[ "$ANSWER_WANT_MTPROTO" != "y" ]]; then
    info "MTProto-прокси пропущен (по выбору)"
    return
  fi
  if ! command -v mtg &>/dev/null; then
    local mtg_version mtg_url
    mtg_version="$(curl -s --max-time 10 https://api.github.com/repos/9seconds/mtg/releases/latest | jq -r '.tag_name' || true)"
    if [[ -n "${mtg_version:-}" && "$mtg_version" != "null" ]]; then
      mtg_url="https://github.com/9seconds/mtg/releases/download/${mtg_version}/mtg-${mtg_version#v}-linux-amd64.tar.gz"
      if curl -sL --max-time 20 -o /tmp/mtg.tar.gz "$mtg_url" && tar -tzf /tmp/mtg.tar.gz &>/dev/null; then
        tar -xzf /tmp/mtg.tar.gz -C /tmp
        find /tmp -maxdepth 2 -type f -name 'mtg' -exec install -m 755 {} /usr/local/bin/mtg \;
        rm -rf /tmp/mtg.tar.gz /tmp/mtg-*
      fi
    fi
  fi
  if ! command -v mtg &>/dev/null; then
    warn "Готовый бинарь mtg не скачался, собираю из исходников (дольше)"
    apt install -y -qq golang-go > /dev/null
    GOPATH=/tmp/gopath GOBIN=/usr/local/bin go install github.com/9seconds/mtg/v2@latest > /dev/null 2>&1 || true
    rm -rf /tmp/gopath
  fi
  if ! command -v mtg &>/dev/null; then
    fail "Не удалось установить mtg, MTProto-прокси будет пропущен"
    ANSWER_WANT_MTPROTO="n"
    return
  fi
  mtg_secret_vrv="$(mtg generate-secret --hex "$MTG_FAKE_TLS_HOST")"
  export mtg_secret_vrv
  cat > "$MTG_DIR/mtg.toml" << EOF
secret = "${mtg_secret_vrv}"
bind-to = "0.0.0.0:${PORT_MTG}"
EOF
  cat > /etc/systemd/system/mtg.service << EOF
[Unit]
Description=mtg - Telegram MTProto proxy
After=network.target
[Service]
ExecStart=/usr/local/bin/mtg run ${MTG_DIR}/mtg.toml
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
User=root
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable mtg --now > /dev/null 2>&1
  systemctl restart mtg
  sleep 1
  if systemctl is-active --quiet mtg; then
    ok "MTProto-прокси (mtg) запущен на порту ${PORT_MTG}"
  else
    fail "mtg не стартовал, смотри: journalctl -u mtg -n 50"
    ANSWER_WANT_MTPROTO="n"
  fi
}
write_client_links() {
  local server_ip="$1"
  local tag_encoded
  tag_encoded="$(printf '%s' "$LOCATION_TAG" | jq -sRr @uri)"
  ss_link_b64="$(printf 'chacha20-ietf-poly1305:%s' "$xray_sspasw_vrv" | base64 -w 0)
  vless_main_link="vless://${xray_uuid_vrv}@${server_ip}:${PORT_VLESS_MAIN}?security=reality&sni=${xray_dest_vrv}&fp=chrome&pbk=${xray_publicKey_vrv}&sid=${xray_shortIds_vrv}&type=tcp&flow=xtls-rprx-vision&encryption=none&spx=%2F#${tag_encoded}%20VLESS%20${PORT_VLESS_MAIN}"
  vless_backup_link="vless://${xray_uuid_vrv}@${server_ip}:${PORT_VLESS_BACKUP}?security=reality&sni=${xray_dest_vrv222}&fp=chrome&pbk=${xray_publicKey_vrv}&sid=${xray_shortIds_vrv}&type=tcp&flow=xtls-rprx-vision&encryption=none&spx=%2F#${tag_encoded}%20VLESS%20${PORT_VLESS_BACKUP}%20backup"
  ss_link="ss://${ss_link_b64}@${server_ip}:${PORT_SS}#${tag_encoded}%20Shadowsocks"
  export vless_main_link vless_backup_link ss_link
  if [[ "$ANSWER_WANT_MTPROTO" == "y" ]]; then
    mtg_tg_link="tg://proxy?server=${server_ip}&port=${PORT_MTG}&secret=${mtg_secret_vrv}"
    mtg_tme_link="https://t.me/proxy?server=${server_ip}&port=${PORT_MTG}&secret=${mtg_secret_vrv}"
    export mtg_tg_link mtg_tme_link
  fi
  all_links_b64="$(
    {
      printf '%s\n' "$vless_main_link" "$vless_backup_link" "$ss_link"
      if [[ "$ANSWER_WANT_MTPROTO" == "y" ]]; then
        printf '%s\n' "$mtg_tg_link"
      fi
    } | base64 -w 0
  )"
  export all_links_b64
  ok "Ссылки сгенерированы"
}
write_server_readme() {
  {
    echo "==========================================="
    echo "VPN — данные установки"
    echo "Локация: ${LOCATION_TAG}"
    echo "Сервер IP: ${ipserv}"
    echo "Дата установки: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "==========================================="
    echo
    echo "VLESS+REALITY (основной, порт ${PORT_VLESS_MAIN}):"
    echo "${vless_main_link}"
    echo
    echo "VLESS+REALITY (резервный, порт ${PORT_VLESS_BACKUP}):"
    echo "${vless_backup_link}"
    echo
    echo "Shadowsocks (порт ${PORT_SS}):"
    echo "${ss_link}"
    if [[ "$ANSWER_WANT_MTPROTO" == "y" ]]; then
      echo
      echo "Telegram MTProto (порт ${PORT_MTG}):"
      echo "${mtg_tg_link}"
      echo "${mtg_tme_link}"
    fi
    echo
    echo "Все конфиги в одной base64-строке:"
    echo "${all_links_b64}"
    echo "==========================================="
  } > "$CLIENT_DIR/README.txt"
  ok "README сохранён в ${CLIENT_DIR}/README.txt"
}
# ---------------------------------------------------------------------------
# Финальный экран
# ---------------------------------------------------------------------------
final_output() {
  clear
  echo -e "${C_GREEN}${C_BOLD}${LINE_BOLD}${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD}   ✅  УСТАНОВКА ЗАВЕРШЕНА — ${LOCATION_TAG}${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD}${LINE_BOLD}${C_RESET}"
  echo
  echo -e "${C_WHITE}${C_BOLD}📡 Сервер${C_RESET}"
  echo -e "  IP: ${C_CYAN}${ipserv}${C_RESET}"
  echo
  echo -e "${C_DIM}${LINE_THIN}${C_RESET}"
  echo -e "${C_WHITE}${C_BOLD}🔗 VLESS+REALITY${C_RESET} ${C_DIM}(основной, port ${PORT_VLESS_MAIN})${C_RESET}"
  echo -e "  ${C_YELLOW}${vless_main_link}${C_RESET}"
  echo
  echo -e "${C_WHITE}${C_BOLD}🔗 VLESS+REALITY${C_RESET} ${C_DIM}(резервный, порт ${PORT_VLESS_BACKUP})${C_RESET}"
  echo -e "  ${C_YELLOW}${vless_backup_link}${C_RESET}"
  echo
  echo -e "${C_WHITE}${C_BOLD}🔗 Shadowsocks${C_RESET} ${C_DIM}(порт ${PORT_SS})${C_RESET}"
  echo -e "  ${C_YELLOW}${ss_link}${C_RESET}"
  if [[ "$ANSWER_WANT_MTPROTO" == "y" ]]; then
    echo
    echo -e "${C_WHITE}${C_BOLD}🔗 Telegram MTProto${C_RESET} ${C_DIM}(порт ${PORT_MTG})${C_RESET}"
    echo -e "  ${C_YELLOW}${mtg_tg_link}${C_RESET}"
    echo -e "  ${C_DIM}${mtg_tme_link}${C_RESET}"
    if command -v qrencode &>/dev/null; then
      echo
      echo -e "${C_DIM}  QR-код для Telegram-прокси:${C_RESET}"
      qrencode -t ANSIUTF8 "$mtg_tg_link"
    fi
  fi
  echo
  echo -e "${C_DIM}${LINE_THIN}${C_RESET}"
  echo -e "${C_WHITE}${C_BOLD}📦 Все конфиги в одной base64-строке${C_RESET}"
  echo -e "  ${C_DIM}${all_links_b64}${C_RESET}"
  echo
  echo -e "${C_DIM}${LINE_THIN}${C_RESET}"
  if [[ "$ANSWER_CREATE_USER" == "y" ]]; then
    echo -e "${C_WHITE}${C_BOLD}👤 Пользователь сервера${C_RESET}"
    echo -e "  Логин:  ${C_CYAN}${ANSWER_USERNAME}${C_RESET}"
    case "$ANSWER_LOGIN_METHOD" in
      password)
        echo -e "  Пароль: ${C_CYAN}${ANSWER_USER_PASSWORD}${C_RESET}"
        echo -e "  Вход:   по паролю — ${C_DIM}ssh ${ANSWER_USERNAME}@${ipserv}${C_RESET}"
        ;;
      key)
        echo -e "  Вход:   только по SSH-ключу — добавь свой публичный ключ в"
        echo -e "          ${C_DIM}/home/${ANSWER_USERNAME}/.ssh/authorized_keys${C_RESET}"
        echo -e "  Системный пароль (для sudo): ${C_CYAN}${ANSWER_USER_PASSWORD}${C_RESET}"
        ;;
      both)
        echo -e "  Пароль: ${C_CYAN}${ANSWER_USER_PASSWORD}${C_RESET}"
        echo -e "  Вход:   по паролю или ключу — ${C_DIM}ssh ${ANSWER_USERNAME}@${ipserv}${C_RESET}"
        ;;
    esac
    echo
    echo -e "${C_DIM}${LINE_THIN}${C_RESET}"
  fi
  echo -e "${C_WHITE}${C_BOLD}📁 Файлы на сервере${C_RESET}"
  echo -e "  Конфиг Xray:      ${SCRIPT_DIR}/config.json"
  echo -e "  README с данными: ${CLIENT_DIR}/README.txt"
  echo -e "  Лог установки:    ${LOG_FILE}"
  echo
  echo -e "${C_DIM}${LINE_THIN}${C_RESET}"
  echo -e "${C_WHITE}${C_BOLD}📲 Что делать дальше${C_RESET}"
  echo
  echo -e "  ${C_GREEN}1.${C_RESET} Установи клиент:"
  echo -e "     • Android  — ${C_CYAN}v2RayTun${C_RESET} или ${C_CYAN}NekoBox${C_RESET}"
  echo -e "     • iOS      — ${C_CYAN}Streisand${C_RESET} или ${C_CYAN}Shadowrocket${C_RESET}"
  echo -e "     • Windows  — ${C_CYAN}v2RayN${C_RESET} или ${C_CYAN}Hiddify${C_RESET}"
  echo -e "     • macOS    — ${C_CYAN}Hiddify${C_RESET} или ${C_CYAN}V2Box${C_RESET}"
  echo
  echo -e "  ${C_GREEN}2.${C_RESET} В клиенте выбери ${C_BOLD}«Добавить конфиг по ссылке»${C_RESET} и вставь"
  echo -e "     любую из ссылок выше — либо ${C_BOLD}«Импорт по base64»${C_RESET} и вставь общий блок."
  echo -e "  ${C_GREEN}3.${C_RESET} Подключайся через VLESS+REALITY (${PORT_VLESS_MAIN}) — это основной;"
  echo -e "     ${PORT_VLESS_BACKUP} и Shadowsocks — запасные, если основной заблокирован."
  if [[ "$ANSWER_WANT_MTPROTO" == "y" ]]; then
    echo
    echo -e "  ${C_GREEN}4.${C_RESET} Для Telegram — открой ссылку ${C_DIM}tg://proxy?...${C_RESET} с телефона"
    echo -e "     (или отсканируй QR выше), Telegram сам предложит включить прокси."
  fi
  if [[ "$ANSWER_CREATE_USER" == "y" ]] && [[ "$ANSWER_LOGIN_METHOD" != "password" ]]; then
    echo
    echo -e "  ${C_YELLOW}5.${C_RESET} Не забудь добавить свой SSH-публичный ключ в"
    echo -e "     ${C_DIM}/home/${ANSWER_USERNAME}/.ssh/authorized_keys${C_RESET} — иначе по ключу не зайти."
  fi
  echo
  echo -e "${C_DIM}${LINE_THIN}${C_RESET}"
  echo -e "${C_YELLOW}⚠  Сохрани данные выше (особенно пароль и ссылки) прямо сейчас —"
  echo -e "   повторно их показать скрипт не сможет.${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD}${LINE_BOLD}${C_RESET}"
}
# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  need_root
  print_banner
  collect_answers
  step "Создание директорий"
  make_dirs
  step "Установка системных пакетов"
  install_packages
  step "Установка Xray-core"
  install_xray
  step "Создание пользователя"
  create_user
  step "Генерация ключей и запись конфигурации Xray"
  generate_xray_data
  write_xray_config
  step "Запуск Xray и настройка firewall"
  start_xray
  setup_ufw
  setup_ssh_hardening
  step "Telegram MTProto-прокси"
  install_mtproto
  step "Подготовка ссылок"
  write_client_links "$ipserv"
  write_server_readme
  sleep 1
  final_output
}
main "$@"
