#!/usr/bin/env bash
# ==============================================================================
#  setup-caddy.sh — подготовка ноды Remnawave к работе за Caddy
#  Автор: Роман Белогор, 2026
#
#  Что делает:
#    • проверяет, что нода Remnawave (Docker-контейнер) запущена и готова;
#    • открывает в UFW порты выбранных транспортов и предупреждает, если порт
#      уже занят чужим процессом (Caddy по умолчанию занимает 443/udp под HTTP/3);
#    • для Hysteria2 находит сертификат Caddy или Let's Encrypt, копирует его
#      в /dev/shm и следит за обновлением: контейнер перезапускается только тогда,
#      когда сертификат действительно изменился.
#
#  Сертификат можно указать вручную:
#      CERT_PATH=/путь/fullchain.pem KEY_PATH=/путь/privkey.pem bash setup-caddy.sh
#  Имя контейнера ноды (по умолчанию remnanode):
#      NODE_CONTAINER=имя bash setup-caddy.sh
#
#  Сами inbound'ы скрипт не создаёт: их добавляют в Config Profile в панели.
# ==============================================================================
set -u -o pipefail

NODE_CONTAINER="${NODE_CONTAINER:-remnanode}"
SYNC_BIN="/usr/local/sbin/remnanode-hy2-certsync"
SYNC_CONF="/etc/remnanode-hy2-certsync.conf"
CERT_PATH="${CERT_PATH:-}"
KEY_PATH="${KEY_PATH:-}"

UFW_ON=0
CERT_DOMAIN=""
CERT_ORIGIN="указан вручную"
CANDIDATES=()   # элементы вида "домен|сертификат|ключ|откуда"
SELECTED=()     # выбранные транспорты: hy2, grpc, xhttp

# ───────────────────────────── вывод ─────────────────────────────

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_OFF=$'\033[0m'

say_ok()   { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
say_info() { printf '%s[ .. ]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
say_warn() { printf '%s[ !! ]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
say_err()  { printf '%s[ xx ]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }

die() {
    say_err "$1"
    if [ -n "${2:-}" ]; then say_warn "$2"; fi
    exit 1
}

# ───────────────────────────── проверка окружения ─────────────────────────────

check_environment() {
    say_info "Проверяю окружение"

    (( EUID == 0 )) || die "Нужны права root" "Запустите: sudo bash $0"
    say_ok "root"

    command -v docker >/dev/null 2>&1 || die "Docker не установлен" "Установите Docker и повторите запуск"
    docker info >/dev/null 2>&1 || die "Docker не отвечает" "Запустите службу: systemctl start docker"
    say_ok "Docker работает"

    docker inspect "$NODE_CONTAINER" >/dev/null 2>&1 \
        || die "Контейнер «$NODE_CONTAINER» не найден" "Сначала установите ноду Remnawave"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$NODE_CONTAINER" 2>/dev/null || echo unknown)
    [ "$state" = "running" ] \
        || die "Контейнер «$NODE_CONTAINER» не запущен (состояние: $state)" "Смотрите логи: docker logs $NODE_CONTAINER"
    say_ok "Контейнер «$NODE_CONTAINER» запущен"

    # Reality на 443/tcp должен уже слушаться: либо на хосте, либо внутри контейнера
    if [ -n "$(ss -H -ltn 'sport = :443' 2>/dev/null)" ]; then
        say_ok "443/tcp слушается"
    elif [ -n "$(docker exec "$NODE_CONTAINER" ss -H -ltn 'sport = :443' 2>/dev/null)" ]; then
        say_ok "443/tcp слушается внутри контейнера"
    else
        die "Никто не слушает 443/tcp" "Похоже, Xray не стартовал: docker logs $NODE_CONTAINER"
    fi

    docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$NODE_CONTAINER" 2>/dev/null \
        | grep -qx '/dev/shm' \
        || die "В контейнер не проброшен /dev/shm" \
               "Добавьте в docker-compose.yml ноды в volumes: - /dev/shm:/dev/shm и выполните docker compose up -d"
    say_ok "/dev/shm проброшен"

    local web=""
    docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qi caddy && web="Caddy"
    docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qi nginx && web="${web:+$web + }Nginx"
    if [ -n "$web" ]; then
        say_ok "Веб-сервер в Docker: $web"
    else
        say_warn "Веб-сервер в контейнерах не найден (если он установлен прямо на хосте, это нормально)"
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        UFW_ON=1
        say_ok "UFW включён, порты открою сам"
    else
        say_warn "UFW не используется: откройте порты в вашем файрволе вручную"
    fi
}

# ───────────────────────────── порты ─────────────────────────────

allow_port() { # порт протокол описание
    local port="$1" proto="$2" what="$3"
    (( UFW_ON )) || return 0
    if ufw status 2>/dev/null | grep -qE "^${port}/${proto}[[:space:]]+ALLOW"; then
        say_ok "$port/$proto уже открыт ($what)"
    elif ufw allow "${port}/${proto}" >/dev/null 2>&1; then
        say_ok "Открыл $port/$proto ($what)"
    else
        say_err "Не удалось открыть $port/$proto"
        return 1
    fi
}

# имена процессов, слушающих порт
port_owner() { # протокол порт
    local flags="-ltnpH"
    [ "$1" = "udp" ] && flags="-lunpH"
    ss $flags 2>/dev/null | awk -v p=":$2\$" '$4 ~ p {print $6}' \
        | grep -o '"[^"]*"' | tr -d '"' | sort -u | tr '\n' ' '
}

warn_if_port_busy() { # протокол порт
    local proto="$1" port="$2" who
    who=$(port_owner "$proto" "$port")
    [ -n "${who// /}" ] || return 0
    if printf '%s' "$who" | grep -qiE 'xray|rw-core|remnanode'; then
        say_ok "$port/$proto уже слушает Xray ($who)"
    else
        say_warn "$port/$proto занят: $who"
        say_warn "Xray не сможет занять порт. Для Caddy отключите HTTP/3 или смените порт; либо выберите другой порт в inbound'е"
    fi
}

# ───────────────────────────── поиск сертификата ─────────────────────────────

remember_cert() { # домен сертификат ключ откуда
    if [ -f "$2" ] && [ -f "$3" ]; then CANDIDATES+=("$1|$2|$3|$4"); fi
    return 0
}

find_letsencrypt_certs() {
    local dir
    for dir in /etc/letsencrypt/live/*/; do
        [ -d "$dir" ] || continue
        [ "$(basename "$dir")" = "README" ] && continue
        remember_cert "$(basename "$dir")" "${dir}fullchain.pem" "${dir}privkey.pem" "Let's Encrypt"
    done
}

# Хранилище Caddy: .../certificates/<каталог ACME>/<домен>/<домен>.crt и .key рядом
scan_caddy_storage() { # каталог метка
    local root="$1" label="$2" crt
    [ -d "$root" ] || return 0
    while IFS= read -r crt; do
        [ -n "$crt" ] || continue
        remember_cert "$(basename "$crt" .crt)" "$crt" "${crt%.crt}.key" "$label"
    done < <(find -L "$root" -maxdepth 6 -type f -name '*.crt' -path '*/certificates/*' 2>/dev/null)
}

find_caddy_certs() {
    local name src
    # Caddy в Docker: смотрим каталоги, смонтированные в контейнер
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        while IFS= read -r src; do
            [ -n "$src" ] && scan_caddy_storage "$src" "Caddy (docker: $name)"
        done < <(docker inspect "$name" -f '{{range .Mounts}}{{println .Source}}{{end}}' 2>/dev/null)
    done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk 'tolower($0) ~ /caddy/ {print $1}')

    # Caddy, поставленный на сам хост
    scan_caddy_storage /var/lib/caddy "Caddy (хост)"
    scan_caddy_storage /root/.local/share/caddy "Caddy (хост)"
}

pick_certificate() {
    if [ -n "$CERT_PATH" ] && [ -n "$KEY_PATH" ]; then
        { [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; } || die "CERT_PATH и KEY_PATH заданы, но файлов там нет"
        CERT_DOMAIN="(не определён)"
        say_ok "Беру сертификат, который вы указали"
    else
        find_letsencrypt_certs
        find_caddy_certs
        (( ${#CANDIDATES[@]} )) || die "Сертификаты не найдены" \
            "Укажите путь сами: CERT_PATH=/путь/fullchain.pem KEY_PATH=/путь/privkey.pem bash $0"

        local pick=0 i answer d c k o
        if (( ${#CANDIDATES[@]} > 1 )); then
            say_info "Нашёл несколько сертификатов. Нужен тот, на чей домен будут заходить клиенты Hysteria2:"
            for i in "${!CANDIDATES[@]}"; do
                IFS='|' read -r d c k o <<< "${CANDIDATES[$i]}"
                printf '   %d) %s  (%s)\n' "$((i + 1))" "$d" "$o"
            done
            read -r -p "Номер: " answer
            [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#CANDIDATES[@]} )) || die "Такого номера нет"
            pick=$((answer - 1))
        fi
        IFS='|' read -r CERT_DOMAIN CERT_PATH KEY_PATH CERT_ORIGIN <<< "${CANDIDATES[$pick]}"
        say_ok "Сертификат: $CERT_DOMAIN ($CERT_ORIGIN)"
    fi

    if command -v openssl >/dev/null 2>&1; then
        local until_date
        until_date=$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)
        [ -n "$until_date" ] && say_info "Срок действия до: $until_date"
        openssl x509 -in "$CERT_PATH" -noout -checkend 0 >/dev/null 2>&1 \
            || say_warn "Сертификат просрочен: проверьте выпуск в Caddy или certbot"
    fi
}

# ───────────────────────────── копирование сертификата ─────────────────────────────

install_certsync() {
    cat > "$SYNC_CONF" <<EOF
CERT_PATH="$CERT_PATH"
KEY_PATH="$KEY_PATH"
NODE_CONTAINER="$NODE_CONTAINER"
EOF
    chmod 600 "$SYNC_CONF"

    cat > "$SYNC_BIN" <<'EOF'
#!/usr/bin/env bash
# Кладёт сертификат в /dev/shm для Hysteria2 в Xray.
# Контейнер ноды перезапускается только если сертификат изменился. Ключ -v: подробный вывод.
set -u
LOUD=0
[ "${1:-}" = "-v" ] && LOUD=1
note() { logger -t remnanode-hy2 "$1"; [ "$LOUD" -eq 1 ] && echo "$1"; return 0; }

. "${CERTSYNC_CONF:-/etc/remnanode-hy2-certsync.conf}"
exec 9>/run/remnanode-hy2-certsync.lock
flock -n 9 || exit 0

DST_CERT=/dev/shm/hysteria_cert.pem
DST_KEY=/dev/shm/hysteria_key.pem

if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
    note "ОШИБКА: не найден сертификат или ключ: $CERT_PATH"
    exit 1
fi

if [ -f "$DST_CERT" ] && [ -f "$DST_KEY" ] && cmp -s "$CERT_PATH" "$DST_CERT" && cmp -s "$KEY_PATH" "$DST_KEY"; then
    note "В /dev/shm уже лежит актуальный сертификат"
    exit 0
fi

cp -f "$CERT_PATH" "$DST_CERT" && cp -f "$KEY_PATH" "$DST_KEY" && chmod 644 /dev/shm/hysteria_*.pem
note "Сертификат скопирован в /dev/shm"
if docker restart "${NODE_CONTAINER:-remnanode}" >/dev/null 2>&1; then
    note "Контейнер ноды перезапущен"
else
    note "Контейнер ноды не перезапущен: Docker недоступен или контейнера нет"
fi
EOF
    chmod 700 "$SYNC_BIN"
    say_ok "Установил $SYNC_BIN"
}

schedule_certsync() {
    local current updated
    current=$(crontab -l 2>/dev/null || true)
    if printf '%s\n' "$current" | grep -q 'hysteria_cert.pem'; then
        say_info "В cron есть старые задачи с копированием сертификата: заменяю их"
    fi
    updated=$(printf '%s\n' "$current" | grep -v 'hysteria_cert.pem' | grep -vF "$SYNC_BIN" || true)
    updated=$(printf '%s\n@reboot sleep 20 && %s\n0 4 * * * %s\n' "$updated" "$SYNC_BIN" "$SYNC_BIN")
    if printf '%s\n' "$updated" | crontab -; then
        say_ok "Cron: проверка при загрузке и каждый день в 04:00"
    fi
}

# ───────────────────────────── выбор транспортов ─────────────────────────────

select_transport() { # hy2|grpc|xhttp
    local t
    for t in "${SELECTED[@]:-}"; do [ "$t" = "$1" ] && return 0; done
    SELECTED+=("$1")
}

choose_transports() {
    say_info "Какие транспорты подготовить к работе рядом с Reality на 443/tcp?"
    echo "   1) Hysteria2         UDP 443"
    echo "   2) VLESS gRPC        TCP 8443  (Reality)"
    echo "   3) VLESS XHTTP       TCP 4443  (Reality)"
    echo "   4) все три сразу"
    local answer token
    read -r -p "Номера через пробел, например «1 3»: " answer
    for token in $answer; do
        case "$token" in
            1) select_transport hy2 ;;
            2) select_transport grpc ;;
            3) select_transport xhttp ;;
            4) SELECTED=(hy2 grpc xhttp); break ;;
            *) die "Не понимаю «$token»" "Допустимы цифры от 1 до 4" ;;
        esac
    done
    (( ${#SELECTED[@]} )) || die "Ничего не выбрано"
    say_ok "Выбрано: ${SELECTED[*]}"
}

prepare_transports() {
    local t
    for t in "${SELECTED[@]}"; do
        case "$t" in
            hy2)
                warn_if_port_busy udp 443
                allow_port 443 udp "Hysteria2"
                pick_certificate
                install_certsync
                "$SYNC_BIN" -v
                schedule_certsync
                ;;
            grpc)
                warn_if_port_busy tcp 8443
                allow_port 8443 tcp "VLESS gRPC"
                ;;
            xhttp)
                warn_if_port_busy tcp 4443
                allow_port 4443 tcp "VLESS XHTTP"
                ;;
        esac
    done
}

# ───────────────────────────── итог ─────────────────────────────

print_summary() {
    local t
    echo
    say_ok "Сервер подготовлен"
    echo "   443/tcp   VLESS Reality (основной)"
    for t in "${SELECTED[@]}"; do
        case "$t" in
            hy2)   echo "   443/udp   Hysteria2; сертификат: $CERT_DOMAIN ($CERT_ORIGIN)"
                   echo "             в inbound укажите /dev/shm/hysteria_cert.pem и /dev/shm/hysteria_key.pem" ;;
            grpc)  echo "   8443/tcp  VLESS gRPC" ;;
            xhttp) echo "   4443/tcp  VLESS XHTTP" ;;
        esac
    done
    echo
    echo "Дальше в панели Remnawave:"
    echo "   1. добавьте нужные inbound'ы в Config Profile ноды;"
    echo "   2. создайте Host на каждый транспорт и включите inbound'ы в Squad."
    echo
    say_warn "Не вставляйте конфиг ноды в онлайн-конвертеры: в нём privateKey Reality."
    say_warn "Если без конвертера не обойтись, на время замените privateKey заглушкой."
}

print_banner() {
    printf '%s' "$C_BLU"
    cat <<'BANNER'
    #####   #####
   ##  ##  ##  ##
  #####   #####
 ## ##   ##  ##
##  ##  #####
BANNER
    printf '%s' "$C_OFF"
    printf '  setup-caddy · Роман Белогор · 2026\n'
}

main() {
    echo
    print_banner
    echo
    say_info "setup-caddy: подготовка ноды Remnawave для работы с Caddy"
    check_environment
    choose_transports
    prepare_transports
    print_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
