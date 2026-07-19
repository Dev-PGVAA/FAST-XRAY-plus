#!/bin/bash
# ============================================================================
#  FastXray FULL v2 — установка VPN-сервера на чистый Ubuntu/Debian VPS
#  Xray-core (VLESS+REALITY, Shadowsocks) + Telegram MTProto + опционально:
#  Cloudflare WARP (анти-гео-детект), мониторинг, харденинг, BBR
#
#  Исправленная версия. Основные фиксы против v1:
#   - убран markdown-мусор в доменах (скрипт снова валиден)
#   - устойчивый парсинг вывода `xray x25519` (новый и старый формат)
#   - узкий WARP-роутинг: через WARP идёт ТОЛЬКО гео-чувствительный Google,
#     а gstatic/googleapis/видео-CDN — напрямую (фикс "всё тормозит")
#   - watchdog проверяет РЕАЛЬНЫЙ выход через WARP (warp=on), а не строку статуса
#   - защита от локаута: root не отключается, пока не подтверждён вход
#   - секреты (пароль, ключи, ссылки) не остаются в world-readable логе
#   - mtg: устойчивый юнит (network-online, LimitNOFILE, авторестарт), fake-TLS host
#   - fail2ban с backend=systemd (иначе не стартует на Debian 12+/Ubuntu 24)
#   - ufw определяет реальный SSH-порт и не блокирует его (limit вместо allow)
#   - валидация конфига `xray -test` перед рестартом службы
# ============================================================================
set -euo pipefail
umask 077   # всё, что создаём, по умолчанию доступно только root

LOCATION_TAG="VPS"
LOG_FILE="/var/log/vpn-setup.log"
SCRIPT_DIR="/usr/local/etc/xray"
CLIENT_DIR="$SCRIPT_DIR/client_configs"
MTG_DIR="/usr/local/etc/mtg"
SERVER_IP_DEFAULT="0.0.0.0"
PORT_VLESS_MAIN=443
PORT_VLESS_BACKUP=8443
PORT_SS=2040
PORT_MTG=2096
WARP_SOCKS_PORT=40000
# Домен для маскировки MTProto под TLS. Можно поменять на любой крупный сайт,
# который НЕ заблокирован у тебя и реально отвечает по HTTPS.
MTG_FAKE_TLS_HOST="www.cloudflare.com"
# Опционально гнать TikTok через WARP (лечит "российскую" ленту).
# ВНИМАНИЕ: на телефоне TikTok определяет регион ещё и по SIM/региону устройства,
# поэтому со стороны сервера это помогает не всегда. Видео-CDN через WARP медленнее.
WARP_ROUTE_TIKTOK="y"

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE" 2>/dev/null || true
chmod 600 "$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# Оформление
# ---------------------------------------------------------------------------
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_CYAN='\033[1;36m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'; C_BLUE='\033[1;34m'; C_MAGENTA='\033[1;35m'; C_WHITE='\033[1;37m'
LINE_THIN="────────────────────────────────────────────────────────────"
LINE_BOLD="════════════════════════════════════════════════════════════"

TOTAL_STEPS=11
CUR_STEP=0
step() {
  CUR_STEP=$((CUR_STEP + 1))
  echo
  echo -e "${C_DIM}${LINE_THIN}${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}[${CUR_STEP}/${TOTAL_STEPS}]${C_RESET} ${C_WHITE}$1${C_RESET}"
  echo -e "${C_DIM}${LINE_THIN}${C_RESET}"
}
info()  { echo -e "  ${C_BLUE}i${C_RESET}  $1"; }
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
    echo -e "${C_RED}Запусти от root: sudo bash setup_vpn_full.sh${C_RESET}"
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
  echo -e "${C_DIM}  VLESS+REALITY · Shadowsocks · MTProto · WARP · Monitoring · Hardening${C_RESET}"
  echo -e "${C_CYAN}${C_BOLD}${LINE_BOLD}${C_RESET}"
  echo
}

# ---------------------------------------------------------------------------
# Чек-бокс меню (↑/↓ — навигация, Пробел — вкл/выкл, Enter — подтвердить)
# ---------------------------------------------------------------------------
CB_LABELS=(
  "Telegram MTProto-прокси"
  "Cloudflare WARP — гнать гео-чувствительный Google-трафик через WARP (фикс 'Казань вместо реальной локации')"
  "Мониторинг ресурсов: btop, htop, iotop, ncdu, vnstat, iftop"
  "fail2ban — бан за перебор паролей по SSH"
  "unattended-upgrades — автоустановка security-патчей ОС"
  "BBR — тюнинг TCP для более стабильного и быстрого туннеля"
)
CB_SELECTED=(1 1 1 1 1 1)

checkbox_menu() {
  local cur=0
  local n=${#CB_LABELS[@]}
  local key key2
  while true; do
    clear
    echo -e "${C_WHITE}${C_BOLD}Что установить дополнительно?${C_RESET}"
    echo -e "${C_DIM}↑/↓ — навигация · Пробел — вкл/выкл · Enter — подтвердить выбор${C_RESET}"
    echo
    for i in "${!CB_LABELS[@]}"; do
      local mark=" "
      [[ "${CB_SELECTED[$i]}" == "1" ]] && mark="x"
      local box="[${mark}]"
      if [[ $i -eq $cur ]]; then
        echo -e "  ${C_CYAN}${C_BOLD}➤ ${box} ${CB_LABELS[$i]}${C_RESET}"
      else
        if [[ "$mark" == "x" ]]; then
          echo -e "    ${C_GREEN}${box}${C_RESET} ${CB_LABELS[$i]}"
        else
          echo -e "    ${C_DIM}${box} ${CB_LABELS[$i]}${C_RESET}"
        fi
      fi
    done
    echo
    IFS= read -rsn1 key </dev/tty
    if [[ $key == $'\x1b' ]]; then
      # -t 0.01: одиночный ESC не подвешивает чтение следующих двух символов
      IFS= read -rsn2 -t 0.01 key2 </dev/tty || true
      case "$key2" in
        '[A') cur=$(( (cur - 1 + n) % n )) ;;   # up
        '[B') cur=$(( (cur + 1) % n )) ;;       # down
      esac
    elif [[ $key == "" ]]; then
      break   # Enter
    elif [[ $key == " " ]]; then
      if [[ "${CB_SELECTED[$cur]}" == "1" ]]; then CB_SELECTED[$cur]=0; else CB_SELECTED[$cur]=1; fi
    fi
  done
  clear
}

# ---------------------------------------------------------------------------
# Опрос — всё спрашиваем до начала установки
# ---------------------------------------------------------------------------
ANSWER_CREATE_USER="n"
ANSWER_USERNAME=""
ANSWER_USER_PASSWORD=""
ANSWER_LOGIN_METHOD=""
ANSWER_SSH_PUBKEY=""
ANSWER_DISABLE_ROOT_LOGIN="y"
WANT_MTPROTO="n"; WANT_WARP="n"; WANT_MONITORING="n"; WANT_FAIL2BAN="n"; WANT_UNATTENDED="n"; WANT_BBR="n"

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

    # Пароль (если вход не только по ключу)
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
      # для sudo всё равно нужен системный пароль
      ANSWER_USER_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
    fi

    # SSH-ключ (если вход по ключу) — просим вставить СЕЙЧАС, чтобы не потерять доступ
    if [[ "$ANSWER_LOGIN_METHOD" == "key" || "$ANSWER_LOGIN_METHOD" == "both" ]]; then
      echo
      echo -e "  ${C_DIM}Вставь свой ПУБЛИЧНЫЙ SSH-ключ (одна строка вида 'ssh-ed25519 AAAA... comment').${C_RESET}"
      echo -e "  ${C_DIM}Он нужен прямо сейчас, иначе после отключения входа по паролю ты не зайдёшь.${C_RESET}"
      while true; do
        local key_in
        read -r -p "$(echo -e "  ${C_MAGENTA}?${C_RESET} SSH public key (Enter — пропустить): ")" key_in </dev/tty
        if [[ -z "$key_in" ]]; then
          if [[ "$ANSWER_LOGIN_METHOD" == "key" ]]; then
            warn "Без ключа вход 'только по ключу' невозможен. Вставь ключ или выбери другой метод."
            if ask_yn "Продолжить БЕЗ ключа (тогда вход по ключу настроишь вручную позже)?" "n"; then
              break
            fi
            continue
          fi
          break
        fi
        if [[ "$key_in" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-) ]]; then
          ANSWER_SSH_PUBKEY="$key_in"; ok "Ключ принят."; break
        fi
        warn "Не похоже на публичный ключ (ожидается 'ssh-ed25519 ...' / 'ssh-rsa ...')."
      done
    fi
  fi

  echo
  if ask_yn "Отключить root login по SSH?" "y"; then
    ANSWER_DISABLE_ROOT_LOGIN="y"
  else
    ANSWER_DISABLE_ROOT_LOGIN="n"
  fi

  # ---- Защита от локаута ----
  # Отключаем root только если гарантированно останется другой способ зайти.
  if [[ "$ANSWER_DISABLE_ROOT_LOGIN" == "y" ]]; then
    local have_login="n"
    if [[ "$ANSWER_CREATE_USER" == "y" ]]; then
      if [[ "$ANSWER_LOGIN_METHOD" == "password" || "$ANSWER_LOGIN_METHOD" == "both" ]]; then
        have_login="y"
      fi
      if [[ "$ANSWER_LOGIN_METHOD" == "key" && -n "$ANSWER_SSH_PUBKEY" ]]; then
        have_login="y"
      fi
      if [[ "$ANSWER_LOGIN_METHOD" == "both" && -n "$ANSWER_SSH_PUBKEY" ]]; then
        have_login="y"
      fi
    fi
    if [[ "$have_login" != "y" ]]; then
      warn "Отключение root login оставит тебя БЕЗ доступа к серверу (нет рабочего пользователя/ключа/пароля)."
      warn "root login НЕ будет отключён, чтобы не потерять сервер."
      ANSWER_DISABLE_ROOT_LOGIN="n"
    fi
  fi

  echo
  ok "Основные настройки получены."
  echo
  read -r -p "$(echo -e "  ${C_MAGENTA}?${C_RESET} Нажми Enter, чтобы перейти к выбору дополнительных компонентов...")" _ </dev/tty
  checkbox_menu

  [[ "${CB_SELECTED[0]}" == "1" ]] && WANT_MTPROTO="y"
  [[ "${CB_SELECTED[1]}" == "1" ]] && WANT_WARP="y"
  [[ "${CB_SELECTED[2]}" == "1" ]] && WANT_MONITORING="y"
  [[ "${CB_SELECTED[3]}" == "1" ]] && WANT_FAIL2BAN="y"
  [[ "${CB_SELECTED[4]}" == "1" ]] && WANT_UNATTENDED="y"
  [[ "${CB_SELECTED[5]}" == "1" ]] && WANT_BBR="y"

  echo -e "${C_WHITE}${C_BOLD}Выбрано:${C_RESET}"
  for i in "${!CB_LABELS[@]}"; do
    if [[ "${CB_SELECTED[$i]}" == "1" ]]; then
      echo -e "  ${C_GREEN}✓${C_RESET} ${CB_LABELS[$i]}"
    else
      echo -e "  ${C_DIM}✗ ${CB_LABELS[$i]}${C_RESET}"
    fi
  done
  echo
  ok "Начинаю установку."
}

# ---------------------------------------------------------------------------
# Системные шаги
# ---------------------------------------------------------------------------
get_server_ip() {
  local ip
  ip="$(curl -s -4 --max-time 5 https://api.ipify.org || true)"
  [[ -z "${ip:-}" ]] && ip="$(curl -s -4 --max-time 5 https://ifconfig.me || true)"
  [[ -z "${ip:-}" ]] && ip="$(hostname -I | awk '{print $1}' || true)"
  [[ -z "${ip:-}" ]] && ip="$SERVER_IP_DEFAULT"
  echo "$ip"
}

detect_ssh_port() {
  local p
  p="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)"
  [[ -z "$p" ]] && p=22
  echo "$p"
}

make_dirs() {
  mkdir -p "$SCRIPT_DIR" "$CLIENT_DIR" "$MTG_DIR"
  chmod 700 "$SCRIPT_DIR" "$CLIENT_DIR" "$MTG_DIR"
  ok "Директории готовы"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt update -qq
  apt install -y -qq jq curl wget ca-certificates openssl qrencode gnupg lsb-release \
      apt-transport-https gettext-base iproute2 dnsutils > /dev/null
  ok "Базовые системные пакеты установлены"

  if [[ "$WANT_MONITORING" == "y" ]]; then
    apt install -y -qq btop htop iotop ncdu vnstat iftop > /dev/null || \
      apt install -y -qq htop iotop ncdu vnstat iftop > /dev/null || true
    systemctl enable --now vnstat > /dev/null 2>&1 || true
    ok "Утилиты мониторинга установлены"
  fi
  if [[ "$WANT_FAIL2BAN" == "y" ]]; then
    apt install -y -qq fail2ban > /dev/null
    ok "fail2ban установлен"
  fi
  if [[ "$WANT_UNATTENDED" == "y" ]]; then
    apt install -y -qq unattended-upgrades apt-listchanges > /dev/null
    ok "unattended-upgrades установлен"
  fi
}

install_xray() {
  if command -v xray &>/dev/null; then
    ok "Xray уже установлен ($(xray version 2>/dev/null | head -n1)), пропускаю"
    return
  fi
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null
  if ! command -v xray &>/dev/null; then
    fail "Xray не установился"
    exit 1
  fi
  ok "Xray-core установлен ($(xray version 2>/dev/null | head -n1))"
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
    install -d -m 700 -o "$username" -g "$username" "/home/$username/.ssh"
    touch "/home/$username/.ssh/authorized_keys"
    if [[ -n "$ANSWER_SSH_PUBKEY" ]]; then
      if ! grep -qF "$ANSWER_SSH_PUBKEY" "/home/$username/.ssh/authorized_keys" 2>/dev/null; then
        echo "$ANSWER_SSH_PUBKEY" >> "/home/$username/.ssh/authorized_keys"
      fi
      ok "SSH-ключ добавлен в authorized_keys"
    fi
    chmod 600 "/home/$username/.ssh/authorized_keys"
    chown -R "$username:$username" "/home/$username/.ssh"
  fi
}

# --- Устойчивый парсинг ключей REALITY (поддержка нового и старого формата) ---
parse_x25519() {
  local out="$1"
  # Приватный ключ: "PrivateKey:" (новый) или "Private key:" (старый)
  xray_privateKey_vrv="$(sed -nE 's/.*[Pp]rivate[ _]?[Kk]ey:[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' <<< "$out" | head -n1)"
  # Публичный ключ: в новых версиях это "Password:", в старых "Public key:"/"PublicKey:"
  xray_publicKey_vrv="$(sed -nE 's/.*[Pp]assword:[[:space:]]*([A-Za-z0-9_-]+).*/\1/p'          <<< "$out" | head -n1)"
  [[ -z "$xray_publicKey_vrv" ]] && \
  xray_publicKey_vrv="$(sed -nE 's/.*[Pp]ublic[ _]?[Kk]ey:[[:space:]]*([A-Za-z0-9_-]+).*/\1/p' <<< "$out" | head -n1)"
}

generate_xray_data() {
  xray_uuid_vrv="$(xray uuid)"

  # Домены-цели для REALITY (SNI). Крупные сайты с TLS1.3+H2, обычно доступные из РФ.
  # При желании поменяй на свои — главное, чтобы домен был доступен и отвечал по HTTPS.
  local domains=(
    www.microsoft.com www.samsung.com www.nvidia.com www.amd.com
    www.icloud.com www.bing.com www.tesla.com www.cisco.com
  )
  xray_dest_vrv="${domains[$RANDOM % ${#domains[@]}]}"
  xray_dest_vrv222="${domains[$RANDOM % ${#domains[@]}]}"
  while [[ "$xray_dest_vrv222" == "$xray_dest_vrv" ]]; do
    xray_dest_vrv222="${domains[$RANDOM % ${#domains[@]}]}"
  done

  local key_output
  key_output="$(xray x25519)"
  parse_x25519 "$key_output"

  # Если публичный ключ не распарсился (в некоторых версиях x25519 его не печатает) —
  # пробуем восстановить из приватного.
  if [[ -z "${xray_publicKey_vrv:-}" && -n "${xray_privateKey_vrv:-}" ]]; then
    local recompute
    recompute="$(xray x25519 -i "$xray_privateKey_vrv" 2>/dev/null || true)"
    parse_x25519 "$recompute"
  fi

  if [[ -z "${xray_privateKey_vrv:-}" || -z "${xray_publicKey_vrv:-}" ]]; then
    fail "Не удалось разобрать вывод 'xray x25519'. Вывод был:"
    echo "$key_output"
    exit 1
  fi

  xray_shortIds_vrv="$(openssl rand -hex 8)"
  xray_sspasw_vrv="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)"
  ipserv="$(get_server_ip)"

  export xray_uuid_vrv xray_dest_vrv xray_dest_vrv222 xray_privateKey_vrv \
         xray_publicKey_vrv xray_shortIds_vrv xray_sspasw_vrv ipserv
  ok "Ключи и параметры сгенерированы"
}

write_xray_config() {
  # envsubst с явным списком переменных — чтобы не тронуть чужие $... в JSON
  local vars='$PORT_VLESS_MAIN $PORT_VLESS_BACKUP $PORT_SS $xray_uuid_vrv $xray_dest_vrv $xray_dest_vrv222 $xray_privateKey_vrv $xray_shortIds_vrv $xray_sspasw_vrv'
  export PORT_VLESS_MAIN PORT_VLESS_BACKUP PORT_SS
  cat << 'EOF' | envsubst "$vars" > "$SCRIPT_DIR/config.json"
{
  "log": { "dnsLog": false, "loglevel": "warning" },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query",
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
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "domain": ["geosite:category-ads-all", "geosite:win-spy"], "outboundTag": "block" },
      { "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF
  chmod 600 "$SCRIPT_DIR/config.json"
  ok "Конфиг Xray записан"
}

patch_xray_with_warp() {
  if [[ "$WANT_WARP" != "y" ]]; then
    return
  fi

  # 1) WARP-outbound (SOCKS5 на localhost, поднимается warp-svc в proxy-режиме)
  if ! jq -e '.outbounds[] | select(.tag=="warp")' "$SCRIPT_DIR/config.json" > /dev/null; then
    jq --argjson port "$WARP_SOCKS_PORT" '.outbounds += [{
      "tag": "warp",
      "protocol": "socks",
      "settings": { "servers": [{ "address": "127.0.0.1", "port": $port }] }
    }]' "$SCRIPT_DIR/config.json" > /tmp/xray_tmp.json && mv /tmp/xray_tmp.json "$SCRIPT_DIR/config.json"
  fi

  # 2) Роутинг. Порядок ВАЖЕН — первое совпадение побеждает.
  #    Идея: через WARP гоним ТОЛЬКО то, что реально геолоцируется (сам google.com,
  #    аккаунты, поиск, карты, play, gemini). А тяжёлое и встроенное везде
  #    (gstatic, googleapis, youtube/видео) — НАПРЯМУЮ, иначе тормозит весь интернет.
  #
  #    Собираем массив правил целиком и ПЕРЕЗАПИСЫВАЕМ routing.rules
  #    (идемпотентно: повторный запуск даёт тот же результат, без дублей).
  local tiktok_rule='[]'
  if [[ "$WARP_ROUTE_TIKTOK" == "y" ]]; then
    tiktok_rule='[{ "domain": ["geosite:tiktok"], "outboundTag": "warp" }]'
  fi

  jq --argjson tiktok "$tiktok_rule" '
    .routing.domainStrategy = "IPIfNonMatch"
    | .routing.rules = (
      [
        # блокировки
        { "domain": ["geosite:category-ads-all", "geosite:win-spy"], "outboundTag": "block" },
        { "ip": ["geoip:private"], "outboundTag": "block" },

        # тяжёлое видео Google — всегда напрямую (WARP не тянет по скорости)
        { "domain": ["domain:youtube.com","domain:googlevideo.com","domain:ytimg.com","domain:youtu.be","domain:ggpht.com","domain:yt3.ggpht.com","domain:youtubei.googleapis.com"],
          "outboundTag": "direct" },

        # CDN/статика/аналитика Google — встроены в пол-интернета, гео не требуют → напрямую
        { "domain": ["domain:gstatic.com","domain:googleapis.com","domain:googleusercontent.com","domain:googletagmanager.com","domain:google-analytics.com","domain:googlesyndication.com","domain:gvt1.com","domain:gvt2.com","domain:doubleclick.net"],
          "outboundTag": "direct" }
      ]
      # гео-чувствительный Google (поиск, аккаунты, карты, play, gemini) → WARP
      + [ { "domain": ["geosite:google"], "outboundTag": "warp" } ]
      # опционально TikTok → WARP
      + $tiktok
    )
  ' "$SCRIPT_DIR/config.json" > /tmp/xray_tmp.json && mv /tmp/xray_tmp.json "$SCRIPT_DIR/config.json"
  chmod 600 "$SCRIPT_DIR/config.json"

  ok "WARP-роутинг: гео-Google → WARP; gstatic/googleapis/видео → напрямую$( [[ "$WARP_ROUTE_TIKTOK" == "y" ]] && echo '; TikTok → WARP' )"
}

validate_xray_config() {
  if xray run -test -config "$SCRIPT_DIR/config.json" >/tmp/xray_test.log 2>&1; then
    ok "Конфиг Xray прошёл проверку (xray -test)"
  else
    fail "Конфиг Xray не прошёл проверку:"
    tail -n 20 /tmp/xray_test.log
    exit 1
  fi
}

start_xray() {
  systemctl enable xray --now > /dev/null 2>&1 || true
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
  # ufw ставим только сейчас, чтобы не тянуть его без нужды
  apt install -y -qq ufw > /dev/null
  local ssh_port; ssh_port="$(detect_ssh_port)"

  local busy_ports=() p
  for p in "$PORT_VLESS_MAIN" "$PORT_VLESS_BACKUP" "$PORT_SS"; do
    if ss -H -tln "sport = :$p" 2>/dev/null | grep -q .; then busy_ports+=("$p"); fi
  done
  if [[ "$WANT_MTPROTO" == "y" ]] && ss -H -tln "sport = :$PORT_MTG" 2>/dev/null | grep -q .; then
    busy_ports+=("$PORT_MTG")
  fi
  if [[ ${#busy_ports[@]} -gt 0 ]]; then
    warn "Уже слушаются порты: ${busy_ports[*]} (это нормально при повторном запуске)."
  fi

  ufw default deny incoming > /dev/null
  ufw default allow outgoing > /dev/null
  ufw limit "${ssh_port}/tcp" comment 'ssh (rate-limited)' > /dev/null
  ufw allow "${PORT_VLESS_MAIN}/tcp" comment 'xray vless reality' > /dev/null
  ufw allow "${PORT_VLESS_BACKUP}/tcp" comment 'xray vless reality backup' > /dev/null
  ufw allow "${PORT_SS}/tcp" comment 'xray shadowsocks' > /dev/null
  if [[ "$WANT_MTPROTO" == "y" ]]; then
    ufw allow "${PORT_MTG}/tcp" comment 'telegram mtproto' > /dev/null
  fi
  ufw --force enable > /dev/null
  ok "Firewall (ufw) настроен; SSH-порт ${ssh_port} разрешён (limit)"
}

setup_ssh_hardening() {
  local ssh_service="ssh"
  systemctl list-unit-files | grep -q '^sshd\.service' && ssh_service="sshd"
  if [[ "$ANSWER_DISABLE_ROOT_LOGIN" == "y" ]]; then
    cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config || true
    grep -q '^PermitRootLogin ' /etc/ssh/sshd_config || echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
    if sshd -t; then
      systemctl restart "$ssh_service"
      ok "SSH: root login отключён"
    else
      warn "sshd -t не прошёл, откатываю изменения, root login НЕ трогаю"
      sed -i 's/^PermitRootLogin no/#PermitRootLogin prohibit-password/' /etc/ssh/sshd_config || true
    fi
  else
    info "SSH: root login не отключаю"
  fi
}

install_mtproto() {
  if [[ "$WANT_MTPROTO" != "y" ]]; then
    info "MTProto-прокси пропущен (по выбору)"
    return
  fi
  if ! command -v mtg &>/dev/null; then
    local mtg_version mtg_url arch
    arch="amd64"; [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
    mtg_version="$(curl -s --max-time 10 https://api.github.com/repos/9seconds/mtg/releases/latest | jq -r '.tag_name' || true)"
    if [[ -n "${mtg_version:-}" && "$mtg_version" != "null" ]]; then
      mtg_url="https://github.com/9seconds/mtg/releases/download/${mtg_version}/mtg-${mtg_version#v}-linux-${arch}.tar.gz"
      if curl -sL --max-time 30 -o /tmp/mtg.tar.gz "$mtg_url" && tar -tzf /tmp/mtg.tar.gz &>/dev/null; then
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
    WANT_MTPROTO="n"
    return
  fi

  mtg_secret_vrv="$(mtg generate-secret --hex "$MTG_FAKE_TLS_HOST")"
  export mtg_secret_vrv
  cat > "$MTG_DIR/mtg.toml" << EOF
secret = "${mtg_secret_vrv}"
bind-to = "0.0.0.0:${PORT_MTG}"
EOF
  # секрет всё равно раздаётся клиентам в tg://-ссылке, поэтому 644 ок (нужно для DynamicUser)
  chmod 644 "$MTG_DIR/mtg.toml"

  cat > /etc/systemd/system/mtg.service << EOF
[Unit]
Description=mtg - Telegram MTProto proxy
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/mtg run ${MTG_DIR}/mtg.toml
Restart=always
RestartSec=3
TimeoutStopSec=15
KillMode=mixed
LimitNOFILE=1048576
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable mtg --now > /dev/null 2>&1 || true
  systemctl restart mtg
  sleep 1
  if systemctl is-active --quiet mtg; then
    ok "MTProto-прокси (mtg) запущен на порту ${PORT_MTG}"
  else
    fail "mtg не стартовал, смотри: journalctl -u mtg -n 50"
    WANT_MTPROTO="n"
  fi
}

install_warp() {
  if [[ "$WANT_WARP" != "y" ]]; then
    info "Cloudflare WARP пропущен (по выбору)"
    return
  fi
  if ! command -v warp-cli &>/dev/null; then
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
      | tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null
    apt update -qq
    apt install -y -qq cloudflare-warp > /dev/null
  fi

  systemctl enable warp-svc --now > /dev/null 2>&1 || true
  sleep 2

  # --accept-tos подавляет интерактивный вопрос о TOS в новых версиях warp-cli
  if ! warp-cli --accept-tos registration show &>/dev/null; then
    warp-cli --accept-tos registration new > /dev/null 2>&1 || \
    warp-cli --accept-tos register     > /dev/null 2>&1 || true
  fi
  warp-cli --accept-tos mode proxy            > /dev/null 2>&1 || true
  warp-cli --accept-tos proxy port "$WARP_SOCKS_PORT" > /dev/null 2>&1 || true
  warp-cli --accept-tos connect               > /dev/null 2>&1 || true
  sleep 3

  # Реальная проверка: именно выход через WARP, а не строка статуса
  if curl -x "socks5h://127.0.0.1:${WARP_SOCKS_PORT}" -s --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q 'warp=on'; then
    ok "Cloudflare WARP подключен, выход через WARP подтверждён (SOCKS5 127.0.0.1:${WARP_SOCKS_PORT})"
  else
    warn "WARP установлен, но выход через него не подтвердился с первого раза."
    warn "Проверь: warp-cli status ; curl -x socks5h://127.0.0.1:${WARP_SOCKS_PORT} https://www.cloudflare.com/cdn-cgi/trace"
    warn "Watchdog (ниже) попробует переподключить его автоматически."
  fi
}

warp_watchdog() {
  if [[ "$WANT_WARP" != "y" ]]; then
    return
  fi
  cat > /usr/local/bin/warp-watchdog.sh << EOF
#!/bin/bash
# Проверяем РЕАЛЬНЫЙ выход через WARP, а не строку "Connected".
PORT=${WARP_SOCKS_PORT}
if ! curl -x "socks5h://127.0.0.1:\${PORT}" -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q 'warp=on'; then
  logger "warp-watchdog: WARP down, reconnecting"
  warp-cli --accept-tos connect >/dev/null 2>&1 || true
  sleep 3
  if ! curl -x "socks5h://127.0.0.1:\${PORT}" -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q 'warp=on'; then
    logger "warp-watchdog: still down, restarting warp-svc"
    systemctl restart warp-svc >/dev/null 2>&1 || true
    sleep 5
    warp-cli --accept-tos connect >/dev/null 2>&1 || true
  fi
fi
EOF
  chmod +x /usr/local/bin/warp-watchdog.sh

  cat > /etc/systemd/system/warp-watchdog.service << 'EOF'
[Unit]
Description=WARP connection watchdog
After=warp-svc.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-watchdog.sh
EOF

  cat > /etc/systemd/system/warp-watchdog.timer << 'EOF'
[Unit]
Description=Run WARP watchdog every 30 seconds

[Timer]
OnBootSec=1min
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now warp-watchdog.timer > /dev/null 2>&1 || true
  ok "WARP watchdog включен (реальная проверка выхода каждые 30 сек)"
}

setup_fail2ban() {
  if [[ "$WANT_FAIL2BAN" != "y" ]]; then
    return
  fi
  local ssh_port; ssh_port="$(detect_ssh_port)"
  # backend=systemd обязателен на Debian 12+/Ubuntu 24 (нет /var/log/auth.log)
  cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
backend = systemd

[sshd]
enabled = true
port = ${ssh_port}
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  systemctl enable fail2ban > /dev/null 2>&1 || true
  systemctl restart fail2ban > /dev/null 2>&1 || true
  if systemctl is-active --quiet fail2ban; then
    ok "fail2ban включен: бан на 1 час после 5 неудач за 10 минут (порт ${ssh_port})"
  else
    warn "fail2ban не стартовал, смотри: journalctl -u fail2ban -n 30"
  fi
}

setup_unattended_upgrades() {
  if [[ "$WANT_UNATTENDED" != "y" ]]; then
    return
  fi
  echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
  dpkg-reconfigure -f noninteractive unattended-upgrades > /dev/null 2>&1 || true
  ok "unattended-upgrades включен (security-патчи будут ставиться сами)"
}

setup_bbr() {
  if [[ "$WANT_BBR" != "y" ]]; then
    return
  fi
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    ok "BBR уже включен"
    return
  fi
  # идемпотентно: не дублируем строки при повторном запуске
  if ! grep -q 'setup_vpn_full.sh: BBR' /etc/sysctl.conf; then
    cat >> /etc/sysctl.conf << 'EOF'
# --- setup_vpn_full.sh: BBR for better VPN throughput ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  fi
  sysctl -p > /dev/null 2>&1 || true
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    ok "BBR включен — туннель стабильнее под нагрузкой"
  else
    warn "Не удалось включить BBR (возможно, ядро не поддерживает)"
  fi
}

write_client_links() {
  local server_ip="$1"
  local tag_encoded
  tag_encoded="$(printf '%s' "$LOCATION_TAG" | jq -sRr @uri)"

  ss_link_b64="$(printf 'chacha20-ietf-poly1305:%s' "$xray_sspasw_vrv" | base64 -w 0)"

  vless_main_link="vless://${xray_uuid_vrv}@${server_ip}:${PORT_VLESS_MAIN}?security=reality&sni=${xray_dest_vrv}&fp=chrome&pbk=${xray_publicKey_vrv}&sid=${xray_shortIds_vrv}&type=tcp&flow=xtls-rprx-vision&encryption=none&spx=%2F#${tag_encoded}%20VLESS%20${PORT_VLESS_MAIN}"
  vless_backup_link="vless://${xray_uuid_vrv}@${server_ip}:${PORT_VLESS_BACKUP}?security=reality&sni=${xray_dest_vrv222}&fp=chrome&pbk=${xray_publicKey_vrv}&sid=${xray_shortIds_vrv}&type=tcp&flow=xtls-rprx-vision&encryption=none&spx=%2F#${tag_encoded}%20VLESS%20${PORT_VLESS_BACKUP}%20backup"
  ss_link="ss://${ss_link_b64}@${server_ip}:${PORT_SS}#${tag_encoded}%20Shadowsocks"
  export vless_main_link vless_backup_link ss_link

  if [[ "$WANT_MTPROTO" == "y" ]]; then
    mtg_tg_link="tg://proxy?server=${server_ip}&port=${PORT_MTG}&secret=${mtg_secret_vrv}"
    mtg_tme_link="https://t.me/proxy?server=${server_ip}&port=${PORT_MTG}&secret=${mtg_secret_vrv}"
    export mtg_tg_link mtg_tme_link
  fi

  all_links_b64="$(
    {
      printf '%s\n' "$vless_main_link" "$vless_backup_link" "$ss_link"
      if [[ "$WANT_MTPROTO" == "y" ]]; then
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
    if [[ "$WANT_MTPROTO" == "y" ]]; then
      echo
      echo "Telegram MTProto (порт ${PORT_MTG}):"
      echo "${mtg_tg_link}"
      echo "${mtg_tme_link}"
    fi
    echo
    echo "Компоненты:"
    echo "  WARP (гео-Google):      $( [[ "$WANT_WARP" == "y" ]] && echo да || echo нет )"
    echo "  Мониторинг:             $( [[ "$WANT_MONITORING" == "y" ]] && echo да || echo нет )"
    echo "  fail2ban:               $( [[ "$WANT_FAIL2BAN" == "y" ]] && echo да || echo нет )"
    echo "  unattended-upgrades:    $( [[ "$WANT_UNATTENDED" == "y" ]] && echo да || echo нет )"
    echo "  BBR:                    $( [[ "$WANT_BBR" == "y" ]] && echo да || echo нет )"
    echo
    echo "Все конфиги в одной base64-строке:"
    echo "${all_links_b64}"
    echo "==========================================="
  } > "$CLIENT_DIR/README.txt"
  chmod 600 "$CLIENT_DIR/README.txt"
  ok "README сохранён в ${CLIENT_DIR}/README.txt (chmod 600)"
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
  if [[ "$WANT_MTPROTO" == "y" ]]; then
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
  echo -e "${C_WHITE}${C_BOLD}🧩 Дополнительные компоненты${C_RESET}"
  echo -e "  WARP (гео-Google через Cloudflare):       $( [[ "$WANT_WARP" == "y" ]] && echo -e "${C_GREEN}включен${C_RESET}" || echo -e "${C_DIM}не устанавливался${C_RESET}" )"
  echo -e "  Мониторинг (btop/htop/iotop/ncdu/vnstat): $( [[ "$WANT_MONITORING" == "y" ]] && echo -e "${C_GREEN}установлен${C_RESET}" || echo -e "${C_DIM}не устанавливался${C_RESET}" )"
  echo -e "  fail2ban:                                 $( [[ "$WANT_FAIL2BAN" == "y" ]] && echo -e "${C_GREEN}включен${C_RESET}" || echo -e "${C_DIM}не устанавливался${C_RESET}" )"
  echo -e "  unattended-upgrades:                      $( [[ "$WANT_UNATTENDED" == "y" ]] && echo -e "${C_GREEN}включен${C_RESET}" || echo -e "${C_DIM}не устанавливался${C_RESET}" )"
  echo -e "  BBR:                                      $( [[ "$WANT_BBR" == "y" ]] && echo -e "${C_GREEN}включен${C_RESET}" || echo -e "${C_DIM}не устанавливался${C_RESET}" )"
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
        echo -e "  Вход:   по SSH-ключу — ${C_DIM}ssh ${ANSWER_USERNAME}@${ipserv}${C_RESET}"
        [[ -z "$ANSWER_SSH_PUBKEY" ]] && echo -e "  ${C_YELLOW}Ключ не добавлен! Добавь его в /home/${ANSWER_USERNAME}/.ssh/authorized_keys${C_RESET}"
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
  echo -e "  README с данными: ${CLIENT_DIR}/README.txt  ${C_DIM}(chmod 600)${C_RESET}"
  echo -e "  Лог установки:    ${LOG_FILE}  ${C_DIM}(chmod 600)${C_RESET}"
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
  echo -e "  ${C_GREEN}2.${C_RESET} В клиенте: ${C_BOLD}«Добавить из буфера/по ссылке»${C_RESET} — вставь ссылку,"
  echo -e "     либо ${C_BOLD}«Импорт base64»${C_RESET} — вставь общий блок."
  echo
  echo -e "  ${C_GREEN}3.${C_RESET} Основной — VLESS+REALITY (${PORT_VLESS_MAIN}); ${PORT_VLESS_BACKUP} и Shadowsocks — запасные."
  if [[ "$WANT_MTPROTO" == "y" ]]; then
    echo
    echo -e "  ${C_GREEN}4.${C_RESET} Telegram — открой ссылку ${C_DIM}tg://proxy?...${C_RESET} с телефона (или QR выше)."
    echo -e "     ${C_DIM}Если MTProto будет отваливаться из-за DPI — гоняй Telegram через VLESS,${C_RESET}"
    echo -e "     ${C_DIM}а MTProto держи как аварийный запасной.${C_RESET}"
  fi
  echo
  echo -e "${C_YELLOW}⚠  Сохрани данные выше (пароль и ссылки) прямо сейчас.${C_RESET}"
  echo -e "${C_DIM}   Всё также лежит в ${CLIENT_DIR}/README.txt${C_RESET}"
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

  step "Cloudflare WARP"
  install_warp
  patch_xray_with_warp

  step "Проверка конфига, запуск Xray и firewall"
  validate_xray_config
  start_xray
  setup_ufw
  setup_ssh_hardening

  step "Telegram MTProto-прокси"
  install_mtproto

  step "WARP watchdog, fail2ban, автообновления, BBR"
  warp_watchdog
  setup_fail2ban
  setup_unattended_upgrades
  setup_bbr

  step "Подготовка ссылок"
  write_client_links "$ipserv"
  write_server_readme

  sleep 1
  final_output
}
main "$@"
