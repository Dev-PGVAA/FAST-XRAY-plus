#!/usr/bin/env bash
# ============================================================================
#  FastXray v2.1.1 — установка и обслуживание VPN-сервера
#  Исправлено: парсинг xray x25519 (Password / Public key)
#  Xray-core (VLESS+REALITY) · Shadowsocks (опц.) · Telegram MTProto (опц.)
#  Debian / Ubuntu.   Запуск:   sudo bash setup_vpn.sh
#
#  Что умеет:
#   • чистая установка ИЛИ исправление уже работающей установки (ключи и ссылки
#     сохраняются) — в том числе установки старой версии этого скрипта;
#   • смена пароля root (свой или сгенерированный);
#   • BBR + fq, conntrack, keepalive, отключение нерабочего IPv6, swap, лимит журнала;
#   • автоперезапуск xray/mtg и сторожевой таймер (проверка порта каждые 2 минуты);
#   • автоподбор лучшего домена маскировки REALITY (TLS 1.3 + HTTP/2);
#   • безопасный SSH/ufw (без самоблокировки), fail2ban;
#   • маршрутизация «Россия напрямую, остальное через VPN, реклама заблокирована,
#     Gemini и AI-сервисы через VPN» — готовая ссылка для Happ (vpn routing);
#   • команда `vpn` для повседневной работы: show, add, del, routing, route, status, diag...
# ============================================================================
set -Eeuo pipefail

VERSION="2.1.1"
LOG_FILE="/var/log/fastxray-setup.log"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CFG="${XRAY_DIR}/config.json"
STATE_DIR="/usr/local/etc/fastxray"
STATE_FILE="${STATE_DIR}/state.env"
MTG_DIR="/usr/local/etc/mtg"
MTG_CFG="${MTG_DIR}/mtg.toml"
VPN_BIN="/usr/local/bin/vpn"
HEALTH_BIN="/usr/local/bin/fastxray-health"

DEF_PORT_MAIN=443
DEF_PORT_BACKUP=8443
DEF_PORT_SS=2040
DEF_PORT_MTG=2096
MTG_FAKE_TLS_HOST="www.cloudflare.com"
BLOCK_TORRENT="y"          # блокировать BitTorrent (иначе хостер может прислать abuse)

# Кандидаты для маскировки REALITY: из них выбираются самые быстрые с TLS 1.3 + h2
REALITY_CANDIDATES=(
  www.microsoft.com www.apple.com www.samsung.com www.nvidia.com
  addons.mozilla.org www.amd.com www.oracle.com dl.google.com
  www.cloudflare.com www.asus.com www.lenovo.com www.dell.com
  www.intel.com www.hp.com
)

# ---------------------------------------------------------------------------
# Оформление и вывод. Все сообщения идут в stderr (и в лог без цветов),
# stdout остаётся чистым — через него возвращаются значения функций.
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
  N=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'; CY=$'\033[1;36m'; GR=$'\033[1;32m'
  YE=$'\033[1;33m'; RD=$'\033[1;31m'; BL=$'\033[1;34m'; MG=$'\033[1;35m'; WH=$'\033[1;37m'
else
  N=''; B=''; D=''; CY=''; GR=''; YE=''; RD=''; BL=''; MG=''; WH=''
fi
LINE="────────────────────────────────────────────────────────────"
TOTAL_STEPS=0
CUR_STEP=0

emit() {
  printf '%b\n' "$1" >&2
  printf '%b\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE" 2>/dev/null || true
}
step() {
  CUR_STEP=$((CUR_STEP + 1))
  emit ""
  emit "${D}${LINE}${N}"
  emit "${CY}${B}[${CUR_STEP}/${TOTAL_STEPS}]${N} ${WH}$1${N}"
  emit "${D}${LINE}${N}"
}
info() { emit "  ${BL}ℹ${N}  $1"; }
ok()   { emit "  ${GR}✓${N}  $1"; }
warn() { emit "  ${YE}⚠${N}  $1"; }
fail() { emit "  ${RD}✗${N}  $1"; }
die()  { fail "$1"; exit 1; }

trap 'rc=$?; printf "\n%s\n" "${RD}❌ Ошибка в строке ${LINENO} (код ${rc}). Подробности: ${LOG_FILE}${N}" >&2; exit "$rc"' ERR

# ---------------------------------------------------------------------------
# Ввод
# ---------------------------------------------------------------------------
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

ask() {  # ask "вопрос" ["по умолчанию"]  → значение в stdout
  local prompt="$1" def="${2:-}" reply=""
  if [[ -n "$def" ]]; then
    printf '  %s?%s %s %s[%s]%s: ' "$MG" "$N" "$prompt" "$D" "$def" "$N" >/dev/tty
  else
    printf '  %s?%s %s: ' "$MG" "$N" "$prompt" >/dev/tty
  fi
  IFS= read -r reply </dev/tty || true
  reply="$(trim "$reply")"
  printf '%s\n' "${reply:-$def}"
}

ask_yn() {  # ask_yn "вопрос" y|n  → код возврата 0 = да
  local prompt="$1" def="${2:-y}" hint reply
  if [[ "$def" == "y" ]]; then hint="Д/н"; else hint="д/Н"; fi
  while true; do
    printf '  %s?%s %s %s[%s]%s: ' "$MG" "$N" "$prompt" "$D" "$hint" "$N" >/dev/tty
    IFS= read -r reply </dev/tty || true
    reply="$(trim "${reply:-$def}")"
    case "$reply" in
      y|Y|yes|YES|Yes|д|Д|да|Да|ДА) return 0 ;;
      n|N|no|NO|No|н|Н|нет|Нет|НЕТ) return 1 ;;
    esac
  done
}

REPLY_PW=""
read_new_password() {  # read_new_password "для кого" → REPLY_PW
  local who="$1" p1 p2
  while true; do
    printf '  %s?%s Новый пароль для %s (мин. 10 символов): ' "$MG" "$N" "$who" >/dev/tty
    IFS= read -r -s p1 </dev/tty || true; printf '\n' >/dev/tty
    if (( ${#p1} < 10 )); then warn "Слишком короткий — нужно минимум 10 символов."; continue; fi
    printf '  %s?%s Повтори пароль: ' "$MG" "$N" >/dev/tty
    IFS= read -r -s p2 </dev/tty || true; printf '\n' >/dev/tty
    if [[ "$p1" != "$p2" ]]; then warn "Пароли не совпали, ещё раз."; continue; fi
    REPLY_PW="$p1"
    return 0
  done
}

rand_str() {  # rand_str N — случайная строка A-Za-z0-9
  local n="${1:-20}" s
  s="$(openssl rand -base64 $((n * 3)) | tr -dc 'A-Za-z0-9')"
  printf '%s' "${s:0:n}"
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# Кто слушает порт (кроме xray/mtg — их мы сами перезапустим). Пусто = свободен.
port_owner() {
  local line
  line="$(ss -tlnp "sport = :$1" 2>/dev/null | tail -n +2 || true)"
  if [[ -z "$line" ]]; then return 0; fi
  if grep -qE '"(xray|mtg)"' <<<"$line"; then return 0; fi
  local name
  name="$(sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<<"$line" | head -n1 || true)"
  printf '%s\n' "${name:-неизвестный процесс}"
}

USED_PORTS=()
ask_port() {  # ask_port ИМЯ_ПЕРЕМЕННОЙ "вопрос" по_умолчанию
  local var="$1" label="$2" def="$3" p owner
  while true; do
    p="$(ask "$label" "$def")"
    if ! valid_port "$p"; then warn "Порт — число от 1 до 65535."; continue; fi
    if [[ " ${USED_PORTS[*]:-} " == *" $p "* ]]; then warn "Порт $p уже выбран для другой службы."; continue; fi
    owner="$(port_owner "$p")"
    if [[ -n "$owner" ]]; then warn "Порт $p занят: $owner. Выбери другой."; continue; fi
    USED_PORTS+=("$p")
    printf -v "$var" '%s' "$p"
    return 0
  done
}

valid_ssh_key() {
  local tmp rc=0
  tmp="$(mktemp)"
  printf '%s\n' "$1" > "$tmp"
  ssh-keygen -l -f "$tmp" >/dev/null 2>&1 || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Проверки окружения
# ---------------------------------------------------------------------------
need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти от root:  sudo bash $0" >&2
    exit 1
  fi
}

init_log() {
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  printf '\n===== FastXray %s — %s =====\n' "$VERSION" "$(date '+%F %T')" >> "$LOG_FILE"
}

check_os() {
  [[ -r /etc/os-release ]] || die "Не удалось определить ОС."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    *debian*|*ubuntu*) ;;
    *) die "Скрипт рассчитан на Debian/Ubuntu (у тебя: ${PRETTY_NAME:-неизвестно})." ;;
  esac
  command -v apt-get >/dev/null 2>&1 || die "Не найден apt-get."
  command -v systemctl >/dev/null 2>&1 || die "Нужен systemd."
}

check_tty() {
  if ! { : </dev/tty; } 2>/dev/null; then
    die "Нужен интерактивный терминал (запусти по SSH, а не из cron)."
  fi
}

bootstrap_tools() {  # curl/jq/ss/ssh-keygen нужны уже на этапе вопросов
  local need=()
  command -v curl >/dev/null 2>&1       || need+=(curl ca-certificates)
  command -v jq >/dev/null 2>&1         || need+=(jq)
  command -v ss >/dev/null 2>&1         || need+=(iproute2)
  command -v ssh-keygen >/dev/null 2>&1 || need+=(openssh-client)
  if (( ${#need[@]} == 0 )); then return 0; fi
  info "Ставлю минимальные утилиты: ${need[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=180 update -qq >>"$LOG_FILE" 2>&1 || true
  apt-get -o DPkg::Lock::Timeout=180 install -y -qq --no-install-recommends "${need[@]}" >>"$LOG_FILE" 2>&1 \
    || die "Не удалось установить: ${need[*]} (см. $LOG_FILE)"
}

print_banner() {
  printf '%s' "${CY}${B}" >&2
  cat >&2 <<'BANNER'
   ____          _  __  __
  |  ___|_ _ ___| |_\ \/ /_ __ __ _ _   _
  | |_ / _` / __| __|\  /| '__/ _` | | | |
  |  _| (_| \__ \ |_ /  \| | | (_| | |_| |
  |_|  \__,_|___/\__/_/\_\_|  \__,_|\__, |
                                    |___/
BANNER
  printf '%s' "${N}" >&2
  emit "${D}  v${VERSION} · VLESS+REALITY · Shadowsocks · Telegram MTProto${N}"
}

# ---------------------------------------------------------------------------
# Состояние установки
# ---------------------------------------------------------------------------
MODE="full"            # full | tune
EXISTING="none"        # none | state | legacy
TAG="" SERVER_IP=""
PORT_MAIN=0 PORT_BACKUP=0 PORT_SS=0 PORT_MTG=0
SNI_MAIN="" SNI_BACKUP="" SID="" PBK="" REALITY_PRIV="" XRAY_UUID="" SS_PASS="" MTG_SECRET=""
CUSTOM_SNI=""
WANT_F2B="y"
CREATE_USER="n" USERNAME="" LOGIN_METHOD="password" USER_PASS="" USER_SSH_KEY=""
DISABLE_ROOT_SSH="n" DISABLE_PW_SSH="n"
ROOT_PW_MODE="skip" ROOT_PW=""
WIPE_OLD="n"

save_state() {
  install -d -m 700 "$STATE_DIR"
  {
    printf 'TAG=%q\n' "$TAG"
    printf 'SERVER_IP=%q\n' "$SERVER_IP"
    printf 'PORT_MAIN=%q\n' "$PORT_MAIN"
    printf 'PORT_BACKUP=%q\n' "$PORT_BACKUP"
    printf 'PORT_SS=%q\n' "$PORT_SS"
    printf 'SS_PASS=%q\n' "$SS_PASS"
    printf 'PBK=%q\n' "$PBK"
    printf 'SID=%q\n' "$SID"
    printf 'SNI_MAIN=%q\n' "$SNI_MAIN"
    printf 'SNI_BACKUP=%q\n' "$SNI_BACKUP"
    printf 'PORT_MTG=%q\n' "$PORT_MTG"
    printf 'MTG_SECRET=%q\n' "$MTG_SECRET"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

get_server_ip() {
  local url pub
  for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    pub="$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$pub" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s\n' "$pub"; return 0; fi
  done
  pub="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  if [[ "$pub" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s\n' "$pub"; return 0; fi
  while true; do
    pub="$(ask "Не удалось определить внешний IP — введи его вручную")"
    if [[ "$pub" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s\n' "$pub"; return 0; fi
  done
}

xray_test() { xray run -test -config "$1" >/dev/null 2>&1 || xray -test -config "$1" >/dev/null 2>&1; }

xray_pub_from_priv() {
  # Поддержка разных форматов вывода xray x25519 (Public key / Password / Password (PublicKey))
  xray x25519 -i "$1" 2>/dev/null | awk -F': *' '
    tolower($1) ~ /(public|password)/ { print $NF; exit }
  '
}

# Группа, от имени которой работает служба xray. Современный установщик запускает
# её от пользователя «xray», старые версии — от «nobody»: конфиг должен читаться ею.
xray_group() {
  local u g
  u="$(systemctl show -p User --value xray 2>/dev/null || true)"
  if [[ -z "$u" ]]; then
    if id xray >/dev/null 2>&1; then u="xray"; else u="nobody"; fi
  fi
  g="$(id -gn "$u" 2>/dev/null || true)"
  printf '%s\n' "${g:-nogroup}"
}

# Подтянуть параметры из config.json (установка старой версии скрипта без state.env)
import_legacy_state() {
  local main backup ss
  [[ -f "$XRAY_CFG" ]] || die "Не найден $XRAY_CFG"
  main="$(jq -c '[.inbounds[]|select(.protocol=="vless")][0] // empty' "$XRAY_CFG")"
  backup="$(jq -c '[.inbounds[]|select(.protocol=="vless")][1] // empty' "$XRAY_CFG")"
  ss="$(jq -c '[.inbounds[]|select(.protocol=="shadowsocks")][0] // empty' "$XRAY_CFG")"
  [[ -n "$main" ]] || die "В $XRAY_CFG нет VLESS-inbound — не могу восстановить параметры. Выбери «переустановить»."

  PORT_MAIN="$(jq -r '.port' <<<"$main")"
  SNI_MAIN="$(jq -r '.streamSettings.realitySettings.serverNames[0]' <<<"$main")"
  SID="$(jq -r '.streamSettings.realitySettings.shortIds[0]' <<<"$main")"
  REALITY_PRIV="$(jq -r '.streamSettings.realitySettings.privateKey' <<<"$main")"
  PBK="$(xray_pub_from_priv "$REALITY_PRIV")"
  [[ -n "$PBK" ]] || die "Не удалось вычислить публичный ключ REALITY."

  if [[ -n "$backup" ]]; then
    PORT_BACKUP="$(jq -r '.port' <<<"$backup")"
    SNI_BACKUP="$(jq -r '.streamSettings.realitySettings.serverNames[0]' <<<"$backup")"
  else
    PORT_BACKUP=0; SNI_BACKUP=""
  fi
  if [[ -n "$ss" ]]; then
    PORT_SS="$(jq -r '.port' <<<"$ss")"
    SS_PASS="$(jq -r '.settings.password // .settings.clients[0].password // ""' <<<"$ss")"
  else
    PORT_SS=0; SS_PASS=""
  fi
  if [[ -f "$MTG_CFG" ]] && command -v mtg >/dev/null 2>&1; then
    MTG_SECRET="$(sed -n 's/^secret *= *"\(.*\)".*/\1/p' "$MTG_CFG" | head -n1 || true)"
    PORT_MTG="$(sed -n 's/^bind-to *= *".*:\([0-9]*\)".*/\1/p' "$MTG_CFG" | head -n1 || true)"
    PORT_MTG="${PORT_MTG:-0}"
  else
    PORT_MTG=0; MTG_SECRET=""
  fi
  SERVER_IP="$(get_server_ip)"
  ok "Параметры текущей установки восстановлены из конфига"
}

# ---------------------------------------------------------------------------
# Вопросы
# ---------------------------------------------------------------------------
detect_existing() {
  if [[ -f "$STATE_FILE" ]]; then
    EXISTING="state"
  elif [[ -f "$XRAY_CFG" ]] && command -v xray >/dev/null 2>&1; then
    EXISTING="legacy"
  else
    MODE="full"; return 0
  fi
  echo >&2
  warn "На сервере уже есть установка Xray."
  echo -e "    ${WH}1${N} — Исправить и обновить текущую установку ${D}(ключи и ссылки НЕ меняются, рекомендуется)${N}" >&2
  echo -e "    ${WH}2${N} — Переустановить с нуля ${D}(новые ключи — старые ссылки перестанут работать)${N}" >&2
  echo -e "    ${WH}3${N} — Выйти" >&2
  case "$(ask "Выбор (1/2/3)" "1")" in
    2) MODE="full" ;;
    3) emit "Выход."; exit 0 ;;
    *) MODE="tune" ;;
  esac
}

collect_root_password() {
  ROOT_PW_MODE="skip"; ROOT_PW=""
  echo >&2
  info "Пароль root обычно выдаёт хостер (он мог светиться в письмах и панели)."
  if ! ask_yn "Сменить пароль root?" "y"; then return 0; fi
  echo -e "    ${WH}1${N} — задать свой" >&2
  echo -e "    ${WH}2${N} — сгенерировать надёжный (24 символа) ${D}[рекомендуется]${N}" >&2
  echo -e "    ${WH}3${N} — не менять" >&2
  case "$(ask "Выбор (1/2/3)" "2")" in
    1) read_new_password "root"; ROOT_PW="$REPLY_PW"; ROOT_PW_MODE="custom" ;;
    3) ;;
    *) ROOT_PW="$(rand_str 24)"; ROOT_PW_MODE="random" ;;
  esac
}

collect_old_artifacts() {
  if [[ -f /var/log/vpn-setup.log || -d "$XRAY_DIR/client_configs" ]]; then
    echo >&2
    warn "Старая версия скрипта оставила лог и README со ссылками и паролями открытым текстом."
    if ask_yn "Удалить их? (новые ссылки всегда доступны командой «vpn show»)" "y"; then WIPE_OLD="y"; fi
  fi
}

collect_full() {
  local m key
  echo >&2
  emit "${WH}${B}Несколько вопросов перед установкой${N} ${D}(Enter = значение по умолчанию)${N}"
  echo >&2
  TAG="$(ask "Название сервера (для имён в приложении)" "$(hostname -s 2>/dev/null || echo VPS)")"
  SERVER_IP="$(get_server_ip)"
  info "Внешний IP сервера: ${SERVER_IP}"

  echo >&2
  ask_port PORT_MAIN "Порт основного VLESS+REALITY" "$DEF_PORT_MAIN"
  if ask_yn "Добавить резервный VLESS на втором порту (с другой маскировкой)?" "y"; then
    ask_port PORT_BACKUP "Порт резервного VLESS" "$DEF_PORT_BACKUP"
  else PORT_BACKUP=0; fi
  if ask_yn "Добавить Shadowsocks? ${D}(простой SS в РФ обычно блокируют — по умолчанию нет)${N}" "n"; then
    ask_port PORT_SS "Порт Shadowsocks" "$DEF_PORT_SS"
  else PORT_SS=0; fi
  if ask_yn "Поднять Telegram MTProto-прокси?" "y"; then
    ask_port PORT_MTG "Порт MTProto" "$DEF_PORT_MTG"
  else PORT_MTG=0; fi
  CUSTOM_SNI="$(ask "Домен для маскировки REALITY (Enter — подобрать лучший автоматически)" "")"

  echo >&2
  if ask_yn "Создать отдельного пользователя для SSH (рекомендуется)?" "y"; then
    CREATE_USER="y"
    while true; do
      USERNAME="$(ask "Имя пользователя" "admin")"
      if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$USERNAME" != "root" ]]; then break; fi
      warn "Латиница в нижнем регистре, цифры, _ и -; не «root»."
    done
    echo -e "    ${WH}1${N} — только пароль" >&2
    echo -e "    ${WH}2${N} — только SSH-ключ ${D}(самый безопасный)${N}" >&2
    echo -e "    ${WH}3${N} — пароль и ключ" >&2
    m="$(ask "Как заходить по SSH (1/2/3)" "3")"
    case "$m" in 1) LOGIN_METHOD="password" ;; 2) LOGIN_METHOD="key" ;; *) LOGIN_METHOD="both" ;; esac
    if [[ "$LOGIN_METHOD" != "password" ]]; then
      key="$(ask "Вставь публичный SSH-ключ одной строкой (Enter — пропустить)" "")"
      if [[ -n "$key" ]] && valid_ssh_key "$key"; then
        USER_SSH_KEY="$key"
      else
        if [[ -n "$key" ]]; then warn "Это не похоже на публичный ключ."; fi
        warn "Ключ не добавлен — вход будет только по паролю."
        LOGIN_METHOD="password"
      fi
    fi
    if [[ "$LOGIN_METHOD" == "key" ]]; then
      USER_PASS="$(rand_str 20)"      # нужен только для sudo
      DISABLE_PW_SSH="y"
      info "Вход по паролю будет отключён (останется только ключ)."
    else
      read_new_password "$USERNAME"; USER_PASS="$REPLY_PW"
    fi
    if ask_yn "Запретить вход root по SSH?" "y"; then DISABLE_ROOT_SSH="y"; fi
  fi
  collect_root_password
  if ask_yn "Поставить fail2ban (защита SSH от подбора пароля)?" "y"; then WANT_F2B="y"; else WANT_F2B="n"; fi
  collect_old_artifacts

  echo >&2
  emit "${D}${LINE}${N}"
  emit "  ${B}Итого:${N} VLESS ${PORT_MAIN}$( ((PORT_BACKUP>0)) && echo " + ${PORT_BACKUP}" )$( ((PORT_SS>0)) && echo " · SS ${PORT_SS}" )$( ((PORT_MTG>0)) && echo " · MTProto ${PORT_MTG}" )"
  emit "  Пользователь: $([[ "$CREATE_USER" == y ]] && echo "$USERNAME ($LOGIN_METHOD)" || echo "не создаётся") · root по SSH: $([[ "$DISABLE_ROOT_SSH" == y ]] && echo "запрещён" || echo "не меняю") · пароль root: $ROOT_PW_MODE"
  emit "${D}${LINE}${N}"
  if ! ask_yn "Начинаем установку?" "y"; then emit "Отменено."; exit 0; fi
}

collect_tune() {
  echo >&2
  emit "${WH}${B}Исправление текущей установки${N} ${D}(ключи и ссылки сохранятся)${N}"
  if [[ "$EXISTING" == "state" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  else
    TAG="$(ask "Название сервера (для имён в приложении)" "$(hostname -s 2>/dev/null || echo VPS)")"
  fi
  collect_root_password
  collect_old_artifacts
  echo >&2
  if ! ask_yn "Применить исправления?" "y"; then emit "Отменено."; exit 0; fi
}

# ---------------------------------------------------------------------------
# Шаги установки
# ---------------------------------------------------------------------------
install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  info "Обновляю списки пакетов..."
  apt-get -o DPkg::Lock::Timeout=180 update -qq >>"$LOG_FILE" 2>&1 \
    || die "apt update не удался (см. $LOG_FILE)"
  local pkgs=(ca-certificates curl jq openssl ufw sudo qrencode iproute2 procps python3 openssh-client)
  apt-get -o DPkg::Lock::Timeout=180 install -y -qq --no-install-recommends "${pkgs[@]}" >>"$LOG_FILE" 2>&1 \
    || die "Не удалось установить пакеты (см. $LOG_FILE)"
  ok "Системные пакеты установлены"
}

tune_network() {
  local mem_mb ct_max bbr_ok="n" f avail
  mem_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  ct_max=$(( mem_mb * 64 ))
  if (( ct_max < 65536 )); then ct_max=65536; fi
  if (( ct_max > 262144 )); then ct_max=262144; fi

  modprobe tcp_bbr >>"$LOG_FILE" 2>&1 || true
  modprobe nf_conntrack >>"$LOG_FILE" 2>&1 || true
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if [[ " ${avail} " == *" bbr "* ]]; then bbr_ok="y"; fi

  # Убираем файлы, которые могли появиться при ручных экспериментах — чтобы не дублировать
  for f in /etc/sysctl.d/99-xray-tune.conf /etc/sysctl.d/99-conntrack.conf /etc/sysctl.d/98-noipv6.conf; do rm -f "$f"; done

  {
    echo "# FastXray ${VERSION}: сетевые настройки"
    echo "net.core.default_qdisc=fq"
    if [[ "$bbr_ok" == "y" ]]; then echo "net.ipv4.tcp_congestion_control=bbr"; fi
    cat <<EOF
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=131072
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.ip_local_port_range=10240 65535
net.core.somaxconn=4096
net.core.netdev_max_backlog=16384
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 131072 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
# keepalive чаще, чем срок жизни записи conntrack: живые соединения не «теряются»,
# а мёртвые клиенты (телефон ушёл из сети) освобождают ресурсы
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.netfilter.nf_conntrack_max=${ct_max}
net.netfilter.nf_conntrack_tcp_timeout_established=86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
vm.swappiness=10
EOF
  } > /etc/sysctl.d/99-fastxray.conf

  printf '%s\n' nf_conntrack > /etc/modules-load.d/fastxray.conf
  if [[ "$bbr_ok" == "y" ]]; then printf '%s\n' tcp_bbr >> /etc/modules-load.d/fastxray.conf; fi
  printf 'options nf_conntrack hashsize=%d\n' $(( ct_max / 4 )) > /etc/modprobe.d/fastxray-conntrack.conf
  if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
    echo $(( ct_max / 4 )) > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
  fi

  sysctl --system >>"$LOG_FILE" 2>&1 || warn "Часть sysctl-параметров не применилась (см. $LOG_FILE)"
  if [[ "$bbr_ok" == "y" ]]; then
    ok "TCP: $(sysctl -n net.ipv4.tcp_congestion_control), очередь $(sysctl -n net.core.default_qdisc), conntrack_max $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo н/д)"
  else
    warn "BBR недоступен в этом ядре — остался стандартный алгоритм. conntrack_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo н/д)"
  fi
}

handle_ipv6() {
  [[ -d /proc/sys/net/ipv6 ]] || return 0
  if curl -6 -fsS --max-time 6 -o /dev/null https://www.google.com 2>/dev/null; then
    info "IPv6 работает — оставляю включённым"
    rm -f /etc/sysctl.d/98-fastxray-noipv6.conf
    return 0
  fi
  if [[ "${SSH_CONNECTION:-}" == *:* ]]; then
    warn "IPv6 не работает, но ты подключён по IPv6 — не отключаю, чтобы не потерять доступ"
    return 0
  fi
  cat > /etc/sysctl.d/98-fastxray-noipv6.conf <<'EOF'
# FastXray: IPv6 на сервере не работает — отключаем, чтобы программы
# не тратили время на заведомо мёртвые IPv6-соединения (SYN-SENT)
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
  sysctl -p /etc/sysctl.d/98-fastxray-noipv6.conf >>"$LOG_FILE" 2>&1 || true
  ok "Нерабочий IPv6 отключён (иначе MTProto зависает на попытках подключиться по нему)"
}

# Swap на маленьких серверах: без него OOM-killer может убить xray посреди работы
ensure_swap() {
  local mem_mb free_mb
  if systemd-detect-virt -cq 2>/dev/null; then return 0; fi          # контейнеры: swap не наш
  if [[ -n "$(swapon --show --noheadings 2>/dev/null || true)" ]]; then
    info "Swap уже есть — не трогаю"; return 0
  fi
  mem_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  if (( mem_mb > 2048 )); then return 0; fi
  free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  if (( free_mb < 4096 )); then info "Мало места на диске — swap не создаю"; return 0; fi
  if { fallocate -l 1G /swapfile 2>>"$LOG_FILE" || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>>"$LOG_FILE"; } \
     && chmod 600 /swapfile && mkswap /swapfile >>"$LOG_FILE" 2>&1 && swapon /swapfile >>"$LOG_FILE" 2>&1; then
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Создан swap 1 ГБ (защита от нехватки памяти)"
  else
    rm -f /swapfile
    warn "Не удалось создать swap — не критично"
  fi
}

# Журнал systemd не должен съедать диск на маленьком VPS
limit_journal() {
  install -d -m 755 /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=100M\nRuntimeMaxUse=50M\n' > /etc/systemd/journald.conf.d/fastxray.conf
  systemctl restart systemd-journald >>"$LOG_FILE" 2>&1 || true
}

create_user() {
  if [[ "$CREATE_USER" != "y" ]]; then info "Пользователь не создаётся"; return 0; fi
  local home grp
  if id "$USERNAME" >/dev/null 2>&1; then
    warn "Пользователь $USERNAME уже существует — обновляю пароль и доступ"
  else
    useradd -m -s /bin/bash "$USERNAME"
    ok "Пользователь $USERNAME создан"
  fi
  getent group sudo >/dev/null 2>&1 || groupadd sudo
  usermod -aG sudo "$USERNAME"
  printf '%s:%s\n' "$USERNAME" "$USER_PASS" | chpasswd
  if [[ -n "$USER_SSH_KEY" ]]; then
    home="$(getent passwd "$USERNAME" | cut -d: -f6)"
    grp="$(id -gn "$USERNAME")"
    install -d -m 700 -o "$USERNAME" -g "$grp" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
    chown "$USERNAME:$grp" "$home/.ssh/authorized_keys"
    grep -qxF "$USER_SSH_KEY" "$home/.ssh/authorized_keys" || printf '%s\n' "$USER_SSH_KEY" >> "$home/.ssh/authorized_keys"
    ok "SSH-ключ добавлен"
  fi
}

apply_root_password() {
  if [[ "$ROOT_PW_MODE" == "skip" ]]; then info "Пароль root не меняю"; return 0; fi
  printf 'root:%s\n' "$ROOT_PW" | chpasswd
  ok "Пароль root изменён"
}

# Установка (или обновление) Xray официальным установщиком.
# Если сервер уже работает, а GitHub недоступен — оставляем то, что стоит.
install_xray() {
  local inst
  inst="$(mktemp)"
  info "Скачиваю официальный установщик Xray..."
  if ! curl -fsSL --retry 3 --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$inst"; then
    rm -f "$inst"
    if command -v xray >/dev/null 2>&1; then warn "Установщик не скачался — оставляю установленную версию Xray"; return 0; fi
    die "Не удалось скачать установщик Xray (GitHub недоступен?)"
  fi
  if ! bash "$inst" install >>"$LOG_FILE" 2>&1; then
    rm -f "$inst"
    if command -v xray >/dev/null 2>&1; then warn "Обновление Xray не удалось — оставляю установленную версию (см. $LOG_FILE)"; return 0; fi
    die "Установка Xray не удалась (см. $LOG_FILE)"
  fi
  rm -f "$inst"
  ok "Xray-core: $(xray version 2>/dev/null | head -n1 || echo ?)"
}

# Автоперезапуск при любых падениях (установщик ставит только on-failure)
install_xray_dropin() {
  install -d -m 755 /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/20-fastxray.conf <<'EOF'
[Service]
Restart=always
RestartSec=3
EOF
  systemctl daemon-reload
  ok "Xray будет автоматически перезапускаться при сбоях"
}

probe_sni() {  # печатает время TLS-рукопожатия, если сайт подходит (TLS1.3 + h2)
  local out ver t
  out="$(curl -sS -o /dev/null --http2 --tlsv1.3 --connect-timeout 4 --max-time 6 \
         -w '%{http_version} %{time_appconnect}' "https://$1/" 2>/dev/null || true)"
  ver="${out%% *}"; t="${out##* }"
  if [[ "$ver" != "2" ]]; then return 0; fi
  awk -v t="$t" 'BEGIN { if (t+0 > 0) printf "%.3f\n", t }'
}

pick_reality_targets() {
  local h t results=() sorted=()
  if [[ -n "$CUSTOM_SNI" ]]; then
    t="$(probe_sni "$CUSTOM_SNI")"
    if [[ -z "$t" ]]; then warn "$CUSTOM_SNI не отвечает по TLS 1.3 + HTTP/2 — маскировка может работать хуже"; fi
    SNI_MAIN="$CUSTOM_SNI"
  fi
  info "Подбираю домен маскировки (TLS 1.3 + HTTP/2, минимальная задержка)..."
  for h in "${REALITY_CANDIDATES[@]}"; do
    if [[ "$h" == "$CUSTOM_SNI" ]]; then continue; fi
    t="$(probe_sni "$h")"
    if [[ -n "$t" ]]; then results+=("$t $h"); fi
  done
  if (( ${#results[@]} > 0 )); then
    mapfile -t sorted < <(printf '%s\n' "${results[@]}" | sort -n | awk '{print $2}')
  fi
  if [[ -z "$SNI_MAIN" ]]; then
    if (( ${#sorted[@]} > 0 )); then
      SNI_MAIN="${sorted[0]}"; sorted=("${sorted[@]:1}")
    else
      warn "Не удалось проверить кандидатов (нет доступа?) — беру www.microsoft.com"
      SNI_MAIN="www.microsoft.com"
    fi
  fi
  if (( PORT_BACKUP > 0 )); then
    if (( ${#sorted[@]} > 0 )); then SNI_BACKUP="${sorted[0]}"
    elif [[ "$SNI_MAIN" == "www.apple.com" ]]; then SNI_BACKUP="www.microsoft.com"
    else SNI_BACKUP="www.apple.com"; fi
  else
    SNI_BACKUP=""
  fi
  ok "Маскировка REALITY: ${SNI_MAIN}$( [[ -n "$SNI_BACKUP" ]] && echo ", резерв: ${SNI_BACKUP}" )"
}

gen_xray_data() {
  local key_output
  XRAY_UUID="$(xray uuid)"
  key_output="$(xray x25519)"
  REALITY_PRIV="$(awk -F': *' 'tolower($1) ~ /private/ {print $NF; exit}' <<<"$key_output")"
  # Поддержка разных форматов: Public key / Password / Password (PublicKey)
  PBK="$(awk -F': *' 'tolower($1) ~ /(public|password)/ {print $NF; exit}' <<<"$key_output")"
  [[ -n "$REALITY_PRIV" && -n "$PBK" ]] || die "Не удалось разобрать вывод «xray x25519»."
  SID="$(openssl rand -hex 8)"
  if (( PORT_SS > 0 )); then SS_PASS="$(rand_str 20)"; else SS_PASS=""; fi
  pick_reality_targets
  ok "Ключи и параметры сгенерированы"
}

# Серверные правила: реклама, BitTorrent и исходящий SMTP (порт 25) блокируются.
# Примечание: geosite:win-spy в штатных geo-файлах Xray нет — с ним конфиг не стартует.
build_xray_json() {
  local bt=false
  if [[ "$BLOCK_TORRENT" == "y" ]]; then bt=true; fi
  jq -n \
    --arg uuid "$XRAY_UUID" --arg priv "$REALITY_PRIV" --arg sid "$SID" \
    --arg sni1 "$SNI_MAIN" --arg sni2 "$SNI_BACKUP" \
    --argjson p1 "$PORT_MAIN" --argjson p2 "$PORT_BACKUP" --argjson pss "$PORT_SS" \
    --arg sspass "$SS_PASS" --argjson bt "$bt" '
    def vless($tag; $port; $sni): {
      tag: $tag, listen: "0.0.0.0", port: $port, protocol: "vless",
      settings: { clients: [ {id: $uuid, flow: "xtls-rprx-vision", email: "main"} ], decryption: "none" },
      sniffing: { enabled: true, destOverride: ["http","tls"], routeOnly: true },
      streamSettings: {
        network: "tcp", security: "reality",
        sockopt: { tcpKeepAliveIdle: 300, tcpKeepAliveInterval: 30 },
        realitySettings: {
          show: false, xver: 0, target: ($sni + ":443"),
          shortIds: [$sid], privateKey: $priv, serverNames: [$sni]
        }
      }
    };
    {
      log: { loglevel: "warning", access: "none" },
      dns: { servers: ["1.1.1.1", "8.8.8.8", "localhost"], queryStrategy: "UseIPv4" },
      inbounds: (
        [ vless("VLESS_MAIN"; $p1; $sni1) ]
        + (if $p2 > 0 then [ vless("VLESS_BACKUP"; $p2; $sni2) ] else [] end)
        + (if $pss > 0 then [ {
              tag: "SHADOWSOCKS", listen: "0.0.0.0", port: $pss, protocol: "shadowsocks",
              settings: { method: "chacha20-ietf-poly1305", password: $sspass, network: "tcp,udp" },
              sniffing: { enabled: true, destOverride: ["http","tls"], routeOnly: true }
            } ] else [] end)
      ),
      outbounds: [
        { tag: "direct", protocol: "freedom", settings: {}, streamSettings: { sockopt: { domainStrategy: "UseIPv4" } } },
        { tag: "block", protocol: "blackhole" }
      ],
      routing: { rules: (
        (if $bt then [ { type: "field", protocol: ["bittorrent"], outboundTag: "block" } ] else [] end)
        + [ { type: "field", network: "tcp", port: "25", outboundTag: "block" },
            { type: "field", domain: ["geosite:category-ads-all", "geosite:private"], outboundTag: "block" },
            { type: "field", ip: ["geoip:private"], outboundTag: "block" } ]
      ) }
    }'
}

install_xray_config() {  # install_xray_config /tmp/файл — проверить и положить на место
  local tmp="$1" grp
  if ! xray_test "$tmp"; then
    # у старых версий Xray поле называется dest, а не target
    sed -i 's/"target":/"dest":/' "$tmp"
    if ! xray_test "$tmp"; then
      xray run -test -config "$tmp" >>"$LOG_FILE" 2>&1 || true
      rm -f "$tmp"
      die "Xray отверг конфигурацию (подробности в $LOG_FILE)"
    fi
  fi
  grp="$(xray_group)"
  install -d -m 755 "$XRAY_DIR"
  install -m 640 -o root -g "$grp" "$tmp" "$XRAY_CFG"
  rm -f "$tmp"
}

write_xray_config() {
  local tmp
  tmp="$(mktemp --suffix=.json)"
  build_xray_json > "$tmp"
  install_xray_config "$tmp"
  ok "Конфиг Xray записан"
}

# Исправление конфига действующей установки (идемпотентно, ключи не трогаем)
patch_xray_config() {
  local tmp bt=false
  tmp="$(mktemp --suffix=.json)"
  if [[ "$BLOCK_TORRENT" == "y" ]]; then bt=true; fi
  cp -a "$XRAY_CFG" "${XRAY_CFG}.bak.$(date +%Y%m%d_%H%M%S)"
  jq --argjson bt "$bt" '
    def fixdom:
      if has("domain")
      then .domain |= ( map(select(. != "geosite:win-spy"))
                        | map(if . == "geosite:category-ads" then "geosite:category-ads-all" else . end) )
      else . end;
    .log = { loglevel: "warning", access: "none" }
    | .dns = { servers: ["1.1.1.1", "8.8.8.8", "localhost"], queryStrategy: "UseIPv4" }
    | .inbounds = [ (.inbounds // [])[]
        | (if .sniffing then .sniffing = { enabled: true, destOverride: ["http","tls"], routeOnly: true } else . end)
        | (if .protocol == "vless"
             then .settings.clients |= map(if has("email") then . else . + { email: "main" } end)
                  | .streamSettings.sockopt = ((.streamSettings.sockopt // {}) + { tcpKeepAliveIdle: 300, tcpKeepAliveInterval: 30 })
             else . end) ]
    | .outbounds = [ (.outbounds // [])[]
        | (if .protocol == "freedom"
             then del(.settings.domainStrategy) | .streamSettings.sockopt.domainStrategy = "UseIPv4"
             else . end) ]
    | .routing.rules = (
        [ (.routing.rules // [])[] | fixdom | select((has("domain") | not) or ((.domain | length) > 0)) ] as $r
        | ( (if $bt and (($r | any((.protocol // []) | index("bittorrent") != null)) | not)
             then [ { type: "field", protocol: ["bittorrent"], outboundTag: "block" } ] else [] end)
          + (if ($r | any((.port // "") == "25")) then []
             else [ { type: "field", network: "tcp", port: "25", outboundTag: "block" } ] end) )
          + $r )
  ' "$XRAY_CFG" > "$tmp" || { rm -f "$tmp"; die "jq не смог обработать $XRAY_CFG"; }
  install_xray_config "$tmp"
  ok "Конфиг Xray исправлен: DNS без DoH, sniffing только для маршрутизации, keepalive, блок торрентов и SMTP"
}

start_xray() {
  systemctl enable xray >>"$LOG_FILE" 2>&1 || true
  systemctl restart xray
  sleep 2
  if systemctl is-active --quiet xray; then
    ok "Служба xray запущена"
  else
    journalctl -u xray -n 20 --no-pager >&2 || true
    die "Xray не стартовал — см. вывод выше"
  fi
}

install_mtg() {
  if (( PORT_MTG == 0 )); then info "MTProto-прокси пропущен"; return 0; fi
  local arch="" tag url tmp bin
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac

  if ! command -v mtg >/dev/null 2>&1; then
    [[ -n "$arch" ]] || { warn "Архитектура $(uname -m) не поддерживается — MTProto пропущен"; PORT_MTG=0; return 0; }
    tag="$(curl -fsSL --max-time 15 https://api.github.com/repos/9seconds/mtg/releases/latest 2>/dev/null | jq -r '.tag_name // empty' || true)"
    if [[ -z "$tag" ]]; then  # запасной путь: лимит GitHub API — берём тег из редиректа
      tag="$(curl -fsSLI --max-time 15 -o /dev/null -w '%{url_effective}' https://github.com/9seconds/mtg/releases/latest 2>/dev/null | sed 's|.*/||' || true)"
    fi
    if [[ -n "$tag" ]]; then
      url="https://github.com/9seconds/mtg/releases/download/${tag}/mtg-${tag#v}-linux-${arch}.tar.gz"
      tmp="$(mktemp -d)"
      if curl -fsSL --max-time 60 -o "$tmp/mtg.tar.gz" "$url" && tar -xzf "$tmp/mtg.tar.gz" -C "$tmp" 2>/dev/null; then
        bin="$(find "$tmp" -type f -name mtg -print -quit)"
        if [[ -n "$bin" ]]; then install -m 755 "$bin" /usr/local/bin/mtg; fi
      fi
      rm -rf "$tmp"
    fi
    if ! command -v mtg >/dev/null 2>&1; then
      warn "Не удалось скачать mtg — MTProto пропущен (остальное работает)"
      PORT_MTG=0; return 0
    fi
  fi

  if [[ -z "$MTG_SECRET" ]]; then
    MTG_SECRET="$(mtg generate-secret --hex "$MTG_FAKE_TLS_HOST" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$MTG_SECRET" ]] || { warn "mtg не сгенерировал секрет — MTProto пропущен"; PORT_MTG=0; return 0; }
  fi

  id mtg >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin mtg
  install -d -m 755 "$MTG_DIR"
  write_mtg_config "prefer-ipv4"
  cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=mtg - Telegram MTProto proxy
After=network-online.target
Wants=network-online.target

[Service]
User=mtg
Group=mtg
ExecStart=/usr/local/bin/mtg run ${MTG_CFG}
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable mtg >>"$LOG_FILE" 2>&1 || true
  systemctl restart mtg
  sleep 2
  if ! systemctl is-active --quiet mtg; then
    warn "mtg не стартовал с prefer-ip — пробую без этой опции"
    write_mtg_config ""
    systemctl restart mtg
    sleep 2
  fi
  if systemctl is-active --quiet mtg; then
    ok "MTProto-прокси (mtg) запущен на порту ${PORT_MTG}, подключение к Telegram — по IPv4"
  else
    journalctl -u mtg -n 15 --no-pager >&2 || true
    warn "mtg не запустился (см. вывод выше) — MTProto отключён, остальное работает"
    systemctl disable --now mtg >>"$LOG_FILE" 2>&1 || true
    PORT_MTG=0
  fi
}

write_mtg_config() {  # write_mtg_config "prefer-ipv4"|""
  {
    printf 'secret = "%s"\n' "$MTG_SECRET"
    printf 'bind-to = "0.0.0.0:%s"\n' "$PORT_MTG"
    if [[ -n "$1" ]]; then printf 'prefer-ip = "%s"\n' "$1"; fi
  } > "$MTG_CFG"
  chown mtg:mtg "$MTG_CFG"
  chmod 600 "$MTG_CFG"
}

detect_ssh_ports() {
  local sshd_bin eff out=""
  sshd_bin="$(command -v sshd || echo /usr/sbin/sshd)"
  eff="$("$sshd_bin" -T 2>/dev/null || true)"
  out="$(awk '$1=="port"{print $2}' <<<"$eff")"
  if [[ -n "${SSH_CONNECTION:-}" ]]; then out+=$'\n'"$(awk '{print $4}' <<<"$SSH_CONNECTION")"; fi
  out="$(printf '%s\n' "$out" | grep -E '^[0-9]+$' | sort -un || true)"
  printf '%s\n' "${out:-22}"
}

setup_firewall() {
  local p
  ufw default deny incoming >>"$LOG_FILE" 2>&1
  ufw default allow outgoing >>"$LOG_FILE" 2>&1
  while read -r p; do
    [[ -n "$p" ]] && ufw allow "${p}/tcp" comment 'ssh' >>"$LOG_FILE" 2>&1
  done < <(detect_ssh_ports)
  ufw allow "${PORT_MAIN}/tcp" comment 'xray vless reality' >>"$LOG_FILE" 2>&1
  if (( PORT_BACKUP > 0 )); then ufw allow "${PORT_BACKUP}/tcp" comment 'xray vless backup' >>"$LOG_FILE" 2>&1; fi
  if (( PORT_SS > 0 )); then ufw allow "${PORT_SS}" comment 'xray shadowsocks' >>"$LOG_FILE" 2>&1; fi
  if (( PORT_MTG > 0 )); then ufw allow "${PORT_MTG}/tcp" comment 'telegram mtproto' >>"$LOG_FILE" 2>&1; fi
  ufw --force enable >>"$LOG_FILE" 2>&1
  ok "Firewall (ufw): открыты SSH ($(detect_ssh_ports | paste -sd, -)) и порты прокси"
  info "Если у хостера есть свой внешний firewall — открой там те же порты"
}

harden_ssh() {
  if [[ "$DISABLE_ROOT_SSH" != "y" && "$DISABLE_PW_SSH" != "y" ]]; then
    info "SSH: настройки входа не меняю"; return 0
  fi
  local cfg=/etc/ssh/sshd_config dropin=/etc/ssh/sshd_config.d/00-fastxray.conf
  local sshd_bin svc bak eff l key lines=()
  sshd_bin="$(command -v sshd || echo /usr/sbin/sshd)"
  if systemctl cat ssh.service >/dev/null 2>&1; then svc=ssh; else svc=sshd; fi
  bak="${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
  cp -a "$cfg" "$bak"

  if [[ "$DISABLE_ROOT_SSH" == "y" ]]; then lines+=("PermitRootLogin no"); fi
  if [[ "$DISABLE_PW_SSH" == "y" ]]; then lines+=("PasswordAuthentication no" "KbdInteractiveAuthentication no"); fi

  # Файл 00-... читается первым, а в sshd побеждает первое значение — перебивает cloud-init
  if [[ -d /etc/ssh/sshd_config.d ]] && grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$cfg"; then
    { echo "# FastXray"; printf '%s\n' "${lines[@]}"; } > "$dropin"
    chmod 644 "$dropin"
  else
    for l in "${lines[@]}"; do
      key="${l%% *}"
      if grep -qiE "^[#[:space:]]*${key}[[:space:]]" "$cfg"; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${l}|" "$cfg"
      else
        printf '%s\n' "$l" >> "$cfg"
      fi
    done
  fi

  if ! "$sshd_bin" -t >>"$LOG_FILE" 2>&1; then
    rm -f "$dropin"; cp -a "$bak" "$cfg"
    warn "Конфиг SSH не прошёл проверку — изменения отменены"
    return 0
  fi
  systemctl reload "$svc" >>"$LOG_FILE" 2>&1 || systemctl restart "$svc" >>"$LOG_FILE" 2>&1 || true

  eff="$("$sshd_bin" -T 2>/dev/null || true)"
  if [[ "$DISABLE_ROOT_SSH" == "y" ]]; then
    if grep -qi '^permitrootlogin no' <<<"$eff"; then ok "SSH: вход root запрещён"
    else warn "SSH: запрет root не применился — проверь /etc/ssh/sshd_config*"; fi
  fi
  if [[ "$DISABLE_PW_SSH" == "y" ]]; then
    if grep -qi '^passwordauthentication no' <<<"$eff"; then ok "SSH: вход по паролю отключён (только ключи)"
    else warn "SSH: отключение пароля не применилось — проверь /etc/ssh/sshd_config*"; fi
  fi
}

setup_fail2ban() {
  if [[ "$WANT_F2B" != "y" ]]; then return 0; fi
  local ports client ign="127.0.0.1/8 ::1"
  if ! apt-get -o DPkg::Lock::Timeout=180 install -y -qq fail2ban >>"$LOG_FILE" 2>&1; then
    warn "fail2ban не установился — пропускаю"; return 0
  fi
  apt-get install -y -qq python3-systemd >>"$LOG_FILE" 2>&1 || true
  ports="$(detect_ssh_ports | paste -sd, -)"
  client="${SSH_CONNECTION%% *}"
  if [[ -n "${SSH_CONNECTION:-}" && -n "$client" ]]; then ign+=" $client"; fi
  cat > /etc/fail2ban/jail.d/fastxray.local <<EOF
[DEFAULT]
ignoreip = ${ign}
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ${ports}
backend = systemd
EOF
  systemctl enable fail2ban >>"$LOG_FILE" 2>&1 || true
  if systemctl restart fail2ban >>"$LOG_FILE" 2>&1; then ok "fail2ban включён для SSH (порты: ${ports})"
  else warn "fail2ban не запустился (см. $LOG_FILE) — не критично"; fi
}

wipe_old_artifacts() {
  if [[ -d "$XRAY_DIR/client_configs" ]]; then chmod -R go-rwx "$XRAY_DIR/client_configs" 2>/dev/null || true; fi
  if [[ "$WIPE_OLD" != "y" ]]; then
    if [[ -f /var/log/vpn-setup.log ]]; then chmod 600 /var/log/vpn-setup.log; fi
    return 0
  fi
  if [[ -f /var/log/vpn-setup.log ]]; then shred -u /var/log/vpn-setup.log 2>/dev/null || rm -f /var/log/vpn-setup.log; fi
  if [[ -d "$XRAY_DIR/client_configs" ]]; then rm -rf "$XRAY_DIR/client_configs"; fi
  ok "Старые лог и README со ссылками удалены"
}

# ---------------------------------------------------------------------------
# Сторожевой таймер: раз в 2 минуты проверяет, что xray (и mtg) живы и слушают порт
# ---------------------------------------------------------------------------
install_watchdog() {
  cat > "$HEALTH_BIN" <<'HEALTH_EOF'
#!/usr/bin/env bash
# fastxray-health — перезапускает упавшие службы, пишет предупреждения в журнал
set -u
STATE_FILE="/usr/local/etc/fastxray/state.env"
[[ -r "$STATE_FILE" ]] || exit 0
# shellcheck disable=SC1090
source "$STATE_FILE"
log() { logger -t fastxray-health "$*"; }
listening() { ss -tln "sport = :$1" 2>/dev/null | grep -q LISTEN; }

if ! systemctl is-active --quiet xray; then
  log "xray не активен — перезапускаю"; systemctl restart xray
elif ! listening "$PORT_MAIN"; then
  log "xray активен, но порт $PORT_MAIN не слушается — перезапускаю"; systemctl restart xray
fi

if (( ${PORT_MTG:-0} > 0 )) && systemctl cat mtg.service >/dev/null 2>&1; then
  if ! systemctl is-active --quiet mtg || ! listening "$PORT_MTG"; then
    log "mtg не отвечает — перезапускаю"; systemctl restart mtg
  fi
fi

cnt="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)"
max="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)"
if (( max > 0 && cnt * 100 / max >= 85 )); then
  log "conntrack заполнен на $((cnt * 100 / max))% ($cnt из $max) — поднимите nf_conntrack_max"
fi
HEALTH_EOF
  chmod 755 "$HEALTH_BIN"
  cat > /etc/systemd/system/fastxray-health.service <<EOF
[Unit]
Description=FastXray health check

[Service]
Type=oneshot
ExecStart=${HEALTH_BIN}
EOF
  cat > /etc/systemd/system/fastxray-health.timer <<'EOF'
[Unit]
Description=FastXray health check every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  if systemctl enable --now fastxray-health.timer >>"$LOG_FILE" 2>&1; then
    ok "Сторожевой таймер включён (проверка каждые 2 минуты)"
  else
    warn "Не удалось включить сторожевой таймер — не критично"
  fi
}

# ---------------------------------------------------------------------------
# Команда `vpn`
# ---------------------------------------------------------------------------
install_vpn_cmd() {
  cat > "$VPN_BIN" <<'VPN_EOF'
#!/usr/bin/env bash
# vpn — управление сервером FastXray
set -uo pipefail

STATE_FILE="${FASTXRAY_STATE:-/usr/local/etc/fastxray/state.env}"
XRAY_CFG="${FASTXRAY_XRAY_CFG:-/usr/local/etc/xray/config.json}"
LISTS_DIR="${FASTXRAY_LISTS:-/usr/local/etc/fastxray}"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

if [[ -t 1 ]]; then
  B=$'\033[1m'; D=$'\033[2m'; CY=$'\033[1;36m'; GR=$'\033[1;32m'; YE=$'\033[1;33m'; RD=$'\033[1;31m'; N=$'\033[0m'
else
  B=''; D=''; CY=''; GR=''; YE=''; RD=''; N=''
fi
die() { echo "${RD}✗ $*${N}" >&2; exit 1; }

if [[ $EUID -ne 0 && -z "${FASTXRAY_ALLOW_NONROOT:-}" ]]; then die "Запусти от root:  sudo vpn $*"; fi
[[ -r "$STATE_FILE" ]] || die "Не найден $STATE_FILE — сначала запусти setup_vpn.sh"
[[ -r "$XRAY_CFG" ]]   || die "Не найден $XRAY_CFG"
# shellcheck disable=SC1090
source "$STATE_FILE"

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }
xray_test() { xray run -test -config "$1" >/dev/null 2>&1 || xray -test -config "$1" >/dev/null 2>&1; }

list_clients() {
  jq -r '[.inbounds[]|select(.protocol=="vless")][0].settings.clients[]? | "\(.email // "user")\t\(.id)"' "$XRAY_CFG"
}

vless_link() {  # имя uuid порт sni метка
  printf 'vless://%s@%s:%s?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision&encryption=none&spx=%%2F#%s\n' \
    "$2" "$SERVER_IP" "$3" "$4" "$PBK" "$SID" "$(urlenc "$TAG $1 $5")"
}
ss_link() {
  printf 'ss://%s@%s:%s#%s\n' "$(printf 'chacha20-ietf-poly1305:%s' "$SS_PASS" | base64 -w0)" \
    "$SERVER_IP" "$PORT_SS" "$(urlenc "$TAG Shadowsocks")"
}
mtg_link()  { printf 'tg://proxy?server=%s&port=%s&secret=%s\n' "$SERVER_IP" "$PORT_MTG" "$MTG_SECRET"; }
mtg_tlink() { printf 'https://t.me/proxy?server=%s&port=%s&secret=%s\n' "$SERVER_IP" "$PORT_MTG" "$MTG_SECRET"; }

user_links() {
  vless_link "$1" "$2" "$PORT_MAIN" "$SNI_MAIN" "$PORT_MAIN"
  if (( PORT_BACKUP > 0 )); then vless_link "$1" "$2" "$PORT_BACKUP" "$SNI_BACKUP" "$PORT_BACKUP backup"; fi
}
extra_links() {
  if (( PORT_SS > 0 )); then ss_link; fi
  if (( PORT_MTG > 0 )); then mtg_link; fi
}
bundle() { { user_links "$1" "$2"; extra_links; } | base64 -w0; echo; }

# ---------------------------------------------------------------------------
# Маршрутизация для клиента: Россия напрямую, остальное через VPN
# ---------------------------------------------------------------------------
# Свои списки: /usr/local/etc/fastxray/custom-{direct,proxy,block}.txt (по домену в строке)
read_list() {  # direct|proxy|block → JSON-массив
  local f="$LISTS_DIR/custom-$1.txt"
  if [[ -r "$f" ]]; then
    sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$f" \
      | awk 'NF { if ($0 ~ /:/) print; else print "domain:" $0 }' | jq -R . | jq -s .
  else
    echo '[]'
  fi
}

routing_json() {
  jq -nc \
    --argjson d "$(read_list direct)" --argjson p "$(read_list proxy)" --argjson b "$(read_list block)" \
    --arg ts "$(date +%s)" --arg gip "$GEOIP_URL" --arg gsite "$GEOSITE_URL" '
    {
      Name: "RU-split",
      GlobalProxy: "true",
      RemoteDNSType: "DoH", RemoteDNSDomain: "https://cloudflare-dns.com/dns-query", RemoteDNSIP: "1.1.1.1",
      DomesticDNSType: "DoU", DomesticDNSDomain: "", DomesticDNSIP: "77.88.8.8",
      Geoipurl: $gip, Geositeurl: $gsite, LastUpdated: $ts,
      DnsHosts: { "cloudflare-dns.com": "1.1.1.1" },
      DirectSites: ($d + ["geosite:category-ru", "geosite:category-gov-ru",
                          "regexp:\\.ru$", "regexp:\\.su$", "regexp:\\.xn--p1ai$"]),
      DirectIp: ["geoip:ru", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                 "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255"],
      ProxySites: ($p + ["geosite:google-gemini", "geosite:category-ai-!cn", "geosite:google@!ads"]),
      ProxyIp: [],
      BlockSites: ($b + ["geosite:category-ads-all", "geosite:win-spy"]),
      BlockIp: [],
      DomainStrategy: "IPIfNonMatch",
      FakeDNS: "false"
    }'
}

routing_link() { printf 'happ://routing/onadd/%s\n' "$(routing_json | base64 -w0)"; }

cmd_routing() {
  case "${1:-}" in
    json) routing_json | jq . ;;
    qr)
      command -v qrencode >/dev/null 2>&1 || die "Нужен qrencode:  apt install qrencode"
      qrencode -t ANSIUTF8 -l L "$(routing_link)" 2>/dev/null \
        || die "Ссылка слишком длинная для QR — используй «vpn routing» и скопируй её текстом" ;;
    "")
      echo
      echo "${CY}${B}━━ 🧭 Маршрутизация: Россия напрямую, остальное через VPN ━━${N}"
      echo "${D}• .ru/.su/.рф и российские сайты (Яндекс, VK, Госуслуги...) и IP России — напрямую"
      echo "• всё зарубежное, включая Gemini/Google/AI-сервисы — через VPN"
      echo "• реклама заблокирована${N}"
      echo
      echo "${B}Happ${N} ${D}(скопируй ссылку целиком и открой/вставь в приложении — профиль включится сам):${N}"
      echo "  $(routing_link)"
      echo
      echo "${D}Свои исключения: vpn route direct|proxy|block <домен>   (список: vpn route list)"
      echo "После изменений открой ссылку заново — профиль с тем же именем обновится."
      echo "Другие клиенты: в Hiddify поищи в настройках регион «Россия» (обход .ru и российских IP),"
      echo "в v2rayN/NekoBox правила можно собрать вручную: «vpn routing json» покажет списки.${N}"
      echo ;;
    *) die "Использование: vpn routing [json|qr]" ;;
  esac
}

cmd_route() {  # vpn route direct|proxy|block <домен> | vpn route del <список> <домен> | vpn route list
  local a="${1:-}" list dom f
  if [[ "$a" == "list" ]]; then
    for list in direct proxy block; do
      f="$LISTS_DIR/custom-$list.txt"
      echo "${B}$list${N}"
      if [[ -s "$f" ]]; then sed 's/^/  /' "$f"; else echo "  ${D}(пусто)${N}"; fi
    done
    return
  fi
  if [[ "$a" == "del" ]]; then
    list="${2:-}"; dom="${3:-}"; f="$LISTS_DIR/custom-$list.txt"
    [[ "$list" =~ ^(direct|proxy|block)$ && -n "$dom" ]] || die "Использование: vpn route del direct|proxy|block <домен>"
    [[ -f "$f" ]] || die "В списке $list ничего нет"
    grep -vxF "$dom" "$f" > "$f.new" || true
    mv "$f.new" "$f"
    echo "${GR}✓ Удалено из $list: $dom${N}"
    return
  fi
  list="$a"; dom="${2:-}"
  [[ "$list" =~ ^(direct|proxy|block)$ && -n "$dom" ]] \
    || die "Использование: vpn route direct|proxy|block <домен>  (пример: vpn route direct sberbank.com)"
  dom="$(printf '%s' "$dom" | tr 'A-Z' 'a-z')"
  [[ "$dom" =~ ^[a-z0-9._:!-]+$ ]] || die "Недопустимые символы в «$dom» (можно: домен, domain:..., full:..., geosite:...)"
  install -d -m 700 "$LISTS_DIR"
  f="$LISTS_DIR/custom-$list.txt"
  touch "$f"
  grep -qxF "$dom" "$f" || printf '%s\n' "$dom" >> "$f"
  echo "${GR}✓ Добавлено в $list: $dom${N}"
  echo "${D}Обнови профиль в Happ: vpn routing → открой ссылку заново.${N}"
}

cmd_show() {
  local filter="${1:-}" name id found=0
  while IFS=$'\t' read -r name id; do
    [[ -n "$name" ]] || continue
    if [[ -n "$filter" && "$name" != "$filter" ]]; then continue; fi
    found=1
    echo
    echo "${CY}${B}━━ 👤 ${name} ━━${N}  ${D}UUID ${id}${N}"
    echo "${B}VLESS+REALITY${N} ${D}(основной, порт ${PORT_MAIN})${N}"
    echo "  $(vless_link "$name" "$id" "$PORT_MAIN" "$SNI_MAIN" "$PORT_MAIN")"
    if (( PORT_BACKUP > 0 )); then
      echo "${B}VLESS+REALITY${N} ${D}(резервный, порт ${PORT_BACKUP})${N}"
      echo "  $(vless_link "$name" "$id" "$PORT_BACKUP" "$SNI_BACKUP" "$PORT_BACKUP backup")"
    fi
    echo "${D}Всё одной base64-строкой (для «Импорт» в клиенте):${N}"
    echo "  $(bundle "$name" "$id")"
  done < <(list_clients)
  if (( found == 0 )); then die "Пользователь «${filter}» не найден (список: vpn list)"; fi
  if (( PORT_SS > 0 )); then
    echo; echo "${B}Shadowsocks${N} ${D}(порт ${PORT_SS}, общий для всех)${N}"; echo "  $(ss_link)"
  fi
  if (( PORT_MTG > 0 )); then
    echo; echo "${B}Telegram MTProto${N} ${D}(порт ${PORT_MTG})${N}"; echo "  $(mtg_link)"; echo "  ${D}$(mtg_tlink)${N}"
  fi
  echo
  echo "${D}Маршрутизация (Россия напрямую, остальное через VPN): vpn routing${N}"
  echo
}

cmd_list() { list_clients | cut -f1; }

apply_cfg() {  # apply_cfg /tmp/новый.json
  local tmp="$1" grp
  if ! xray_test "$tmp"; then rm -f "$tmp"; die "Новый конфиг не прошёл проверку — изменения отменены"; fi
  cp -a "$XRAY_CFG" "${XRAY_CFG}.bak"
  cat "$tmp" > "$XRAY_CFG"
  grp="$(stat -c %G "${XRAY_CFG}.bak" 2>/dev/null || true)"
  if [[ -n "$grp" && "$grp" != "UNKNOWN" ]]; then chgrp "$grp" "$XRAY_CFG" 2>/dev/null || true; fi
  rm -f "$tmp"
  systemctl restart xray; sleep 1
  if ! systemctl is-active --quiet xray; then
    cp -a "${XRAY_CFG}.bak" "$XRAY_CFG"; systemctl restart xray
    die "Xray не запустился — конфиг возвращён как был"
  fi
}

cmd_add() {
  local name="${1:-}" id tmp
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "Имя: латиница, цифры, _ и -, до 32 символов.  Пример: vpn add anna"
  if list_clients | cut -f1 | grep -qx "$name"; then die "Пользователь «$name» уже есть"; fi
  id="$(xray uuid)"; tmp="$(mktemp --suffix=.json)"
  jq --arg id "$id" --arg n "$name" \
    '.inbounds |= map(if .protocol=="vless" then .settings.clients += [{id:$id, flow:"xtls-rprx-vision", email:$n}] else . end)' \
    "$XRAY_CFG" > "$tmp" || { rm -f "$tmp"; die "jq не смог изменить конфиг"; }
  apply_cfg "$tmp"
  echo "${GR}✓ Пользователь «$name» добавлен${N}"
  cmd_show "$name"
}

cmd_del() {
  local name="${1:-}" tmp
  [[ -n "$name" ]] || die "Укажи имя:  vpn del anna"
  list_clients | cut -f1 | grep -qx "$name" || die "Пользователь «$name» не найден"
  if (( $(list_clients | wc -l) <= 1 )); then die "Нельзя удалить последнего пользователя"; fi
  tmp="$(mktemp --suffix=.json)"
  jq --arg n "$name" \
    '.inbounds |= map(if .protocol=="vless" then .settings.clients |= map(select(.email != $n)) else . end)' \
    "$XRAY_CFG" > "$tmp" || { rm -f "$tmp"; die "jq не смог изменить конфиг"; }
  apply_cfg "$tmp"
  echo "${GR}✓ Пользователь «$name» удалён${N}"
}

cmd_qr() {
  command -v qrencode >/dev/null 2>&1 || die "Нужен qrencode:  apt install qrencode"
  local who="${1:-}" id
  if [[ "$who" == "mtg" ]]; then
    if (( PORT_MTG == 0 )); then die "MTProto не настроен"; fi
    qrencode -t ANSIUTF8 "$(mtg_link)"; return
  fi
  if [[ -z "$who" ]]; then who="$(list_clients | head -n1 | cut -f1)"; fi
  id="$(list_clients | awk -F'\t' -v n="$who" '$1==n{print $2; exit}')"
  [[ -n "$id" ]] || die "Пользователь «$who» не найден"
  qrencode -t ANSIUTF8 "$(vless_link "$who" "$id" "$PORT_MAIN" "$SNI_MAIN" "$PORT_MAIN")"
}

svc() {
  if systemctl cat "$1.service" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$1"; then echo "  ${GR}●${N} $1 работает"; else echo "  ${RD}●${N} $1 НЕ работает"; fi
  fi
}
tcp_retrans() {
  awk '/^Tcp:/ { if (!h) { for (i=1;i<=NF;i++) idx[$i]=i; h=1 }
                 else { o=$idx["OutSegs"]; r=$idx["RetransSegs"];
                        if (o>0) printf "%.2f%% (%.0f из %.0f сегментов)", r*100/o, r, o; else printf "н/д" } }' /proc/net/snmp
}

cmd_status() {
  echo "${B}Службы${N}"; svc xray; svc mtg; svc fail2ban; svc ufw
  if systemctl is-active --quiet fastxray-health.timer 2>/dev/null; then echo "  ${GR}●${N} сторожевой таймер активен"; else echo "  ${YE}●${N} сторожевой таймер выключен"; fi
  echo "  Xray: $(xray version 2>/dev/null | head -n1 | cut -d' ' -f1-2)"
  echo "${B}Сеть${N}"
  echo "  алгоритм TCP: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo н/д), очередь: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo н/д)"
  echo "  conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo н/д) / $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo н/д)"
  echo "  ретрансмиты TCP: $(tcp_retrans)  ${D}(норма < 1%, > 3% — потери на пути)${N}"
  echo "  $(ss -s 2>/dev/null | awk '/^TCP:/')"
  echo "${B}Ресурсы${N}"
  echo "  $(uptime | sed 's/^ *//')"
  echo "  $(free -m | awk '/^Mem:/ {printf "RAM: занято %d из %d МБ", $3, $2}')"
  echo
}

cmd_diag() {
  local syn
  cmd_status
  syn="$(ss -tn state syn-sent 2>/dev/null | tail -n +2 | wc -l)"
  echo "${B}Диагностика${N}"
  echo "  зависших исходящих SYN: ${syn}  ${D}(много — сервер не может достучаться до адресов; часто виноват нерабочий IPv6)${N}"
  if ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1 && ! curl -6 -fsS --max-time 4 -o /dev/null https://www.google.com 2>/dev/null; then
    echo "  ${YE}⚠ IPv6-маршрут есть, но связи нет — запусти setup_vpn.sh и выбери «исправить»${N}"
  fi
  echo "  ретрансмиты по соединениям (формат retrans:сейчас/всего, слева — число таких соединений):"
  ss -tin state established "( sport = :${PORT_MAIN} or sport = :${PORT_BACKUP} )" 2>/dev/null \
    | grep -oE 'retrans:[0-9]+/[0-9]+' | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'
  echo "  последние сообщения сторожевого таймера:"
  journalctl -t fastxray-health -n 5 --no-pager 2>/dev/null | sed 's/^/    /'
  echo
  echo "${B}Как читать:${N}"
  echo "  • vpn speed показывает ~полный канал, а в приложении 2-5 Мбит/с, и ретрансмитов много →"
  echo "    потери на маршруте РФ ↔ сервер (шейпинг ТСПУ/оператора), а не проблема сервера."
  echo "    Пробуй: резервный порт, другой оператор/Wi-Fi, другой SNI, цепочку через VPS в РФ."
  echo "  • conntrack близок к максимуму → поднять net.netfilter.nf_conntrack_max в /etc/sysctl.d/99-fastxray.conf."
  echo
}

cmd_speed() {
  command -v python3 >/dev/null 2>&1 || die "Нужен python3"
  curl -fsSL --max-time 30 https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python3 - --simple
}

cmd_update() {
  local inst; inst="$(mktemp)"
  curl -fsSL --retry 3 --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$inst" || die "Не скачался установщик Xray"
  bash "$inst" install || die "Обновление не удалось"
  rm -f "$inst"
  if ! xray_test "$XRAY_CFG"; then
    echo "${YE}⚠ Новая версия Xray не принимает текущий конфиг — смотри: xray run -test -config $XRAY_CFG${N}" >&2
  fi
  systemctl daemon-reload
  systemctl restart xray
  echo "${GR}✓ Xray обновлён:${N} $(xray version 2>/dev/null | head -n1)"
}

usage() {
  cat <<EOF
${B}vpn${N} — управление сервером FastXray

  vpn show [имя]          ссылки для подключения (всех или одного пользователя)
  vpn qr [имя|mtg]        QR-код (для телефона)
  vpn list                список пользователей
  vpn add <имя>           добавить пользователя (своя ссылка/UUID)
  vpn del <имя>           удалить пользователя
  vpn routing [json|qr]   правила «Россия напрямую, остальное через VPN» (ссылка для Happ)
  vpn route direct|proxy|block <домен>   свои исключения;  vpn route del ... / vpn route list
  vpn status              состояние служб, conntrack, ретрансмиты
  vpn diag                расширенная диагностика «почему медленно»
  vpn speed               скорость самого сервера (speedtest)
  vpn update              обновить Xray-core
  vpn restart             перезапустить xray (и mtg)
  vpn logs                последние строки журнала xray
EOF
}

case "${1:-}" in
  show)    shift; cmd_show "${1:-}" ;;
  qr)      shift; cmd_qr "${1:-}" ;;
  list)    cmd_list ;;
  add)     shift; cmd_add "${1:-}" ;;
  del|rm)  shift; cmd_del "${1:-}" ;;
  routing) shift; cmd_routing "${1:-}" ;;
  route)   shift; cmd_route "$@" ;;
  status)  cmd_status ;;
  diag)    cmd_diag ;;
  speed)   cmd_speed ;;
  update)  cmd_update ;;
  restart) systemctl restart xray; if systemctl cat mtg.service >/dev/null 2>&1; then systemctl restart mtg; fi; echo "${GR}✓ перезапущено${N}" ;;
  logs)    journalctl -u xray -n 50 --no-pager ;;
  *)       usage ;;
esac
VPN_EOF
  chmod 755 "$VPN_BIN"
  ok "Установлена команда «vpn» (vpn show, vpn routing, vpn status, vpn diag ...)"
}

# ---------------------------------------------------------------------------
# Итог
# ---------------------------------------------------------------------------
final_output() {
  # Секреты печатаем только на экран (не в лог)
  {
    echo
    echo "${GR}${B}════════════════════════════════════════════════════════════${N}"
    echo "${GR}${B}   ✅  ГОТОВО — ${TAG}${N}"
    echo "${GR}${B}════════════════════════════════════════════════════════════${N}"
    echo
    echo "${WH}${B}📡 Сервер${N}  ${CY}${SERVER_IP}${N}"
  } >&2
  "$VPN_BIN" show
  if (( PORT_MTG > 0 )) && command -v qrencode >/dev/null 2>&1; then
    echo "${D}QR для Telegram-прокси:${N}"
    qrencode -t ANSIUTF8 "tg://proxy?server=${SERVER_IP}&port=${PORT_MTG}&secret=${MTG_SECRET}"
  fi
  "$VPN_BIN" routing
  {
    echo "${D}${LINE}${N}"
    if [[ "$ROOT_PW_MODE" != "skip" ]]; then
      echo "${WH}${B}🔑 Новый пароль root${N}"
      echo "   ${CY}${ROOT_PW}${N}"
      echo "   ${D}(нужен для консоли хостера и «su»; по SSH root — см. настройки ниже)${N}"
      echo
    fi
    if [[ "$CREATE_USER" == "y" ]]; then
      echo "${WH}${B}👤 Пользователь сервера${N}"
      echo "   Логин:  ${CY}${USERNAME}${N}"
      case "$LOGIN_METHOD" in
        password) echo "   Пароль: ${CY}${USER_PASS}${N}"; echo "   Вход:   ${D}ssh ${USERNAME}@${SERVER_IP}${N}" ;;
        key)      echo "   Вход:   только по SSH-ключу — ${D}ssh ${USERNAME}@${SERVER_IP}${N}"; echo "   Пароль для sudo: ${CY}${USER_PASS}${N}" ;;
        both)     echo "   Пароль: ${CY}${USER_PASS}${N}"; echo "   Вход:   по паролю или ключу — ${D}ssh ${USERNAME}@${SERVER_IP}${N}" ;;
      esac
      echo
    fi
    echo "${WH}${B}🧰 Управление${N}"
    echo "   ${CY}vpn show${N} — ссылки   ${CY}vpn add имя${N} — новый пользователь   ${CY}vpn qr${N} — QR"
    echo "   ${CY}vpn routing${N} — правила РФ/мир   ${CY}vpn route direct сайт.com${N} — исключение"
    echo "   ${CY}vpn status${N} / ${CY}vpn diag${N} — состояние и диагностика   ${CY}vpn speed${N} — скорость сервера"
    echo
    echo "${WH}${B}📲 Подключение${N}"
    echo "   Клиент: Android — Happ/v2RayTun/NekoBox, iOS — Happ/Streisand/Shadowrocket, Windows/macOS — Hiddify/v2RayN."
    echo "   «Добавить из буфера/ссылки» → основной порт ${PORT_MAIN}$( ((PORT_BACKUP>0)) && echo "; ${PORT_BACKUP} — запасной" )."
    echo "   Правила «РФ напрямую» подхватывает Happ (ссылка happ://routing/... выше)."
    echo
    echo "${YE}⚠  Сохрани пароли и ссылки прямо сейчас — пароли нигде не хранятся (ссылки покажет «vpn show»).${N}"
    if [[ "$DISABLE_ROOT_SSH" == "y" || "$DISABLE_PW_SSH" == "y" ]]; then
      echo "${YE}⚠  НЕ закрывай эту SSH-сессию, пока не проверишь вход новым пользователем из ДРУГОГО окна терминала.${N}"
    fi
    echo "${D}Лог установки (без паролей и ссылок): ${LOG_FILE}${N}"
    echo "${GR}${B}════════════════════════════════════════════════════════════${N}"
  } >&2
}

# ---------------------------------------------------------------------------
# Сценарии
# ---------------------------------------------------------------------------
run_full() {
  collect_full
  TOTAL_STEPS=7
  step "Системные пакеты";                            install_packages
  step "Сеть и стабильность: BBR, conntrack, IPv6, swap"; tune_network; handle_ipv6; ensure_swap; limit_journal
  step "Пользователь и пароль root";                  create_user; apply_root_password
  step "Xray-core: установка, ключи, конфиг";         install_xray; gen_xray_data; write_xray_config; install_xray_dropin; start_xray
  step "Telegram MTProto-прокси";                     install_mtg
  step "Firewall, SSH, защита от подбора пароля";     setup_firewall; harden_ssh; setup_fail2ban
  step "Автоперезапуск, команда vpn и итог";          install_watchdog; save_state; install_vpn_cmd; wipe_old_artifacts; final_output
}

run_tune() {
  collect_tune
  TOTAL_STEPS=6
  step "Системные пакеты";                            install_packages
  step "Сеть и стабильность: BBR, conntrack, IPv6, swap"; tune_network; handle_ipv6; ensure_swap; limit_journal
  step "Xray: обновление и исправление конфигурации"
  install_xray
  if [[ "$EXISTING" == "legacy" ]]; then import_legacy_state; fi
  patch_xray_config; install_xray_dropin; start_xray
  step "Telegram MTProto-прокси"
  if (( PORT_MTG > 0 )); then install_mtg; else info "MTProto не настроен — пропускаю"; fi
  step "Безопасность: пароль root, старые логи";      apply_root_password; wipe_old_artifacts
  step "Автоперезапуск, команда vpn и итог";          install_watchdog; save_state; install_vpn_cmd; final_output
}

main() {
  need_root
  init_log
  check_os
  check_tty
  print_banner
  bootstrap_tools
  detect_existing
  if [[ "$MODE" == "tune" ]]; then run_tune; else run_full; fi
}

# Позволяет подключать файл как библиотеку (для тестов): main запускается только напрямую
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
