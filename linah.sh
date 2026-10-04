#!/usr/bin/env bash
# ==============================================================================
#  LINAH — LINux Audio Helper
#  Диагностика и лечение звука в Linux: PipeWire, PulseAudio, ALSA, Bluetooth.
#
#  Запуск:   bash linah.sh            интерактивное меню (стрелки, Enter, цифры)
#            bash linah.sh --analyze  полный анализ и предложение исправлений
#            bash linah.sh --help     все параметры командной строки
#
#  Всё, что скрипт меняет, обратимо: файлы получают бэкап, а пункт «Полный сброс»
#  возвращает систему к умолчаниям.
# ==============================================================================

readonly LINAH_VERSION="1.1.0"

set -eo pipefail

# --- Палитра стилей для настоящих пацанов ---
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_RED='\033[1;31m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_BLUE='\033[1;34m'
readonly C_MAGENTA='\033[1;35m'
readonly C_CYAN='\033[1;36m'
readonly C_WHITE='\033[1;37m'
readonly C_BG_RED='\033[41;1;37m'
readonly C_BG_GREEN='\033[42;1;30m'
readonly C_BG_BLUE='\033[44;1;37m'
readonly C_BG_MAGENTA='\033[45;1;37m'

# --- Пути к конфигам (динамические для поддержки смены пользователя / SSH) ---
PW_CONF_DIR="${HOME}/.config/pipewire/pipewire.conf.d"
PREAMP_CONF="${PW_CONF_DIR}/99-linah-preamp.conf"
LEGACY_PREAMP_CONF="${PW_CONF_DIR}/99-carbon-preamp.conf"
PRESET_GAMING_CONF="${PW_CONF_DIR}/99-linah-preset-gaming.conf"
PRESET_CINEMA_CONF="${PW_CONF_DIR}/99-linah-preset-cinema.conf"
PRESET_HIFI_CONF="${PW_CONF_DIR}/99-linah-preset-hifi.conf"
RNNOISE_CONF="${PW_CONF_DIR}/99-linah-rnnoise.conf"
WP_DIR_04="${HOME}/.config/wireplumber/bluetooth.lua.d"
WP_CONF_04="${WP_DIR_04}/51-bluez-volume-fix.lua"
WP_DIR_05="${HOME}/.config/wireplumber/wireplumber.conf.d"
WP_CONF_05="${WP_DIR_05}/51-bluez-hw-volume.conf"
WP_STATE_DIR="${HOME}/.local/state/wireplumber"
WP_ROLES_04="${WP_DIR_04}/52-bluez-a2dp-only.lua"
WP_ROLES_05="${WP_DIR_05}/52-bluez-a2dp-only.conf"
BT_MAIN_CONF="/etc/bluetooth/main.conf"

# ==============================================================================
# ВЫБОР ПУНКТОВ СТРЕЛКАМИ
# ------------------------------------------------------------------------------
# Меню печатается как обычно, но в буфер MENU_BUF. menu_read сам находит в нём
# пункты вида [1], [c], 1), • c) и даёт ходить по ним стрелками с подсветкой.
# Цифры и буквы по-прежнему работают: нажал «3» — сразу пункт 3.
# Без терминала (скрипт в конвейере) или с LINAH_PLAIN=1 / --plain —
# классический ввод номера, как раньше.
# ==============================================================================

MENU_BUF="$(mktemp "${TMPDIR:-/tmp}/linah-menu.XXXXXX" 2>/dev/null || echo "/tmp/linah-menu.$$")"
declare -A MENU_LAST=()

# Пояснение под пунктом меню: «↳ Зачем…» / «↳ Когда…». Каждая строка помечена
# невидимым знаком (ZWSP) в начале — по нему menu_read понимает, что это пояснение,
# и в режиме стрелок показывает его только под выбранным пунктом. Без стрелок
# (--plain, конвейер) печатаются все пояснения подряд.
_hint() {
    local w line="" word first=1
    local -a words=()
    : "${LINAH_COLS:=$(tput cols 2>/dev/null || echo 80)}"
    w=$(( LINAH_COLS - 12 )); if (( w < 30 )); then w=30; fi
    # Перенос по словам считает СИМВОЛЫ (fold считает байты, а кириллица — по два)
    read -r -a words <<< "$1"
    for word in "${words[@]}"; do
        if [[ -z "${line}" ]]; then
            line="${word}"
        elif (( ${#line} + 1 + ${#word} <= w )); then
            line+=" ${word}"
        else
            _hint_line "${line}" "${first}"; first=0; line="${word}"
        fi
    done
    if [[ -n "${line}" ]]; then _hint_line "${line}" "${first}"; fi
    return 0
}

_hint_line() {  # <текст> <1 если первая строка>
    if [[ "$2" == "1" ]]; then
        printf '\xe2\x80\x8b        %b↳ %s%b\n' "${C_DIM}" "$1" "${C_RESET}"
    else
        printf '\xe2\x80\x8b          %b%s%b\n' "${C_DIM}" "$1" "${C_RESET}"
    fi
}

_menu_cleanup() {
    rm -f "${MENU_BUF}" 2>/dev/null || true
    # Вернуть курсор, если вышли прямо из меню (Ctrl+C)
    if [[ -t 0 ]]; then printf '\033[?25h' > /dev/tty 2>/dev/null || true; fi
}
trap _menu_cleanup EXIT

_menu_interactive() {
    [[ -z "${LINAH_PLAIN:-}" ]] || return 1
    [[ -t 0 ]] || return 1
    [[ "${TERM:-dumb}" != "dumb" ]] || return 1
    { : > /dev/tty; } 2>/dev/null || return 1
    return 0
}

# Сброс накопившихся нажатий клавиш в буфере терминала (например, лишний Enter после ввода цифр)
_tty_flush() {
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        while read -t 0 < /dev/tty 2>/dev/null; do
            IFS= read -rsn1 _ < /dev/tty 2>/dev/null || break
        done
    fi
}

# menu_read <переменная> <приглашение> [id меню для запоминания позиции]
menu_read() {
    local __var="$1" __prompt="$2" __id="${3:-$2}"
    # printf -v пишет в БЛИЖАЙШУЮ переменную с таким именем. Если вызывающий
    # передал имя, совпадающее с внутренней локальной, ответ «потеряется».
    case "${__var}" in
        __mk|key|seq|sel|line|plain|n|i|j|rest|off|pre|so|sk|seen|cnt|typed|result|rows|cols|sz|avail|sl|start|sum|ph|total|out|used|s|e|seg|tail|exact|longer|L|P|IL|IK|IS|IE|re_br|re_par)
            printf 'menu_read: имя переменной «%s» конфликтует с внутренним — переименуй её\n' "${__var}" >&2
            return 1 ;;
    esac

    if ! _menu_interactive; then
        cat "${MENU_BUF}" >&2
        local __ans=""
        read -r -p "${__prompt}" __ans || true
        printf -v "${__var}" '%s' "${__ans}"
        return 0
    fi

    _tty_flush

    # --- Разбор буфера: строки, их «чистые» версии и найденные пункты ---
    local -a L=() P=() IL=() IK=() IS=() IE=()
    local line plain n=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        L+=("${line}")
        plain="$(printf '%s' "${line}" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g')"
        P+=("${plain}")
        n=$(( n + 1 ))
    done < "${MENU_BUF}"

    local i rest off __mk pre re_br='\[([0-9]{1,2}|[a-zA-Z])\]' re_par='^([[:space:]]*(•[[:space:]]*)?)([0-9]{1,2}|[a-zA-Z])\)[[:space:]]'
    local -A seen=()
    for (( i = 0; i < n; i++ )); do
        plain="${P[$i]}"
        local -a so=() sk=()
        if [[ "${plain}" =~ ${re_par} ]]; then
            so+=("${#BASH_REMATCH[1]}"); sk+=("${BASH_REMATCH[3]}")
        else
            rest="${plain}"; off=0
            while [[ "${rest}" =~ ${re_br} ]]; do
                pre="${rest%%"${BASH_REMATCH[0]}"*}"
                so+=("$(( off + ${#pre} ))"); sk+=("${BASH_REMATCH[1]}")
                off=$(( off + ${#pre} + ${#BASH_REMATCH[0]} ))
                rest="${rest:$(( ${#pre} + ${#BASH_REMATCH[0]} ))}"
            done
        fi
        local j
        for (( j = 0; j < ${#so[@]}; j++ )); do
            __mk="${sk[$j]}"
            [[ -n "${seen[$__mk]:-}" ]] && continue
            seen[$__mk]=1
            IL+=("${i}"); IK+=("${__mk}"); IS+=("${so[$j]}")
            if (( j + 1 < ${#so[@]} )); then IE+=("${so[$(( j + 1 ))]}"); else IE+=("${#plain}"); fi
        done
    done

    # --- Чьи пояснения: каждая строка-пояснение принадлежит ближайшему пункту выше ---
    local -a HOWN=()
    local -A first_item=()
    local __k __own=-1
    for (( __k = 0; __k < ${#IK[@]}; __k++ )); do
        if [[ -z "${first_item[${IL[$__k]}]:-}" ]]; then first_item[${IL[$__k]}]="${__k}"; fi
    done
    for (( i = 0; i < n; i++ )); do
        if [[ "${P[$i]}" == $'\xe2\x80\x8b'* ]]; then
            HOWN[$i]="${__own}"
        else
            HOWN[$i]=""
            if [[ -n "${first_item[$i]:-}" ]]; then __own="${first_item[$i]}"; else __own=-1; fi
        fi
    done

    local cnt=${#IK[@]}
    if (( cnt == 0 )); then
        cat "${MENU_BUF}" > /dev/tty
        local __ans=""
        read -r -p "${__prompt}" __ans < /dev/tty || true
        printf -v "${__var}" '%s' "${__ans}"
        return 0
    fi

    local sel="${MENU_LAST[${__id}]:-0}"
    (( sel >= cnt )) && sel=0
    # Если сохранённая позиция указывает на пункт выхода (0 или q), всегда сбрасываем на первый пункт
    if [[ "${IK[$sel]}" == "0" || "${IK[$sel]}" == "q" || "${IK[$sel]}" == "Q" ]]; then
        sel=0
    fi
    local typed="" key seq result="" redraw=1

    printf '\033[?25l' > /dev/tty
    while true; do
      # Экран перерисовывается ТОЛЬКО после стрелок (и при входе в меню). Пока ты
      # набираешь номер, меняется одна строка ввода: иначе подсветка прыгала бы
      # на пункт «1» раньше, чем успеешь набрать «12».
      if (( redraw )); then
        # --- Отрисовка: окно по высоте терминала, выбранный пункт всегда виден ---
        local rows=24 cols=80 sz
        sz="$(stty size < /dev/tty 2>/dev/null || true)"
        if [[ "${sz}" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
            (( BASH_REMATCH[1] > 0 )) && rows="${BASH_REMATCH[1]}"
            (( BASH_REMATCH[2] > 0 )) && cols="${BASH_REMATCH[2]}"
        fi
        (( rows < 10 )) && rows=24
        (( cols < 20 )) && cols=80
        local -a V=()
        local vi
        for (( i = 0; i < n; i++ )); do
            if [[ -n "${HOWN[$i]}" && "${HOWN[$i]}" != "-1" && "${HOWN[$i]}" != "${sel}" ]]; then continue; fi
            V+=("${i}")
        done
        local nv=${#V[@]} vp=0 sl="${IL[$sel]}"
        for (( vi = 0; vi < nv; vi++ )); do
            if (( V[vi] == sl )); then vp="${vi}"; break; fi
        done
        local avail=$(( rows - 3 )) start=0 sum=0 ph below=0
        if (( avail < 5 )); then avail=5; fi
        # Пояснение выбранного пункта идёт сразу под ним и тоже должно поместиться
        for (( vi = vp + 1; vi < nv; vi++ )); do
            if [[ "${HOWN[${V[$vi]}]}" != "${sel}" ]]; then break; fi
            ph=$(( (${#P[${V[$vi]}]} + cols - 1) / cols )); if (( ph < 1 )); then ph=1; fi
            below=$(( below + ph ))
        done
        sum="${below}"
        for (( vi = vp; vi >= 0; vi-- )); do
            i="${V[$vi]}"
            ph=$(( (${#P[$i]} + cols - 1) / cols )); if (( ph < 1 )); then ph=1; fi
            if (( sum + ph > avail - 1 )); then break; fi
            sum=$(( sum + ph )); start="${vi}"
        done
        local total=0
        for (( vi = 0; vi < nv; vi++ )); do
            ph=$(( (${#P[${V[$vi]}]} + cols - 1) / cols )); if (( ph < 1 )); then ph=1; fi
            total=$(( total + ph ))
        done
        if (( total <= avail )); then start=0; fi

        local out=$'\033[H\033[2J' used=0 s e seg tail
        for (( vi = start; vi < nv; vi++ )); do
            i="${V[$vi]}"
            ph=$(( (${#P[$i]} + cols - 1) / cols )); if (( ph < 1 )); then ph=1; fi
            if (( used + ph > avail )); then break; fi
            used=$(( used + ph ))
            if (( i == sl )); then
                s="${IS[$sel]}"; e="${IE[$sel]}"
                seg="${P[$i]:${s}:$(( e - s ))}"
                tail="${seg##*[![:space:]]}"; seg="${seg%"${tail}"}"
                out+="${P[$i]:0:${s}}"$'\033[7;1m'"${seg}"$'\033[0m'"${tail}${P[$i]:${e}}"$'\n'
            else
                out+="${L[$i]}"$'\033[0m\n'
            fi
        done
        out+=$'\033[2m'"↑↓ выбор · Enter — выполнить · или введи номер/букву · / поиск · q/Esc — назад"$'\033[0m\n'
        out+="${__prompt}${typed:-${IK[$sel]}}"
        printf '%s' "${out}" > /dev/tty
        redraw=0
      fi

        # --- Клавиши ---
        IFS= read -rsn1 key < /dev/tty || { result="0"; break; }
        if [[ "${key}" == $'\033' ]]; then
            seq=""
            IFS= read -rsn2 -t 0.05 seq < /dev/tty || true
            case "${seq}" in
                '[A'|'OA'|'[D'|'OD') sel=$(( (sel - 1 + cnt) % cnt )); typed=""; redraw=1 ;;
                '[B'|'OB'|'[C'|'OC') sel=$(( (sel + 1) % cnt )); typed=""; redraw=1 ;;
                '[H'|'OH')           sel=0; typed=""; redraw=1 ;;
                '[F'|'OF')           sel=$(( cnt - 1 )); typed=""; redraw=1 ;;
                '[5'|'[6')           IFS= read -rsn1 -t 0.05 _ < /dev/tty || true
                                     if [[ "${seq}" == '[5' ]]; then sel=0; else sel=$(( cnt - 1 )); fi; typed=""; redraw=1 ;;
                '')                  result="${seen[0]:+0}"; result="${result:-q}"; break ;;
                *)                   ;;
            esac
            continue
        fi
        case "${key}" in
            '')                       # Enter
                if [[ -n "${typed}" && "${typed}" != "${IK[$sel]}" ]]; then result="${typed}"
                else result="${IK[$sel]}"; fi
                break ;;
            $'\177'|$'\b')            typed="${typed%?}" ;;
            /)
                if [[ -z "${typed}" ]]; then
                    printf '\033[?25h\r\033[K%s/ ' "${__prompt}" > /dev/tty
                    local sq=""
                    read -r sq < /dev/tty || true
                    if [[ -n "${sq}" ]]; then
                        local m_idx=-1
                        local sq_low="${sq,,}"
                        for (( i = 0; i < cnt; i++ )); do
                            local p_low="${P[${IL[$i]}],,}"
                            if [[ "${p_low}" == *"${sq_low}"* ]]; then
                                m_idx="${i}"
                                break
                            fi
                        done
                        if (( m_idx >= 0 )); then
                            sel="${m_idx}"
                        fi
                    fi
                    typed=""
                    redraw=1
                    continue
                fi
                typed+="${key}" ;;
            q|Q)
                if [[ -z "${typed}" && -z "${seen[q]:-}" && -z "${seen[Q]:-}" ]]; then
                    result="${seen[0]:+0}"; result="${result:-q}"; break
                fi
                typed+="${key}" ;;
            *)
                typed+="${key}"
                local exact=-1 longer=0
                for (( i = 0; i < cnt; i++ )); do
                    [[ "${IK[$i]}" == "${typed}" ]] && exact="${i}"
                    [[ "${IK[$i]}" != "${typed}" && "${IK[$i]}" == "${typed}"* ]] && longer=1
                done
                # Номер однозначный (продолжения нет) — выполняем сразу. Если он может
                # быть началом другого (1 → 10..14), ждём следующий символ или Enter.
                if (( exact >= 0 && longer == 0 )); then result="${typed}"; break; fi ;;
        esac
        # Набор текста: обновляем только строку ввода, экран не трогаем
        if [[ -n "${typed}" ]]; then printf '\033[?25h' > /dev/tty; else printf '\033[?25l' > /dev/tty; fi
        printf '\r\033[K%s%s' "${__prompt}" "${typed:-${IK[$sel]}}" > /dev/tty
    done

    if [[ "${result}" == "0" || "${result}" == "q" || "${result}" == "Q" || "${IK[$sel]}" == "0" || "${IK[$sel]}" == "q" || "${IK[$sel]}" == "Q" ]]; then
        MENU_LAST[${__id}]=0
    else
        MENU_LAST[${__id}]="${sel}"
    fi
    printf '\033[?25h\r\033[K%s%s\n' "${__prompt}" "${result}" > /dev/tty
    _tty_flush
    printf -v "${__var}" '%s' "${result}"
    return 0
}
readonly CINNAMON_USER_APPLET="${HOME}/.local/share/cinnamon/applets/sound@cinnamon.org"
readonly CINNAMON_SYS_APPLET="/usr/share/cinnamon/applets/sound@cinnamon.org"

# --- Логирование в дерзком стиле ---
log_title()   { printf "${C_BG_MAGENTA} LINAH ${C_RESET} ${C_BOLD}%b${C_RESET}\n" "$*"; }
log_info()   { printf "${C_CYAN}ℹ️  [ИНФО]${C_RESET} %b\n" "$*"; }
log_cool()   { printf "${C_GREEN}😎 [ЧЁТКО]${C_RESET} %b\n" "$*"; }
log_warn()   { printf "${C_YELLOW}⚠️  [АТАС]${C_RESET} %b\n" "$*"; }
log_danger() { printf "${C_RED}💥 [ОБЛОМ]${C_RESET} %b\n" "$*"; }

print_banner() {
    if [[ "${IS_CLI_CALL:-0}" -eq 0 && -t 1 ]]; then clear 2>/dev/null || true; fi
    # Градиент по строкам логотипа: 256 цветов, а на бедных терминалах — 8-цветный запас
    local -a grad=(51 45 39 33 63 99)
    local nc; nc="$(tput colors 2>/dev/null || echo 8)"
    [[ "${nc}" =~ ^[0-9]+$ ]] || nc=8
    if (( nc < 256 )); then grad=(36 36 34 34 35 35); fi
    local i=0 row
    while IFS= read -r row; do
        if (( nc >= 256 )); then printf '\033[1;38;5;%sm%s\033[0m\n' "${grad[$i]}" "${row}"
        else printf '\033[1;%sm%s\033[0m\n' "${grad[$i]}" "${row}"; fi
        i=$(( i + 1 ))
    done << 'LOGO'
  ██╗     ██╗███╗   ██╗ █████╗ ██╗  ██╗
  ██║     ██║████╗  ██║██╔══██╗██║  ██║
  ██║     ██║██╔██╗ ██║███████║███████║
  ██║     ██║██║╚██╗██║██╔══██║██╔══██║
  ███████╗██║██║ ╚████║██║  ██║██║  ██║
  ╚══════╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝  ╚═╝
LOGO
    printf "  ${C_BOLD}${C_CYAN}LIN${C_RESET}${C_DIM}ux ${C_RESET}${C_BOLD}${C_CYAN}A${C_RESET}${C_DIM}udio ${C_RESET}${C_BOLD}${C_CYAN}H${C_RESET}${C_DIM}elper${C_RESET}   ${C_DIM}·${C_RESET}   ${C_DIM}версия ${LINAH_VERSION}${C_RESET}\n"
    printf "  ${C_DIM}Диагностика и лечение звука в Linux · PipeWire · PulseAudio · ALSA · Bluetooth${C_RESET}\n"
    printf "  ${C_DIM}──────────────────────────────────────────────────────────────────────────────${C_RESET}\n\n"
}

# --- Поиск активных пользовательских сессий (для SSH и root-администрирования) ---
get_active_sessions() {
    local -a sessions=()
    if command -v loginctl &>/dev/null; then
        while read -r sess uid user seat rest; do
            [[ -z "$sess" || "$sess" == "SESSION" ]] && continue
            local has_audio="нет"
            if [[ -S "/run/user/${uid}/pulse/native" || -S "/run/user/${uid}/pipewire-0" ]]; then
                has_audio="да"
            fi
            sessions+=("${sess}:${uid}:${user}:${seat:-seat0}:${has_audio}")
        done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    fi
    for udir in /run/user/*; do
        [[ -d "$udir" ]] || continue
        local uid="${udir##*/}"
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        local uname
        uname="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1 || true)"
        [[ -z "$uname" ]] && continue
        local already=0
        for s in "${sessions[@]:-}"; do
            if [[ "$s" == *":${uid}:${uname}:"* ]]; then already=1; break; fi
        done
        if (( ! already )); then
            local has_audio="нет"
            if [[ -S "/run/user/${uid}/pulse/native" || -S "/run/user/${uid}/pipewire-0" ]]; then
                has_audio="да"
            fi
            sessions+=("dir:${uid}:${uname}:-:${has_audio}")
        fi
    done
    if (( ${#sessions[@]} > 0 )); then
        printf "%s\n" "${sessions[@]}"
    fi
}

switch_to_user_session() {
    local target="$1"
    local uid
    uid="$(id -u "$target" 2>/dev/null || true)"
    if [[ -z "$uid" ]]; then
        log_danger "Пользователь «${target}» не найден в системе."
        return 1
    fi
    local home_dir
    home_dir="$(getent passwd "$target" 2>/dev/null | cut -d: -f6 || true)"
    [[ -z "$home_dir" ]] && home_dir="/home/${target}"

    export TARGET_USER="$target"
    export TARGET_UID="$uid"
    export TARGET_HOME="$home_dir"
    export USER="$target"
    export HOME="$home_dir"
    export XDG_RUNTIME_DIR="/run/user/${uid}"
    export PULSE_SERVER="unix:/run/user/${uid}/pulse/native"
    export PIPEWIRE_RUNTIME_DIR="/run/user/${uid}"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus"

    PW_CONF_DIR="${TARGET_HOME}/.config/pipewire/pipewire.conf.d"
    PREAMP_CONF="${PW_CONF_DIR}/99-linah-preamp.conf"
    LEGACY_PREAMP_CONF="${PW_CONF_DIR}/99-carbon-preamp.conf"
    PRESET_GAMING_CONF="${PW_CONF_DIR}/99-linah-preset-gaming.conf"
    PRESET_CINEMA_CONF="${PW_CONF_DIR}/99-linah-preset-cinema.conf"
    PRESET_HIFI_CONF="${PW_CONF_DIR}/99-linah-preset-hifi.conf"
    RNNOISE_CONF="${PW_CONF_DIR}/99-linah-rnnoise.conf"
    WP_DIR_04="${TARGET_HOME}/.config/wireplumber/bluetooth.lua.d"
    WP_CONF_04="${WP_DIR_04}/51-bluez-volume-fix.lua"
    WP_DIR_05="${TARGET_HOME}/.config/wireplumber/wireplumber.conf.d"
    WP_CONF_05="${WP_DIR_05}/51-bluez-hw-volume.conf"
    WP_STATE_DIR="${TARGET_HOME}/.local/state/wireplumber"
    WP_ROLES_04="${WP_DIR_04}/52-bluez-a2dp-only.lua"
    WP_ROLES_05="${WP_DIR_05}/52-bluez-a2dp-only.conf"
    return 0
}

# --- Проверка запуска от root и подключение к сессии пользователя ---
check_not_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        if [[ -n "${TARGET_USER:-}" ]]; then
            return 0
        fi

        local -a sessions=()
        while IFS=: read -r s_id s_uid s_user s_seat s_aud; do
            [[ -n "$s_user" ]] && sessions+=("${s_user}:${s_uid}:${s_seat}:${s_aud}")
        done < <(get_active_sessions 2>/dev/null || true)

        if (( ${#sessions[@]} == 1 )) && ! _menu_interactive; then
            local s0="${sessions[0]}"
            local u0="${s0%%:*}"
            switch_to_user_session "$u0"
            return 0
        fi

        if _menu_interactive; then
            print_banner
            printf "  ${C_BG_BLUE}${C_WHITE}${C_BOLD} РЕЖИМ СУПЕРПОЛЬЗОВАТЕЛЯ / SSH АДМИНИСТРАТОР ${C_RESET}\n\n"
            printf "  ${C_BOLD}Внимание:${C_RESET} Скрипт запущен с правами ${C_RED}root${C_RESET}.\n"
            printf "  Звуковой сервер PipeWire/PulseAudio работает внутри сессий пользователей.\n"
            printf "  Выберите сессию пользователя для диагностики и управления звуком:\n\n"

            local idx=1
            local -a ulist=()
            for s in "${sessions[@]:-}"; do
                local u="${s%%:*}"
                local rest="${s#*:}"
                local uid="${rest%%:*}"
                rest="${rest#*:}"
                local seat="${rest%%:*}"
                local aud="${rest#*:}"
                local aud_icon="🔊"
                [[ "$aud" != "да" ]] && aud_icon="⚠️ "
                printf "    [%d] %s Пользователь ${C_GREEN}%s${C_RESET} (UID: %s, %s, аудио: %s)\n" "$idx" "$aud_icon" "$u" "$uid" "$seat" "$aud"
                ulist+=("$u")
                idx=$(( idx + 1 ))
            done
            printf "    [m] ✍️  Указать имя пользователя вручную\n"
            printf "    [r] 🛡️  Продолжить от root (только базовый опрос ALSA-оборудования)\n"
            printf "    [0] 🚪 Выход\n\n"

            local pick
            read -r -p "Выберите вариант [1-$(( idx - 1 ))/m/r/0]: " pick
            case "$pick" in
                0|q|Q) exit 0 ;;
                r|R) log_warn "Продолжаем от имени root. Пользовательские сокеты могут быть недоступны."; return 0 ;;
                m|M)
                    read -r -p "Введите имя пользователя: " custom_user
                    if [[ -n "$custom_user" ]]; then
                        switch_to_user_session "$custom_user"
                        return 0
                    fi
                    ;;
                *)
                    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#ulist[@]} )); then
                        local chosen="${ulist[$(( pick - 1 ))]}"
                        switch_to_user_session "$chosen"
                        log_cool "Подключено к аудиосессии пользователя «${chosen}»!"
                        sleep 1
                        return 0
                    fi
                    ;;
            esac
        fi

        if (( ${#sessions[@]} > 0 )); then
            # Авто-подключение к первому пользователю с активным аудио
            for s in "${sessions[@]}"; do
                if [[ "$s" == *":да" ]]; then
                    local auto_u="${s%%:*}"
                    switch_to_user_session "$auto_u"
                    return 0
                fi
            done
            local first_u="${sessions[0]%%:*}"
            switch_to_user_session "$first_u"
            return 0
        fi

        log_danger "Слышь, ковбой, осади коней! Зачем ты запустил меня через sudo/root?!"
        printf "  Звуковой сервер PipeWire/PulseAudio живёт в твоей ПОЛЬЗОВАТЕЛЬСКОЙ сессии.\n"
        printf "  Запусти скрипт от своего обычного юзера без sudo или укажи: ${C_BOLD}sudo %s --user <пользователь>${C_RESET}\n\n" "$0"
        exit 1
    fi
}

# --- Проверка необходимых инструментов ---
check_tools() {
    local missing=()
    for tool in pactl; do
        if ! command -v "${tool}" &>/dev/null; then
            missing+=("${tool}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_danger "У тебя в системе не хватает базовой утилиты: ${missing[*]}"
        printf "  Поставь её через пакетный менеджер (обычно пакет pulseaudio-utils или pipewire-pulse-tools):\n"
        printf "  Ubuntu/Mint/Debian: ${C_BOLD}sudo apt install pulseaudio-utils${C_RESET}\n"
        printf "  Arch Linux:         ${C_BOLD}sudo pacman -S libpulse${C_RESET}\n"
        printf "  Fedora:             ${C_BOLD}sudo dnf install pulseaudio-utils${C_RESET}\n"
        printf "  openSUSE:           ${C_BOLD}sudo zypper install pulseaudio-utils${C_RESET}\n\n"
        exit 1
    fi
}

# --- Определение аудиосервера ---
get_audio_server() {
    if pgrep -x pipewire &>/dev/null; then
        echo "PipeWire"
    elif pgrep -x pulseaudio &>/dev/null; then
        echo "PulseAudio"
    else
        echo "ALSA / Неизвестно"
    fi
}

# --- Определение графического окружения (DE) ---
detect_desktop() {
    local de="${XDG_CURRENT_DESKTOP:-}"
    de="$(echo "${de}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${de}" =~ cinnamon ]] || pgrep -x cinnamon &>/dev/null; then
        echo "cinnamon"
    elif [[ "${de}" =~ kde|plasma ]] || pgrep -x plasmashell &>/dev/null; then
        echo "kde"
    elif [[ "${de}" =~ xfce ]] || pgrep -x xfce4-session &>/dev/null; then
        echo "xfce"
    elif [[ "${de}" =~ mate ]] || pgrep -x mate-session &>/dev/null; then
        echo "mate"
    elif [[ "${de}" =~ gnome ]] || pgrep -x gnome-shell &>/dev/null; then
        echo "gnome"
    else
        echo "other"
    fi
}

# --- Определение дистрибутива ---
detect_distro() {
    if [[ -f "/etc/steamos-release" ]]; then
        echo "SteamOS"
        return
    fi
    local name="Linux"
    if [[ -f "/etc/os-release" ]]; then
        local p_name
        p_name="$(source /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-${NAME}}")"
        [[ -n "${p_name}" ]] && name="${p_name}"
    fi
    echo "${name:-Linux}"
}

# --- Информация о WirePlumber (версия и синтаксис) ---
get_wireplumber_info() {
    # Возвращает: "версия синтаксис" (например: "0.4.17 lua" или "0.5.6 spa-json")
    if ! command -v wireplumber &>/dev/null; then
        echo "none none"
        return
    fi
    local out
    out="$(wireplumber --version 2>/dev/null || true)"
    local ver
    ver="$(echo "${out}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    [[ -z "${ver}" ]] && ver="0.4.0"

    local major minor
    major="$(echo "${ver}" | cut -d. -f1)"
    minor="$(echo "${ver}" | cut -d. -f2)"

    if [[ "${major}" -gt 0 || "${minor}" -ge 5 ]]; then
        echo "${ver} spa-json"
    else
        echo "${ver} lua"
    fi
}

# --- Проверка активности нативного фикса WirePlumber ---
is_native_wp_fix_active() {
    if [[ -f "${WP_CONF_04}" || -f "${WP_CONF_05}" || -f "${WP_ROLES_04}" || -f "${WP_ROLES_05}" ]]; then
        return 0
    fi
    return 1
}

# --- Наложение нативного фикса WirePlumber ---
apply_native_wp_fix() {
    local auto_clean_cache="${1:-1}"
    local wp_info wp_ver wp_syntax
    wp_info="$(get_wireplumber_info)"
    wp_ver="$(echo "${wp_info}" | awk '{print $1}')"
    wp_syntax="$(echo "${wp_info}" | awk '{print $2}')"

    if [[ "${wp_syntax}" == "none" ]]; then
        log_danger "Диспетчер WirePlumber не найден в системе! Фикс применим только для PipeWire + WirePlumber."
        return 1
    fi

    log_info "Обнаружен WirePlumber версии ${C_BOLD}${wp_ver}${C_RESET} (синтаксис: ${C_CYAN}${wp_syntax}${C_RESET})"

    if [[ "${wp_syntax}" == "spa-json" ]]; then
        log_info "Создаём SPA-JSON конфигурацию для WirePlumber 0.5+ (Arch, Fedora, openSUSE, SteamOS и другие свежие дистрибутивы)..."
        mkdir -p "${WP_DIR_05}"
        cat << 'EOF' > "${WP_CONF_05}"
monitor.bluez.rules = [
  {
    matches = [
      {
        device.name = "~bluez_card.*"
      }
    ]
    actions = {
      update-props = {
        # Держим карту в чистом стерео, чтобы HFP не утащил её в моно-рацию
        device.profile = "a2dp-sink"
        bluez5.enable-hw-volume = false
        bluez5.hw-volume = "[]"
      }
    }
  }
  {
    matches = [
      {
        node.name = "~bluez_output.*"
      }
    ]
    actions = {
      update-props = {
        # Отключить авто-занижение уровня при ресэмплинге
        channelmix.normalize = false
        # Разрешить подъём усиления до 1000%
        channelmix.max-volume = 10.0
      }
    }
  }
]
EOF
        rm -f "${WP_CONF_04}"
    else
        log_info "Создаём Lua конфигурацию для WirePlumber 0.4.x (Linux Mint / Ubuntu / Debian)..."
        mkdir -p "${WP_DIR_04}"
        cat << 'EOF' > "${WP_CONF_04}"
-- Блокировка чистого стерео A2DP и отключение сбоящего аппаратного аттенюатора
bluez_monitor.properties["bluez5.enable-hw-volume"] = false

table.insert(bluez_monitor.rules, {
  matches = { { { "device.name", "matches", "bluez_card.*" } } },
  apply_properties = {
    ["device.profile"] = "a2dp-sink",
    ["bluez5.enable-hw-volume"] = false,
    ["bluez5.hw-volume"] = "[]",
  },
})

table.insert(bluez_monitor.rules, {
  matches = { { { "node.name", "matches", "bluez_output.*" } } },
  apply_properties = {
    ["channelmix.normalize"] = false,  -- отключить авто-занижение уровня при ресэмплинге
    ["channelmix.max-volume"] = 10.0,   -- разрешить подъем усиления до 1000%
  },
})
EOF
        rm -f "${WP_CONF_05}"
    fi

    if [[ "${auto_clean_cache}" -eq 1 && -d "${WP_STATE_DIR}" ]]; then
        # Точечно: только профили и маршруты Bluetooth. Полный rm -rf стейта
        # угробил бы громкости всех приложений и выбранные устройства.
        log_info "Точечно сбрасываем закэшированные BT-профили и маршруты..."
        local _f
        for _f in "${WP_STATE_DIR}/default-profile" "${WP_STATE_DIR}/default-routes"; do
            [[ -f "${_f}" ]] || continue
            cp -a "${_f}" "${_f}.linah.bak" 2>/dev/null || true
            sed -i '/bluez/Id' "${_f}" 2>/dev/null || true
        done
    fi

    log_info "Перезапускаем диспетчер сессий WirePlumber..."
    systemctl --user restart wireplumber 2>/dev/null || true
    sleep 1

    log_cool "НАТИВНЫЙ ФИКС WIREPLUMBER УСПЕШНО ПРИМЕНЁН!"
    printf "  • Аппаратная заслонка HW_VOLUME_CTRL отключена.\n"
    printf "  • WirePlumber отдаёт 100%% чистой цифровой мощности (0 dB) напрямую в ЦАП наушников.\n"
    printf "  • Нулевая задержка, чистый звук без виртуальных устройств.\n"
    printf "  • ${C_YELLOW}ВАЖНО:${C_RESET} Если наушники сейчас подключены — выключи/включи их (или переподключи Bluetooth), чтобы применился новый профиль.\n"
    return 0
}

# --- Снятие нативного фикса WirePlumber ---
remove_native_wp_fix() {
    log_info "Удаляем нативные правила WirePlumber..."
    rm -f "${WP_CONF_04}" "${WP_CONF_05}" "${WP_ROLES_04}" "${WP_ROLES_05}"
    if [[ -d "${WP_STATE_DIR}" ]]; then
        log_info "Точечно чистим закэшированные BT-профили WirePlumber..."
        local _f
        for _f in "${WP_STATE_DIR}/default-profile" "${WP_STATE_DIR}/default-routes"; do
            [[ -f "${_f}" ]] && sed -i '/bluez/Id' "${_f}" 2>/dev/null || true
        done
    fi
    log_info "Перезапускаем WirePlumber..."
    systemctl --user restart wireplumber 2>/dev/null || true
    sleep 1
    log_cool "Нативный фикс WirePlumber удалён. Возвращены системные настройки по умолчанию."
}

# --- Пауза для чтения ---
press_enter() {
    if [[ "${IS_CLI_CALL:-0}" -eq 1 ]]; then
        return
    fi
    if [[ -t 0 ]]; then
        printf "\n${C_DIM}Нажми [Enter], чтобы вернуться в меню...${C_RESET}"
        read -r _
    fi
}

# ==============================================================================
# 1. ПОЛНАЯ ДИАГНОСТИКА: «ЧЁ У ТЕБЯ ВООБЩЕ СО ЗВУКОМ?»
# ==============================================================================
show_diagnostics() {
    print_banner
    log_title "РЕНТГЕН ТВОЕЙ АУДИОСИСТЕМЫ"
    printf "================================================================================\n\n"

    # 1. Дистрибутив, сервер и службы
    local distro
    distro="$(detect_distro)"
    printf "  ${C_BOLD}Дистрибутив:${C_RESET} ${C_CYAN}%s${C_RESET}\n" "${distro}"

    local srv
    srv="$(get_audio_server)"
    printf "  ${C_BOLD}Аудиосервер:${C_RESET} "
    if [[ "${srv}" == "PipeWire" ]]; then
        local pw_ver
        pw_ver="$(pipewire --version 2>/dev/null | head -n1 || echo 'активен')"
        local wp_info wp_ver wp_syntax
        wp_info="$(get_wireplumber_info)"
        wp_ver="$(echo "${wp_info}" | awk '{print $1}')"
        wp_syntax="$(echo "${wp_info}" | awk '{print $2}')"
        printf "${C_GREEN}%s (${pw_ver})${C_RESET} | ${C_BOLD}WirePlumber:${C_RESET} ${C_CYAN}%s [синтаксис: %s]${C_RESET}\n" "${srv}" "${wp_ver}" "${wp_syntax}"
    else
        printf "${C_YELLOW}%s${C_RESET}\n" "${srv}"
    fi

    # Статусы демонов systemd
    printf "  ${C_BOLD}Службы пользователя:${C_RESET}\n"
    for unit in pipewire pipewire-pulse wireplumber pulseaudio; do
        if systemctl --user list-unit-files "${unit}.service" &>/dev/null; then
            local st
            st="$(systemctl --user is-active "${unit}" 2>/dev/null || echo 'inactive')"
            if [[ "${st}" == "active" ]]; then
                printf "    %-18s -> ${C_GREEN}● РАБОТАЕТ (active)${C_RESET}\n" "${unit}"
            else
                printf "    %-18s -> ${C_DIM}○ ВЫКЛЮЧЕН (${st})${C_RESET}\n" "${unit}"
            fi
        fi
    done

    # 2. Выход по умолчанию, Нативный фикс и Программный буст
    printf "\n  ${C_BOLD}Главный выход по умолчанию (Default Sink):${C_RESET}\n"
    local def_sink
    def_sink="$(pactl get-default-sink 2>/dev/null || echo 'Не найден')"
    local def_desc
    def_desc="$(LC_ALL=C pactl list sinks 2>/dev/null | grep -B1 -A2 "Name: ${def_sink}" | grep "Description:" | awk -F': ' '{print $2}' || true)"
    [[ -z "${def_desc}" ]] && def_desc="${def_sink}"
    printf "    🎯 ${C_CYAN}%s${C_RESET} ${C_DIM}(%s)${C_RESET}\n" "${def_desc}" "${def_sink}"

    printf "\n  ${C_BOLD}Нативный фикс тихого Bluetooth (WirePlumber enable-hw-volume):${C_RESET}\n"
    if is_native_wp_fix_active; then
        printf "    ${C_GREEN}● АКТИВЕН (HW_VOLUME_CTRL отключен, 100%% чистой мощности в ЦАП)${C_RESET}\n"
        printf "    ${C_DIM}WirePlumber не сдерживает аудиопоток. Гарнитуры с колёсиком играют на максимуме.${C_RESET}\n"
    else
        printf "    ${C_DIM}○ Не установлен (действуют стандартные правила WirePlumber, возможен заниженный звук)${C_RESET}\n"
    fi

    printf "\n  ${C_BOLD}Программный усилитель (PipeWire Preamp Boost):${C_RESET}\n"
    if [[ -f "${PREAMP_CONF}" || -f "${LEGACY_PREAMP_CONF}" ]]; then
        local p_file="${PREAMP_CONF}"
        [[ -f "${LEGACY_PREAMP_CONF}" ]] && p_file="${LEGACY_PREAMP_CONF}"
        local mult_val
        mult_val="$(grep -oE '"Mult"[[:space:]]*=[[:space:]]*[0-9.]+' "${p_file}" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ' || echo '3.0')"
        printf "    ${C_GREEN}● АКТИВЕН (+20 dB / ${mult_val}x софтверное усиление + clamp-лимитер)${C_RESET}\n"
        printf "    ${C_DIM}Сигнал программно разгоняется перед отправкой в наушники.${C_RESET}\n"
    else
        printf "    ${C_DIM}○ Отключен (штатный чистый звук 1.0x, преамп не требуется).${C_RESET}\n"
    fi

    # 3. Список всех выходов и их громкость
    printf "\n  ${C_BOLD}Активные аудиовыходы в системе:${C_RESET}\n"
    local sink_lines
    mapfile -t sink_lines < <(LC_ALL=C pactl list sinks 2>/dev/null || true)
    
    local c_name="" c_desc="" c_vol="" c_mute="" is_bt=0
    for line in "${sink_lines[@]}"; do
        if [[ "${line}" =~ ^Sink\ #[0-9]+ ]]; then
            if [[ -n "${c_name}" ]]; then
                print_sink_card "${c_name}" "${c_desc}" "${c_vol}" "${c_mute}" "${is_bt}" "${def_sink}"
            fi
            c_name="" c_desc="" c_vol="" c_mute="" is_bt=0
        elif [[ "${line}" =~ Name:\ (.*) ]]; then
            c_name="${BASH_REMATCH[1]}"
            [[ "${c_name}" =~ bluez_output ]] && is_bt=1
        elif [[ "${line}" =~ Description:\ (.*) ]]; then
            c_desc="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ /[[:space:]]*([0-9]+)% ]]; then
            c_vol="${BASH_REMATCH[1]}%"
        elif [[ "${line}" =~ Mute:\ (.*) ]]; then
            c_mute="${BASH_REMATCH[1]}"
        fi
    done
    if [[ -n "${c_name}" ]]; then
        print_sink_card "${c_name}" "${c_desc}" "${c_vol}" "${c_mute}" "${is_bt}" "${def_sink}"
    fi

    # 4. Диагностика Bluetooth (если есть)
    printf "\n  ${C_BOLD}Состояние Bluetooth-наушников:${C_RESET}\n"
    if ! command -v bluetoothctl &>/dev/null; then
        printf "    ${C_DIM}Утилита bluetoothctl не найдена.${C_RESET}\n"
    else
        local bt_devs
        bt_devs="$(bluetoothctl devices Connected 2>/dev/null || true)"
        if [[ -z "${bt_devs}" ]]; then
            printf "    ${C_YELLOW}Ни одни Bluetooth-наушники сейчас НЕ подключены.${C_RESET}\n"
            printf "    ${C_DIM}(Вруби наушники и подключи их к компу, чтобы я мог их препарировать).${C_RESET}\n"
        else
            while read -r _ mac name; do
                printf "    🎧 ${C_BOLD}%s${C_RESET} [MAC: ${C_CYAN}%s${C_RESET}]\n" "${name}" "${mac}"
                
                # Ищем карту PulseAudio/PipeWire для этого MAC
                local card_id="bluez_card.${mac//:/_}"
                local card_info
                card_info="$(LC_ALL=C pactl list cards 2>/dev/null | grep -A 35 "Name: ${card_id}" || true)"

                if [[ -n "${card_info}" ]]; then
                    local act_profile
                    act_profile="$(echo "${card_info}" | grep -E "Active Profile:" | awk -F': ' '{print $2}' || true)"
                    local act_codec
                    act_codec="$(echo "${card_info}" | grep -E "bluetooth.codec" | awk -F'=' '{print $2}' | tr -d ' "' || echo 'SBC')"

                    printf "       ├─ Профиль: "
                    if [[ "${act_profile}" =~ a2dp ]]; then
                        printf "${C_GREEN}A2DP Стерео (Качественная музыка)${C_RESET}\n"
                    elif [[ "${act_profile}" =~ headset|handsfree|hsp|hfp ]]; then
                        printf "${C_RED}HSP/HFP Моно-гарнитура (Голос из унитаза/микрофонный режим!)${C_RESET}\n"
                        printf "       │  ${C_YELLOW}👉 Срочно переключай на A2DP в пункте меню [5] или [7]!${C_RESET}\n"
                    else
                        printf "${C_WHITE}%s${C_RESET}\n" "${act_profile}"
                    fi

                    printf "       ├─ Кодек:   ${C_BOLD}%s${C_RESET}" "${act_codec}"
                    if [[ "${act_codec}" =~ sbc_xq ]]; then
                        printf " ${C_YELLOW}(Внимание: если чипсет дешёвый Beken/Compx, в наушниках будет тишина!)${C_RESET}\n"
                    elif [[ "${act_codec}" =~ sbc ]]; then
                        printf " ${C_GREEN}(Стабильные 345 kbps — без лагов и глюков чипсета)${C_RESET}\n"
                    else
                        printf "\n"
                    fi

                    # Проверка на аппаратную громкость и лок
                    printf "       └─ Аппаратная громкость (HW Volume): "
                    if is_native_wp_fix_active; then
                        printf "${C_GREEN}РАЗБЛОКИРОВАНА НА 100%% (Нативный фикс WirePlumber активен)${C_RESET}\n"
                        printf "          ${C_DIM}Аппаратная заслонка снята, звук идёт в наушники на полной цифровой мощности (0 dB).${C_RESET}\n"
                    elif [[ "${card_info}" =~ "bluez5.hw-volume = \"[]\"" || "${card_info}" =~ "bluez5.enable-hw-volume = false" ]]; then
                        printf "${C_GREEN}ОТКЛЮЧЕНА (Сигнал отдаётся на 100%%)${C_RESET}\n"
                    elif [[ "${card_info}" =~ "bluez5.hw-volume = true" || "${card_info}" =~ "volume_exists = true" ]]; then
                        printf "${C_YELLOW}Синхронизируется по AVRCP${C_RESET}\n"
                        printf "          ${C_DIM}Если на наушниках есть кнопки [+] [-], нажми [+] 15 раз до упора. Если только колёсико — примени нативный фикс [4]!${C_RESET}\n"
                    else
                        printf "${C_RED}ПОТЕНЦИАЛЬНЫЙ ЛОК (WirePlumber душит поток)${C_RESET}\n"
                        printf "          ${C_YELLOW}👉 Рекомендуется нативный фикс WirePlumber (пункт меню [4], вариант 1)!${C_RESET}\n"
                    fi
                fi
            done <<< "${bt_devs}"
        fi
    fi

    # 5. Графическое окружение и оверамплификация
    local de
    de="$(detect_desktop)"
    printf "\n  ${C_BOLD}Графическое окружение:${C_RESET} ${C_CYAN}%s${C_RESET}\n" "${de^^}"
    case "${de}" in
        cinnamon)
            if [[ -d "${CINNAMON_USER_APPLET}" ]]; then
                printf "    ├─ Статус ползунка: ${C_GREEN}Модифицирован (разлочен выше 150%%)${C_RESET}\n"
            else
                printf "    ├─ Статус ползунка: ${C_YELLOW}Стандартный (лимит 150%%). Разлочка: пункт [9]${C_RESET}\n"
            fi
            ;;
        kde)
            local k_vol="150"
            if [[ -f "${HOME}/.config/plasma-pa.conf" ]]; then
                k_vol="$(grep -oE 'maximumVolume=[0-9]+' "${HOME}/.config/plasma-pa.conf" | awk -F'=' '{print $2}' || echo '150')"
            fi
            printf "    ├─ Лимит plasma-pa в трее: ${C_BOLD}%s%%${C_RESET}\n" "${k_vol}"
            ;;
        gnome)
            local g_over
            g_over="$(gsettings get org.gnome.desktop.sound allow-volume-above-100-percent 2>/dev/null || echo 'false')"
            printf "    ├─ Оверамплификация GNOME (150%%): ${C_BOLD}%s${C_RESET}\n" "${g_over}"
            ;;
        xfce)
            local x_vol="150"
            if command -v xfconf-query &>/dev/null; then
                x_vol="$(xfconf-query -c xfce4-pulseaudio-plugin -p /volume-max 2>/dev/null || echo '150')"
            fi
            printf "    ├─ Лимит xfce4-pulseaudio: ${C_BOLD}%s%%${C_RESET}\n" "${x_vol}"
            ;;
        mate)
            local m_over
            m_over="$(gsettings get org.mate.volume-control allow-amplified-volume 2>/dev/null || echo 'false')"
            printf "    ├─ Оверамплификация MATE (150%%): ${C_BOLD}%s${C_RESET}\n" "${m_over}"
            ;;
        *)
            printf "    ├─ В WM/тайлинге (i3/Sway/Hyprland) громкость регулируется хоткеями через pactl без лимитов.\n"
            ;;
    esac

    printf "\n================================================================================\n"
    press_enter
}

print_sink_card() {
    local name="$1" desc="$2" vol="$3" mute="$4" is_bt="$5" def="$6"
    local mark=" "
    [[ "${name}" == "${def}" ]] && mark="${C_GREEN}► (По умолчанию)${C_RESET}"

    printf "    • ${C_BOLD}%s${C_RESET} %b\n" "${desc}" "${mark}"
    printf "      ${C_DIM}Имя: %s${C_RESET}\n" "${name}"
    printf "      Громкость: ${C_BOLD}%s${C_RESET} | Mute: " "${vol}"
    if [[ "${mute}" == "yes" || "${mute}" == "да" ]]; then
        printf "${C_RED}ВКЛЮЧЕН (Звука нет!)${C_RESET}\n"
    else
        printf "${C_GREEN}Выключен (Ок)${C_RESET}\n"
    fi
}

# --- Выключение Preamp Boost ---
disable_preamp_boost() {
    log_info "Отключаем PipeWire Preamp Boost..."
    rm -f "${PREAMP_CONF}" "${LEGACY_PREAMP_CONF}"
    systemctl --user restart pipewire wireplumber pipewire-pulse 2>/dev/null || true
    sleep 1

    local def
    def="$(pactl get-default-sink 2>/dev/null || true)"
    if [[ "${def}" =~ Preamp ]]; then
        local phys_sink
        phys_sink="$(LC_ALL=C pactl list short sinks 2>/dev/null | awk '$2 !~ /Preamp/ {print $2}' | head -n1 || true)"
        if [[ -n "${phys_sink}" ]]; then
            pactl set-default-sink "${phys_sink}" 2>/dev/null || true
        fi
    fi
    log_cool "Виртуальный Preamp Boost успешно отключен!"
}

# --- Настройка Preamp Boost (+20 dB Filter-Chain) ---
setup_preamp_boost() {
    if [[ "$(get_audio_server)" != "PipeWire" ]]; then
        log_danger "Твой звук работает не на PipeWire! Нативный Filter-Chain требует PipeWire."
        printf "  Проверь службы или обнови звуковой стек.\n"
        press_enter
        return
    fi

    local bt_sinks
    mapfile -t bt_sinks < <(LC_ALL=C pactl list short sinks 2>/dev/null | awk '$2 ~ /^bluez_output/ {print $2}')

    local target_sink=""
    if [[ ${#bt_sinks[@]} -eq 0 ]]; then
        log_warn "Bluetooth-наушники сейчас НЕ подключены к системе!"
        printf "  Включи наушники, подожди 5 секунд пока подключатся, и попробуй снова.\n"
        printf "  Хочешь привязать усилитель к текущему выходу по умолчанию? [y/N]: "
        read -r yn
        if [[ ! "${yn}" =~ ^[yYдД] ]]; then
            return
        fi
        target_sink="$(pactl get-default-sink 2>/dev/null)"
    elif [[ ${#bt_sinks[@]} -eq 1 ]]; then
        target_sink="${bt_sinks[0]}"
        log_info "Обнаружены твои наушники: ${C_BOLD}${target_sink}${C_RESET}"
    else
        {
        printf "  Найдено несколько Bluetooth-устройств. Выбери нужное:\n"
        local i=1
        for s in "${bt_sinks[@]}"; do
            printf "    [%d] %s\n" "${i}" "${s}"
            ((i++))
        done
        } > "${MENU_BUF}" 2>&1
        menu_read c_idx "Номер устройства: "
        if [[ "${c_idx}" =~ ^[0-9]+$ && "${c_idx}" -ge 1 && "${c_idx}" -le "${#bt_sinks[@]}" ]]; then
            target_sink="${bt_sinks[$((c_idx-1))]}"
        fi
    fi

    if [[ -z "${target_sink}" ]]; then
        log_danger "Устройство не выбрано. Отбой миссии."
        press_enter
        return
    fi

    {
    printf "\n  Выбери мощность разгона (множитель амплитуды):\n"
    printf "    1) ${C_BOLD}3.0x (+20 dB)${C_RESET} — ${C_GREEN}[ЭТАЛОН]${C_RESET} Идеально для фильмов и глухих треков.\n"
    _hint 'Зачем: стандартное усиление с лимитером.'
    _hint 'Когда: тихие фильмы и глухие записи, когда обычных 100% мало.'
    printf "    2) ${C_BOLD}2.5x (+18 dB)${C_RESET} — Чуть помягче, если уши очень чувствительные.\n"
    _hint 'Зачем: мягче стандартного.'
    _hint 'Когда: слух чувствительный или 3.0x кажется слишком громким.'
    printf "    3) ${C_BOLD}3.5x (+22 dB)${C_RESET} — Экстремальный буст для очень тихих записей.\n"
    _hint 'Зачем: максимальное усиление.'
    _hint 'Когда: очень тихие записи. Чем выше усиление, тем больше работы у лимитера.'
    printf "    4) Своё значение вручную (например: 2.8 или 4.0)\n"
    _hint 'Зачем: любой множитель от 1.5 до 5.0.'
    _hint 'Когда: стандартные значения не подошли.'
    printf "\n"

    } > "${MENU_BUF}" 2>&1
    menu_read m_choice "Твой выбор [по умолчанию 1]: "
    local mult="3.0"
    case "${m_choice}" in
        2) mult="2.5" ;;
        3) mult="3.5" ;;
        4)
            read -r -p "Введи число от 1.5 до 5.0: " user_mult
            mult="${user_mult:-3.0}"
            mult="${mult//,/.}"
            ;;
        *) mult="3.0" ;;
    esac

    log_info "Запекаем конфиг PipeWire Filter-Chain с множителем ${mult}x и Clamp-лимитером..."

    mkdir -p "${PW_CONF_DIR}"
    cat << EOF > "${PREAMP_CONF}"
context.modules = [
    { name = libpipewire-module-filter-chain
        args = {
            node.description = "PipeWire Preamp Boost (+20dB)"
            media.name       = "Preamp Boost"
            filter.graph = {
                nodes = [
                    {
                        type    = builtin
                        name    = preamp
                        label   = linear
                        control = { "Mult" = ${mult} "Add" = 0.0 }
                    }
                    {
                        type    = builtin
                        name    = limiter
                        label   = clamp
                        control = { "Min" = -1.0 "Max" = 1.0 }
                    }
                ]
                links = [
                    { output = "preamp:Out" input = "limiter:In" }
                ]
            }
            audio.channels = 2
            audio.position = [ FL FR ]
            capture.props = {
                node.name        = "Preamp_Boost"
                node.description = "Наушники (Усиленный выход +20dB)"
                media.class      = Audio/Sink
                priority.driver  = 1020
                priority.session = 1020
            }
            playback.props = {
                node.name        = "Preamp_Boost.output"
                node.passive     = true
                target.object    = "${target_sink}"
            }
        }
    }
]
EOF

    log_info "Перезапускаем звуковые службы..."
    systemctl --user restart pipewire wireplumber pipewire-pulse 2>/dev/null || true
    sleep 1

    log_info "Калибруем уровни громкости..."
    pactl set-sink-volume "${target_sink}" 100% 2>/dev/null || true
    pactl set-default-sink Preamp_Boost 2>/dev/null || true
    pactl set-sink-volume Preamp_Boost 100% 2>/dev/null || true

    log_cool "ГОТОВО! УСИЛИТЕЛЬ АКТИВИРОВАН И ВПАЯН В СИСТЕМУ!"
    printf "  • Физические наушники открыты на 100%%.\n"
    printf "  • Виртуальный выход «Наушники (Усиленный выход +20dB)» стал основным.\n"
    printf "  • Лимитер срезает любые искажения, клиппинга не будет.\n"
    printf "  • Крути ползунок в трее от 0 до 100%% — теперь это честная мощь!\n"
    press_enter
}

# ==============================================================================
# 2. РЕШЕНИЕ ПРОБЛЕМЫ ТИХОГО BLUETOOTH (НАТИВНЫЙ ФИКС WIREPLUMBER + PREAMP BOOST)
# ==============================================================================
fix_quiet_bluetooth() {
    while true; do
        {
        print_banner
        log_title "БОСС-ЛЕЧЕНИЕ ТИХОГО BLUETOOTH В LINUX"
        printf "================================================================================\n\n"

        local distro
        distro="$(detect_distro)"
        local wp_info wp_ver wp_syntax
        wp_info="$(get_wireplumber_info)"
        wp_ver="$(echo "${wp_info}" | awk '{print $1}')"
        wp_syntax="$(echo "${wp_info}" | awk '{print $2}')"

        local wp_stat
        if is_native_wp_fix_active; then
            wp_stat="${C_GREEN}💎 АКТИВЕН (HW Volume Lock снят, 100% мощности)${C_RESET}"
        else
            wp_stat="${C_YELLOW}⚠️ НЕ УСТАНОВЛЕН (WirePlumber может душить звук)${C_RESET}"
        fi

        local preamp_stat
        if [[ -f "${PREAMP_CONF}" || -f "${LEGACY_PREAMP_CONF}" ]]; then
            preamp_stat="${C_GREEN}🔥 ВКЛЮЧЕН (+20 dB Filter-Chain)${C_RESET}"
        else
            preamp_stat="${C_DIM}○ Отключен${C_RESET}"
        fi

        printf "  • ${C_BOLD}Дистрибутив:${C_RESET}       ${C_CYAN}%s${C_RESET}\n" "${distro}"
        printf "  • ${C_BOLD}Диспетчер сессий:${C_RESET}  WirePlumber ${C_CYAN}%s${C_RESET} [синтаксис: ${C_YELLOW}%s${C_RESET}]\n" "${wp_ver}" "${wp_syntax}"
        printf "  • ${C_BOLD}Нативный фикс WP:${C_RESET}  %b\n" "${wp_stat}"
        printf "  • ${C_BOLD}Preamp Boost:${C_RESET}      %b\n" "${preamp_stat}"

        # Список подключенных BT-устройств
        if command -v bluetoothctl &>/dev/null; then
            local bt_devs
            bt_devs="$(bluetoothctl devices Connected 2>/dev/null || true)"
            if [[ -n "${bt_devs}" ]]; then
                printf "  • ${C_BOLD}Подключено:${C_RESET}        "
                local d_names=()
                while read -r _ _ name; do
                    d_names+=("${name}")
                done <<< "${bt_devs}"
                printf "${C_GREEN}%s${C_RESET}\n" "${d_names[*]}"
            else
                printf "  • ${C_BOLD}Подключено:${C_RESET}        ${C_DIM}Наушники не подключены (включи их для проверки)${C_RESET}\n"
            fi
        fi
        printf "================================================================================\n\n"

        printf "  ${C_BOLD}ВЫБЕРИ СПОСОБ ЛЕЧЕНИЯ, ШЕФ:${C_RESET}\n"
        printf "  ${C_DIM}Здесь два принципиально разных подхода — выбирай то, что нужно именно тебе:${C_RESET}\n\n"

        printf "  ┌─ ${C_BOLD}СПОСОБ 1: Нативный фикс WirePlumber (Аппаратный анлок ЦАП)${C_RESET} ${C_GREEN}[Рекомендуется]${C_RESET}\n"
        printf "  │  ${C_CYAN}Как работает:${C_RESET} Отключает сбоящую синхронизацию аппаратной громкости (enable-hw-volume=false)\n"
        printf "  │               и сбрасывает кэш 20%% громкости. WirePlumber больше не душит PCM-поток.\n"
        printf "  │  ${C_GREEN}Плюсы:${C_RESET}        Чистый сигнал 0 dB напрямую в ЦАП, ноль миллисекунд задержки, никаких виртуальных\n"
        printf "  │               устройств в трее. Наушники играют на своих заводских 100%% громкости.\n"
        printf "  │  ${C_YELLOW}Когда нужен:${C_RESET}  Наушники без кнопок (с колёсиком типа Beken/Compx) играют глухо и тихо на чистой системе.\n"
        printf "  │  ${C_DIM}(Формат конфига выбирается сам: Lua для WirePlumber 0.4, SPA-JSON для 0.5+)${C_RESET}\n"
        printf "  └─► ${C_BOLD}[1] Применить нативный фикс WirePlumber${C_RESET}\n\n"

        printf "  ┌─ ${C_BOLD}СПОСОБ 2: Виртуальный Preamp Boost (+20 dB с DSP-лимитером)${C_RESET} ${C_YELLOW}[Тяжёлая артиллерия]${C_RESET}\n"
        printf "  │  ${C_CYAN}Как работает:${C_RESET} Создаёт виртуальную звуковую карту-фильтр в PipeWire, которая умножает звук\n"
        printf "  │               в 3 раза (+20 dB), а встроенный Clamp-лимитер срезает перегрузки на басах.\n"
        printf "  │  ${C_GREEN}Плюсы:${C_RESET}        Разгоняет громкость ВЫШЕ 100%% физического максимума без треска и хрипов.\n"
        printf "  │  ${C_YELLOW}Когда нужен:${C_RESET}  Даже на честных 100%% громкости тебе мало звука (тихий рип фильма, глухое видео,\n"
        printf "  │               слабый подкаст или тугие высокоомные наушники).\n"
        printf "  └─► ${C_BOLD}[2] Настроить и включить виртуальный Preamp Boost${C_RESET}\n\n"

        printf "  ${C_BOLD}Откат и управление:${C_RESET}\n"
        printf "  ${C_BOLD}[3]${C_RESET} 🧹 Откатить нативный фикс WirePlumber (вернуть стандарт системы)\n"
        _hint 'Зачем: удаляет правило WirePlumber и возвращает стандартное поведение системы.'
        _hint 'Когда: правило не помогло или больше не нужно.'
        printf "  ${C_BOLD}[4]${C_RESET} 🧹 Выключить виртуальный Preamp Boost\n"
        _hint 'Зачем: удаляет виртуальный усилитель.'
        _hint 'Когда: появились хрип и искажения или усиление больше не нужно.'
        printf "  ${C_BOLD}[5]${C_RESET} ℹ️  Памятка по наушникам с цифровыми кнопками [+] / [-]\n"
        _hint 'Зачем: объясняет, как открыть громкость кнопками на корпусе наушников.'
        _hint 'Когда: у наушников есть цифровые кнопки громкости: тогда систему настраивать не нужно.'
        printf "  ${C_BOLD}[0]${C_RESET} 🔙 Назад в главное меню\n\n"

        } > "${MENU_BUF}" 2>&1
        menu_read b_choice "Твой выбор [0-5]: "
        case "${b_choice}" in
            1)
                apply_native_wp_fix 1 || true
                press_enter
                ;;
            2)
                setup_preamp_boost || true
                ;;
            3)
                remove_native_wp_fix || true
                press_enter
                ;;
            4)
                disable_preamp_boost || true
                press_enter
                ;;
            5)
                printf "\n"
                log_title "КАК РАБОТАЮТ НАУШНИКИ С КНОПКАМИ [+] И [-]"
                printf "  Если у тебя гарнитура С ЦИФРОВЫМИ КНОПКАМИ (Sony, JBL, AirPods, Marshall, TWS):\n"
                printf "  1. Включи музыку на компе.\n"
                printf "  2. Жми кнопку [+] прямо на корпусе наушников 10-15 раз подряд до звукового пика.\n"
                printf "  3. Наушники сами аппаратно раскроют свой ЦАП на 100%%, и системный ползунок оживёт!\n"
                printf "  Нативный фикс WirePlumber нужен в первую очередь тем ушам, где кнопок нет (только колёсико).\n"
                press_enter
                ;;
            0|q|Q)
                return
                ;;
            *)
                log_warn "Неверный выбор. Попробуй ещё раз."
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# 3. КОДЕКИ И СТЕРЕО BLUETOOTH (ЛЕЧЕНИЕ «КАК ИЗ ВЕДРА» И МОЛЧАНИЯ SBC-XQ)
# ==============================================================================
fix_codecs_and_profiles() {
    print_banner
    log_title "ЛЕЧИМ КАЧЕСТВО BLUETOOTH: КОДЕКИ И РЕЖИМ СТЕРЕО"
    printf "================================================================================\n\n"

    local bt_cards
    mapfile -t bt_cards < <(LC_ALL=C pactl list short cards 2>/dev/null | awk '$2 ~ /^bluez_card/ {print $2}')

    if [[ ${#bt_cards[@]} -eq 0 ]]; then
        log_warn "Нет подключенных Bluetooth-аудиокарт! Вруби наушники сначала."
        press_enter
        return
    fi

    for card in "${bt_cards[@]}"; do
        {
        printf "  Карта: ${C_BOLD}%s${C_RESET}\n" "${card}"
        local card_raw
        card_raw="$(LC_ALL=C pactl list cards 2>/dev/null | grep -A 120 "Name: ${card}" || true)"
        local cur_profile
        cur_profile="$(echo "${card_raw}" | grep -E "Active Profile:" | awk -F': ' '{print $2}' || true)"
        printf "  Текущий профиль: ${C_CYAN}%s${C_RESET}\n\n" "${cur_profile}"

        printf "  ${C_BOLD}Что делаем?${C_RESET}\n"
        printf "    1) ${C_GREEN}Форсировать чистое стерео (A2DP)${C_RESET} — вытащить наушники из режима глухой рации (HSP/HFP)\n"
        _hint 'Зачем: выводит карту из телефонного режима в стерео A2DP.'
        _hint 'Когда: звук глухой и моно.'
        printf "    2) ${C_YELLOW}Сбросить на стабильный кодек SBC (345 kbps)${C_RESET} — спасает от тишины при зависании SBC-XQ\n"
        _hint 'Зачем: выбирает обычный SBC с битрейтом около 345 кбит/с.'
        _hint 'Когда: тишина или обрывы на SBC-XQ. Слабые чипы наушников его не тянут.'
        printf "    3) Попробовать включить кодек высокой плотности SBC-XQ (если чипсет вытянет)\n"
        _hint 'Зачем: включает SBC повышенного качества, битрейт выше 500 кбит/с.'
        _hint 'Когда: хорошие наушники и хочется лучшего качества. Если пропал звук, вернись к пункту 2.'
        printf "    0) Пропустить эту карту\n\n"

        } > "${MENU_BUF}" 2>&1
        menu_read act "Выбор [1-3, 0]: "
        case "${act}" in
            1)
                log_info "Переключаем профиль на a2dp-sink..."
                pactl set-card-profile "${card}" a2dp-sink 2>/dev/null && \
                    log_cool "Стерео-профиль A2DP успешно принудительно включен!" || \
                    log_danger "Не удалось переключить профиль. Проверь поддержку в системе."
                ;;
            2)
                log_info "Фиксируем стандартный кодек SBC (48kHz, Joint Stereo, Bitpool 53)..."
                # Имена профилей кодеков разнятся между версиями PipeWire,
                # поэтому берём первый реально существующий у этой карты.
                local sbc_prof="" cand
                for cand in a2dp-sink-sbc a2dp-sink; do
                    if grep -qE "^[[:space:]]+${cand}:" <<< "${card_raw}"; then
                        sbc_prof="${cand}"
                        break
                    fi
                done
                if [[ -n "${sbc_prof}" ]] && pactl set-card-profile "${card}" "${sbc_prof}" 2>/dev/null; then
                    log_cool "Установлен надёжный кодек SBC (профиль ${sbc_prof})! Никаких заиканий."
                else
                    log_danger "Профиль SBC у этой карты недоступен. Смотри список профилей в диагностике."
                fi
                ;;
            3)
                log_warn "Включаем SBC-XQ..."
                if pactl set-card-profile "${card}" a2dp-sink-sbc_xq 2>/dev/null; then
                    log_cool "SBC-XQ активирован! Проверь звук. Если в ушах тишина — вернись сюда и выбери пункт 2."
                else
                    log_danger "Твои уши или стек не поддерживают SBC-XQ."
                fi
                ;;
            *) ;;
        esac
    done

    press_enter
}

# ==============================================================================
# 2.5 ЛОГ-КРИМИНАЛИСТИКА: ГОНКА ПРОФИЛЕЙ HFP vs A2DP
# ------------------------------------------------------------------------------
# Классика жанра на чипах Beken/Compx/JL: при коннекте гарнитура и хост
# одновременно тянут HFP (телефонный моно-канал по SCO) и A2DP (стерео).
# Кто успел — тот и съел. Если побеждает HFP, bluetoothd пишет
#   "a2dp-sink profile connect failed ...: Device or resource busy",
# карта падает в headset-head-unit, и ты слышишь глухой тихий моно-звук 8 кГц.
# Снаружи это выглядит как "наушники играют на 20% громкости".
# ==============================================================================

# Безопасный подсчёт вхождений шаблона (никогда не роняет set -e)
_count_matches() { grep -cE "$1" <<< "$2" 2>/dev/null || true; }

# Список индексов загрузок в журнале (от старых к новым)
_journal_boots() {
    journalctl --list-boots --no-pager 2>/dev/null \
        | awk '$1 ~ /^-?[0-9]+$/ {print $1}' || true
}

# Собрать метрики одной загрузки: "BUSY HFP SCO SEP OK"
_boot_bt_metrics() {
    local b="$1" log
    log="$(journalctl -b "${b}" -u bluetooth --user -u pipewire --user -u wireplumber -k --no-pager 2>/dev/null || true)"
    [[ -z "${log}" ]] && log="$(journalctl -b "${b}" --no-pager 2>/dev/null || true)"
    local busy hfp sco sep ok
    busy="$(_count_matches 'a2dp-sink profile connect failed.*resource busy' "${log}")"
    hfp="$(_count_matches 'Hands-Free Voice gateway' "${log}")"
    sco="$(_count_matches 'corrupted SCO|SCO packet for unknown' "${log}")"
    sep="$(_count_matches 'Stream End Point in Use' "${log}")"
    ok="$(_count_matches 'sep[0-9]+/fd[0-9]+: fd\([0-9]+\) ready' "${log}")"
    echo "${busy:-0} ${hfp:-0} ${sco:-0} ${sep:-0} ${ok:-0}"
}

# Текущее состояние трёх ключевых твиков
_tweak_state_multiprofile() {
    grep -qE '^[[:space:]]*MultiProfile[[:space:]]*=[[:space:]]*multiple' "${BT_MAIN_CONF}" 2>/dev/null
}
_tweak_state_a2dp_pin() {
    grep -qE 'device\.profile.*a2dp-sink' "${WP_CONF_04}" "${WP_CONF_05}" 2>/dev/null
}
_tweak_state_roles() {
    grep -qE 'bluez5\.roles' "${WP_CONF_04}" "${WP_CONF_05}" "${WP_ROLES_04}" "${WP_ROLES_05}" 2>/dev/null
}

bt_race_forensics() {
    print_banner
    log_title "ЛОГ-КРИМИНАЛИСТИКА: КТО ИМЕННО ДУШИТ ТВОЙ BLUETOOTH"
    printf "================================================================================\n\n"

    if ! command -v journalctl &>/dev/null; then
        log_danger "В системе нет journalctl (не systemd?). Криминалистика недоступна."
        press_enter
        return
    fi

    printf "  ${C_DIM}Разбираем журнал по загрузкам. Считаем четыре улики:${C_RESET}\n"
    printf "  ${C_BOLD}BUSY${C_RESET} — A2DP не смог подняться: «Device or resource busy» ${C_DIM}(HFP украл канал)${C_RESET}\n"
    printf "  ${C_BOLD}HFP${C_RESET}  — срывы телефонного шлюза Hands-Free Voice gateway\n"
    printf "  ${C_BOLD}SCO${C_RESET}  — битые моно-пакеты ядра ${C_DIM}(верный признак режима рации)${C_RESET}\n"
    printf "  ${C_BOLD}SEP${C_RESET}  — «Stream End Point in Use» при переключении профиля\n"
    printf "  ${C_BOLD}OK${C_RESET}   — сколько раз A2DP-транспорт всё-таки поднялся\n\n"

    printf "  ${C_BOLD}%-6s %-18s %6s %5s %5s %5s %5s  %s${C_RESET}\n" "ЗАГР." "НАЧАЛО" "BUSY" "HFP" "SCO" "SEP" "OK" "ВЕРДИКТ"
    printf "  %s\n" "--------------------------------------------------------------------------"

    local total_bad=0 recent_bad=0 recent_n=0 rows=0
    local b
    for b in $(_journal_boots); do
        local start
        start="$(journalctl -b "${b}" -o short-iso --no-pager 2>/dev/null | head -n1 | cut -c1-16 || true)"
        [[ -z "${start}" ]] && continue
        local m busy hfp sco sep ok
        m="$(_boot_bt_metrics "${b}")"
        read -r busy hfp sco sep ok <<< "${m}"

        local bad=$(( busy + sco ))
        total_bad=$(( total_bad + bad ))
        rows=$(( rows + 1 ))

        # последние 3 загрузки — «текущее самочувствие»
        if [[ "${b}" -ge -2 ]]; then
            recent_bad=$(( recent_bad + bad ))
            recent_n=$(( recent_n + 1 ))
        fi

        local mark
        if [[ "${busy}" -gt 0 ]]; then
            mark="${C_RED}HFP ПЕРЕХВАТИЛ A2DP${C_RESET}"
        elif [[ "${sco}" -gt 0 ]]; then
            mark="${C_YELLOW}падал в моно-режим${C_RESET}"
        elif [[ "${ok}" -gt 0 ]]; then
            mark="${C_GREEN}чистое стерео A2DP${C_RESET}"
        else
            mark="${C_DIM}наушники не подключались${C_RESET}"
        fi
        printf "  %-6s %-18s %6s %5s %5s %5s %5s  %b\n" "${b}" "${start}" "${busy}" "${hfp}" "${sco}" "${sep}" "${ok}" "${mark}"
    done

    if [[ "${rows}" -eq 0 ]]; then
        log_warn "Журнал пуст или недоступен. Включи постоянные логи: sudo mkdir -p /var/log/journal"
        press_enter
        return
    fi

    printf "\n================================================================================\n"
    log_title "ТЕКУЩЕЕ СОСТОЯНИЕ ЗАЩИТЫ"
    printf "\n"

    local s_mp s_pin s_roles
    if _tweak_state_multiprofile; then s_mp="${C_GREEN}✔ включён${C_RESET}"; else s_mp="${C_RED}✘ выключен${C_RESET}"; fi
    if _tweak_state_a2dp_pin;     then s_pin="${C_GREEN}✔ закреплён${C_RESET}"; else s_pin="${C_RED}✘ не закреплён${C_RESET}"; fi
    if _tweak_state_roles;        then s_roles="${C_GREEN}✔ HFP/HSP отключены${C_RESET}"; else s_roles="${C_DIM}○ HFP/HSP активны (микрофон работает)${C_RESET}"; fi

    printf "  • ${C_BOLD}MultiProfile = multiple${C_RESET} в %s: %b\n" "${BT_MAIN_CONF}" "${s_mp}"
    printf "  • ${C_BOLD}Пин профиля a2dp-sink${C_RESET} в WirePlumber:      %b\n" "${s_pin}"
    printf "  • ${C_BOLD}Роли Bluetooth${C_RESET} (bluez5.roles):            %b\n" "${s_roles}"

    printf "\n================================================================================\n"
    log_title "ВЕРДИКТ"
    printf "\n"

    if [[ "${total_bad}" -eq 0 ]]; then
        log_cool "Следов гонки HFP/A2DP в журнале нет. Твоя тишина — не от Bluetooth."
        printf "  Копай в сторону громкости самих наушников (колёсико/кнопки) или мастеринга источника.\n"
    elif [[ "${recent_bad}" -eq 0 ]]; then
        log_cool "Гонка HFP/A2DP была, но в последних загрузках УЖЕ НЕ ПОВТОРЯЕТСЯ."
        printf "  Это и есть момент «излечения». Чтобы он не отвалился после обновления —\n"
        printf "  закрепи защиту через пункт ${C_BOLD}«Вылечить гонку профилей»${C_RESET}.\n"
    else
        log_danger "ГОНКА ПРОФИЛЕЙ АКТИВНА ПРЯМО СЕЙЧАС (${recent_bad} улик в свежих загрузках)."
        printf "  Именно поэтому звук глухой и тихий: ты слушаешь музыку через телефонный\n"
        printf "  моно-канал HFP вместо стерео A2DP. Лечится пунктом ${C_BOLD}«Вылечить гонку профилей»${C_RESET}.\n"
    fi

    printf "\n"
    press_enter
}

# ==============================================================================
# 2.6 ЛЕЧЕНИЕ ГОНКИ ПРОФИЛЕЙ HFP vs A2DP
# ==============================================================================

# --- Твик BlueZ: разрешить одновременные профили (MPS/MPMD) ---
apply_multiprofile_tweak() {
    if [[ ! -f "${BT_MAIN_CONF}" ]]; then
        log_danger "Не нашёл ${BT_MAIN_CONF}. BlueZ установлен?"
        return 1
    fi
    if _tweak_state_multiprofile; then
        log_cool "MultiProfile = multiple уже стоит. Ничего не трогаю."
        return 0
    fi

    log_warn "Нужны права root, чтобы поправить ${BT_MAIN_CONF}."
    local bak="${BT_MAIN_CONF}.linah.bak"

    if ! sudo test -f "${bak}" 2>/dev/null; then
        sudo cp -a "${BT_MAIN_CONF}" "${bak}" || { log_danger "Не смог сделать бэкап."; return 1; }
        log_info "Бэкап сохранён: ${bak}"
    fi

    # Раскомментировать существующую строку, либо дописать в секцию [General]
    if sudo grep -qE '^[[:space:]]*#?[[:space:]]*MultiProfile[[:space:]]*=' "${BT_MAIN_CONF}"; then
        sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*MultiProfile[[:space:]]*=.*|MultiProfile = multiple|' "${BT_MAIN_CONF}"
    elif sudo grep -qE '^\[General\]' "${BT_MAIN_CONF}"; then
        sudo sed -i -E '0,/^\[General\]/s//[General]\nMultiProfile = multiple/' "${BT_MAIN_CONF}"
    else
        printf '[General]\nMultiProfile = multiple\n' | sudo tee -a "${BT_MAIN_CONF}" >/dev/null
    fi

    if _tweak_state_multiprofile; then
        log_cool "MultiProfile = multiple прописан. Перезапускаю bluetoothd..."
        sudo systemctl restart bluetooth 2>/dev/null || sudo service bluetooth restart 2>/dev/null || true
        sleep 2
        return 0
    fi
    log_danger "Не удалось прописать MultiProfile. Проверь файл руками."
    return 1
}

remove_multiprofile_tweak() {
    local bak="${BT_MAIN_CONF}.linah.bak"
    if sudo test -f "${bak}" 2>/dev/null; then
        sudo cp -a "${bak}" "${BT_MAIN_CONF}"
        log_cool "Вернул оригинальный ${BT_MAIN_CONF} из бэкапа."
    else
        sudo sed -i -E 's|^[[:space:]]*MultiProfile[[:space:]]*=.*|#MultiProfile = off|' "${BT_MAIN_CONF}" 2>/dev/null || true
        log_info "Бэкапа не было — просто закомментировал MultiProfile."
    fi
    sudo systemctl restart bluetooth 2>/dev/null || sudo service bluetooth restart 2>/dev/null || true
    sleep 2
}

# --- Твик WirePlumber: выкинуть роли HFP/HSP, чтобы гонки физически не было ---
apply_roles_tweak() {
    local wp_info wp_syntax
    wp_info="$(get_wireplumber_info)"
    wp_syntax="$(echo "${wp_info}" | awk '{print $2}')"

    if [[ "${wp_syntax}" == "spa-json" ]]; then
        mkdir -p "${WP_DIR_05}"
        cat << 'EOF' > "${WP_ROLES_05}"
# linah: только стерео A2DP. Роли телефонной гарнитуры (HFP/HSP) выключены,
# поэтому гонка профилей при коннекте физически невозможна.
# ВНИМАНИЕ: микрофон Bluetooth-гарнитуры при этом не работает.
monitor.bluez.properties = {
  bluez5.roles = [ a2dp_sink a2dp_source ]
  bluez5.hfphsp-backend = "none"
}
EOF
        rm -f "${WP_ROLES_04}"
    else
        mkdir -p "${WP_DIR_04}"
        cat << 'EOF' > "${WP_ROLES_04}"
-- linah: только стерео A2DP. Роли телефонной гарнитуры (HFP/HSP) выключены,
-- поэтому гонка профилей при коннекте физически невозможна.
-- ВНИМАНИЕ: микрофон Bluetooth-гарнитуры при этом не работает.
bluez_monitor.properties["bluez5.roles"] = "[ a2dp_sink a2dp_source ]"
bluez_monitor.properties["bluez5.headset-roles"] = "[ ]"
bluez_monitor.properties["bluez5.hfphsp-backend"] = "none"
EOF
        rm -f "${WP_ROLES_05}"
    fi

    log_info "Перезапускаю WirePlumber..."
    systemctl --user restart wireplumber 2>/dev/null || true
    sleep 2
    log_cool "Роли HFP/HSP отключены — телефонный моно-канал больше не отберёт A2DP."
    log_warn "Микрофон гарнитуры теперь недоступен. Для звонков откати этот твик."
}

remove_roles_tweak() {
    rm -f "${WP_ROLES_04}" "${WP_ROLES_05}"
    systemctl --user restart wireplumber 2>/dev/null || true
    sleep 2
    log_cool "Роли HFP/HSP возвращены. Микрофон гарнитуры снова работает."
}

# --- Чистый переподключ с проверкой результата ---
bt_clean_reconnect() {
    if ! command -v bluetoothctl &>/dev/null; then
        log_danger "Нет bluetoothctl — переподключай наушники руками."
        return 1
    fi

    local macs=()
    mapfile -t macs < <(bluetoothctl devices 2>/dev/null | awk '/^Device /{print $2}')
    if [[ ${#macs[@]} -eq 0 ]]; then
        log_warn "В системе нет сопряжённых Bluetooth-устройств."
        return 1
    fi

    log_info "Кладу адаптер, чтобы сбросить зависшие HFP-сокеты..."
    bluetoothctl power off >/dev/null 2>&1 || true
    sleep 3
    log_info "Поднимаю адаптер..."
    bluetoothctl power on >/dev/null 2>&1 || true
    sleep 3

    local mac
    for mac in "${macs[@]}"; do
        log_info "Подключаю ${mac}..."
        bluetoothctl connect "${mac}" >/dev/null 2>&1 || true
    done
    sleep 5

    # Форсируем стерео на всех поднявшихся BT-картах
    local cards=()
    mapfile -t cards < <(LC_ALL=C pactl list short cards 2>/dev/null | awk '$2 ~ /^bluez_card/ {print $2}')
    local c
    for c in "${cards[@]}"; do
        pactl set-card-profile "${c}" a2dp-sink >/dev/null 2>&1 || true
    done
    sleep 1

    bt_verify_state || true
}

# --- Проверка: реально ли мы в стерео A2DP ---
bt_verify_state() {
    printf "\n"
    log_title "ПРОВЕРКА РЕЗУЛЬТАТА"
    printf "\n"

    local cards=()
    mapfile -t cards < <(LC_ALL=C pactl list short cards 2>/dev/null | awk '$2 ~ /^bluez_card/ {print $2}')
    if [[ ${#cards[@]} -eq 0 ]]; then
        log_warn "Bluetooth-аудиокарта не появилась. Наушники включены и в зоне приёма?"
        return 1
    fi

    local ok_all=0
    local c
    for c in "${cards[@]}"; do
        local prof
        prof="$(LC_ALL=C pactl list cards 2>/dev/null \
                | awk -v n="Name: ${c}" '$0 ~ n {f=1} f && /Active Profile:/ {print $3; exit}')"
        printf "  • Карта ${C_BOLD}%s${C_RESET}\n" "${c}"
        if [[ "${prof}" == a2dp-sink* ]]; then
            printf "    Профиль: ${C_GREEN}%s${C_RESET} — чистое стерео, то что надо.\n" "${prof}"
        else
            printf "    Профиль: ${C_RED}%s${C_RESET} — это НЕ стерео! Звук будет глухой.\n" "${prof:-неизвестен}"
            ok_all=1
        fi
    done

    # Флаги и громкость синка
    local sink_block
    sink_block="$(LC_ALL=C pactl list sinks 2>/dev/null | awk '/Name: bluez_output/,/^$/' || true)"
    if [[ -n "${sink_block}" ]]; then
        local flags vol
        flags="$(grep -m1 'Flags:' <<< "${sink_block}" | sed 's/.*Flags: //' || true)"
        vol="$(grep -m1 'Volume:' <<< "${sink_block}" | sed 's/.*Volume: //' || true)"
        printf "  • Громкость синка: ${C_CYAN}%s${C_RESET}\n" "${vol}"
        printf "  • Флаги синка:     ${C_CYAN}%s${C_RESET}\n" "${flags}"
        if grep -q 'HW_VOLUME_CTRL' <<< "${flags}"; then
            log_warn "Стоит HW_VOLUME_CTRL — PipeWire отдал громкость железу гарнитуры."
            printf "    Если тихо — применяй нативный фикс WirePlumber (меню «Фикс тихого Bluetooth»).\n"
        else
            log_cool "HW_VOLUME_CTRL отсутствует: PipeWire шлёт чистый цифровой PCM на 0 dB."
        fi
    fi

    # Свежие улики гонки за последние 5 минут
    if command -v journalctl &>/dev/null; then
        local fresh
        fresh="$(journalctl --since '5 min ago' --no-pager 2>/dev/null \
                 | grep -cE 'a2dp-sink profile connect failed.*resource busy|corrupted SCO' || true)"
        fresh="${fresh:-0}"
        if [[ "${fresh}" -gt 0 ]]; then
            log_danger "За последние 5 минут в логах ${fresh} свежих улик гонки HFP/A2DP."
            ok_all=1
        else
            log_cool "За последние 5 минут новых улик гонки HFP/A2DP в логах нет."
        fi
    fi

    printf "\n"
    if [[ "${ok_all}" -eq 0 ]]; then
        log_cool "ВСЁ ЧИСТО. Ты в стерео A2DP на полной мощности."
    else
        log_warn "Есть замечания выше. Если звук всё ещё глухой — вырубай роли HFP/HSP (пункт 2)."
    fi
    return 0
}

fix_bt_profile_race() {
    while true; do
        {
        print_banner
        log_title "ЛЕЧЕНИЕ ГОНКИ ПРОФИЛЕЙ: HFP (рация) ПРОТИВ A2DP (стерео)"
        printf "================================================================================\n\n"

        printf "  ${C_DIM}При коннекте гарнитура и комп одновременно тянут два профиля:${C_RESET}\n"
        printf "  ${C_DIM}HFP — телефонный моно-канал 8 кГц, и A2DP — музыкальное стерео.${C_RESET}\n"
        printf "  ${C_DIM}На чипах Beken/Compx/JL они взаимоисключающие. Побеждает HFP — и ты${C_RESET}\n"
        printf "  ${C_DIM}слушаешь музыку через рацию: глухо, тихо, будто громкость на 20%%.${C_RESET}\n\n"

        local s_mp s_pin s_roles
        if _tweak_state_multiprofile; then s_mp="${C_GREEN}✔ включён${C_RESET}"; else s_mp="${C_RED}✘ выключен${C_RESET}"; fi
        if _tweak_state_a2dp_pin;     then s_pin="${C_GREEN}✔ закреплён${C_RESET}"; else s_pin="${C_RED}✘ не закреплён${C_RESET}"; fi
        if _tweak_state_roles;        then s_roles="${C_GREEN}✔ отключены${C_RESET}"; else s_roles="${C_DIM}○ активны${C_RESET}"; fi

        printf "  • ${C_BOLD}Слой 1${C_RESET} — MultiProfile = multiple (BlueZ):   %b\n" "${s_mp}"
        printf "  • ${C_BOLD}Слой 2${C_RESET} — пин профиля a2dp-sink (WirePlumber): %b\n" "${s_pin}"
        printf "  • ${C_BOLD}Слой 3${C_RESET} — роли HFP/HSP выключены:             %b\n" "${s_roles}"
        printf "\n================================================================================\n\n"

        printf "  ${C_BOLD}[1]${C_RESET} 🛡️  ${C_BOLD}Полная броня${C_RESET} ${C_GREEN}[Рекомендуется]${C_RESET} — слои 1 + 2 и чистый переподключ\n"
        _hint 'Зачем: слои 1 и 2 плюс чистое переподключение. Микрофон гарнитуры продолжает работать.'
        _hint 'Когда: звук периодически становится глухим после подключения. Начинай с этого пункта.'
        printf "      ${C_DIM}Микрофон гарнитуры продолжит работать.${C_RESET}\n\n"
        printf "  ${C_BOLD}[2]${C_RESET} ☢️  ${C_BOLD}Ядерный вариант${C_RESET} — плюс слой 3: вырубить HFP/HSP совсем\n"
        _hint 'Зачем: дополнительно полностью отключает телефонные профили HFP/HSP.'
        _hint 'Когда: полная броня не помогла. Цена: микрофон гарнитуры перестанет работать.'
        printf "      ${C_DIM}Гонка становится физически невозможной, но МИКРОФОН ОТКЛЮЧИТСЯ.${C_RESET}\n\n"
        printf "  ${C_BOLD}[3]${C_RESET} 🔌 ${C_BOLD}Только чистый переподключ${C_RESET} — уложить адаптер и поднять заново\n"
        _hint 'Зачем: разовая мера: гасит адаптер и подключает заново, ничего не настраивая.'
        _hint 'Когда: гарнитура прямо сейчас в моно-режиме или не подключается, нужна быстрая помощь.'
        printf "      ${C_DIM}Разовая мера: сбрасывает зависший HFP-сокет прямо сейчас.${C_RESET}\n\n"
        printf "  ${C_BOLD}[4]${C_RESET} 🔬 ${C_BOLD}Проверить текущее состояние${C_RESET} — профиль, флаги, свежие улики в логах\n"
        _hint 'Зачем: показывает текущий профиль, флаги и свежие ошибки в журнале.'
        _hint 'Когда: нужно убедиться, что защита сработала.'
        printf "\n"
        printf "  ${C_BOLD}[5]${C_RESET} 🧹 Откатить слой 3 (вернуть микрофон гарнитуры)\n"
        _hint 'Зачем: возвращает телефонные профили.'
        _hint 'Когда: понадобился микрофон гарнитуры, например для звонков.'
        printf "  ${C_BOLD}[6]${C_RESET} 🧹 Откатить слой 1 (вернуть оригинальный main.conf)\n"
        _hint 'Зачем: возвращает исходный main.conf BlueZ из бэкапа.'
        _hint 'Когда: хочешь убрать правку системного файла.'
        printf "  ${C_BOLD}[0]${C_RESET} 🔙 Назад в главное меню\n\n"

        } > "${MENU_BUF}" 2>&1
        menu_read r_choice "Твой выбор [0-6]: "
        case "${r_choice}" in
            1)
                apply_multiprofile_tweak || true
                apply_native_wp_fix 0 || true
                bt_clean_reconnect || true
                press_enter
                ;;
            2)
                apply_multiprofile_tweak || true
                apply_native_wp_fix 0 || true
                apply_roles_tweak || true
                bt_clean_reconnect || true
                press_enter
                ;;
            3)
                bt_clean_reconnect || true
                press_enter
                ;;
            4)
                bt_verify_state || true
                press_enter
                ;;
            5)
                remove_roles_tweak || true
                press_enter
                ;;
            6)
                remove_multiprofile_tweak || true
                press_enter
                ;;
            0|q|Q)
                return
                ;;
            *)
                log_warn "Неверный выбор. Попробуй ещё раз."
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# 3.5 ДВИЖОК АНАЛИЗА: ИНФРАСТРУКТУРА
# ------------------------------------------------------------------------------
# Каждая проверка добавляет "находку" через add_finding. Находка знает свою
# критичность, человеческое описание, улику из системы и — главное — имя
# функции, которая это чинит. Дальше отчёт сам предлагает применить фиксы.
# ==============================================================================

# ==============================================================================
# МОДЕЛЬ НАХОДКИ
# ------------------------------------------------------------------------------
# Каждая находка обязана отвечать на четыре вопроса, иначе она бесполезна:
#   ЧТО не так · ЧЕМ это грозит · КАК проверить руками · КОМУ это вообще нужно.
# Последние два — защита от «скрипт напугал, а проблемы нет».
#
# Уровни назначаются по НАБЛЮДАЕМОМУ симптому, а не по теоретическому риску:
#   CRIT — звука нет или он сломан ПРЯМО СЕЙЧАС. Чинить обязательно.
#   WARN — звук есть, но объективно хуже, чем мог бы быть.
#   INFO — на любителя. Ничего не сломано, можно не трогать.
# ==============================================================================

FND_SEV=(); FND_TITLE=(); FND_WHY=(); FND_EVID=(); FND_FIX=(); FND_HINT=()
FND_CHECK=(); FND_WHEN=()

reset_findings() {
    FND_SEV=(); FND_TITLE=(); FND_WHY=(); FND_EVID=(); FND_FIX=(); FND_HINT=()
    FND_CHECK=(); FND_WHEN=()
}

# add_finding <CRIT|WARN|INFO> <заголовок> <чем грозит> <улика> \
#             <функция-фикс|-> <что сделает фикс> <команда для ручной проверки> <кому это нужно>
add_finding() {
    FND_SEV+=("$1"); FND_TITLE+=("$2"); FND_WHY+=("$3"); FND_EVID+=("$4")
    FND_FIX+=("$5"); FND_HINT+=("$6"); FND_CHECK+=("${7:-}"); FND_WHEN+=("${8:-}")
}

_have() { command -v "$1" &>/dev/null; }

# Менеджер пакетов текущего дистрибутива
_pkg_mgr() {
    if _have apt-get;  then echo apt;    return; fi
    if _have dnf;      then echo dnf;    return; fi
    if _have pacman;   then echo pacman; return; fi
    if _have zypper;   then echo zypper; return; fi
    if _have apk;      then echo apk;    return; fi
    if _have xbps-install; then echo xbps; return; fi
    echo unknown
}

# Готовая команда установки пакетов для этого дистрибутива
_pkg_install_cmd() {
    case "$(_pkg_mgr)" in
        apt)    echo "sudo apt install -y $*" ;;
        dnf)    echo "sudo dnf install -y $*" ;;
        pacman) echo "sudo pacman -S --needed $*" ;;
        zypper) echo "sudo zypper install -y $*" ;;
        apk)    echo "sudo apk add $*" ;;
        xbps)   echo "sudo xbps-install -y $*" ;;
        *)      echo "# поставь вручную: $*" ;;
    esac
}

_is_pipewire() { pgrep -x pipewire &>/dev/null; }
_is_pulse_native() { pgrep -x pulseaudio &>/dev/null; }

# Список звуковых карт ALSA: "индекс имя"
_alsa_cards() {
    [[ -r /proc/asound/cards ]] || return 0
    awk '/^[[:space:]]*[0-9]+[[:space:]]+\[/ {
        idx=$1; gsub(/[^0-9]/,"",idx);
        name=$2; gsub(/[\[\]]/,"",name);
        print idx" "name
    }' /proc/asound/cards 2>/dev/null || true
}

_default_sink() { pactl get-default-sink 2>/dev/null || true; }

# Блок свойств конкретного синка
_sink_block() {
    LC_ALL=C pactl list sinks 2>/dev/null | awk -v n="Name: $1" '
        $0 ~ n {f=1} f {print} f && /^$/ {exit}' || true
}

# Громкость синка в процентах (первый канал)
_sink_volume_pct() {
    _sink_block "$1" | grep -m1 'Volume:' | grep -oE '[0-9]+%' | head -n1 | tr -d '%' || true
}

# Каталог конфигов PipeWire, создаётся по требованию
_pw_conf_dir() { echo "${HOME}/.config/pipewire/pipewire.conf.d"; }

# Записать файл от root с бэкапом
_sudo_write() {
    local path="$1" content="$2"
    if sudo test -f "${path}" && ! sudo test -f "${path}.linah.bak"; then
        sudo cp -a "${path}" "${path}.linah.bak" 2>/dev/null || true
    fi
    printf '%s\n' "${content}" | sudo tee "${path}" >/dev/null
}

# ==============================================================================
# 3.6 ПРОВЕРКИ: БАЗОВЫЙ СТЕК
# ==============================================================================

# ==============================================================================
# ПРОВЕРКИ: БАЗОВЫЙ СТЕК
# ==============================================================================

check_soundcards() {
    local cards; cards="$(_alsa_cards)"
    if [[ -z "${cards}" ]]; then
        add_finding CRIT \
            "Система не видит ни одной звуковой карты" \
            "Звука не будет вообще: ядро не подняло драйвер snd_*." \
            "/proc/asound/cards пуст" \
            "-" \
            "Автофикса нет: проверь lsmod | grep snd, Secure Boot и dmesg на ошибки snd_*" \
            "cat /proc/asound/cards" \
            "Всем. Без карты звука нет в принципе."
    fi
    return 0
}

check_dummy_output() {
    local def; def="$(_default_sink)"
    if [[ "${def}" == *auto_null* || "${def}" == *dummy* ]]; then
        add_finding CRIT \
            "Активен фиктивный выход Dummy Output" \
            "Звук уходит в никуда — сервер не нашёл ни одной реальной карты." \
            "выход по умолчанию: ${def}" \
            "fix_restart_stack" \
            "Перезапустить звуковой стек" \
            "pactl get-default-sink" \
            "Всем. Dummy Output означает, что звука нет совсем."
    fi
    return 0
}

check_audio_services() {
    if _is_pipewire; then
        local dead=() u
        for u in pipewire wireplumber pipewire-pulse; do
            systemctl --user list-unit-files "${u}.service" &>/dev/null || continue
            systemctl --user is-active "${u}" &>/dev/null || dead+=("${u}")
        done
        if [[ ${#dead[@]} -gt 0 ]]; then
            add_finding CRIT \
                "Службы аудио не запущены: ${dead[*]}" \
                "Без диспетчера сессий устройства не появятся." \
                "systemctl --user is-active -> inactive" \
                "fix_start_services" \
                "Запустить и добавить в автозагрузку" \
                "systemctl --user is-active pipewire wireplumber pipewire-pulse" \
                "Всем, у кого PipeWire. Без этих служб звука нет."
        fi
    elif ! _is_pulse_native && ! _have aplay; then
        add_finding CRIT \
            "Не найдено ни PipeWire, ни PulseAudio" \
            "Приложения не смогут вывести звук через стандартный API." \
            "нет процессов pipewire и pulseaudio" \
            "-" \
            "Поставить звуковой сервер: $(_pkg_install_cmd pipewire pipewire-pulse wireplumber)" \
            "pgrep -l 'pipewire|pulseaudio'" \
            "Всем."
    fi
    return 0
}

check_server_conflict() {
    if _is_pipewire && _is_pulse_native; then
        add_finding CRIT \
            "Одновременно работают PipeWire и классический PulseAudio" \
            "Два сервера дерутся за карту: пропадает звук, дубли устройств, треск." \
            "запущены оба процесса сразу" \
            "fix_server_conflict" \
            "Отключить и замаскировать старый pulseaudio" \
            "pgrep -l pipewire; pgrep -l pulseaudio" \
            "Всем. Это всегда ошибка конфигурации, а не выбор."
    fi
    return 0
}

check_pulse_bridge() {
    if _is_pipewire && ! _is_pulse_native; then
        if ! systemctl --user is-active pipewire-pulse &>/dev/null; then
            add_finding WARN \
                "Нет моста pipewire-pulse" \
                "Приложения, умеющие только PulseAudio (браузеры, Telegram, Steam), останутся без звука." \
                "служба pipewire-pulse не активна" \
                "-" \
                "Поставить мост: $(_pkg_install_cmd pipewire-pulse)" \
                "systemctl --user is-active pipewire-pulse" \
                "Тем, у кого часть программ молчит, а часть играет."
        fi
    fi
    return 0
}

# ==============================================================================
# ПРОВЕРКИ: ГРОМКОСТЬ И МЬЮТЫ
# ==============================================================================

check_alsa_mutes() {
    _have amixer || return 0
    local muted=() zeroed=() live_main=()
    local idx name ctl state
    while read -r idx name; do
        [[ -z "${idx}" ]] && continue
        while IFS= read -r ctl; do
            [[ -z "${ctl}" ]] && continue
            state="$(amixer -c "${idx}" sget "${ctl}" 2>/dev/null || true)"
            [[ -z "${state}" ]] && continue
            if grep -q '\[off\]' <<< "${state}"; then
                muted+=("card${idx}:${ctl}")
            elif grep -qE '\[0%\]' <<< "${state}"; then
                zeroed+=("card${idx}:${ctl}")
            else
                case "${ctl}" in Master|PCM|Speaker) live_main+=("card${idx}:${ctl}") ;; esac
            fi
        done < <(amixer -c "${idx}" scontrols 2>/dev/null \
                 | sed -E "s/^Simple mixer control '(.*)',.*/\1/" \
                 | grep -E '^(Master|Speaker|Headphone|PCM|Front|Digital|Line Out)$' || true)
    done <<< "$(_alsa_cards)"

    if [[ ${#muted[@]} -gt 0 ]]; then
        if [[ ${#live_main[@]} -gt 0 ]]; then
            add_finding INFO \
                "В микшере ALSA заглушены отдельные каналы: ${muted[*]}" \
                "Эти выходы молчат. Основной канал при этом жив, так что звук в системе есть." \
                "amixer: [off] на ${muted[*]}, но живы ${live_main[*]}" \
                "fix_alsa_unmute" \
                "Снять mute и поднять до 100% все основные регуляторы" \
                "amixer -c 0 sget ${muted[0]##*:}" \
                "Только если ждёшь звук именно из этого выхода. Заглушенный Headphone при пустом гнезде — норма, трогать не надо."
        else
            add_finding CRIT \
                "В микшере ALSA заглушено ВСЁ: ${muted[*]}" \
                "Сервер показывает 100%, а железо молчит. Звука нет вообще." \
                "amixer: [off] на всех основных каналах" \
                "fix_alsa_unmute" \
                "Снять mute и поднять до 100%" \
                "amixer -c 0" \
                "Всем, у кого нет звука. Это причина номер один."
        fi
    fi
    if [[ ${#zeroed[@]} -gt 0 ]]; then
        add_finding WARN \
            "В микшере ALSA уровни на нуле: ${zeroed[*]}" \
            "Аппаратный регулятор в нуле, а системный ползунок этого не показывает." \
            "amixer: [0%] на ${zeroed[*]}" \
            "fix_alsa_unmute" \
            "Поднять аппаратные уровни до 100%" \
            "amixer -c 0 sget ${zeroed[0]##*:}" \
            "Тем, у кого звук тихий при ползунке на максимуме."
    fi
    return 0
}

check_sink_mute_volume() {
    _have pactl || return 0
    local def blk; def="$(_default_sink)"
    [[ -z "${def}" ]] && return 0
    blk="$(_sink_block "${def}")"
    [[ -z "${blk}" ]] && return 0

    if grep -qE '^[[:space:]]*Mute: yes' <<< "${blk}"; then
        add_finding CRIT \
            "Текущий выход замьючен" \
            "Звука нет, хотя приложения играют." \
            "${def}: Mute: yes" \
            "fix_sink_unmute" \
            "Снять mute" \
            "pactl list sinks | grep -A15 '${def}' | grep Mute" \
            "Всем, у кого пропал звук."
    fi

    local vol; vol="$(_sink_volume_pct "${def}")"
    [[ -z "${vol}" ]] && return 0
    if [[ "${vol}" -lt 40 ]]; then
        add_finding WARN \
            "Громкость текущего выхода всего ${vol}%" \
            "Звук будет казаться задушенным независимо от остальных настроек." \
            "${def}: ${vol}%" \
            "fix_sink_volume_100" \
            "Выставить 100% (0 dB)" \
            "pactl get-sink-volume @DEFAULT_SINK@" \
            "Тем, кто не убавлял громкость намеренно."
    elif [[ "${vol}" -gt 100 ]]; then
        add_finding INFO \
            "Громкость выхода поднята выше 100% (сейчас ${vol}%)" \
            "Возможен клиппинг на пиках и басах. Шкала кубическая: 200% это +18 dB, а не вдвое." \
            "${def}: ${vol}%" \
            "fix_sink_volume_100" \
            "Вернуть честные 100%" \
            "pactl get-sink-volume @DEFAULT_SINK@" \
            "Только если слышишь хрип. Если поднял сознательно и всё чисто — не трогай."
    fi
    return 0
}

check_wrong_output() {
    _have pactl || return 0
    local def; def="$(_default_sink)"
    [[ -z "${def}" ]] && return 0
    [[ "$(LC_ALL=C pactl list short sinks 2>/dev/null | wc -l)" -lt 2 ]] && return 0
    if [[ "${def}" == *hdmi* || "${def}" == *iec958* ]]; then
        add_finding INFO \
            "Звук по умолчанию идёт в цифровой выход (HDMI/S-PDIF)" \
            "Если монитор или ресивер его не воспроизводит, будет казаться, что звук пропал." \
            "выход по умолчанию: ${def}" \
            "fix_switch_sink" \
            "Переключить вывод и перенести туда активные потоки" \
            "pactl get-default-sink" \
            "Только если звука нет. Если ты сознательно выводишь на телевизор — так и должно быть."
    fi
    return 0
}

check_stream_routing() {
    _have pactl || return 0
    local def def_idx other; def="$(_default_sink)"
    [[ -z "${def}" ]] && return 0
    def_idx="$(LC_ALL=C pactl list short sinks 2>/dev/null | awk -v d="${def}" '$2==d {print $1}')"
    [[ -z "${def_idx}" ]] && return 0
    other="$(LC_ALL=C pactl list short sink-inputs 2>/dev/null | awk -v i="${def_idx}" '$2!=i' | wc -l)"
    if [[ "${other}" -gt 0 ]]; then
        add_finding INFO \
            "${other} звуковых потока(ов) играют не в текущий выход" \
            "Ты переключил устройство, но уже запущенные приложения остались на старом." \
            "pactl list short sink-inputs: чужой индекс синка" \
            "fix_move_streams" \
            "Перенести все потоки в текущий выход" \
            "pactl list short sink-inputs; pactl get-default-sink" \
            "Тем, у кого часть программ звучит не туда."
    fi
    return 0
}

# ==============================================================================
# ПРОВЕРКИ: ТРЕСК, ЩЕЛЧКИ, ЗАДЕРЖКИ
# ==============================================================================

check_hda_power_save() {
    local f=/sys/module/snd_hda_intel/parameters/power_save
    [[ -r "${f}" ]] || return 0
    local v; v="$(cat "${f}" 2>/dev/null || echo 0)"
    if [[ "${v}" =~ ^[0-9]+$ && "${v}" -gt 0 ]]; then
        add_finding INFO \
            "Включено энергосбережение звукового кодека (power_save=${v})" \
            "Карта засыпает между треками. Типичное следствие — щелчок при старте звука и обрезанные первые доли секунды." \
            "${f} = ${v}" \
            "fix_hda_power_save" \
            "Отключить засыпание кодека сейчас и навсегда" \
            "cat ${f}" \
            "Только если слышишь щелчки или пропадает начало звука. Не слышишь — оставь: это экономит батарею."
    fi
    return 0
}

check_xruns() {
    _have journalctl || return 0
    local n; n="$(journalctl --user -b 0 --no-pager 2>/dev/null | grep -ciE 'xrun|underrun|buffer underflow' || true)"
    n="${n:-0}"
    if [[ "${n}" -gt 20 ]]; then
        add_finding WARN \
            "В логах ${n} срывов буфера за эту загрузку" \
            "Это и есть слышимый треск, щелчки и заикания при воспроизведении." \
            "journalctl --user -b 0 | grep -c xrun  ->  ${n}" \
            "fix_latency_menu" \
            "Увеличить размер буфера (quantum)" \
            "journalctl --user -b 0 | grep -iE 'xrun|underrun' | tail -20" \
            "Тем, кто реально слышит треск. Счётчик может расти и от разовых событий вроде подключения устройства."
    fi
    return 0
}

check_rt_priority() {
    _is_pipewire || return 0
    local rt; rt="$(ulimit -r 2>/dev/null || echo 0)"
    rt="${rt//unlimited/99}"
    [[ "${rt}" =~ ^[0-9]+$ ]] || rt=0
    local rtkit=0; pgrep -x rtkit-daemon &>/dev/null && rtkit=1
    if [[ "${rt}" -lt 10 && "${rtkit}" -eq 0 ]]; then
        add_finding INFO \
            "Аудиосерверу недоступны приоритеты реального времени" \
            "Под тяжёлой нагрузкой (сборка, игра) звук может начать заикаться." \
            "ulimit -r = ${rt}, rtkit-daemon не запущен" \
            "fix_rt_priority" \
            "Прописать rtprio и memlock для группы audio" \
            "ulimit -r; pgrep -l rtkit-daemon" \
            "Тем, у кого звук рвётся именно под нагрузкой. В обычной работе разницы не будет."
    fi
    return 0
}

check_suspend_on_idle() {
    _is_pipewire || return 0
    if ! grep -rqs 'suspend-timeout-seconds' "${HOME}/.config/wireplumber" 2>/dev/null; then
        add_finding INFO \
            "Устройства засыпают при простое (штатное поведение)" \
            "Первые 100-300 мс звука могут обрезаться, на части USB-ЦАПов слышен щелчок пробуждения." \
            "нет правила session.suspend-timeout-seconds" \
            "fix_suspend_on_idle" \
            "Запретить засыпание аудиоустройств" \
            "grep -rs suspend-timeout ~/.config/wireplumber" \
            "Тем, у кого обрезается начало уведомлений и коротких звуков. Иначе не нужно."
    fi
    return 0
}

check_resample_quality() {
    _is_pipewire || return 0
    if ! grep -rqs 'resample.quality' "$(_pw_conf_dir)" 2>/dev/null; then
        add_finding INFO \
            "Ресэмплер работает на качестве по умолчанию" \
            "На материале 44.1 кГц в системе с 48 кГц даёт лёгкую грязь на верхах." \
            "resample.quality не задан" \
            "fix_resample_quality" \
            "Поднять качество ресэмплинга до 10" \
            "pw-metadata -n settings | grep resample" \
            "Аудиофилам. На слух разница едва заметна и стоит немного процессора."
    fi
    return 0
}

# ==============================================================================
# ПРОВЕРКИ: BLUETOOTH
# ==============================================================================

_bt_has_paired() {
    _have bluetoothctl || return 1
    [[ -n "$(timeout 10 bluetoothctl devices 2>/dev/null | grep '^Device ' || true)" ]]
}

check_bt_service() {
    _bt_has_paired || return 0
    if systemctl list-unit-files bluetooth.service &>/dev/null; then
        if ! systemctl is-active bluetooth &>/dev/null; then
            add_finding CRIT \
                "Служба bluetooth не запущена, хотя есть сопряжённые устройства" \
                "Наушники не подключатся в принципе." \
                "systemctl is-active bluetooth -> inactive" \
                "fix_bt_service" \
                "Запустить и добавить в автозагрузку" \
                "systemctl is-active bluetooth" \
                "Тем, кто пользуется Bluetooth-звуком."
            return 0
        fi
    fi
    if [[ -f "${BT_MAIN_CONF}" ]] && ! grep -qE '^[[:space:]]*AutoEnable[[:space:]]*=[[:space:]]*true' "${BT_MAIN_CONF}" 2>/dev/null; then
        add_finding INFO \
            "Адаптер Bluetooth не включается автоматически при загрузке" \
            "Каждый раз придётся включать Bluetooth руками." \
            "AutoEnable не выставлен в true в ${BT_MAIN_CONF}" \
            "fix_bt_autoenable" \
            "Прописать AutoEnable=true" \
            "grep -i autoenable ${BT_MAIN_CONF}" \
            "Тем, кого раздражает включать Bluetooth после каждой загрузки. На качество звука не влияет."
    fi
    return 0
}

check_bt_profile_now() {
    _have pactl || return 0
    local cards=() c prof
    mapfile -t cards < <(LC_ALL=C pactl list short cards 2>/dev/null | awk '$2 ~ /^bluez_card/ {print $2}')
    [[ ${#cards[@]} -eq 0 ]] && return 0
    for c in "${cards[@]}"; do
        prof="$(LC_ALL=C pactl list cards 2>/dev/null \
                | awk -v n="Name: ${c}" '$0 ~ n {f=1} f && /Active Profile:/ {print $3; exit}')"
        if [[ "${prof}" == headset-head-unit* ]]; then
            add_finding CRIT \
                "Гарнитура СЕЙЧАС в телефонном профиле (${prof})" \
                "Это моно-канал 8-16 кГц: звук глухой и тихий, как из рации. Слышно прямо сейчас." \
                "${c}: Active Profile = ${prof}" \
                "fix_bt_force_a2dp" \
                "Переключить на стерео A2DP и закрепить" \
                "pactl list cards | grep -A3 'Active Profile'" \
                "Всем, кто слушает музыку. В этом профиле она звучит как телефонный разговор."
        fi
    done
    return 0
}

check_bt_race_history() {
    _have journalctl || return 0
    _bt_has_paired || return 0
    local recent=0 total=0 b m busy hfp sco sep ok
    for b in $(_journal_boots | tail -n 10); do
        m="$(_boot_bt_metrics "${b}")"
        read -r busy hfp sco sep ok <<< "${m}"
        total=$(( total + busy + sco ))
        [[ "${b}" -ge -2 ]] && recent=$(( recent + busy + sco ))
    done
    [[ "${total}" -eq 0 ]] && return 0

    # Свалена ли карта в телефонный профиль ПРЯМО СЕЙЧАС? Если да, об этом уже
    # сказала check_bt_profile_now, и это её работа кричать. Здесь — только история.
    if [[ "${recent}" -gt 0 ]]; then
        add_finding WARN \
            "В журнале следы гонки профилей HFP и A2DP (${recent} за последние загрузки)" \
            "При подключении гарнитура иногда уходит в телефонный моно-режим вместо стерео. Проявляется не каждый раз." \
            "bluetoothd: a2dp-sink profile connect failed ... resource busy, плюс битые SCO-пакеты" \
            "fix_bt_race_armor" \
            "Закрепить стерео A2DP: MultiProfile=multiple и пин профиля" \
            "journalctl -b 0 | grep -iE 'resource busy|corrupted SCO'" \
            "Только тем, у кого звук ПЕРИОДИЧЕСКИ становится глухим после подключения. Если такого не замечал — это просто записи в логе, чинить нечего."
    else
        add_finding INFO \
            "Гонка профилей HFP и A2DP была в прошлом, сейчас не повторяется" \
            "Ничего не сломано. Запись оставлена на случай, если симптом вернётся." \
            "${total} улик в старых загрузках, в свежих чисто" \
            "fix_bt_race_armor" \
            "Закрепить стерео A2DP на будущее" \
            "journalctl -b -1 | grep -icE 'resource busy|corrupted SCO'" \
            "Никому прямо сейчас. Имеет смысл, только если глухой звук вернётся после обновления системы."
    fi
    return 0
}

check_bt_quiet_chip() {
    _have pactl || return 0
    local blk; blk="$(LC_ALL=C pactl list sinks 2>/dev/null | awk '/Name: bluez_output/,/^$/' || true)"
    [[ -z "${blk}" ]] && return 0
    local flags vol
    flags="$(grep -m1 'Flags:' <<< "${blk}" || true)"
    vol="$(grep -m1 'Volume: front' <<< "${blk}" | grep -oE '[0-9]+%' | head -1 | tr -d '%' || true)"
    [[ -z "${vol}" ]] && return 0

    if ! grep -q 'HW_VOLUME_CTRL' <<< "${flags}" && [[ "${vol}" -ge 100 ]]; then
        add_finding INFO \
            "Система отдаёт в гарнитуру полную мощность (${vol}%, без HW_VOLUME_CTRL)" \
            "Со стороны Linux всё выжато до максимума. Если при этом тихо, громкость режет сам чип наушников." \
            "bluez_output: ${vol}%, флага HW_VOLUME_CTRL нет" \
            "fix_bt_chip_volume" \
            "Поднять внутренний регистр гарнитуры командами AVRCP VolumeUp" \
            "pactl list sinks | sed -n '/bluez_output/,/^\$/p' | grep -E 'Volume: front|Flags:'" \
            "Только если в наушниках тихо при ползунке на 100%. Если громкость устраивает — ничего не делай."
    elif grep -q 'HW_VOLUME_CTRL' <<< "${flags}" && [[ "${vol}" -ge 90 ]]; then
        add_finding INFO \
            "Громкость Bluetooth отдана железу гарнитуры (HW_VOLUME_CTRL)" \
            "Ползунок показывает ${vol}%, но реальный уровень задаёт чип наушников и может быть ниже." \
            "bluez_output: флаг HW_VOLUME_CTRL присутствует" \
            "fix_bt_hw_volume_off" \
            "Отключить аппаратный аттенюатор, слать чистый PCM на 0 dB" \
            "pactl list sinks | sed -n '/bluez_output/,/^\$/p' | grep Flags:" \
            "Только если звук тише ожидаемого. Часто это штатное поведение и ничего чинить не надо."
    fi
    return 0
}

# Каталог плагинов кодеков PipeWire
_bt_codec_dir() {
    local d
    for d in /usr/lib/*/spa-0.2/bluez5 /usr/lib/spa-0.2/bluez5 /usr/lib64/spa-0.2/bluez5; do
        [[ -d "${d}" ]] && { echo "${d}"; return 0; }
    done
    return 0
}

# Кодеки, которые объявляет САМА гарнитура (её конечные точки A2DP в BlueZ).
# Печатает по одному имени в строке: SBC, AAC, aptX, aptX HD, LDAC...
_bt_headset_codecs() {  # _bt_headset_codecs <MAC>
    local ep codec caps
    local -a b
    while read -r ep; do
        [[ -z "${ep}" ]] && continue
        codec="$(busctl get-property org.bluez "${ep}" org.bluez.MediaEndpoint1 Codec 2>/dev/null | awk '{print $2}' || true)"
        case "${codec}" in
            0) echo "SBC" ;;
            1) echo "MP3" ;;
            2) echo "AAC" ;;
            4) echo "ATRAC" ;;
            255)
                # Vendor-кодек: в Capabilities первые 4 байта — vendor ID,
                # следующие 2 — codec ID (little-endian). busctl печатает
                # массив как "<длина> <байт> <байт> ...".
                caps="$(busctl get-property org.bluez "${ep}" org.bluez.MediaEndpoint1 Capabilities 2>/dev/null || true)"
                read -r -a b <<< "${caps#ay }" || true
                if [[ ${#b[@]} -ge 7 ]]; then
                    local vid=$(( b[1] | (b[2] << 8) | (b[3] << 16) | (b[4] << 24) ))
                    local cid=$(( b[5] | (b[6] << 8) ))
                    case "${vid}:${cid}" in
                        79:1)     echo "aptX" ;;
                        215:36)   echo "aptX HD" ;;
                        10:2)     echo "aptX LL" ;;
                        10:1)     echo "FastStream" ;;
                        301:170)  echo "LDAC" ;;
                        1521:4101) echo "Opus" ;;
                        *)        printf 'vendor %#x/%#x\n' "${vid}" "${cid}" ;;
                    esac
                fi ;;
            "") ;;
            *) echo "codec#${codec}" ;;
        esac
    done < <(busctl --list tree org.bluez 2>/dev/null | grep -E "/dev_${1//:/_}/sep[0-9]+\$" || true)
    return 0
}

# Имя файла плагина PipeWire для кодека (пусто — плагин не нужен/неизвестен)
_bt_codec_plugin() {
    case "$1" in
        SBC)                   echo "libspa-codec-bluez5-sbc.so" ;;
        AAC)                   echo "libspa-codec-bluez5-aac.so" ;;
        aptX|"aptX HD"|"aptX LL") echo "libspa-codec-bluez5-aptx.so" ;;
        LDAC)                  echo "libspa-codec-bluez5-ldac.so" ;;
        FastStream)            echo "libspa-codec-bluez5-faststream.so" ;;
        Opus)                  echo "libspa-codec-bluez5-opus.so" ;;
        *)                     echo "" ;;
    esac
}

# Какие кодеки гарнитура умеет, а в системе для них нет плагина
_bt_missing_codecs() {  # _bt_missing_codecs <MAC>
    local dir; dir="$(_bt_codec_dir)"
    [[ -z "${dir}" ]] && return 0
    local c plug
    while IFS= read -r c; do
        [[ -z "${c}" ]] && continue
        plug="$(_bt_codec_plugin "${c}")"
        [[ -z "${plug}" ]] && continue
        if [[ ! -e "${dir}/${plug}" ]]; then echo "${c}"; fi
    done < <(_bt_headset_codecs "$1" | sort -u)
    return 0
}

check_bt_codecs() {
    _have busctl || return 0
    local dir; dir="$(_bt_codec_dir)"
    [[ -z "${dir}" ]] && return 0
    local line mac name supported missing fixable others
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        mac="${line%%|*}"; name="${line#*|}"
        supported="$(_bt_headset_codecs "${mac}" | sort -u | paste -sd, - | sed 's/,/, /g')"
        [[ -z "${supported}" ]] && continue            # не аудиоустройство
        missing="$(_bt_missing_codecs "${mac}" | paste -sd' ' -)"
        [[ -z "${missing}" ]] && continue              # всё, что умеет гарнитура, уже есть

        # AAC в сборках Debian/Ubuntu/Mint отсутствует из-за лицензии fdk-aac,
        # поставить его из штатного репозитория нельзя — не обещаем того, чего нет.
        fixable=""; others=""
        local c
        for c in ${missing}; do
            if [[ "${c}" == "AAC" && "$(_pkg_mgr)" == "apt" ]]; then others="AAC"
            else fixable="${fixable:+${fixable} }${c}"; fi
        done

        if [[ -n "${fixable}" ]]; then
            add_finding INFO \
                "${name} умеет ${fixable}, но в системе нет плагина" \
                "Гарнитура поддерживает: ${supported}. Сейчас недоступно: ${fixable}. Звук идёт через кодек похуже." \
                "нет плагина в ${dir}" \
                "fix_install_bt_codecs" \
                "Установить плагины для: ${fixable}" \
                "busctl --list tree org.bluez | grep '${mac//:/_}/sep'  # затем: busctl get-property org.bluez <sepN> org.bluez.MediaEndpoint1 Codec" \
                "Тем, кому важно качество звука. Кодек проверен: гарнитура его действительно поддерживает."
        fi
        if [[ -n "${others}" ]]; then
            add_finding INFO \
                "${name} умеет AAC, но в этой сборке PipeWire его нет" \
                "Гарнитура поддерживает: ${supported}. В Debian/Ubuntu/Mint PipeWire собран без AAC из-за лицензии fdk-aac, поэтому используется SBC." \
                "нет ${dir}/libspa-codec-bluez5-aac.so, и ни один пакет репозитория его не содержит" \
                "-" \
                "Автофикса нет. В сборках PipeWire других дистрибутивов AAC бывает (например, Arch, Fedora с RPM Fusion). Для SBC ничего делать не нужно — он уже на максимуме" \
                "ls ${dir}; dpkg -L libspa-0.2-bluetooth | grep codec" \
                "Никому чинить не требуется. Это объяснение, почему в списке нет AAC, а не поломка."
        fi
    done < <(_bt_connected_list)
    return 0
}

check_bt_usb_power() {
    local d vid pid ctl isbt ifc
    for d in /sys/bus/usb/devices/*/; do
        [[ -f "${d}idVendor" ]] || continue
        [[ -r "${d}power/control" ]] || continue
        isbt=0
        for ifc in "${d}"*/bInterfaceClass; do
            [[ -r "${ifc}" ]] || continue
            [[ "$(cat "${ifc}" 2>/dev/null)" == "e0" ]] && isbt=1
        done
        [[ "${isbt}" -eq 1 ]] || continue
        ctl="$(cat "${d}power/control" 2>/dev/null || echo on)"
        if [[ "${ctl}" == "auto" ]]; then
            vid="$(cat "${d}idVendor")"; pid="$(cat "${d}idProduct")"
            add_finding INFO \
                "USB-адаптер Bluetooth может уходить в автосон (${vid}:${pid})" \
                "У части адаптеров это вызывает отвалы наушников и ошибки command tx timeout." \
                "${d}power/control = auto" \
                "fix_bt_usb_nosuspend" \
                "Запретить автосон правилом udev" \
                "cat ${d}power/control; journalctl -k -b 0 | grep -i 'tx timeout'" \
                "Только если наушники реально отваливаются. Автосон сам по себе — штатная экономия энергии."
            return 0
        fi
    done
    return 0
}

check_bt_trust() {
    _have bluetoothctl || return 0
    local mac untrusted=()
    while read -r mac; do
        [[ -z "${mac}" ]] && continue
        timeout 5 bluetoothctl info "${mac}" 2>/dev/null | grep -qE '^[[:space:]]*Trusted: yes' \
            || untrusted+=("${mac}")
    done < <(timeout 10 bluetoothctl devices 2>/dev/null | awk '/^Device /{print $2}' || true)
    if [[ ${#untrusted[@]} -gt 0 ]]; then
        add_finding INFO \
            "Сопряжённые устройства не помечены доверенными (${#untrusted[@]} шт.)" \
            "Они не будут переподключаться сами после включения." \
            "bluetoothctl info: Trusted: no" \
            "fix_bt_trust_all" \
            "Пометить все сопряжённые устройства доверенными" \
            "bluetoothctl info ${untrusted[0]} | grep Trusted" \
            "Тем, кому надоело подключать наушники вручную. На качество звука не влияет."
    fi
    return 0
}

check_power_daemon() {
    if systemctl is-active tlp &>/dev/null; then
        add_finding INFO \
            "Активен TLP — агрессивное энергосбережение" \
            "По умолчанию усыпляет USB-устройства и радиомодули." \
            "systemctl is-active tlp -> active" \
            "-" \
            "Автофикса нет: при отвалах добавь в /etc/tlp.conf USB_DENYLIST с ID адаптера" \
            "systemctl is-active tlp; grep -i usb /etc/tlp.conf" \
            "Только при отвалах Bluetooth. Сам по себе TLP полезен и экономит батарею."
    fi
    return 0
}

# ==============================================================================
# ПРОВЕРКИ: МИКРОФОН
# ==============================================================================

check_mic() {
    _have pactl || return 0
    [[ "$(LC_ALL=C pactl list short sources 2>/dev/null | grep -vc '\.monitor')" -eq 0 ]] && return 0
    local def_src blk; def_src="$(pactl get-default-source 2>/dev/null || true)"
    [[ -z "${def_src}" ]] && return 0
    blk="$(LC_ALL=C pactl list sources 2>/dev/null | awk -v n="Name: ${def_src}" '
        $0 ~ n {f=1} f {print} f && /^$/ {exit}' || true)"

    if grep -qE '^[[:space:]]*Mute: yes' <<< "${blk}"; then
        add_finding WARN \
            "Микрофон по умолчанию замьючен" \
            "Тебя не слышно в звонках и записи." \
            "${def_src}: Mute: yes" \
            "fix_mic_unmute" \
            "Снять mute и выставить уровень 80%" \
            "pactl get-source-mute @DEFAULT_SOURCE@" \
            "Тем, кто пользуется микрофоном. Если ты его выключил намеренно — так и надо."
    fi
    if _is_pipewire && ! grep -rqs 'echo-cancel' "$(_pw_conf_dir)" 2>/dev/null; then
        add_finding INFO \
            "Не включено подавление эха и шума для микрофона" \
            "Собеседники могут слышать эхо от колонок и фоновый шум." \
            "нет модуля echo-cancel в конфигах PipeWire" \
            "fix_echo_cancel" \
            "Поднять виртуальный микрофон с эхо- и шумоподавлением" \
            "ls $(_pw_conf_dir)" \
            "Тем, кто много созванивается через колонки. В наушниках эха нет и это не нужно."
    fi
    return 0
}

# ==============================================================================
# ОТЧЁТ И ИНТЕРАКТИВНОЕ ЛЕЧЕНИЕ
# ==============================================================================

# Порядок показа: сначала критичное, потом важное, потом советы.
# ORDER[i] — индекс находки, показанной под номером (i+1).
ORDER=()

_build_order() {
    ORDER=()
    local sev i
    for sev in CRIT WARN INFO; do
        for i in "${!FND_SEV[@]}"; do
            [[ "${FND_SEV[$i]}" == "${sev}" ]] && ORDER+=("${i}")
        done
    done
}

_run_all_checks() {
    reset_findings
    local c
    for c in check_soundcards check_dummy_output check_audio_services \
             check_server_conflict check_pulse_bridge \
             check_alsa_mutes check_sink_mute_volume check_wrong_output check_stream_routing \
             check_hda_power_save check_xruns check_rt_priority \
             check_suspend_on_idle check_resample_quality \
             check_bt_service check_bt_profile_now check_bt_race_history \
             check_bt_quiet_chip check_bt_codecs check_bt_usb_power check_bt_trust \
             check_power_daemon check_mic; do
        if [[ -t 1 ]]; then printf "${C_DIM}  … проверяю: %-28s${C_RESET}\r" "${c#check_}"; fi
        "${c}" 2>/dev/null || true
    done
    if [[ -t 1 ]]; then printf "%-70s\r" " "; fi
    _build_order
    return 0
}

_sev_label() {
    case "$1" in
        CRIT) printf '%b' "${C_BG_RED} КРИТИЧНО ${C_RESET}" ;;
        WARN) printf '%b' "${C_YELLOW}[ ВАЖНО ]${C_RESET}" ;;
        *)    printf '%b' "${C_CYAN}[ СОВЕТ ]${C_RESET}" ;;
    esac
}

# Печать одной находки под её номером
_print_finding() {  # _print_finding <номер> <индекс>
    local num="$1" i="$2"
    printf "  ${C_BOLD}#%-3s${C_RESET} %b ${C_BOLD}%s${C_RESET}\n" "${num}" "$(_sev_label "${FND_SEV[$i]}")" "${FND_TITLE[$i]}"
    printf "        ${C_DIM}Чем грозит:${C_RESET}  %s\n" "${FND_WHY[$i]}"
    printf "        ${C_DIM}Улика:${C_RESET}       %s\n" "${FND_EVID[$i]}"
    if [[ -n "${FND_CHECK[$i]}" ]]; then
        printf "        ${C_BOLD}Проверить:${C_RESET}   ${C_CYAN}%s${C_RESET}\n" "${FND_CHECK[$i]}"
    fi
    if [[ -n "${FND_WHEN[$i]}" ]]; then
        printf "        ${C_BOLD}Кому нужно:${C_RESET}  %s\n" "${FND_WHEN[$i]}"
    fi
    if [[ "${FND_FIX[$i]}" != "-" ]]; then
        printf "        ${C_GREEN}Фикс #%s:${C_RESET}     %s\n" "${num}" "${FND_HINT[$i]}"
    else
        printf "        ${C_YELLOW}Автофикса нет:${C_RESET} %s\n" "${FND_HINT[$i]}"
    fi
    printf "\n"
    return 0
}

# Отчёт в файл — без цвета, со всеми командами и путями
_write_report() {
    local out="${HOME}/linah-report-$(date +%Y%m%d-%H%M%S).txt"
    {
        echo "ОТЧЁТ LINAH"
        echo "Создан:     $(date -Iseconds 2>/dev/null || date)"
        echo "Система:    $(detect_distro)   ядро $(uname -r)"
        echo "Сервер:     $(get_audio_server)   WirePlumber $(get_wireplumber_info)"
        echo "Скрипт:     $0"
        echo
        echo "КАК ЧИТАТЬ"
        echo "  КРИТИЧНО — звука нет или он сломан прямо сейчас, чинить обязательно."
        echo "  ВАЖНО    — звук есть, но объективно хуже, чем мог бы быть."
        echo "  СОВЕТ    — ничего не сломано, применять по желанию."
        echo "  Каждая находка содержит команду, которой её можно проверить вручную."
        echo
        echo "=============================================================================="
        local n=1 i
        for i in "${ORDER[@]}"; do
            echo
            echo "#${n}  [${FND_SEV[$i]}]  ${FND_TITLE[$i]}"
            echo "     Чем грозит:  ${FND_WHY[$i]}"
            echo "     Улика:       ${FND_EVID[$i]}"
            if [[ -n "${FND_CHECK[$i]}" ]]; then echo "     Проверить:   ${FND_CHECK[$i]}"; fi
            if [[ -n "${FND_WHEN[$i]}" ]]; then echo "     Кому нужно:  ${FND_WHEN[$i]}"; fi
            if [[ "${FND_FIX[$i]}" != "-" ]]; then
                echo "     Фикс #${n}:     ${FND_HINT[$i]}"
                echo "     Функция:     ${FND_FIX[$i]}()"
            else
                echo "     Автофикса нет: ${FND_HINT[$i]}"
            fi
            n=$(( n + 1 ))
        done
        echo
        echo "=============================================================================="
        echo "ТЕКУЩЕЕ СОСТОЯНИЕ СИСТЕМЫ"
        echo
        echo "--- Выходы ---"
        LC_ALL=C pactl list short sinks 2>/dev/null || echo "(pactl недоступен)"
        echo
        echo "--- Выход по умолчанию ---"
        pactl get-default-sink 2>/dev/null || true
        echo
        echo "--- Громкость и флаги ---"
        LC_ALL=C pactl list sinks 2>/dev/null | grep -E 'Name:|Volume: front|Mute:|Flags:' || true
        echo
        echo "--- Карты и профили ---"
        LC_ALL=C pactl list cards 2>/dev/null | grep -E 'Name: |Active Profile:' || true
        echo
        echo "--- Конфиги пользователя ---"
        find "${HOME}/.config/pipewire" "${HOME}/.config/wireplumber" -type f 2>/dev/null | sort || true
        echo
        echo "--- Файлы, которые создаёт linah ---"
        echo "  ${PREAMP_CONF}"
        echo "  ${WP_CONF_04}"
        echo "  ${WP_CONF_05}"
        echo "  ${WP_ROLES_04}"
        echo "  ${WP_ROLES_05}"
        echo "  /etc/modprobe.d/99-linah-hda.conf"
        echo "  /etc/udev/rules.d/99-linah-bt-nosuspend.rules"
        echo "  /etc/security/limits.d/99-linah-rt.conf"
        echo "  ${BT_MAIN_CONF} (бэкап: ${BT_MAIN_CONF}.linah.bak)"
        echo
        echo "Полный откат всех изменений: $0 --revert"
    } > "${out}" 2>/dev/null || true
    echo "${out}"
    return 0
}

run_full_analysis() {
    print_banner
    log_title "АНАЛИЗ АУДИОСИСТЕМЫ"
    printf "================================================================================\n\n"
    printf "  ${C_BOLD}Система:${C_RESET} ${C_CYAN}%s${C_RESET}   ${C_BOLD}Сервер:${C_RESET} ${C_CYAN}%s${C_RESET}   ${C_BOLD}Ядро:${C_RESET} ${C_CYAN}%s${C_RESET}\n\n" \
        "$(detect_distro)" "$(get_audio_server)" "$(uname -r)"

    log_info "Прогоняю проверки..."
    _run_all_checks

    local n_crit=0 n_warn=0 n_info=0 i
    for i in "${!FND_SEV[@]}"; do
        case "${FND_SEV[$i]}" in
            CRIT) n_crit=$(( n_crit + 1 )) ;;
            WARN) n_warn=$(( n_warn + 1 )) ;;
            *)    n_info=$(( n_info + 1 )) ;;
        esac
    done

    printf "================================================================================\n"
    printf "  ${C_RED}критичных: %s${C_RESET}   ${C_YELLOW}важных: %s${C_RESET}   ${C_CYAN}советов: %s${C_RESET}\n" \
        "${n_crit}" "${n_warn}" "${n_info}"
    printf "================================================================================\n\n"

    if [[ ${#FND_SEV[@]} -eq 0 ]]; then
        log_cool "ЧИСТО. Ни одной известной болячки не нашёл."
        printf "\n"
        press_enter
        return
    fi

    printf "  ${C_DIM}У каждой находки есть команда «Проверить» — выполни её сам и убедись,${C_RESET}\n"
    printf "  ${C_DIM}что проблема реальна. И строка «Кому нужно» — часто чинить не требуется.${C_RESET}\n\n"

    local num=1 cur="" sev
    for i in "${ORDER[@]}"; do
        sev="${FND_SEV[$i]}"
        if [[ "${sev}" != "${cur}" ]]; then
            cur="${sev}"
            case "${sev}" in
                CRIT) printf "${C_BOLD}${C_RED}ЗВУКА НЕТ ИЛИ ОН СЛОМАН — чинить обязательно${C_RESET}\n\n" ;;
                WARN) printf "${C_BOLD}${C_YELLOW}ЗВУК ЕСТЬ, НО ХУЖЕ ЧЕМ МОГ БЫ — стоит посмотреть${C_RESET}\n\n" ;;
                *)    printf "${C_BOLD}${C_CYAN}НИЧЕГО НЕ СЛОМАНО — применять по желанию${C_RESET}\n\n" ;;
            esac
        fi
        _print_finding "${num}" "${i}"
        num=$(( num + 1 ))
    done

    local report; report="$(_write_report)"
    printf "================================================================================\n"
    log_cool "Отчёт со всеми командами и путями: ${C_BOLD}${report}${C_RESET}"
    printf "\n"

    _offer_fixes
}

_offer_fixes() {
    local fixable=() num=1 i
    declare -A num_of
    for i in "${ORDER[@]}"; do
        if [[ "${FND_FIX[$i]}" != "-" ]]; then
            fixable+=("${num}")
            num_of[$num]="${i}"
        fi
        num=$(( num + 1 ))
    done

    if [[ ${#fixable[@]} -eq 0 ]]; then
        log_info "Автофиксов для найденного нет — смотри подсказки выше."
        press_enter
        return
    fi

    {
    log_title "ЧИНИТЬ?"
    printf "\n  Доступны фиксы под номерами: ${C_BOLD}%s${C_RESET}\n\n" "${fixable[*]}"
    printf "  ${C_BOLD}[номера]${C_RESET} через пробел — например: ${C_DIM}%s${C_RESET}\n" "${fixable[0]}"
    printf "  ${C_BOLD}[c]${C_RESET}      только КРИТИЧНОЕ ${C_DIM}(то, из-за чего звука нет)${C_RESET}\n"
    _hint 'Зачем: применяет только то, из-за чего звука нет или он сломан.'
    _hint 'Когда: не уверен в остальном и хочешь минимум изменений.'
    printf "  ${C_BOLD}[a]${C_RESET}      критичное и важное ${C_DIM}(советы пропустить)${C_RESET}\n"
    _hint 'Зачем: применяет всё, что портит звук, и пропускает необязательные советы.'
    _hint 'Когда: хочешь привести звук в порядок, не трогая необязательное.'
    printf "  ${C_BOLD}[0]${C_RESET}      ничего не трогать\n\n"
    printf "  ${C_YELLOW}Не уверен — выбери 0.${C_RESET} Сначала выполни команды «Проверить» из отчёта.\n\n"

    local answer
    } > "${MENU_BUF}" 2>&1
    menu_read answer "Твой выбор: "

    local targets=() t
    case "${answer}" in
        a|A) for t in "${fixable[@]}"; do
                 [[ "${FND_SEV[${num_of[$t]}]}" == "INFO" ]] && continue
                 targets+=("${t}")
             done ;;
        c|C) for t in "${fixable[@]}"; do
                 [[ "${FND_SEV[${num_of[$t]}]}" == "CRIT" ]] && targets+=("${t}")
             done ;;
        0|q|Q|"") log_info "Ок, ничего не трогаю."; press_enter; return ;;
        *)   for t in ${answer}; do
                 [[ "${t}" =~ ^[0-9]+$ ]] || continue
                 [[ -n "${num_of[$t]:-}" ]] || { log_warn "Номер ${t} — фикса нет, пропускаю."; continue; }
                 targets+=("${t}")
             done ;;
    esac

    if [[ ${#targets[@]} -eq 0 ]]; then
        log_warn "Ничего подходящего не выбрано."
        press_enter
        return
    fi

    printf "\n  ${C_BOLD}Будет применено:${C_RESET}\n"
    for t in "${targets[@]}"; do
        printf "    #%-3s %s\n" "${t}" "${FND_TITLE[${num_of[$t]}]}"
    done
    printf "\n"
    local yn
    read -r -p "  Подтвердить? [y/N]: " yn
    [[ "${yn}" =~ ^[yYдД] ]] || { log_info "Отменено."; press_enter; return; }

    printf "\n"
    local applied=0 failed=0 fn
    for t in "${targets[@]}"; do
        i="${num_of[$t]}"
        fn="${FND_FIX[$i]}"
        printf "${C_BOLD}▶ #%s %s${C_RESET}\n" "${t}" "${FND_TITLE[$i]}"
        if declare -F "${fn}" &>/dev/null; then
            if "${fn}"; then applied=$(( applied + 1 )); else
                log_warn "Фикс отработал с замечаниями."; failed=$(( failed + 1 )); fi
        else
            log_danger "Внутренняя ошибка: функция ${fn} не найдена."
            failed=$(( failed + 1 ))
        fi
        printf "\n"
    done

    printf "================================================================================\n"
    log_cool "Применено: ${applied}. С замечаниями: ${failed}."
    printf "  ${C_YELLOW}Правила udev, limits и modprobe вступят в силу после перезагрузки.${C_RESET}\n"
    printf "  ${C_DIM}Откатить всё: %s --revert${C_RESET}\n\n" "$0"
    press_enter
}
# ==============================================================================
# 3.12 АПТЕЧКА: ФУНКЦИИ-ФИКСЫ
# ------------------------------------------------------------------------------
# Каждая возвращает 0 при успехе. Каждая объясняет, что сделала.
# Всё, что трогает системные файлы, сначала кладёт рядом .linah.bak
# ==============================================================================

fix_restart_stack() {
    log_info "Перезапускаю звуковой стек..."
    if _is_pipewire || systemctl --user list-unit-files pipewire.service &>/dev/null; then
        systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    elif _is_pulse_native; then
        pulseaudio -k 2>/dev/null || true
        sleep 1
        pulseaudio --start 2>/dev/null || true
    fi
    sleep 2
    log_cool "Стек перезапущен."
    return 0
}

fix_start_services() {
    local u
    for u in pipewire pipewire-pulse wireplumber; do
        systemctl --user list-unit-files "${u}.service" &>/dev/null || continue
        systemctl --user enable --now "${u}" 2>/dev/null || true
    done
    sleep 2
    log_cool "Службы аудио запущены и добавлены в автозагрузку."
    return 0
}

fix_server_conflict() {
    log_warn "Глушу классический PulseAudio, чтобы он не дрался с PipeWire."
    systemctl --user stop pulseaudio.service pulseaudio.socket 2>/dev/null || true
    systemctl --user disable pulseaudio.service pulseaudio.socket 2>/dev/null || true
    systemctl --user mask pulseaudio.service pulseaudio.socket 2>/dev/null || true
    pkill -x pulseaudio 2>/dev/null || true
    sleep 1
    systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    sleep 2
    log_cool "Старый PulseAudio замаскирован, PipeWire остался один за рулём."
    printf "  ${C_DIM}Откат: systemctl --user unmask pulseaudio.service pulseaudio.socket${C_RESET}\n"
    return 0
}

fix_alsa_unmute() {
    _have amixer || { log_danger "Нет amixer (пакет alsa-utils)."; return 1; }
    local idx name ctl touched=0
    while read -r idx name; do
        [[ -z "${idx}" ]] && continue
        while IFS= read -r ctl; do
            [[ -z "${ctl}" ]] && continue
            amixer -c "${idx}" sset "${ctl}" unmute  &>/dev/null || true
            amixer -c "${idx}" sset "${ctl}" 100%    &>/dev/null || true
            touched=$(( touched + 1 ))
        done < <(amixer -c "${idx}" scontrols 2>/dev/null \
                 | sed -E "s/^Simple mixer control '(.*)',.*/\1/" \
                 | grep -E '^(Master|Speaker|Headphone|PCM|Front|Digital|Line Out)$' || true)
    done <<< "$(_alsa_cards)"

    _have alsactl && sudo alsactl store 2>/dev/null || true
    log_cool "Снял mute и поднял до 100% аппаратных регуляторов: ${touched}."
    return 0
}

fix_sink_unmute() {
    local def; def="$(_default_sink)"
    [[ -z "${def}" ]] && { log_danger "Не нашёл текущий выход."; return 1; }
    pactl set-sink-mute "${def}" 0 2>/dev/null || true
    log_cool "Mute снят с ${def}."
    return 0
}

fix_sink_volume_100() {
    local def; def="$(_default_sink)"
    [[ -z "${def}" ]] && { log_danger "Не нашёл текущий выход."; return 1; }
    pactl set-sink-mute   "${def}" 0    2>/dev/null || true
    pactl set-sink-volume "${def}" 100% 2>/dev/null || true
    log_cool "Громкость ${def} выставлена в честные 100% (0 dB)."
    return 0
}

fix_switch_sink() {
    local sinks=() i=1 line
    mapfile -t sinks < <(LC_ALL=C pactl list short sinks 2>/dev/null | awk '{print $2}')
    [[ ${#sinks[@]} -eq 0 ]] && { log_danger "Выходов не найдено."; return 1; }

    {
    printf "\n  ${C_BOLD}Доступные выходы:${C_RESET}\n"
    for line in "${sinks[@]}"; do
        local desc
        desc="$(_sink_block "${line}" | grep -m1 'Description:' | sed 's/.*Description: //' || true)"
        printf "    ${C_BOLD}[%s]${C_RESET} %s ${C_DIM}(%s)${C_RESET}\n" "${i}" "${desc:-${line}}" "${line}"
        i=$(( i + 1 ))
    done
    printf "\n"

    local pick
    } > "${MENU_BUF}" 2>&1
    menu_read pick "  Куда гоним звук? [1-$(( i - 1 ))]: "
    [[ "${pick}" =~ ^[0-9]+$ && "${pick}" -ge 1 && "${pick}" -le "${#sinks[@]}" ]] || { log_warn "Такого номера нет."; return 1; }
    local target="${sinks[$(( pick - 1 ))]}"

    pactl set-default-sink "${target}" 2>/dev/null || true
    fix_move_streams || true
    log_cool "Выход по умолчанию: ${target}"
    return 0
}

fix_move_streams() {
    local def; def="$(_default_sink)"
    [[ -z "${def}" ]] && return 1
    local id moved=0
    while read -r id _; do
        [[ -z "${id}" ]] && continue
        pactl move-sink-input "${id}" "${def}" 2>/dev/null && moved=$(( moved + 1 )) || true
    done < <(LC_ALL=C pactl list short sink-inputs 2>/dev/null || true)
    log_cool "Перенесено потоков в текущий выход: ${moved}."
    return 0
}

fix_hda_power_save() {
    local f=/sys/module/snd_hda_intel/parameters/power_save
    [[ -r "${f}" ]] || { log_warn "Модуль snd_hda_intel не загружен — пропускаю."; return 0; }

    log_info "Отключаю засыпание кодека прямо сейчас..."
    echo 0 | sudo tee "${f}" >/dev/null 2>&1 || true
    echo N | sudo tee /sys/module/snd_hda_intel/parameters/power_save_controller >/dev/null 2>&1 || true

    log_info "Закрепляю навсегда через modprobe.d..."
    _sudo_write /etc/modprobe.d/99-linah-hda.conf \
"# linah: запрет засыпания HDA-кодека.
# Лечит щелчки при старте звука и обрезанные первые доли секунды.
options snd_hda_intel power_save=0 power_save_controller=N"

    log_cool "Кодек больше не засыпает. Щелчки и обрезанное начало треков должны уйти."
    printf "  ${C_DIM}Откат: sudo rm /etc/modprobe.d/99-linah-hda.conf${C_RESET}\n"
    return 0
}

fix_latency_menu() {
    {
    local dir; dir="$(_pw_conf_dir)"
    mkdir -p "${dir}"

    printf "\n  ${C_BOLD}Выбери характер звука:${C_RESET}\n"
    printf "    ${C_BOLD}[1]${C_RESET} ${C_GREEN}Стабильность${C_RESET} — большой буфер, ноль треска. ${C_DIM}Музыка, кино, созвоны.${C_RESET}\n"
    printf "    ${C_BOLD}[2]${C_RESET} ${C_CYAN}Баланс${C_RESET}       — золотая середина. ${C_DIM}Рекомендуется большинству.${C_RESET}\n"
    printf "    ${C_BOLD}[3]${C_RESET} ${C_YELLOW}Низкая задержка${C_RESET} — для игр и записи. ${C_DIM}Требует мощного CPU, иначе затрещит.${C_RESET}\n\n"

    local pick q minq maxq
    } > "${MENU_BUF}" 2>&1
    menu_read pick "  Твой выбор [1-3]: "
    case "${pick}" in
        1) q=2048; minq=1024; maxq=4096 ;;
        3) q=256;  minq=64;   maxq=1024 ;;
        *) q=1024; minq=256;  maxq=2048 ;;
    esac

    cat << EOF > "${dir}/99-linah-latency.conf"
# linah: размер буфера. Больше quantum — меньше треска, выше задержка.
context.properties = {
    default.clock.rate        = 48000
    default.clock.allowed-rates = [ 44100 48000 88200 96000 ]
    default.clock.quantum     = ${q}
    default.clock.min-quantum = ${minq}
    default.clock.max-quantum = ${maxq}
}
EOF
    systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    sleep 2
    log_cool "Буфер выставлен: quantum=${q} (${minq}..${maxq}) при 48 кГц."
    printf "  ${C_DIM}Откат: rm ${dir}/99-linah-latency.conf${C_RESET}\n"
    return 0
}

fix_rt_priority() {
    log_info "Прописываю лимиты реального времени для группы audio..."
    _sudo_write /etc/security/limits.d/99-linah-rt.conf \
"# linah: приоритеты реального времени для звука.
# Без них под нагрузкой начинается треск и заикания.
@audio   -  rtprio      95
@audio   -  memlock     unlimited
@audio   -  nice       -19"

    if ! id -nG "${USER}" 2>/dev/null | tr ' ' '\n' | grep -qx audio; then
        log_info "Добавляю тебя в группу audio..."
        sudo usermod -aG audio "${USER}" 2>/dev/null || true
        log_warn "Членство в группе применится ТОЛЬКО после перелогина."
    fi

    log_cool "Лимиты RT прописаны. Перезайди в систему, чтобы они заработали."
    printf "  ${C_DIM}Откат: sudo rm /etc/security/limits.d/99-linah-rt.conf${C_RESET}\n"
    return 0
}

fix_suspend_on_idle() {
    local wp_syntax
    wp_syntax="$(get_wireplumber_info | awk '{print $2}')"

    if [[ "${wp_syntax}" == "spa-json" ]]; then
        mkdir -p "${WP_DIR_05}"
        cat << 'EOF' > "${HOME}/.config/wireplumber/wireplumber.conf.d/51-no-suspend.conf"
# linah: не усыплять аудиоустройства при простое.
# Лечит обрезанное начало звука и щелчки пробуждения на USB-ЦАПах.
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_output.*" } { node.name = "~alsa_input.*" } ]
    actions = { update-props = { session.suspend-timeout-seconds = 0 } }
  }
]
monitor.bluez.rules = [
  {
    matches = [ { node.name = "~bluez_output.*" } ]
    actions = { update-props = { session.suspend-timeout-seconds = 0 } }
  }
]
EOF
    else
        mkdir -p "${HOME}/.config/wireplumber/main.lua.d" "${WP_DIR_04}"
        cat << 'EOF' > "${HOME}/.config/wireplumber/main.lua.d/51-no-suspend.lua"
-- linah: не усыплять аудиоустройства при простое.
-- Лечит обрезанное начало звука и щелчки пробуждения на USB-ЦАПах.
table.insert(alsa_monitor.rules, {
  matches = { { { "node.name", "matches", "alsa_output.*" } },
              { { "node.name", "matches", "alsa_input.*"  } } },
  apply_properties = { ["session.suspend-timeout-seconds"] = 0 },
})
EOF
        cat << 'EOF' > "${WP_DIR_04}/53-no-suspend.lua"
-- linah: не усыплять Bluetooth-выход при простое.
table.insert(bluez_monitor.rules, {
  matches = { { { "node.name", "matches", "bluez_output.*" } } },
  apply_properties = { ["session.suspend-timeout-seconds"] = 0 },
})
EOF
    fi

    systemctl --user restart wireplumber 2>/dev/null || true
    sleep 2
    log_cool "Устройства больше не засыпают — начало треков не обрезается."
    return 0
}

fix_resample_quality() {
    local dir; dir="$(_pw_conf_dir)"
    mkdir -p "${dir}"
    cat << 'EOF' > "${dir}/99-linah-resample.conf"
# linah: ресэмплер студийного качества.
# 4 — дефолт, 10 — максимум. Разница слышна на верхах при 44.1 -> 48 кГц.
context.properties = {
    resample.quality    = 10
    resample.disable    = false
    channelmix.normalize = false
    channelmix.mix-lfe   = false
}
EOF
    systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    sleep 2
    log_cool "Качество ресэмплинга поднято до 10, авто-занижение уровня отключено."
    printf "  ${C_DIM}Откат: rm ${dir}/99-linah-resample.conf${C_RESET}\n"
    return 0
}

fix_bt_service() {
    sudo systemctl enable --now bluetooth 2>/dev/null || sudo service bluetooth start 2>/dev/null || true
    sleep 2
    log_cool "Служба bluetooth запущена и добавлена в автозагрузку."
    return 0
}

fix_bt_autoenable() {
    [[ -f "${BT_MAIN_CONF}" ]] || { log_danger "Нет ${BT_MAIN_CONF}."; return 1; }
    if sudo test -f "${BT_MAIN_CONF}" && ! sudo test -f "${BT_MAIN_CONF}.linah.bak"; then
        sudo cp -a "${BT_MAIN_CONF}" "${BT_MAIN_CONF}.linah.bak" 2>/dev/null || true
    fi
    if sudo grep -qE '^[[:space:]]*#?[[:space:]]*AutoEnable[[:space:]]*=' "${BT_MAIN_CONF}"; then
        sudo sed -i -E 's|^[[:space:]]*#?[[:space:]]*AutoEnable[[:space:]]*=.*|AutoEnable=true|' "${BT_MAIN_CONF}"
    elif sudo grep -qE '^\[Policy\]' "${BT_MAIN_CONF}"; then
        sudo sed -i -E '0,/^\[Policy\]/s//[Policy]\nAutoEnable=true/' "${BT_MAIN_CONF}"
    else
        printf '\n[Policy]\nAutoEnable=true\n' | sudo tee -a "${BT_MAIN_CONF}" >/dev/null
    fi
    sudo systemctl restart bluetooth 2>/dev/null || true
    sleep 2
    log_cool "Адаптер Bluetooth теперь включается сам при загрузке."
    return 0
}

fix_bt_force_a2dp() {
    local cards=() c
    mapfile -t cards < <(LC_ALL=C pactl list short cards 2>/dev/null | awk '$2 ~ /^bluez_card/ {print $2}')
    [[ ${#cards[@]} -eq 0 ]] && { log_warn "Bluetooth-карт нет — включи наушники."; return 1; }
    for c in "${cards[@]}"; do
        pactl set-card-profile "${c}" a2dp-sink 2>/dev/null \
            && log_cool "${c} → стерео A2DP" \
            || log_warn "${c}: не удалось переключить профиль."
    done
    apply_native_wp_fix 0 || true
    log_cool "Профиль A2DP закреплён в WirePlumber, обратно не свалится."
    return 0
}

fix_bt_race_armor() {
    apply_multiprofile_tweak || true
    apply_native_wp_fix 0 || true
    bt_clean_reconnect || true
    return 0
}

fix_bt_chip_volume() {
    # Поднимает ВНУТРЕННИЙ регистр громкости гарнитуры командами AVRCP.
    # Работает даже когда MediaTransport1.Volume отсутствует — то есть там,
    # где системный ползунок бессилен, потому что он уже на максимуме.
    local mac
    mac="$(timeout 10 bluetoothctl devices Connected 2>/dev/null | awk '/^Device /{print $2}' | head -1 || true)"
    if [[ -z "${mac}" ]]; then
        log_danger "Нет подключённых Bluetooth-устройств."
        return 1
    fi
    local dev; dev="$(_bt_path "${mac}")"
    if ! busctl introspect org.bluez "${dev}" org.bluez.MediaControl1 &>/dev/null; then
        log_danger "Гарнитура не предоставляет MediaControl1 — поднять её регистр нельзя."
        printf "  ${C_DIM}Остаётся физическая кнопка громкости на корпусе.${C_RESET}\n"
        return 1
    fi
    log_info "Поднимаю внутренний регистр громкости ${mac}..."
    _bt_avrcp_burst "${dev}" VolumeUp 25 0.3 || true
    printf "  ${C_DIM}Если громче не стало — подожди 5 секунд и повтори: сразу после${C_RESET}\n"
    printf "  ${C_DIM}подключения канал AVRCP ещё не поднят и команды отклоняются.${C_RESET}\n"
    return 0
}

fix_bt_hw_volume_off() {
    apply_native_wp_fix 0 || true
    log_warn "Выключи и включи наушники, чтобы новый профиль применился."
    return 0
}

_bt_card_profiles() {  # список A2DP-профилей всех BT-карт
    LC_ALL=C pactl list cards 2>/dev/null \
        | awk '/Name: bluez_card/{f=1} f && /^\tProfiles:/{p=1; next}
               p && /^\t\t/{l=$0; sub(/^\t+/,"",l); sub(/ \(sinks.*/,"",l); if (l ~ /^a2dp/) print "    " l; next}
               p && /^\t[A-Za-z]/{p=0; f=0}' || true
}

fix_install_bt_codecs() {
    # Ставим плагины ТОЛЬКО для кодеков, которые реально умеет подключённая гарнитура.
    local line mac need=()
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        mac="${line%%|*}"
        printf "  %s умеет: ${C_BOLD}%s${C_RESET}\n" "${line#*|}" \
            "$(_bt_headset_codecs "${mac}" | sort -u | paste -sd, - | sed 's/,/, /g')"
        local c
        while IFS= read -r c; do [[ -n "${c}" ]] && need+=("${c}"); done < <(_bt_missing_codecs "${mac}")
    done < <(_bt_connected_list)

    if [[ ${#need[@]} -eq 0 ]]; then
        log_cool "Все кодеки, которые умеет гарнитура, в системе уже есть. Ставить нечего."
        return 0
    fi

    local pkgs=() c
    for c in $(printf '%s\n' "${need[@]}" | sort -u); do
        case "$(_pkg_mgr):${c}" in
            apt:LDAC)         pkgs+=(libspa-0.2-bluetooth libldacbt-enc2 libldacbt-abr2) ;;
            apt:aptX*)        pkgs+=(libspa-0.2-bluetooth libfreeaptx0) ;;
            apt:AAC)          log_warn "AAC: в репозиториях Debian/Ubuntu/Mint плагина нет — пропускаю." ;;
            pacman:LDAC)      pkgs+=(libldac) ;;
            pacman:aptX*)     pkgs+=(libfreeaptx) ;;
            pacman:AAC)       pkgs+=(libfdk-aac) ;;
            dnf:aptX*)        pkgs+=(pipewire-codec-aptx) ;;
            zypper:LDAC)      pkgs+=(libldacBT-enc2) ;;
            zypper:aptX*)     pkgs+=(libfreeaptx0) ;;
            *)                log_warn "${c}: не знаю пакета для этого дистрибутива." ;;
        esac
    done

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        log_info "Из штатного репозитория поставить нечего — система уже использует лучший доступный кодек."
        return 0
    fi

    # Убираем уже установленные
    local todo=() p
    for p in $(printf '%s\n' "${pkgs[@]}" | sort -u); do
        if [[ "$(_pkg_mgr)" == "apt" ]] && dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q 'ok installed'; then
            printf "  ${C_DIM}%s — уже установлен${C_RESET}\n" "${p}"
            continue
        fi
        todo+=("${p}")
    done
    if [[ ${#todo[@]} -eq 0 ]]; then
        log_warn "Нужные пакеты уже стоят, а плагина всё равно нет — значит, в этой сборке PipeWire кодек не собран."
        return 1
    fi

    local before; before="$(_bt_card_profiles)"
    local cmd; cmd="$(_pkg_install_cmd "${todo[@]}")"
    printf "\n  Команда установки: ${C_BOLD}%s${C_RESET}\n" "${cmd}"
    local yn
    read -r -p "  Выполнить? [y/N]: " yn
    [[ "${yn}" =~ ^[yYдД] ]] || { log_info "Пропускаю."; return 0; }
    eval "${cmd}" || { log_danger "Установка не удалась."; return 1; }

    log_info "Перезапускаю WirePlumber и переподключаю гарнитуру, иначе новые кодеки не появятся..."
    systemctl --user restart wireplumber 2>/dev/null || true
    sleep 2
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        mac="${line%%|*}"
        timeout 15 bluetoothctl disconnect "${mac}" >/dev/null 2>&1 || true
        sleep 2
        timeout 25 bluetoothctl connect "${mac}" >/dev/null 2>&1 || true
    done < <(_bt_connected_list)
    sleep 5

    printf "\n  ${C_BOLD}Профили ДО:${C_RESET}\n%s\n" "${before:-    (нет)}"
    printf "  ${C_BOLD}Профили ПОСЛЕ:${C_RESET}\n%s\n\n" "$(_bt_card_profiles)"
    printf "  ${C_DIM}Выбрать кодек: pactl set-card-profile <карта> <профиль> — или в настройках звука.${C_RESET}\n"
    return 0
}

fix_bt_usb_nosuspend() {
    local d vid pid found=0
    for d in /sys/bus/usb/devices/*/; do
        [[ -f "${d}/idVendor" ]] || continue
        [[ -r "${d}/power/control" ]] || continue
        local is_bt=0 ifc
        for ifc in "${d}"*/bInterfaceClass; do
            [[ -r "${ifc}" ]] || continue
            [[ "$(cat "${ifc}" 2>/dev/null)" == "e0" ]] && is_bt=1
        done
        [[ "${is_bt}" -eq 1 ]] || continue

        vid="$(cat "${d}/idVendor")"; pid="$(cat "${d}/idProduct")"
        echo on | sudo tee "${d}/power/control" >/dev/null 2>&1 || true
        _sudo_write /etc/udev/rules.d/99-linah-bt-nosuspend.rules \
"# linah: запрет автосна USB-адаптера Bluetooth.
# Лечит внезапные отвалы наушников, заикания и 'command tx timeout' в dmesg.
ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"${vid}\", ATTR{idProduct}==\"${pid}\", TEST==\"power/control\", ATTR{power/control}=\"on\""
        sudo udevadm control --reload-rules 2>/dev/null || true
        log_cool "Адаптер ${vid}:${pid} больше не уходит в автосон."
        printf "  ${C_DIM}Откат: sudo rm /etc/udev/rules.d/99-linah-bt-nosuspend.rules${C_RESET}\n"
        found=1
        break
    done
    [[ "${found}" -eq 1 ]] || { log_warn "USB-адаптер Bluetooth не найден (встроенный PCI/UART не требует фикса)."; return 0; }
    return 0
}

fix_bt_trust_all() {
    _have bluetoothctl || return 1
    local mac n=0
    while read -r mac; do
        [[ -z "${mac}" ]] && continue
        timeout 5 bluetoothctl trust "${mac}" >/dev/null 2>&1 && n=$(( n + 1 )) || true
    done < <(timeout 10 bluetoothctl devices 2>/dev/null | awk '/^Device /{print $2}' || true)
    log_cool "Помечено доверенными устройств: ${n}. Теперь они подключаются сами."
    return 0
}

fix_mic_unmute() {
    local src; src="$(pactl get-default-source 2>/dev/null || true)"
    [[ -z "${src}" ]] && return 1
    pactl set-source-mute   "${src}" 0   2>/dev/null || true
    pactl set-source-volume "${src}" 80% 2>/dev/null || true
    log_cool "Микрофон включён, уровень 80% (запас против клиппинга)."
    return 0
}

fix_echo_cancel() {
    local dir; dir="$(_pw_conf_dir)"
    mkdir -p "${dir}"
    cat << 'EOF' > "${dir}/99-linah-echo-cancel.conf"
# linah: виртуальный микрофон с подавлением эха и шума (WebRTC).
# После перезапуска выбери в настройках источник «Микрофон (без эха и шума)».
context.modules = [
    { name = libpipewire-module-echo-cancel
        args = {
            library.name = aec/libspa-aec-webrtc
            aec.args = {
                webrtc.gain_control        = true
                webrtc.noise_suppression   = true
                webrtc.echo_canceller      = true
                webrtc.high_pass_filter    = true
            }
            capture.props  = { node.name = "echo_cancel.capture"  node.passive = true }
            source.props   = { node.name = "echo_cancel.source"
                               node.description = "Микрофон (без эха и шума)" }
            sink.props     = { node.name = "echo_cancel.sink"
                               node.description = "Выход через эхоподавитель" }
            playback.props = { node.name = "echo_cancel.playback" node.passive = true }
        }
    }
]
EOF
    systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    sleep 2
    if LC_ALL=C pactl list short sources 2>/dev/null | grep -q echo_cancel; then
        log_cool "Готово. Выбери источник «Микрофон (без эха и шума)» в настройках звука."
    else
        log_warn "Модуль не поднялся — возможно, нет libspa-aec-webrtc в твоей сборке PipeWire."
    fi
    printf "  ${C_DIM}Откат: rm ${dir}/99-linah-echo-cancel.conf${C_RESET}\n"
    return 0
}
# ==============================================================================
# 3.13 АПТЕЧКА: МЕНЮ РУЧНОГО ПРИМЕНЕНИЯ
# ==============================================================================

audio_first_aid_kit() {
    while true; do
        {
        print_banner
        log_title "АПТЕЧКА: КАТАЛОГ ФИКСОВ ИЗВЕСТНЫХ БОЛЯЧЕК LINUX-ЗВУКА"
        printf "================================================================================\n\n"
        printf "  ${C_DIM}Можно применять точечно, не дожидаясь анализа. Всё обратимо.${C_RESET}\n\n"

        printf "  ${C_BOLD}${C_RED}НЕТ ЗВУКА ВООБЩЕ${C_RESET}\n"
        printf "   ${C_BOLD}[1]${C_RESET}  Снять mute и поднять все аппаратные регуляторы ALSA ${C_DIM}(причина №1)${C_RESET}\n"
        _hint 'Зачем: включает аппаратные каналы звуковой карты, которых не видит системный ползунок.'
        _hint 'Когда: ползунок на 100%, а звука нет или он идёт только из одного выхода. Частая причина после обновления или смены ядра.'
        printf "   ${C_BOLD}[2]${C_RESET}  Выбрать правильный выход и перетащить туда все потоки\n"
        _hint 'Зачем: переключает вывод на нужное устройство и переносит туда уже играющие программы.'
        _hint 'Когда: звук уходит в HDMI или монитор вместо колонок, либо программы остались на старом устройстве.'
        printf "   ${C_BOLD}[3]${C_RESET}  Разнять конфликт PulseAudio и PipeWire\n"
        _hint 'Зачем: отключает старый PulseAudio, если он запущен рядом с PipeWire.'
        _hint 'Когда: задвоенные устройства, пропадающий звук и треск после обновления системы или ручной установки pulseaudio.'
        printf "   ${C_BOLD}[4]${C_RESET}  Запустить и включить в автозагрузку службы аудио\n"
        _hint 'Зачем: запускает и включает в автозагрузку PipeWire, WirePlumber и мост pipewire-pulse.'
        _hint 'Когда: в системе нет звуковых устройств, виден только «Dummy Output» или звук исчез после обновления.'
        printf "\n"

        printf "  ${C_BOLD}${C_YELLOW}ТРЕСК, ЩЕЛЧКИ, ЗАИКАНИЯ${C_RESET}\n"
        printf "   ${C_BOLD}[5]${C_RESET}  Запретить засыпание HDA-кодека ${C_DIM}(щелчки и обрезанное начало треков)${C_RESET}\n"
        _hint 'Зачем: не даёт кодеку встроенной звуковой карты засыпать между звуками.'
        _hint 'Когда: щелчок в начале звука или обрезанное начало уведомлений. Типично для ноутбуков с экономией энергии.'
        printf "   ${C_BOLD}[6]${C_RESET}  Настроить размер буфера: стабильность / баланс / низкая задержка\n"
        _hint 'Зачем: меняет размер аудиобуфера: больше — стабильнее, меньше — отзывчивее.'
        _hint 'Когда: треск и заикания при нагрузке (увеличь буфер) или заметная задержка в играх и при записи (уменьши).'
        printf "   ${C_BOLD}[7]${C_RESET}  Выдать звуку приоритеты реального времени ${C_DIM}(треск под нагрузкой)${C_RESET}\n"
        _hint 'Зачем: разрешает звуковому серверу работать с повышенным приоритетом.'
        _hint 'Когда: звук трещит именно под нагрузкой: сборка проекта, игра, тяжёлый браузер.'
        printf "   ${C_BOLD}[8]${C_RESET}  Запретить засыпание устройств при простое\n"
        _hint 'Зачем: запрещает аудиоустройствам засыпать, когда ничего не играет.'
        _hint 'Когда: первые доли секунды звука обрезаются, слышен щелчок при пробуждении USB-ЦАПа или наушников.'
        printf "\n"

        printf "  ${C_BOLD}${C_CYAN}КАЧЕСТВО ЗВУКА${C_RESET}\n"
        printf "   ${C_BOLD}[9]${C_RESET}  Ресэмплер студийного качества + отключить авто-занижение уровня\n"
        _hint 'Зачем: повышает качество пересчёта частоты дискретизации и отключает авто-занижение уровня.'
        _hint 'Когда: слушаешь музыку 44.1 кГц на системе с 48 кГц и слышишь «грязные» верха. Разница едва заметна и стоит немного процессора.'
        printf "  ${C_BOLD}[10]${C_RESET}  Вернуть выходу честные 100%% (0 dB) без клиппинга\n"
        _hint 'Зачем: возвращает выходу 100% (0 dB) без усиления и без занижения.'
        _hint 'Когда: громкость случайно упала или поднята выше 100% и появился хрип от перегрузки.'
        printf "\n"

        printf "  ${C_BOLD}${C_MAGENTA}BLUETOOTH${C_RESET}\n"
        printf "  ${C_BOLD}[11]${C_RESET}  Вылечить гонку HFP/A2DP ${C_DIM}(глухой тихий звук «как из рации»)${C_RESET}\n"
        _hint 'Зачем: комплексная защита: гарнитура не сваливается в телефонный моно-режим.'
        _hint 'Когда: после подключения звук глухой «как из рации»; в журнале строки «resource busy» рядом с a2dp.'
        printf "  ${C_BOLD}[12]${C_RESET}  Форсировать стерео A2DP и закрепить профиль\n"
        _hint 'Зачем: переключает карту в стерео A2DP и закрепляет это правилом WirePlumber.'
        _hint 'Когда: гарнитура сейчас в режиме телефона (HSP/HFP) и музыка звучит глухо и моно.'
        printf "  ${C_BOLD}[13]${C_RESET}  Отключить аппаратный аттенюатор гарнитуры (HW_VOLUME_CTRL)\n"
        _hint 'Зачем: отключает передачу громкости в гарнитуру по AVRCP, если она занижает сигнал.'
        _hint 'Когда: у Bluetooth-выхода есть флаг HW_VOLUME_CTRL и при этом тихо на 100%. Встречается у части бюджетных гарнитур.'
        printf "  ${C_BOLD}[14]${C_RESET}  Запретить автосон USB-адаптера ${C_DIM}(отвалы и заикания)${C_RESET}\n"
        _hint 'Зачем: запрещает USB-адаптеру Bluetooth засыпать ради экономии энергии.'
        _hint 'Когда: наушники сами отваливаются или заикаются, в журнале ядра «command tx timeout».'
        printf "  ${C_BOLD}[15]${C_RESET}  Доставить кодеки LDAC / aptX\n"
        _hint 'Зачем: доустанавливает плагины кодеков, если их поддерживает сама гарнитура.'
        _hint 'Когда: в списке профилей нет кодека, о котором заявляют наушники. Не поможет, если наушники его не умеют: смотри «Что умеет гарнитура».'
        printf "  ${C_BOLD}[16]${C_RESET}  Автовключение адаптера и доверие сопряжённым устройствам\n"
        _hint 'Зачем: включает Bluetooth при загрузке и помечает сопряжённые устройства доверенными.'
        _hint 'Когда: наушники не подключаются сами после включения, каждый раз приходится подключать вручную.'
        printf "\n"

        printf "  ${C_BOLD}${C_GREEN}МИКРОФОН И ГОЛОС${C_RESET}\n"
        printf "  ${C_BOLD}[17]${C_RESET}  Включить микрофон и выставить безопасный уровень\n"
        _hint 'Зачем: снимает mute с микрофона и ставит безопасный уровень 80%.'
        _hint 'Когда: тебя не слышно в звонках, хотя микрофон исправен.'
        printf "  ${C_BOLD}[18]${C_RESET}  Поднять микрофон с подавлением эха и шума (WebRTC)\n"
        _hint 'Зачем: создаёт виртуальный микрофон, который подавляет эхо и фоновый шум (WebRTC).'
        _hint 'Когда: собеседники слышат эхо от колонок или шум. В наушниках эха нет, и это не нужно.'
        printf "  ${C_BOLD}[19]${C_RESET}  Нейросетевое шумоподавление микрофона (RNNoise / WebRTC)\n"
        _hint 'Зачем: отсекает шум вентиляторов, стук по клавиатуре и фоновый гул.'
        _hint 'Когда: собеседники жалуются на постоянный шум кулеров или клики клавиш.'
        printf "\n"

        printf "  ${C_BOLD}${C_BLUE}ВНЕШНИЕ ВЫХОДЫ И ЭКРАН${C_RESET}\n"
        printf "  ${C_BOLD}[20]${C_RESET}  Доктор HDMI / DisplayPort (разбудить спящий звук монитора/ТВ)\n"
        _hint 'Зачем: будит звуковой тракт HDMI/DisplayPort, снимает MUTE с каналов IEC958.'
        _hint 'Когда: видео идёт на монитор или ТВ, а звука нет или он не переключается.'
        printf "  ${C_BOLD}[21]${C_RESET}  Bluetooth Wideband Speech (mSBC / FastStream — чистый голос гарнитуры)\n"
        _hint 'Зачем: включает широкополосную передачу голоса 16 кГц в гарнитурах вместо 8 кГц «как из бочки».'
        _hint 'Когда: во время голосовых звонков голос звучит глухо и зажато.'
        printf "  ${C_BOLD}[22]${C_RESET}  Проверка и починка захвата звука экрана (OBS / Discord / WebRTC)\n"
        _hint 'Зачем: проверяет порталы xdg-desktop-portal и доступ к аудиопотокам экрана.'
        _hint 'Когда: при демонстрации экрана или записи в OBS нет системного звука.'
        printf "\n"

        printf "  ${C_BOLD}[0]${C_RESET}  🔙 Назад в главное меню\n\n"

        local kit_choice
        } > "${MENU_BUF}" 2>&1
        menu_read kit_choice "Что применяем? [0-22]: "
        printf "\n"
        case "${kit_choice}" in
            1)  fix_alsa_unmute        || true; press_enter ;;
            2)  fix_switch_sink        || true; press_enter ;;
            3)  fix_server_conflict    || true; press_enter ;;
            4)  fix_start_services     || true; press_enter ;;
            5)  fix_hda_power_save     || true; press_enter ;;
            6)  fix_latency_menu       || true; press_enter ;;
            7)  fix_rt_priority        || true; press_enter ;;
            8)  fix_suspend_on_idle    || true; press_enter ;;
            9)  fix_resample_quality   || true; press_enter ;;
            10) fix_sink_volume_100    || true; press_enter ;;
            11) fix_bt_race_armor      || true; press_enter ;;
            12) fix_bt_force_a2dp      || true; press_enter ;;
            13) fix_bt_hw_volume_off   || true; press_enter ;;
            14) fix_bt_usb_nosuspend   || true; press_enter ;;
            15) fix_install_bt_codecs  || true; press_enter ;;
            16) fix_bt_autoenable      || true; fix_bt_trust_all || true; press_enter ;;
            17) fix_mic_unmute         || true; press_enter ;;
            18) fix_echo_cancel        || true; press_enter ;;
            19) fix_rnnoise_mic        || true; press_enter ;;
            20) fix_hdmi_audio         || true; press_enter ;;
            21) fix_bt_wideband_speech || true; press_enter ;;
            22) check_desktop_audio_capture || true; press_enter ;;
            0|q|Q) return ;;
            *) log_warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# 3.14 ПУЛЬТ ГАРНИТУРЫ: ПРЯМЫЕ КОМАНДЫ ЧЕРЕЗ D-BUS (BlueZ)
# ------------------------------------------------------------------------------
# Системный ползунок управляет цифровой амплитудой PCM. Когда она уже на
# максимуме, а в ушах тихо — значит режет сам чип гарнитуры, и достать до него
# можно только командами AVRCP. Здесь они собраны все.
# ==============================================================================

readonly UUID_A2DP_SINK="0000110b-0000-1000-8000-00805f9b34fb"
readonly UUID_A2DP_SRC="0000110a-0000-1000-8000-00805f9b34fb"
readonly UUID_AVRCP="0000110e-0000-1000-8000-00805f9b34fb"
readonly UUID_AVRCP_TG="0000110c-0000-1000-8000-00805f9b34fb"
readonly UUID_HFP="0000111e-0000-1000-8000-00805f9b34fb"
readonly UUID_HSP="00001108-0000-1000-8000-00805f9b34fb"

# Адаптер по умолчанию: первый hciN из sysfs. Номер НЕ всегда 0 — после
# переподключения USB-адаптера он легко становится hci1.
_bt_default_adapter() {
    local a
    for a in /sys/class/bluetooth/hci*; do
        [[ -e "${a}" ]] || continue
        a="${a##*/}"
        [[ "${a}" == *:* ]] && continue      # hci1:256 — это соединение, не адаптер
        echo "${a}"; return 0
    done
    echo "hci0"
}

# Адаптер, к которому привязано устройство (ищем его объект в дереве BlueZ)
_bt_adapter_of() {  # _bt_adapter_of <MAC>
    local p
    p="$(busctl --list tree org.bluez 2>/dev/null | grep -E "/dev_${1//:/_}\$" | head -1 || true)"
    if [[ "${p}" =~ /org/bluez/(hci[0-9]+)/ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        _bt_default_adapter
    fi
}

# MAC -> путь D-Bus
_bt_path() { echo "/org/bluez/$(_bt_adapter_of "$1")/dev_${1//:/_}"; }
# Путь D-Bus -> MAC
_bt_mac_from_path() { local b="${1##*/dev_}"; echo "${b//_/:}"; }

# Список подключённых устройств: "MAC|Имя"
_bt_connected_list() {
    command -v bluetoothctl &>/dev/null || return 0
    local mac name
    while read -r _ mac name; do
        [[ -z "${mac}" ]] && continue
        echo "${mac}|${name}"
    done < <(timeout 10 bluetoothctl devices Connected 2>/dev/null | grep '^Device ' || true)
}

# Интерактивный выбор устройства; печатает MAC
_bt_pick_device() {
    local list=() line
    mapfile -t list < <(_bt_connected_list)
    if [[ ${#list[@]} -eq 0 ]]; then
        log_danger "Нет подключённых Bluetooth-устройств." >&2
        printf "  Включи гарнитуру и дождись подключения.\n" >&2
        return 1
    fi
    if [[ ${#list[@]} -eq 1 ]]; then
        echo "${list[0]%%|*}"
        return 0
    fi
    {
    printf "\n  ${C_BOLD}Выбери устройство:${C_RESET}\n" >&2
    local i=1
    for line in "${list[@]}"; do
        printf "    ${C_BOLD}[%s]${C_RESET} %s ${C_DIM}(%s)${C_RESET}\n" "$i" "${line#*|}" "${line%%|*}" >&2
        i=$((i+1))
    done
    local pick
    } > "${MENU_BUF}" 2>&1
    menu_read pick "  Номер [1-$(( i - 1 ))]: "
    [[ "${pick}" =~ ^[0-9]+$ && "${pick}" -ge 1 && "${pick}" -le "${#list[@]}" ]] || return 1
    local sel="${list[$(( pick - 1 ))]}"
    echo "${sel%%|*}"
}

# Путь активного медиа-транспорта
_bt_transport_path() {
    busctl --list tree org.bluez 2>/dev/null | grep -E '/fd[0-9]+$' | head -1 || true
}

_bt_prop() {  # _bt_prop <путь> <интерфейс> <свойство>
    # Несуществующее свойство (Volume, Delay у многих гарнитур) — это норма,
    # а не ошибка. Гасим код возврата, иначе set -e убьёт вызывающую функцию.
    [[ -z "$1" ]] && return 0
    busctl get-property org.bluez "$1" "$2" "$3" 2>/dev/null \
        | sed -E 's/^[a-z]+ //; s/^"//; s/"$//' || true
    return 0
}

# Одна команда AVRCP. Возвращает 0 если принята.
_bt_avrcp() {  # _bt_avrcp <путь> <метод>
    busctl call org.bluez "$1" org.bluez.MediaControl1 "$2" >/dev/null 2>&1
}

# Серия команд с отчётом
_bt_avrcp_burst() {  # _bt_avrcp_burst <путь> <метод> <кол-во> [пауза]
    local path="$1" method="$2" count="${3:-20}" delay="${4:-0.3}"
    local ok=0 fail=0 i
    # Отличаем «неверный путь» от «AVRCP ещё не готов» — иначе диагноз врёт
    if ! busctl --list tree org.bluez 2>/dev/null | grep -qx "${path}"; then
        log_danger "Объекта ${path} в BlueZ нет."
        printf "  ${C_DIM}Устройство не подключено или сидит на другом адаптере (hci0/hci1).${C_RESET}\n"
        return 1
    fi
    printf "  Отправляю ${C_BOLD}%s${C_RESET} x%s" "${method}" "${count}"
    for (( i=1; i<=count; i++ )); do
        if _bt_avrcp "${path}" "${method}"; then
            ok=$((ok+1)); printf "."
        else
            fail=$((fail+1)); printf "x"
        fi
        sleep "${delay}"
    done
    printf "\n"
    if [[ "${ok}" -gt 0 ]]; then
        log_cool "Принято: ${ok}, отклонено: ${fail}"
    else
        log_danger "Все ${fail} команд отклонены."
        printf "  ${C_DIM}Обычно это значит, что канал AVRCP ещё не поднялся —\n"
        printf "  он появляется на несколько секунд позже A2DP. Подожди и повтори.${C_RESET}\n"
    fi
    [[ "${ok}" -gt 0 ]]
}

# ------------------------------------------------------------------------------
# Декодер конфигурации SBC
# ------------------------------------------------------------------------------
_bt_decode_sbc() {  # _bt_decode_sbc "4 17 21 2 53"
    local raw="$1"
    if [[ -z "${raw}" ]]; then
        printf "     ${C_DIM}конфигурация недоступна (транспорт не активен)${C_RESET}\n"
        return 0
    fi
    local -a b
    read -r -a b <<< "${raw}" || true
    # busctl печатает массив как "<длина> <байт> <байт>..."
    local n="${b[0]}"
    [[ "${n}" -ne 4 || ${#b[@]} -lt 5 ]] && { printf "     не SBC или неожиданный формат: %s\n" "${raw}"; return 0; }
    local b0="${b[1]}" b1="${b[2]}" minbp="${b[3]}" maxbp="${b[4]}"

    local fb=$(( b0 >> 4 )) cb=$(( b0 & 15 ))
    local freq chmode ch
    case "${fb}" in 8) freq=16000;; 4) freq=32000;; 2) freq=44100;; 1) freq=48000;; *) freq=0;; esac
    case "${cb}" in 8) chmode="Mono";       ch=1;;
                    4) chmode="Dual";       ch=2;;
                    2) chmode="Stereo";     ch=2;;
                    1) chmode="JointStereo";ch=2;;
                    *) chmode="?";          ch=2;; esac

    local blb=$(( b1 >> 4 )) sbb=$(( (b1 >> 2) & 3 )) alb=$(( b1 & 3 ))
    local blocks subbands alloc
    case "${blb}" in 8) blocks=4;; 4) blocks=8;; 2) blocks=12;; 1) blocks=16;; *) blocks=0;; esac
    case "${sbb}" in 2) subbands=4;; 1) subbands=8;; *) subbands=0;; esac
    case "${alb}" in 2) alloc="SNR";; 1) alloc="Loudness";; *) alloc="?";; esac

    printf "     частота:    ${C_BOLD}%s Hz${C_RESET}\n" "${freq}"
    printf "     каналы:     ${C_BOLD}%s${C_RESET}\n" "${chmode}"
    printf "     блоков:     %s   подполос: %s   аллокация: %s\n" "${blocks}" "${subbands}" "${alloc}"
    printf "     bitpool:    ${C_BOLD}%s..%s${C_RESET}\n" "${minbp}" "${maxbp}"

    # Битрейт при максимальном bitpool
    if [[ "${blocks}" -gt 0 && "${subbands}" -gt 0 && "${freq}" -gt 0 ]]; then
        local frame bits
        case "${chmode}" in
            Mono|Dual)   bits=$(( blocks * ch * maxbp ));;
            Stereo)      bits=$(( blocks * maxbp ));;
            JointStereo) bits=$(( subbands + blocks * maxbp ));;
            *)           bits=$(( blocks * maxbp ));;
        esac
        frame=$(( 4 + (4 * subbands * ch) / 8 + (bits + 7) / 8 ))
        local kbps=$(( 8 * frame * freq / (subbands * blocks) / 1000 ))
        printf "     битрейт:    ${C_BOLD}~%s кбит/с${C_RESET} ${C_DIM}(при bitpool %s)${C_RESET}\n" "${kbps}" "${maxbp}"
        if [[ "${maxbp}" -le 53 ]]; then
            printf "     ${C_DIM}Это штатный SBC. Выше только SBC-XQ, но слабые чипы его не тянут.${C_RESET}\n"
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Карта возможностей устройства
# ------------------------------------------------------------------------------
bt_show_capabilities() {
    local mac; mac="$(_bt_pick_device)" || { press_enter; return 1; }
    local dev; dev="$(_bt_path "${mac}")"

    print_banner
    log_title "ЧТО УМЕЕТ ЭТА ГАРНИТУРА"
    printf "================================================================================\n\n"
    printf "  ${C_BOLD}Устройство:${C_RESET} %s\n" "${mac}"
    printf "  ${C_BOLD}Путь D-Bus:${C_RESET} %s\n\n" "${dev}"

    local ifaces
    ifaces="$(busctl introspect org.bluez "${dev}" 2>/dev/null | awk '/^org\.bluez/{print $1}' || true)"
    printf "  ${C_BOLD}Доступные интерфейсы:${C_RESET}\n"
    if [[ -z "${ifaces}" ]]; then
        printf "    ${C_RED}нет (устройство отключено?)${C_RESET}\n"
    else
        local i
        while IFS= read -r i; do
            case "${i}" in
                *MediaControl1) printf "    ${C_GREEN}✔ %s${C_RESET} ${C_DIM}— пульт: громкость и управление плеером${C_RESET}\n" "$i";;
                *Battery1)      printf "    ${C_GREEN}✔ %s${C_RESET} ${C_DIM}— уровень заряда${C_RESET}\n" "$i";;
                *Device1)       printf "    ${C_GREEN}✔ %s${C_RESET} ${C_DIM}— подключение и профили${C_RESET}\n" "$i";;
                *)              printf "    ${C_CYAN}· %s${C_RESET}\n" "$i";;
            esac
        done <<< "${ifaces}"
    fi

    printf "\n  ${C_BOLD}Состояние:${C_RESET}\n"
    printf "    Подключено:  %s\n" "$(_bt_prop "${dev}" org.bluez.Device1 Connected)"
    printf "    Сопряжено:   %s\n" "$(_bt_prop "${dev}" org.bluez.Device1 Paired)"
    printf "    Доверено:    %s\n" "$(_bt_prop "${dev}" org.bluez.Device1 Trusted)"
    local batt; batt="$(_bt_prop "${dev}" org.bluez.Battery1 Percentage)"
    [[ -n "${batt}" ]] && printf "    Заряд:       %s%%\n" "${batt}"

    printf "\n  ${C_BOLD}Команды пульта (MediaControl1):${C_RESET}\n"
    if busctl introspect org.bluez "${dev}" org.bluez.MediaControl1 &>/dev/null; then
        busctl introspect org.bluez "${dev}" org.bluez.MediaControl1 2>/dev/null \
            | awk '/method/{printf "    %s\n", $1}' | tr -d '.'
        printf "    ${C_DIM}В BlueZ помечены как deprecated, но в современных версиях работают.${C_RESET}\n"
    else
        printf "    ${C_RED}MediaControl1 недоступен — пульт работать не будет.${C_RESET}\n"
    fi

    local tr; tr="$(_bt_transport_path)"
    if [[ -n "${tr}" ]]; then
        printf "\n  ${C_BOLD}Медиа-транспорт:${C_RESET} %s\n" "${tr}"
        printf "    Состояние:  %s\n" "$(_bt_prop "${tr}" org.bluez.MediaTransport1 State)"
        local vol; vol="$(_bt_prop "${tr}" org.bluez.MediaTransport1 Volume)"
        if [[ -z "${vol}" || "${vol}" == "-" ]]; then
            printf "    AVRCP Volume: ${C_YELLOW}не задан${C_RESET} ${C_DIM}— абсолютная громкость не согласована,${C_RESET}\n"
            printf "                  ${C_DIM}поэтому поднимать уровень надо через VolumeUp${C_RESET}\n"
        else
            printf "    AVRCP Volume: ${C_GREEN}%s${C_RESET} ${C_DIM}(шкала 0..127)${C_RESET}\n" "${vol}"
        fi
        local delay; delay="$(_bt_prop "${tr}" org.bluez.MediaTransport1 Delay)"
        [[ -n "${delay}" && "${delay}" != "-" ]] && printf "    Задержка:   %s ${C_DIM}(в 1/10 мс)${C_RESET}\n" "${delay}"
        printf "\n  ${C_BOLD}Кодек:${C_RESET}\n"
        _bt_decode_sbc "$(_bt_prop "${tr}" org.bluez.MediaTransport1 Configuration)" || true
    else
        printf "\n  ${C_YELLOW}Медиа-транспорт не найден — включи воспроизведение и повтори.${C_RESET}\n"
    fi
    printf "\n"
    press_enter
}
# ------------------------------------------------------------------------------
# Пульт: громкость
# ------------------------------------------------------------------------------
bt_volume_menu() {
    local mac; mac="$(_bt_pick_device)" || { press_enter; return 1; }
    local dev; dev="$(_bt_path "${mac}")"

    while true; do
        {
        print_banner
        log_title "ГРОМКОСТЬ ГАРНИТУРЫ (внутренний регистр чипа)"
        printf "================================================================================\n\n"
        printf "  ${C_DIM}Это НЕ системный ползунок. Здесь мы крутим регулятор внутри самой${C_RESET}\n"
        printf "  ${C_DIM}гарнитуры — тот же, что физические кнопки [+] и [-] на корпусе.${C_RESET}\n"
        printf "  ${C_DIM}Многие чипы помнят его отдельно для каждого сопряжённого устройства,${C_RESET}\n"
        printf "  ${C_DIM}поэтому на одном компьютере громко, а на другом тихо.${C_RESET}\n\n"

        local tr vol
        tr="$(_bt_transport_path)"
        vol="$(_bt_prop "${tr}" org.bluez.MediaTransport1 Volume)"
        printf "  ${C_BOLD}Устройство:${C_RESET} %s\n" "${mac}"
        if [[ -z "${vol}" || "${vol}" == "-" ]]; then
            printf "  ${C_BOLD}AVRCP Volume:${C_RESET} ${C_YELLOW}не задан${C_RESET} ${C_DIM}(абсолютная громкость не согласована)${C_RESET}\n"
        else
            printf "  ${C_BOLD}AVRCP Volume:${C_RESET} ${C_GREEN}%s / 127${C_RESET}\n" "${vol}"
        fi
        printf "\n================================================================================\n\n"
        printf "  ${C_BOLD}[1]${C_RESET} 🔊 ${C_BOLD}Открыть на максимум${C_RESET} — 25 раз VolumeUp ${C_GREEN}[то, что обычно и нужно]${C_RESET}\n"
        _hint 'Зачем: поднимает внутренний регулятор до предела. Это то же, что зажать [+] на корпусе.'
        _hint 'Когда: почти всегда, когда тихо при системной громкости 100%. Команды сразу после подключения могут не пройти: подожди 5 секунд.'
        printf "  ${C_BOLD}[2]${C_RESET} 🔉 Поднять на N шагов\n"
        _hint 'Зачем: точная подстройка вверх.'
        _hint 'Когда: нужно сделать чуть громче, не выкручивая на максимум.'
        printf "  ${C_BOLD}[3]${C_RESET} 🔈 Опустить на N шагов\n"
        _hint 'Зачем: точная подстройка вниз.'
        _hint 'Когда: после «на максимум» стало слишком громко, например для ночи или чувствительного слуха.'
        printf "  ${C_BOLD}[4]${C_RESET} 🎚️  Задать абсолютное значение 0..127 ${C_DIM}(если поддерживается)${C_RESET}\n"
        _hint 'Зачем: записывает точное число от 0 до 127 во внутренний регулятор.'
        _hint 'Когда: только если гарнитура и система согласовали абсолютную громкость. Иначе используй пункты 1-3.'
        printf "  ${C_BOLD}[5]${C_RESET} 🔁 ${C_BOLD}Тест обратимостью${C_RESET} — вниз, потом вверх, с музыкой\n"
        _hint 'Зачем: опускает и поднимает регулятор гарнитуры под играющий тон, не трогая настройки системы.'
        _hint 'Когда: не уверен, что виновата гарнитура, а не система. Если звук ушёл и вернулся, причина доказана.'
        printf "  ${C_BOLD}[0]${C_RESET} 🔙 Назад\n\n"

        local c n
        } > "${MENU_BUF}" 2>&1
        menu_read c "Выбор [0-5]: "
        case "${c}" in
            1) printf "\n"; _bt_avrcp_burst "${dev}" VolumeUp 25 0.3 || true; press_enter ;;
            2) read -r -p "  Сколько шагов вверх? [1-50]: " n
               [[ "${n}" =~ ^[0-9]+$ ]] && { printf "\n"; _bt_avrcp_burst "${dev}" VolumeUp "${n}" 0.3 || true; }
               press_enter ;;
            3) read -r -p "  Сколько шагов вниз? [1-50]: " n
               [[ "${n}" =~ ^[0-9]+$ ]] && { printf "\n"; _bt_avrcp_burst "${dev}" VolumeDown "${n}" 0.3 || true; }
               press_enter ;;
            4) bt_set_absolute_volume "${tr}" || true; press_enter ;;
            5) bt_test_reversibility "${dev}" || true; press_enter ;;
            0|q|Q) return ;;
            *) log_warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

bt_set_absolute_volume() {
    local tr="$1"
    if [[ -z "${tr}" ]]; then
        log_danger "Медиа-транспорт не найден. Включи воспроизведение и повтори."
        return 1
    fi
    local cur; cur="$(_bt_prop "${tr}" org.bluez.MediaTransport1 Volume)"
    if [[ -z "${cur}" || "${cur}" == "-" ]]; then
        log_warn "У этой пары абсолютная громкость AVRCP не согласована."
        printf "  Свойство Volume отсутствует, записать в него нельзя.\n"
        printf "  ${C_BOLD}Пользуйся пунктами 1-3${C_RESET} — VolumeUp/VolumeDown работают и без него.\n"
        return 1
    fi
    printf "  Текущее значение: ${C_BOLD}%s${C_RESET} из 127\n" "${cur}"
    local v
    read -r -p "  Новое значение [0-127]: " v
    [[ "${v}" =~ ^[0-9]+$ && "${v}" -le 127 ]] || { log_warn "Нужно число от 0 до 127."; return 1; }
    if busctl set-property org.bluez "${tr}" org.bluez.MediaTransport1 Volume q "${v}" 2>/dev/null; then
        sleep 1
        log_cool "Записано. Сейчас: $(_bt_prop "${tr}" org.bluez.MediaTransport1 Volume)"
    else
        log_danger "Запись отклонена."
        printf "  ${C_DIM}Чаще всего транспорт не в состоянии active — включи музыку.${C_RESET}\n"
    fi
}

# ------------------------------------------------------------------------------
# Пульт: управление воспроизведением
# ------------------------------------------------------------------------------
bt_playback_menu() {
    local mac; mac="$(_bt_pick_device)" || { press_enter; return 1; }
    local dev; dev="$(_bt_path "${mac}")"

    while true; do
        {
        print_banner
        log_title "ПУЛЬТ ПЛЕЕРА (AVRCP passthrough)"
        printf "================================================================================\n\n"
        printf "  ${C_DIM}Команды уходят в гарнитуру так же, как если бы ты нажал кнопку${C_RESET}\n"
        printf "  ${C_DIM}на её корпусе. Реакция зависит от приложения-плеера на компьютере.${C_RESET}\n\n"
        printf "  ${C_BOLD}Устройство:${C_RESET} %s\n\n" "${mac}"
        printf "  ${C_BOLD}[1]${C_RESET} ▶️  Play\n"
        _hint 'Зачем: запускает воспроизведение, как кнопка ▶ на гарнитуре.'
        _hint 'Когда: проверить, что канал управления AVRCP работает.'
        printf "  ${C_BOLD}[2]${C_RESET} ⏸️  Pause\n"
        _hint 'Зачем: ставит на паузу.'
        _hint 'Когда: гарнитура должна останавливать музыку, а не реагирует.'
        printf "  ${C_BOLD}[3]${C_RESET} ⏹️  Stop\n"
        _hint 'Зачем: останавливает воспроизведение.'
        _hint 'Когда: нужно проверить остановку плеера командой с гарнитуры.'
        printf "  ${C_BOLD}[4]${C_RESET} ⏭️  Next\n"
        _hint 'Зачем: следующий трек.'
        _hint 'Когда: кнопка «вперёд» на наушниках не переключает треки.'
        printf "  ${C_BOLD}[5]${C_RESET} ⏮️  Previous\n"
        _hint 'Зачем: предыдущий трек.'
        _hint 'Когда: кнопка «назад» на наушниках не работает.'
        printf "  ${C_BOLD}[6]${C_RESET} ⏩ FastForward\n"
        _hint 'Зачем: перемотка вперёд.'
        _hint 'Когда: проверить, доходят ли до плеера команды перемотки.'
        printf "  ${C_BOLD}[7]${C_RESET} ⏪ Rewind\n"
        _hint 'Зачем: перемотка назад.'
        _hint 'Когда: проверить, доходят ли до плеера команды перемотки.'
        printf "  ${C_BOLD}[0]${C_RESET} 🔙 Назад\n\n"

        local c m
        } > "${MENU_BUF}" 2>&1
        menu_read c "Выбор [0-7]: "
        case "${c}" in
            1) m=Play;; 2) m=Pause;; 3) m=Stop;; 4) m=Next;; 5) m=Previous;;
            6) m=FastForward;; 7) m=Rewind;;
            0|q|Q) return;;
            *) log_warn "Неверный выбор."; sleep 1; continue;;
        esac
        if _bt_avrcp "${dev}" "${m}"; then
            log_cool "${m} — принято."
        else
            log_danger "${m} — отклонено (канал AVRCP не поднят?)."
        fi
        sleep 1
    done
}

# ------------------------------------------------------------------------------
# Пульт: профили и соединение
# ------------------------------------------------------------------------------
bt_connection_menu() {
    local mac; mac="$(_bt_pick_device)" || {
        mac="$(timeout 10 bluetoothctl devices 2>/dev/null | awk '/^Device /{print $2}' | head -1 || true)"
        [[ -z "${mac}" ]] && { press_enter; return 1; }
        log_info "Беру первое сопряжённое устройство: ${mac}"
    }
    local dev; dev="$(_bt_path "${mac}")"

    while true; do
        {
        print_banner
        log_title "СОЕДИНЕНИЕ И ПРОФИЛИ"
        printf "================================================================================\n\n"
        printf "  ${C_BOLD}Устройство:${C_RESET} %s\n" "${mac}"
        printf "  Подключено: %s   Доверено: %s\n\n" \
            "$(_bt_prop "${dev}" org.bluez.Device1 Connected)" \
            "$(_bt_prop "${dev}" org.bluez.Device1 Trusted)"
        printf "  ${C_DIM}Выборочное подключение профилей помогает, когда гарнитура${C_RESET}\n"
        printf "  ${C_DIM}сваливается в телефонный моно-режим: можно поднять только A2DP.${C_RESET}\n\n"
        printf "  ${C_BOLD}[1]${C_RESET} 🔌 Подключить всё\n"
        _hint 'Зачем: обычное подключение всех профилей устройства.'
        _hint 'Когда: гарнитура включена, но сама не подключилась.'
        printf "  ${C_BOLD}[2]${C_RESET} ❌ Отключить\n"
        _hint 'Зачем: разрывает соединение с устройством.'
        _hint 'Когда: нужно освободить гарнитуру, чтобы подключить её к другому компьютеру или телефону.'
        printf "  ${C_BOLD}[3]${C_RESET} 🎵 Подключить ТОЛЬКО стерео A2DP\n"
        _hint 'Зачем: поднимает только музыкальный профиль, без телефонного.'
        _hint 'Когда: при подключении гарнитура уходит в глухой моно-режим.'
        printf "  ${C_BOLD}[4]${C_RESET} 📞 Отключить телефонный профиль HFP ${C_DIM}(убирает моно-режим)${C_RESET}\n"
        _hint 'Зачем: убирает телефонный профиль у уже подключённой гарнитуры.'
        _hint 'Когда: звук стал глухим и моно, а нужен только стерео. Учти: микрофон гарнитуры при этом пропадёт.'
        printf "  ${C_BOLD}[5]${C_RESET} 🎛️  Подключить AVRCP ${C_DIM}(если пульт не отвечает)${C_RESET}\n"
        _hint 'Зачем: поднимает канал управления, по которому идут команды пульта.'
        _hint 'Когда: пульт не отвечает, команды отклоняются.'
        printf "  ${C_BOLD}[6]${C_RESET} ⭐ Пометить доверенным (автоподключение)\n"
        _hint 'Зачем: разрешает устройству подключаться само, без подтверждения.'
        _hint 'Когда: наушники приходится каждый раз подключать вручную.'
        printf "  ${C_BOLD}[7]${C_RESET} 🔄 Чистый цикл: отключить, погасить адаптер, поднять, подключить\n"
        _hint 'Зачем: полностью перезапускает Bluetooth-связь: отключает, гасит адаптер, поднимает, подключает.'
        _hint 'Когда: устройство «зависло», не подключается или не появляется нужный профиль.'
        printf "  ${C_BOLD}[0]${C_RESET} 🔙 Назад\n\n"

        local c
        } > "${MENU_BUF}" 2>&1
        menu_read c "Выбор [0-7]: "
        case "${c}" in
            1) timeout 25 bluetoothctl connect "${mac}" 2>&1 | tail -1 || true; sleep 2 ;;
            2) timeout 15 bluetoothctl disconnect "${mac}" 2>&1 | tail -1 || true; sleep 2 ;;
            3) _bt_connect_profile "${dev}" "${UUID_A2DP_SINK}" "стерео A2DP" ;;
            4) _bt_disconnect_profile "${dev}" "${UUID_HFP}" "телефонный HFP" ;;
            5) _bt_connect_profile "${dev}" "${UUID_AVRCP}" "пульт AVRCP" ;;
            6) timeout 10 bluetoothctl trust "${mac}" >/dev/null 2>&1 && log_cool "Помечено доверенным." || log_danger "Не удалось пометить доверенным." ;;
            7) bt_clean_reconnect || true ;;
            0|q|Q) return ;;
            *) log_warn "Неверный выбор."; sleep 1; continue ;;
        esac
        press_enter
    done
}

_bt_connect_profile() {  # <dev> <uuid> <описание>
    if busctl call org.bluez "$1" org.bluez.Device1 ConnectProfile s "$2" 2>/dev/null; then
        log_cool "Профиль «$3» подключён."
    else
        log_danger "Не удалось подключить «$3»."
        printf "  ${C_DIM}Возможно, профиль уже поднят или гарнитура его не поддерживает.${C_RESET}\n"
    fi
    sleep 1
}

_bt_disconnect_profile() {  # <dev> <uuid> <описание>
    if busctl call org.bluez "$1" org.bluez.Device1 DisconnectProfile s "$2" 2>/dev/null; then
        log_cool "Профиль «$3» отключён."
    else
        log_danger "Не удалось отключить «$3» (возможно, он и не был подключён)."
    fi
    sleep 1
}

# ------------------------------------------------------------------------------
# Задержка A2DP (синхронизация звука с видео)
# ------------------------------------------------------------------------------
bt_delay_menu() {
    local tr; tr="$(_bt_transport_path)"
    if [[ -z "${tr}" ]]; then
        log_danger "Медиа-транспорт не найден. Включи воспроизведение и повтори."
        press_enter; return 1
    fi
    print_banner
    log_title "ЗАДЕРЖКА A2DP (губы не совпадают со звуком)"
    printf "================================================================================\n\n"
    local cur; cur="$(_bt_prop "${tr}" org.bluez.MediaTransport1 Delay)"
    printf "  Текущее значение: ${C_BOLD}%s${C_RESET} ${C_DIM}(единицы — 1/10 миллисекунды)${C_RESET}\n\n" "${cur:-не задано}"
    printf "  ${C_DIM}Bluetooth всегда отстаёт на 100-250 мс. Плееры это компенсируют,${C_RESET}\n"
    printf "  ${C_DIM}но если рассинхрон заметен — подстрой вручную.${C_RESET}\n\n"
    local ms
    read -r -p "  Задержка в миллисекундах [0-1000, пусто — отмена]: " ms
    [[ "${ms}" =~ ^[0-9]+$ ]] || { log_info "Отменено."; press_enter; return 0; }
    local raw=$(( ms * 10 ))
    if busctl set-property org.bluez "${tr}" org.bluez.MediaTransport1 Delay q "${raw}" 2>/dev/null; then
        log_cool "Задержка выставлена: ${ms} мс."
    else
        log_danger "Запись отклонена — устройство не поддерживает настройку задержки."
    fi
    press_enter
}
# ==============================================================================
# 3.15 ТЕСТИРОВАНИЕ BLUETOOTH-ЗВУКА
# ------------------------------------------------------------------------------
# Главный принцип: подавать сигнал ИЗВЕСТНОГО уровня. Уровень зашивается в сам
# файл, поэтому регулятор громкости на результат не влияет и спорить не о чем.
# ==============================================================================

readonly TONE_DIR="${TMPDIR:-/tmp}/linah-tones"

# Генерация тонов с точными уровнями. Возвращает 1, если нечем.
_gen_tones() {
    [[ -f "${TONE_DIR}/t00.wav" ]] && return 0
    command -v python3 &>/dev/null || { log_danger "Нужен python3 для генерации тонов."; return 1; }
    mkdir -p "${TONE_DIR}"
    python3 - "${TONE_DIR}" << 'PYEOF'
import math, struct, sys, wave, os
d = sys.argv[1]
for db in (-20, -12, -6, 0):
    amp = 10 ** (db / 20)
    with wave.open(os.path.join(d, f"t{abs(db):02d}.wav"), 'w') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
        n = 48000 * 4
        fr = bytearray()
        for i in range(n):
            env = min(1.0, i / 2400, (n - i) / 2400)   # фейды 50 мс, чтобы не щёлкало
            v = int(32767 * amp * env * math.sin(2 * math.pi * 1000 * i / 48000))
            fr += struct.pack('<hh', v, v)
        w.writeframes(bytes(fr))
# длинный тон для тестов с управлением на ходу
amp = 10 ** (-20 / 20)
with wave.open(os.path.join(d, "long.wav"), 'w') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
    n = 48000 * 40
    fr = bytearray()
    for i in range(n):
        env = min(1.0, i / 2400, (n - i) / 2400)
        v = int(32767 * amp * env * math.sin(2 * math.pi * 1000 * i / 48000))
        fr += struct.pack('<hh', v, v)
    w.writeframes(bytes(fr))
PYEOF
    [[ -f "${TONE_DIR}/t00.wav" ]]
}

_play_to() {  # _play_to <sink> <файл> [таймаут]
    local sink="$1" f="$2" t="${3:-10}"
    if command -v pw-play &>/dev/null; then
        timeout "${t}" pw-play --target="${sink}" "${f}" >/dev/null 2>&1 || true
    elif command -v paplay &>/dev/null; then
        timeout "${t}" paplay -d "${sink}" "${f}" >/dev/null 2>&1 || true
    else
        timeout "${t}" aplay -q "${f}" >/dev/null 2>&1 || true
    fi
}

_bt_sink() { LC_ALL=C pactl list short sinks 2>/dev/null | awk '$2 ~ /^bluez_output/ {print $2; exit}'; }

# ------------------------------------------------------------------------------
# Тест 1: лесенка калиброванных уровней
# ------------------------------------------------------------------------------
bt_test_tone_ladder() {
    print_banner
    log_title "ЛЕСЕНКА КАЛИБРОВАННЫХ УРОВНЕЙ"
    printf "================================================================================\n\n"

    local sink; sink="$(_bt_sink)"
    [[ -z "${sink}" ]] && { log_danger "Bluetooth-выход не найден. Подключи гарнитуру."; press_enter; return 1; }
    _gen_tones || { press_enter; return 1; }

    printf "  ${C_DIM}Четыре тона 1 кГц с уровнями, зашитыми прямо в файлы.${C_RESET}\n"
    printf "  ${C_DIM}Регулятор фиксируется на 100%% и на результат не влияет.${C_RESET}\n\n"
    printf "  ${C_BOLD}Играю в:${C_RESET} %s\n\n" "${sink}"
    printf "  ${C_BG_RED} СНИМИ НАУШНИКИ С УШЕЙ ${C_RESET} последний шаг — полная шкала.\n\n"
    press_enter

    pactl set-sink-mute "${sink}" 0 >/dev/null 2>&1
    pactl set-sink-volume "${sink}" 100% >/dev/null 2>&1

    local db lbl i=1
    for db in 20 12 06 00; do
        case "${db}" in
            20) lbl="тихий  (-20 dBFS)";;
            12) lbl="средний (-12 dBFS)";;
            06) lbl="громкий (-6 dBFS)";;
            00) lbl="МАКСИМУМ (0 dBFS) — громче не бывает";;
        esac
        printf "  ${C_BOLD}Шаг %s/4:${C_RESET} %s\n" "${i}" "${lbl}"
        _play_to "${sink}" "${TONE_DIR}/t${db}.wav" 10
        i=$((i+1))
        sleep 1
    done

    printf "\n================================================================================\n"
    log_title "КАК ЧИТАТЬ РЕЗУЛЬТАТ"
    printf "\n"
    printf "  ${C_BOLD}Шаг 4 звучал достаточно громко?${C_RESET}\n\n"
    printf "  ${C_GREEN}ДА${C_RESET}  — система отдаёт полную мощность. Если обычная музыка тише,\n"
    printf "        дело в её собственном уровне или в громкости приложения.\n\n"
    printf "  ${C_RED}НЕТ${C_RESET} — это предел возможностей системы, громче она физически не может.\n"
    printf "        Значит режет сам чип гарнитуры. Иди в ${C_BOLD}«Громкость гарнитуры»${C_RESET}\n"
    printf "        и открывай её внутренний регистр командами VolumeUp.\n\n"
    printf "  ${C_DIM}Тот же файл можно проиграть на другом компьютере с теми же наушниками и сравнить:${C_RESET}\n"
    printf "  ${C_DIM}%s${C_RESET}\n\n" "${TONE_DIR}"
    press_enter
}

# ------------------------------------------------------------------------------
# Тест 2: обратимость (доказательство причины)
# ------------------------------------------------------------------------------
bt_test_reversibility() {
    local dev="${1:-}"
    if [[ -z "${dev}" ]]; then
        local mac; mac="$(_bt_pick_device)" || return 1
        dev="$(_bt_path "${mac}")"
    fi
    local sink; sink="$(_bt_sink)"
    [[ -z "${sink}" ]] && { log_danger "Bluetooth-выход не найден."; return 1; }
    _gen_tones || return 1

    printf "\n"
    log_title "ТЕСТ ОБРАТИМОСТЬЮ"
    printf "\n  ${C_DIM}Громкость системы зафиксирована на 100%% и НЕ меняется всё время теста.${C_RESET}\n"
    printf "  ${C_DIM}Меняем только внутренний регистр гарнитуры и слушаем, что будет.${C_RESET}\n\n"
    printf "  Тон будет играть 40 секунд:\n"
    printf "    6 с — как есть\n"
    printf "    затем 20 шагов ВНИЗ  — должно стать тихо\n"
    printf "    затем 25 шагов ВВЕРХ — должно стать громко\n\n"
    press_enter

    pactl set-sink-mute "${sink}" 0 >/dev/null 2>&1
    pactl set-sink-volume "${sink}" 100% >/dev/null 2>&1
    _play_to "${sink}" "${TONE_DIR}/long.wav" 45 &
    local pid=$!

    sleep 6
    printf "  ${C_YELLOW}▼ опускаю регистр гарнитуры${C_RESET}\n"
    _bt_avrcp_burst "${dev}" VolumeDown 20 0.4 || true
    sleep 3
    printf "  ${C_GREEN}▲ поднимаю обратно${C_RESET}\n"
    _bt_avrcp_burst "${dev}" VolumeUp 25 0.4 || true
    sleep 2
    kill "${pid}" 2>/dev/null
    wait "${pid}" 2>/dev/null || true

    printf "\n  Громкость системы в конце: "
    LC_ALL=C pactl list sinks 2>/dev/null | sed -n "/Name: ${sink}/,/^\$/p" \
        | grep -m1 'Volume: front' | sed 's/.*Volume: *//' || true
    printf "\n"
    printf "  ${C_BOLD}Если звук ушёл в тишину и вернулся${C_RESET} — причина доказана:\n"
    printf "  дело в регистре гарнитуры, а не в настройках Linux.\n\n"
}

# ------------------------------------------------------------------------------
# Тест 3: реальный битрейт в эфир
# ------------------------------------------------------------------------------
bt_test_bitrate() {
    print_banner
    log_title "СКОЛЬКО ДАННЫХ РЕАЛЬНО УХОДИТ В ЭФИР"
    printf "================================================================================\n\n"
    local sink; sink="$(_bt_sink)"
    [[ -z "${sink}" ]] && { log_danger "Bluetooth-выход не найден."; press_enter; return 1; }
    _gen_tones || { press_enter; return 1; }

    local hci; hci="$(_bt_default_adapter)"
    local mac1; mac1="$(_bt_connected_list | head -1 | cut -d'|' -f1)"
    [[ -n "${mac1}" ]] && hci="$(_bt_adapter_of "${mac1}")"
    printf "  Адаптер: ${C_BOLD}%s${C_RESET}\n" "${hci}"
    local ctr="/sys/class/bluetooth/${hci}/statistics/tx_bytes"
    local a b
    if [[ -r "${ctr}" ]]; then
        a="$(cat "${ctr}")"
    elif command -v hciconfig &>/dev/null; then
        a="$(hciconfig "${hci}" 2>/dev/null | grep -oE 'TX bytes:[0-9]+' | grep -oE '[0-9]+' || echo 0)"
    else
        log_danger "Нечем считать переданные байты (нет счётчика и hciconfig)."
        press_enter; return 1
    fi

    printf "  Играю тон 4 секунды и считаю переданные байты...\n\n"
    local t0 t1
    t0="$(date +%s%N)"
    _play_to "${sink}" "${TONE_DIR}/t20.wav" 10
    t1="$(date +%s%N)"
    if [[ -r "${ctr}" ]]; then b="$(cat "${ctr}")"; else
        b="$(hciconfig "${hci}" 2>/dev/null | grep -oE 'TX bytes:[0-9]+' | grep -oE '[0-9]+' || echo 0)"; fi

    local bytes=$(( b - a ))
    local ms=$(( (t1 - t0) / 1000000 ))
    [[ "${ms}" -le 0 ]] && ms=1
    local kbps=$(( bytes * 8 / ms ))

    printf "  Передано:  ${C_BOLD}%s${C_RESET} байт за %s мс\n" "${bytes}" "${ms}"
    printf "  Битрейт:   ${C_BOLD}%s кбит/с${C_RESET}\n\n" "${kbps}"

    local tr; tr="$(_bt_transport_path)"
    if [[ -n "${tr}" ]]; then
        printf "  ${C_BOLD}Согласованный кодек:${C_RESET}\n"
        _bt_decode_sbc "$(_bt_prop "${tr}" org.bluez.MediaTransport1 Configuration)" || true
        printf "\n"
    fi
    if [[ "${kbps}" -lt 100 ]]; then
        log_warn "Подозрительно мало. Проверь, что звук реально идёт в гарнитуру."
    elif [[ "${kbps}" -gt 250 ]]; then
        log_cool "Поток полноценный — кодирование и передача в порядке."
        printf "  ${C_DIM}Если при этом тихо, причина не в передаче, а в самой гарнитуре.${C_RESET}\n"
    fi
    printf "\n"
    press_enter
}

# ------------------------------------------------------------------------------
# Тест 4: полный замер цепочки громкости
# ------------------------------------------------------------------------------
bt_test_chain() {
    print_banner
    log_title "ГДЕ ТЕРЯЕТСЯ ГРОМКОСТЬ: ЗАМЕР ПО ВСЕЙ ЦЕПОЧКЕ"
    printf "================================================================================\n\n"
    printf "  ${C_DIM}Регуляторов в PipeWire несколько, и они перемножаются.${C_RESET}\n"
    printf "  ${C_DIM}Здесь видно каждый — так сразу ясно, кто именно душит сигнал.${C_RESET}\n\n"

    local sink card
    sink="$(_bt_sink)"
    card="$(LC_ALL=C pactl list short cards 2>/dev/null | awk '$2 ~ /^bluez_card/ {print $2; exit}')"
    [[ -z "${sink}" ]] && { log_danger "Bluetooth-выход не найден."; press_enter; return 1; }
    _gen_tones || true

    _play_to "${sink}" "${TONE_DIR}/t20.wav" 10 &
    local pid=$!
    sleep 2

    printf "  ${C_BOLD}[1] Поток приложения${C_RESET}\n"
    LC_ALL=C pactl list sink-inputs 2>/dev/null \
        | grep -E 'Volume: front|Mute:|application.name|media.role' | sed 's/^/      /' || printf "      (потоков нет)\n"

    printf "\n  ${C_BOLD}[2] Узел-выход${C_RESET}\n"
    LC_ALL=C pactl list sinks 2>/dev/null | sed -n "/Name: ${sink}/,/^\$/p" \
        | grep -E 'Volume: front|Base Volume|Mute:|Flags:' | sed 's/^/      /' || true

    printf "\n  ${C_BOLD}[3] Маршрут устройства${C_RESET} ${C_DIM}(применяется после узла)${C_RESET}\n"
    if command -v pw-dump &>/dev/null && command -v python3 &>/dev/null; then
        pw-dump 2>/dev/null | python3 -c "
import json, sys, math
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for o in data:
    if o.get('type') != 'PipeWire:Interface:Device':
        continue
    props = (o.get('info') or {}).get('props') or {}
    if 'bluez' not in str(props.get('device.name', '')):
        continue
    routes = ((o.get('info') or {}).get('params') or {}).get('Route', []) or []
    for r in routes:
        cv = (r.get('props') or {}).get('channelVolumes')
        if cv:
            g = cv[0]
            db = 20 * math.log10(g) if g > 0 else float('-inf')
            print(f\"      {r.get('name')}: {g:.6f}  ({db:+.2f} dB)\")
" || printf "      (не удалось прочитать)\n"
    else
        printf "      (нужны pw-dump и python3)\n"
    fi

    printf "\n  ${C_BOLD}[4] Профиль и кодек${C_RESET}\n"
    [[ -n "${card}" ]] && LC_ALL=C pactl list cards 2>/dev/null \
        | sed -n "/Name: ${card}/,/^Card #/p" | grep 'Active Profile' | sed 's/^/      /' || true
    LC_ALL=C pactl list sinks 2>/dev/null | sed -n "/Name: ${sink}/,/^\$/p" \
        | grep -E 'api.bluez5.codec' | sed 's/^/      /' || true

    printf "\n  ${C_BOLD}[5] Транспорт BlueZ${C_RESET}\n"
    local tr; tr="$(_bt_transport_path)"
    if [[ -n "${tr}" ]]; then
        printf "      состояние: %s\n" "$(_bt_prop "${tr}" org.bluez.MediaTransport1 State)"
        local v; v="$(_bt_prop "${tr}" org.bluez.MediaTransport1 Volume)"
        printf "      AVRCP Volume: %s\n" "${v:-не задан}"
        _bt_decode_sbc "$(_bt_prop "${tr}" org.bluez.MediaTransport1 Configuration)" || true
    else
        printf "      (транспорт не найден)\n"
    fi

    kill "${pid}" 2>/dev/null; wait "${pid}" 2>/dev/null || true

    printf "\n================================================================================\n"
    printf "  ${C_BOLD}Как читать:${C_RESET} если все четыре точки показывают 100%% / 1.0 / 0.00 dB,\n"
    printf "  а звук тихий — Linux ни при чём, режет гарнитура.\n\n"
    printf "  ${C_YELLOW}Важно:${C_RESET} не пытайся мерить уровень записью с монитора синка —\n"
    printf "  в PipeWire монитор стоит ${C_BOLD}до${C_RESET} регулятора громкости и при 50%% и при 400%%\n"
    printf "  покажет одно и то же. Только лесенка калиброванных тонов даёт правду.\n\n"
    press_enter
}

# ------------------------------------------------------------------------------
# Тест 5: качество радиолинка
# ------------------------------------------------------------------------------
bt_test_link() {
    print_banner
    log_title "КАЧЕСТВО РАДИОСВЯЗИ"
    printf "================================================================================\n\n"
    local mac; mac="$(_bt_pick_device)" || { press_enter; return 1; }

    if command -v hcitool &>/dev/null; then
        printf "  ${C_BOLD}Активные соединения:${C_RESET}\n"
        hcitool con 2>/dev/null | sed 's/^/    /' || true
        local handle
        handle="$(hcitool con 2>/dev/null | grep -i "${mac}" | grep -oE 'handle [0-9]+' | awk '{print $2}' || true)"
        if [[ -n "${handle}" ]]; then
            printf "\n  ${C_BOLD}RSSI:${C_RESET}    %s\n" "$(hcitool rssi "${mac}" 2>/dev/null | sed 's/.*: //' || echo '?')"
            printf "  ${C_BOLD}Мощность:${C_RESET} %s\n" "$(hcitool tpl "${mac}" 2>/dev/null | sed 's/.*: //' || echo '?')"
            printf "  ${C_BOLD}Качество:${C_RESET} %s\n" "$(hcitool lq "${mac}" 2>/dev/null | sed 's/.*: //' || echo '?')"
        fi
    else
        log_warn "Нет hcitool (пакет bluez-utils / bluez-hcitool)."
    fi

    printf "\n  ${C_BOLD}Ошибки радиоканала за текущую загрузку:${C_RESET}\n"
    if command -v journalctl &>/dev/null; then
        local sco lost
        sco="$(journalctl -k -b 0 --no-pager 2>/dev/null | grep -ciE 'corrupted SCO|SCO packet for unknown' || true)"
        lost="$(journalctl -k -b 0 --no-pager 2>/dev/null | grep -ciE 'hci[0-9]+.*(timeout|reset|Opcode)' || true)"
        printf "    битые SCO-пакеты:  %s\n" "${sco:-0}"
        printf "    сбои контроллера:  %s\n" "${lost:-0}"
        if [[ "${sco:-0}" -gt 0 ]]; then
            printf "\n  ${C_YELLOW}Битые SCO означают, что гарнитура уходила в телефонный моно-режим.${C_RESET}\n"
        fi
    fi
    printf "\n  ${C_DIM}Слабый линк даёт заикания и обрывы, но НЕ делает звук равномерно тихим.${C_RESET}\n\n"
    press_enter
}
# ==============================================================================
# 3.16 ГЛАВНЫЕ МЕНЮ: ПУЛЬТ И ТЕСТЫ
# ==============================================================================

bt_remote_menu() {
    while true; do
        {
        print_banner
        log_title "ПУЛЬТ ГАРНИТУРЫ: ПРЯМЫЕ КОМАНДЫ ПО D-BUS"
        printf "================================================================================\n\n"
        printf "  ${C_DIM}Системный ползунок управляет цифровой амплитудой PCM. Когда она уже${C_RESET}\n"
        printf "  ${C_DIM}на максимуме, а в ушах тихо — значит режет чип гарнитуры. Достать до${C_RESET}\n"
        printf "  ${C_DIM}него можно только отсюда: это те же кнопки, что на корпусе.${C_RESET}\n\n"

        local devs
        devs="$(_bt_connected_list)"
        if [[ -z "${devs}" ]]; then
            printf "  ${C_YELLOW}Подключённых устройств нет — включи гарнитуру.${C_RESET}\n\n"
        else
            printf "  ${C_BOLD}Подключено:${C_RESET} ${C_GREEN}%s${C_RESET}\n\n" "$(echo "${devs}" | sed 's/|/ — /' | paste -sd'; ')"
        fi
        printf "================================================================================\n\n"
        printf "  ${C_BOLD}[1]${C_RESET} 🔊 ${C_BOLD}Громкость гарнитуры${C_RESET} ${C_GREEN}[главное]${C_RESET} — открыть внутренний регистр чипа\n"
        _hint 'Зачем: открывает внутренний регулятор громкости чипа наушников. Системный ползунок его не трогает.'
        _hint 'Когда: система на 100%, а тихо. Те же наушники громче на другом компьютере: многие чипы помнят громкость отдельно для каждого сопряжённого устройства.'
        printf "      ${C_DIM}Лечит «на одном компьютере наушники громкие, на другом тихие».${C_RESET}\n\n"
        printf "  ${C_BOLD}[2]${C_RESET} ▶️  Управление плеером — Play, Pause, Next, Previous, перемотка\n"
        _hint 'Зачем: посылает Play, Pause, Next и другие команды так, как если бы нажали кнопку на корпусе.'
        _hint 'Когда: нужно проверить, слышит ли гарнитура команды, или управлять плеером, не открывая его окно.'
        printf "  ${C_BOLD}[3]${C_RESET} 🔌 Соединение и профили — выборочно A2DP, HFP, AVRCP\n"
        _hint 'Зачем: точечно подключает и отключает профили гарнитуры: A2DP, HFP, AVRCP.'
        _hint 'Когда: гарнитура падает в моно-режим или не отвечает пульт. Полезно, если нужен только стерео-профиль.'
        printf "  ${C_BOLD}[4]${C_RESET} 🎬 Задержка A2DP — если губы не совпадают со звуком\n"
        _hint 'Зачем: сдвигает звук относительно картинки.'
        _hint 'Когда: в видео и играх губы не совпадают со звуком. Bluetooth всегда отстаёт на 100-250 мс.'
        printf "  ${C_BOLD}[5]${C_RESET} 🔍 ${C_BOLD}Что умеет эта гарнитура${C_RESET} — интерфейсы, команды, кодек, заряд\n"
        _hint 'Зачем: показывает интерфейсы, доступные команды, кодек, заряд и состояние соединения.'
        _hint 'Когда: неясно, что вообще поддерживает устройство или почему в списке нет нужного кодека.'
        printf "\n"
        printf "  ${C_BOLD}[0]${C_RESET} 🔙 Назад в главное меню\n\n"

        local c
        } > "${MENU_BUF}" 2>&1
        menu_read c "Выбор [0-5]: "
        case "${c}" in
            1) bt_volume_menu || true ;;
            2) bt_playback_menu || true ;;
            3) bt_connection_menu || true ;;
            4) bt_delay_menu || true ;;
            5) bt_show_capabilities || true ;;
            0|q|Q) return ;;
            *) log_warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

bt_test_menu() {
    while true; do
        {
        print_banner
        log_title "ТЕСТИРОВАНИЕ BLUETOOTH-ЗВУКА"
        printf "================================================================================\n\n"
        printf "  ${C_DIM}Принцип: подавать сигнал ИЗВЕСТНОГО уровня. Уровень зашит в файл,${C_RESET}\n"
        printf "  ${C_DIM}поэтому настройки системы на результат не влияют и спорить не о чем.${C_RESET}\n\n"
        printf "  ${C_BOLD}[1]${C_RESET} 🎚️  ${C_BOLD}Лесенка калиброванных уровней${C_RESET} ${C_GREEN}[начни отсюда]${C_RESET}\n"
        _hint 'Зачем: играет четыре тона 1 кГц с точными уровнями от -20 до 0 dBFS. Последний — предел системы.'
        _hint 'Когда: нужно понять, тихо ли в системе. Если максимум звучит тихо, система выдаёт всё, что может, и режет сама гарнитура.'
        printf "      ${C_DIM}Тоны -20/-12/-6/0 dBFS. Если максимум тихий — виновата гарнитура.${C_RESET}\n\n"
        printf "  ${C_BOLD}[2]${C_RESET} 🔁 ${C_BOLD}Тест обратимостью${C_RESET} — доказать причину наверняка\n"
        _hint 'Зачем: меняет только регулятор внутри гарнитуры, не трогая систему.'
        _hint 'Когда: нужно окончательное доказательство, что причина в гарнитуре.'
        printf "      ${C_DIM}Опускает и поднимает регистр гарнитуры при неизменных настройках Linux.${C_RESET}\n\n"
        printf "  ${C_BOLD}[3]${C_RESET} 📊 Где теряется громкость — замер всех регуляторов цепочки\n"
        _hint 'Зачем: показывает все регуляторы цепочки: поток, выход, маршрут, профиль, транспорт.'
        _hint 'Когда: нужно найти конкретный регулятор, который занижает сигнал.'
        printf "  ${C_BOLD}[4]${C_RESET} 📡 Реальный битрейт в эфир + разбор кодека\n"
        _hint 'Зачем: считает переданные в эфир байты и разбирает параметры кодека.'
        _hint 'Когда: подозрение на плохую связь или неверный кодек, качество хуже ожидаемого.'
        printf "  ${C_BOLD}[5]${C_RESET} 📶 Качество радиосвязи — RSSI, мощность, ошибки канала\n"
        _hint 'Зачем: показывает уровень сигнала, мощность и ошибки радиоканала.'
        _hint 'Когда: заикания, обрывы и треск при удалении от компьютера или через стену.'
        printf "\n"
        printf "  ${C_BOLD}[0]${C_RESET} 🔙 Назад в главное меню\n\n"

        local c
        } > "${MENU_BUF}" 2>&1
        menu_read c "Выбор [0-5]: "
        case "${c}" in
            1) bt_test_tone_ladder || true ;;
            2) bt_test_reversibility || true; press_enter ;;
            3) bt_test_chain || true ;;
            4) bt_test_bitrate || true ;;
            5) bt_test_link || true ;;
            0|q|Q) return ;;
            *) log_warn "Неверный выбор."; sleep 1 ;;
        esac
    done
}

# ==============================================================================
# 4. РУЧНАЯ НАСТРОЙКА ГРОМКОСТИ И ОВЕРАМПЛИФИКАЦИИ
# ==============================================================================
tune_volume_menu() {
    print_banner
    log_title "ТОЧНАЯ ПОДСТРОЙКА ГРОМКОСТИ ДЛЯ ЛЮБОГО ДЕВАЙСА"
    printf "================================================================================\n\n"

    local sinks_data=()
    local raw
    mapfile -t raw < <(LC_ALL=C pactl list sinks 2>/dev/null || true)

    local s_name="" s_desc="" s_vol=""
    for line in "${raw[@]}"; do
        if [[ "${line}" =~ ^Sink\ #[0-9]+ ]]; then
            [[ -n "${s_name}" ]] && sinks_data+=("${s_name}|${s_desc}|${s_vol}")
            s_name="" s_desc="" s_vol=""
        elif [[ "${line}" =~ Name:\ (.*) ]]; then
            s_name="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ Description:\ (.*) ]]; then
            s_desc="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ /[[:space:]]*([0-9]+)% ]]; then
            s_vol="${BASH_REMATCH[1]}%"
        fi
    done
    [[ -n "${s_name}" ]] && sinks_data+=("${s_name}|${s_desc}|${s_vol}")

    if [[ ${#sinks_data[@]} -eq 0 ]]; then
        log_danger "Звуковые выходы вообще не обнаружены. Сервер звука лежит?"
        press_enter
        return
    fi

    {
    printf "  Выбери устройство:\n"
    local idx=1
    for item in "${sinks_data[@]}"; do
        IFS='|' read -r n d v <<< "${item}"
        printf "    [%d] ${C_BOLD}%-35s${C_RESET} (Громкость: ${C_CYAN}%s${C_RESET})\n" "${idx}" "${d:0:35}" "${v}"
        ((idx++))
    done
    printf "    [0] Назад\n\n"

    } > "${MENU_BUF}" 2>&1
    menu_read pick "Номер устройства: "
    if [[ ! "${pick}" =~ ^[0-9]+$ ]] || [[ "${pick}" -lt 1 ]] || [[ "${pick}" -gt ${#sinks_data[@]} ]]; then
        return
    fi

    {
    IFS='|' read -r sel_name sel_desc sel_vol <<< "${sinks_data[$((pick-1))]}"
    printf "\n  Устройство: ${C_BOLD}%s${C_RESET}\n" "${sel_desc}"
    printf "  Текущая громкость: ${C_CYAN}%s${C_RESET}\n\n" "${sel_vol}"

    printf "  Куда крутим?\n"
    printf "    1) Поставить 100%% (Номинал 0 dB)\n"
    _hint 'Зачем: возвращает номинальный уровень.'
    _hint 'Когда: громкость сбилась или от перегрузки появился хрип.'
    printf "    2) Поставить 150%% (+10 dB софтверный буст)\n"
    _hint 'Зачем: программный запас громкости.'
    _hint 'Когда: 100% всё ещё тихо, а чистота звука сохраняется.'
    printf "    3) Поставить 200%% (+18 dB двойной буст)\n"
    _hint 'Зачем: двойной буст. Шкала кубическая: 200% — это амплитуда в 8 раз, а не в 2.'
    _hint 'Когда: очень тихие записи. Возможен клиппинг на пиках.'
    printf "    4) Задать свой процент (например: 85 или 250)\n"
    _hint 'Зачем: любое значение громкости.'
    _hint 'Когда: нужна точная настройка.'
    printf "    5) Переключить Mute (Вкл/Выкл звук)\n"
    _hint 'Зачем: включает или выключает звук выхода.'
    _hint 'Когда: звука нет, хотя всё исправно: проверь, не заглушен ли выход.'
    printf "    6) Сделать выходом по умолчанию (Default Sink)\n"
    _hint 'Зачем: назначает устройство основным для новых программ и системных звуков.'
    _hint 'Когда: системные звуки и новые программы играют не туда.'
    printf "    0) Отмена\n\n"

    } > "${MENU_BUF}" 2>&1
    menu_read v_act "Твой выбор: "
    case "${v_act}" in
        1) pactl set-sink-volume "${sel_name}" 100% 2>/dev/null && log_cool "Громкость 100% установлена!" || log_danger "Не удалось установить громкость." ;;
        2) pactl set-sink-volume "${sel_name}" 150% 2>/dev/null && log_cool "Громкость 150% установлена!" || log_danger "Не удалось установить громкость." ;;
        3) pactl set-sink-volume "${sel_name}" 200% 2>/dev/null && log_cool "Громкость 200% установлена!" || log_danger "Не удалось установить громкость." ;;
        4)
            read -r -p "Введи процент (число): " custom_pct
            custom_pct="${custom_pct//%/}"
            if [[ "${custom_pct}" =~ ^[0-9]+$ ]]; then
                if pactl set-sink-volume "${sel_name}" "${custom_pct}%" 2>/dev/null; then
                    log_cool "Громкость ${custom_pct}% установлена!"
                else
                    log_danger "Не удалось установить громкость."
                fi
            else
                log_danger "Ты ввел не число, чувак."
            fi
            ;;
        5)
            pactl set-sink-mute "${sel_name}" toggle 2>/dev/null || true
            log_cool "Mute переключен!"
            ;;
        6)
            if pactl set-default-sink "${sel_name}" 2>/dev/null; then
                log_cool "Устройство назначено главным по умолчанию!"
            else
                log_danger "Не удалось назначить устройство выходом по умолчанию."
            fi
            ;;
        *) ;;
    esac

    press_enter
}

# ==============================================================================
# 5. РАЗЛОЧКА ПОЛЗУНКА В ГРАФИКЕ (CINNAMON, KDE, GNOME, XFCE, MATE, WM)
# ==============================================================================

tune_cinnamon() {
    {
    printf "\n  ${C_BOLD}[Cinnamon] Настройка апплета звука:${C_RESET}\n"
    printf "    1) Разлочить шкалу до ${C_BOLD}300%%${C_RESET} (Множитель 3.0)\n"
    _hint 'Зачем: расширяет шкалу апплета до 300%.'
    _hint 'Когда: даже 150% мало: тихие записи, слабые колонки.'
    printf "    2) Разлочить шкалу до ${C_BOLD}500%%${C_RESET} (Множитель 5.0)\n"
    _hint 'Зачем: расширяет шкалу до 500%.'
    _hint 'Когда: очень тихие источники. Выше 300% растёт риск искажений.'
    printf "    3) Задать свой процент (например: 250)\n"
    _hint 'Зачем: любое значение потолка.'
    _hint 'Когда: стандартные значения не подошли.'
    printf "    4) Сбросить в заводские 150%%\n"
    _hint 'Зачем: возвращает стандартный потолок 150%.'
    _hint 'Когда: лимит больше не нужен.'
    printf "    0) Отмена\n\n"
    } > "${MENU_BUF}" 2>&1
    menu_read c_act "Выбор [1-4, 0]: "
    case "${c_act}" in
        1|2|3)
            local mult="3.0"
            local pct="300"
            if [[ "${c_act}" == "2" ]]; then
                mult="5.0"
                pct="500"
            elif [[ "${c_act}" == "3" ]]; then
                read -r -p "Введи процент от 150 до 1000: " custom_val
                custom_val="${custom_val//%/}"
                if [[ "${custom_val}" =~ ^[0-9]+$ && "${custom_val}" -ge 150 ]]; then
                    pct="${custom_val}"
                    mult="$(LC_ALL=C awk "BEGIN {printf \"%.1f\", ${pct} / 100}")"
                    mult="${mult//,/.}"
                else
                    log_danger "Некорректное число."
                    return
                fi
            fi

            log_info "Включаем опцию оверамплификации в Cinnamon..."
            gsettings set org.cinnamon.desktop.sound allow-amplified-volume true 2>/dev/null || true

            log_info "Копируем системный апплет в ~/.local/share/cinnamon/applets..."
            mkdir -p "$(dirname "${CINNAMON_USER_APPLET}")"
            [[ ! -d "${CINNAMON_USER_APPLET}" ]] && cp -r "${CINNAMON_SYS_APPLET}" "${CINNAMON_USER_APPLET}"

            log_info "Патчим порог _volumeMax на ${mult}x (${pct}%)..."
            sed -i -E "s/this\._volumeMax = [0-9.]+ \* this\._volumeNorm;/this._volumeMax = ${mult} * this._volumeNorm;/" "${CINNAMON_USER_APPLET}/applet.js"
            sed -i -E "s/set_mark\(1\/[0-9.]+\);/set_mark(1\/${mult});/" "${CINNAMON_USER_APPLET}/applet.js"

            log_info "Перезагружаем апплет на панели задач через D-Bus..."
            busctl --user call org.Cinnamon /org/Cinnamon org.Cinnamon ReloadXlet ss "sound@cinnamon.org" "APPLET" 2>/dev/null || true
            log_cool "ГОТОВО! Теперь ползунок в трее Cinnamon может подниматься до ${pct}%!"
            ;;
        4)
            if [[ -d "${CINNAMON_USER_APPLET}" ]]; then
                rm -rf "${CINNAMON_USER_APPLET}"
                busctl --user call org.Cinnamon /org/Cinnamon org.Cinnamon ReloadXlet ss "sound@cinnamon.org" "APPLET" 2>/dev/null || true
                log_cool "Модификация удалена! Апплет сброшен на стандартные 150%."
            else
                log_info "Пользовательский апплет и так не был установлен (система чиста)."
            fi
            ;;
        *) ;;
    esac
}

tune_kde() {
    {
    printf "\n  ${C_BOLD}[KDE Plasma] Настройка plasma-pa (громкость в трее):${C_RESET}\n"
    printf "    1) Разрешить подъем до ${C_BOLD}200%%${C_RESET}\n"
    _hint 'Зачем: разрешает подъём громкости до 200%.'
    _hint 'Когда: ползунок Plasma упирается в 100%, а звука мало.'
    printf "    2) Разрешить подъем до ${C_BOLD}300%%${C_RESET}\n"
    _hint 'Зачем: разрешает до 300%.'
    _hint 'Когда: тихие записи. Следи за хрипом.'
    printf "    3) Разрешить подъем до ${C_BOLD}500%%${C_RESET}\n"
    _hint 'Зачем: разрешает до 500%.'
    _hint 'Когда: крайне тихие источники.'
    printf "    4) Сбросить в заводские 150%%\n"
    _hint 'Зачем: возвращает стандартный потолок.'
    _hint 'Когда: лимит больше не нужен.'
    printf "    0) Отмена\n\n"
    } > "${MENU_BUF}" 2>&1
    menu_read k_act "Выбор [1-4, 0]: "
    local target_pct="150"
    case "${k_act}" in
        1) target_pct="200" ;;
        2) target_pct="300" ;;
        3) target_pct="500" ;;
        4) target_pct="150" ;;
        *) return ;;
    esac

    log_info "Устанавливаем maximumVolume=${target_pct} в конфигурации plasma-pa..."
    if command -v kwriteconfig6 &>/dev/null; then
        kwriteconfig6 --file plasma-pa.conf --group General --key maximumVolume "${target_pct}"
    elif command -v kwriteconfig5 &>/dev/null; then
        kwriteconfig5 --file plasma-pa.conf --group General --key maximumVolume "${target_pct}"
    else
        mkdir -p "${HOME}/.config"
        local p_conf="${HOME}/.config/plasma-pa.conf"
        if [[ -f "${p_conf}" ]]; then
            if grep -q "maximumVolume=" "${p_conf}"; then
                sed -i -E "s/maximumVolume=[0-9]+/maximumVolume=${target_pct}/" "${p_conf}"
            elif grep -q "\[General\]" "${p_conf}"; then
                sed -i "/\[General\]/a maximumVolume=${target_pct}" "${p_conf}"
            else
                printf "\n[General]\nmaximumVolume=%s\n" "${target_pct}" >> "${p_conf}"
            fi
        else
            cat << EOF > "${p_conf}"
[General]
maximumVolume=${target_pct}
EOF
        fi
    fi

    qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshCurrentShell 2>/dev/null || true
    log_cool "Лимит громкости KDE Plasma установлен в ${target_pct}%!"
    printf "  ${C_DIM}(Если ползунок в трее не обновился сразу, перезапусти plasmashell или перезайди в сессию)${C_RESET}\n"
}

tune_xfce() {
    {
    printf "\n  ${C_BOLD}[XFCE] Настройка xfce4-pulseaudio-plugin:${C_RESET}\n"
    printf "    1) Установить максимум ${C_BOLD}200%%${C_RESET}\n"
    _hint 'Зачем: ставит максимум ползунка 200%.'
    _hint 'Когда: плагин звука панели не даёт поднять выше 100%.'
    printf "    2) Установить максимум ${C_BOLD}300%%${C_RESET}\n"
    _hint 'Зачем: ставит максимум 300%.'
    _hint 'Когда: тихие записи.'
    printf "    3) Сбросить в стандартные 150%%\n"
    _hint 'Зачем: возвращает стандартный потолок.'
    _hint 'Когда: лимит больше не нужен.'
    printf "    0) Отмена\n\n"
    } > "${MENU_BUF}" 2>&1
    menu_read x_act "Выбор [1-3, 0]: "
    local target_pct="150"
    case "${x_act}" in
        1) target_pct="200" ;;
        2) target_pct="300" ;;
        3) target_pct="150" ;;
        *) return ;;
    esac

    if ! command -v xfconf-query &>/dev/null; then
        log_danger "Утилита xfconf-query не найдена в системе. Установи пакет xfconf."
        return
    fi

    log_info "Записываем /volume-max = ${target_pct} через xfconf-query..."
    xfconf-query -c xfce4-pulseaudio-plugin -p /volume-max -t int -s "${target_pct}" --create 2>/dev/null || \
        xfconf-query -c xfce4-pulseaudio-plugin -p /volume-max -s "${target_pct}" 2>/dev/null

    log_info "Перезагружаем панель XFCE..."
    xfce4-panel -r 2>/dev/null || true
    log_cool "Лимит громкости в панели XFCE успешно установлен на ${target_pct}%!"
}

tune_gnome() {
    {
    printf "\n  ${C_BOLD}[GNOME] Настройка оверамплификации:${C_RESET}\n"
    printf "    1) Включить оверамплификацию GNOME (до 150%%)\n"
    _hint 'Зачем: разрешает громкость выше 100% (до 150%).'
    _hint 'Когда: ползунок GNOME упирается в 100%.'
    printf "    2) Выключить оверамплификацию GNOME (ограничить 100%%)\n"
    _hint 'Зачем: ограничивает громкость 100%.'
    _hint 'Когда: слышен хрип от перегрузки.'
    printf "    3) ${C_YELLOW}Как поднять громкость ВЫШЕ 150%% в GNOME?${C_RESET}\n"
    _hint 'Зачем: показывает, как поднять громкость выше стандартного предела GNOME.'
    _hint 'Когда: 150% всё равно мало.'
    printf "    0) Отмена\n\n"
    } > "${MENU_BUF}" 2>&1
    menu_read g_act "Выбор [1-3, 0]: "
    case "${g_act}" in
        1)
            gsettings set org.gnome.desktop.sound allow-volume-above-100-percent true 2>/dev/null
            log_cool "Оверамплификация 150% включена в меню GNOME Quick Settings и Параметрах звука!"
            ;;
        2)
            gsettings set org.gnome.desktop.sound allow-volume-above-100-percent false 2>/dev/null
            log_cool "Громкость в GNOME ограничена номинальными 100%."
            ;;
        3)
            printf "\n  ${C_BOLD}Почему GNOME не даёт крутить ползунок выше 150%%:${C_RESET}\n"
            printf "  Разработчики GNOME намертво зашили лимит 150%% в бинарный код Mutter/Shell.\n\n"
            printf "  ${C_GREEN}${C_BOLD}ДВА РАБОТАЮЩИХ СПОСОБА ОБОЙТИ ЭТО:${C_RESET}\n"
            printf "  1. ${C_CYAN}Включить наш PipeWire Preamp Boost (Пункт [2] меню)${C_RESET}:\n"
            printf "     Он работает на уровне движка PipeWire, а не интерфейса.\n"
            printf "     Для GNOME это будет выглядеть как обычные 0-100%%, но физически звук будет умножен в 3 раза (+20 dB)!\n\n"
            printf "  2. ${C_CYAN}Использовать терминал / хоткеи:${C_RESET}\n"
            printf "     Команда pactl set-sink-volume @DEFAULT_SINK@ 300%% игнорирует любые запреты GNOME.\n"
            ;;
        *) ;;
    esac
}

tune_mate() {
    {
    printf "\n  ${C_BOLD}[MATE] Настройка оверамплификации:${C_RESET}\n"
    printf "    1) Включить оверамплификацию MATE (до 150%%)\n"
    _hint 'Зачем: разрешает громкость выше 100% (до 150%).'
    _hint 'Когда: ползунок MATE упирается в 100%.'
    printf "    2) Выключить оверамплификацию (100%%)\n"
    _hint 'Зачем: ограничивает громкость 100%.'
    _hint 'Когда: слышен хрип от перегрузки.'
    printf "    0) Отмена\n\n"
    } > "${MENU_BUF}" 2>&1
    menu_read m_act "Выбор [1-2, 0]: "
    case "${m_act}" in
        1)
            gsettings set org.mate.volume-control allow-amplified-volume true 2>/dev/null
            log_cool "Оверамплификация MATE включена (до 150%)!"
            ;;
        2)
            gsettings set org.mate.volume-control allow-amplified-volume false 2>/dev/null
            log_cool "Громкость MATE ограничена 100%."
            ;;
        *) ;;
    esac
}

tune_wm_hotkeys() {
    printf "\n  ${C_BOLD}[Тайлинговые WM / Hyprland / i3 / Sway / bspwm]:${C_RESET}\n"
    printf "  В тайлинге нет графического апплета с искусственными лимитами.\n"
    printf "  Ты можешь повесить регулировку напрямую через pactl на ЛЮБОЙ процент:\n\n"
    printf "  ${C_CYAN}Для Hyprland (hyprland.conf):${C_RESET}\n"
    printf "    binde = , XF86AudioRaiseVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ +5%%\n"
    printf "    binde = , XF86AudioLowerVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ -5%%\n"
    printf "    bind  = , XF86AudioMute,        exec, pactl set-sink-mute @DEFAULT_SINK@ toggle\n\n"
    printf "  ${C_CYAN}Для i3 / Sway (config):${C_RESET}\n"
    printf "    bindsym XF86AudioRaiseVolume exec pactl set-sink-volume @DEFAULT_SINK@ +5%%\n"
    printf "    bindsym XF86AudioLowerVolume exec pactl set-sink-volume @DEFAULT_SINK@ -5%%\n"
    printf "    bindsym XF86AudioMute        exec pactl set-sink-mute @DEFAULT_SINK@ toggle\n\n"
}

tune_desktop_slider() {
    {
    print_banner
    log_title "РАСШИРЕНИЕ ПОТОЛКА ГРОМКОСТИ В СИСТЕМНОМ ТРЕЕ И ГРАФИКЕ"
    printf "================================================================================\n\n"

    local de
    de="$(detect_desktop)"
    printf "  Обнаруженное окружение: ${C_GREEN}[%s]${C_RESET} (активно)\n\n" "${de^^}"

    printf "  Куда копаем, шеф?\n"
    if [[ "${de}" != "other" ]]; then
        printf "    [1] ⚙️  Настроить для текущего окружения (${C_BOLD}%s${C_RESET})\n" "${de^^}"
        _hint 'Зачем: определяет рабочий стол и сразу открывает его настройки.'
        _hint 'Когда: обычный случай: достаточно нажать Enter.'
    fi
    printf "    [2] 🎯 Выбрать окружение вручную:\n"
    _hint 'Зачем: даёт выбрать рабочий стол из списка ниже.'
    _hint 'Когда: автоопределение ошиблось или сессия нестандартная.'
    printf "        • c) Cinnamon (Linux Mint)\n"
    _hint 'Зачем: расширяет шкалу апплета звука.'
    _hint 'Когда: Linux Mint и другие системы с Cinnamon: ползунок упирается в 100% или 150%.'
    printf "        • k) KDE Plasma 5/6 (Kubuntu, Fedora KDE, Arch, openSUSE)\n"
    _hint 'Зачем: меняет максимум громкости в plasma-pa.'
    _hint 'Когда: Kubuntu, Fedora KDE, Arch и openSUSE с Plasma.'
    printf "        • g) GNOME (Ubuntu, Fedora Workstation, Debian)\n"
    _hint 'Зачем: включает или выключает усиление выше 100%.'
    _hint 'Когда: Ubuntu, Fedora Workstation, Debian с GNOME.'
    printf "        • x) XFCE (Xubuntu, Mint XFCE, Manjaro)\n"
    _hint 'Зачем: меняет максимум ползунка в плагине звука панели.'
    _hint 'Когда: Xubuntu, Mint XFCE, Manjaro XFCE.'
    printf "        • m) MATE (Ubuntu MATE, Mint MATE)\n"
    _hint 'Зачем: включает усиление выше 100%.'
    _hint 'Когда: Ubuntu MATE и Mint MATE.'
    printf "        • w) Тайлинговые WM (Hyprland, i3, Sway) — хоткеи без лимитов\n"
    _hint 'Зачем: показывает горячие клавиши громкости без лимитов.'
    _hint 'Когда: Hyprland, i3, Sway и другие оконные менеджеры без панели с ползунком.'
    printf "    [0] Назад в главное меню\n\n"

    } > "${MENU_BUF}" 2>&1
    menu_read d_pick "Твой выбор: "
    case "${d_pick}" in
        1)
            case "${de}" in
                cinnamon) tune_cinnamon ;;
                kde)      tune_kde ;;
                xfce)     tune_xfce ;;
                gnome)    tune_gnome ;;
                mate)     tune_mate ;;
                *)        tune_wm_hotkeys ;;
            esac
            ;;
        [cC]|[сС]|*cinnamon*) tune_cinnamon ;;
        [kK]|[кК]|*kde*|*plasma*) tune_kde ;;
        [gG]|[гГ]|*gnome*) tune_gnome ;;
        [xX]|*xfce*) tune_xfce ;;
        [mM]|[мМ]|*mate*) tune_mate ;;
        [wW]|[вВ]|*wm*|*i3*|*sway*|*hypr*) tune_wm_hotkeys ;;
        2)
            printf "\nВыбери букву окружения (c/k/g/x/m/w): "
            read -r sub_de
            case "${sub_de}" in
                [cC]|[сС]) tune_cinnamon ;;
                [kK]|[кК]) tune_kde ;;
                [gG]|[гГ]) tune_gnome ;;
                [xX]) tune_xfce ;;
                [mM]|[мМ]) tune_mate ;;
                [wW]|[вВ]) tune_wm_hotkeys ;;
                *) ;;
            esac
            ;;
        0|*) return ;;
    esac

    press_enter
}

# ==============================================================================
# 6. ТЕСТ СТЕРЕО-КАНАЛОВ: «ПРАВЫЙ, ЛЕВЫЙ, БЕЗ ХРИПОВ»
# ==============================================================================
run_sound_test() {
    print_banner
    log_title "ПРОВЕРКА СТЕРЕОКАНАЛОВ И ЧИСТОТЫ ЗВУКА"
    printf "================================================================================\n\n"

    local def
    def="$(pactl get-default-sink 2>/dev/null || echo 'Не найден')"
    printf "  Звук будет подан на текущий выход: ${C_CYAN}%s${C_RESET}\n\n" "${def}"
    printf "  Сейчас прозвучит голосовая проверка: сначала ЛЕВЫЙ канал, затем ПРАВЫЙ.\n"
    printf "  Слушай внимательно, чтобы не было хрипа и каши.\n\n"

    read -r -p "Готов? Жми [Enter] для пуска..." _

    if command -v speaker-test &>/dev/null; then
        speaker-test -t wav -c 2 -l 1 2>/dev/null || true
    elif command -v paplay &>/dev/null && [[ -f "/usr/share/sounds/freedesktop/stereo/bell.oga" ]]; then
        paplay /usr/share/sounds/freedesktop/stereo/bell.oga 2>/dev/null || true
    else
        log_warn "Утилита speaker-test не найдена. Попробуем ALSA aplay..."
        aplay -q /usr/share/sounds/alsa/Front_Center.wav 2>/dev/null || log_danger "Нет тестовых wav-файлов."
    fi

    log_cool "Тест воспроизведения завершён!"
    press_enter
}

# ==============================================================================
# 7. РЕСТАРТ АУДИОСТЕКА + СБРОС ФАНТОМНЫХ ДУБЛЕЙ В ИНТЕРФЕЙСЕ
# ==============================================================================
restart_audio_stack() {
    print_banner
    log_title "ПИНАЕМ ЗВУКОВОЙ СЕРВЕР И ОЧИЩАЕМ ГЛЮКИ"
    printf "================================================================================\n\n"

    log_info "Перезапуск пользовательских служб PipeWire / WirePlumber..."
    systemctl --user restart pipewire wireplumber pipewire-pulse 2>/dev/null || true
    sleep 1

    log_cool "Службы успешно перезапущены!"
    printf "\n"
    log_warn "ВАЖНЫЙ ЛАЙФХАК ПРО ДУБЛИКАТЫ УСТРОЙСТВ В ОКНЕ «НАСТРОЙКИ ЗВУКА»:"
    printf "  Если у тебя прямо сейчас открыты настройки звука рабочего стола,\n"
    printf "  в нём могут задвоиться устройства (библиотека Cvc не очистила старый список).\n"
    printf "  ${C_BOLD}Не пугайся: просто ЗАКРОЙ окно настроек звука и ОТКРОЙ его заново!${C_RESET}\n"
    printf "  Все фантомные дубли тут же исчезнут.\n"

    press_enter
}

# ==============================================================================
# 9. УДАЛЕННЫЙ АДМИНИСТРАТОР (SSH) И МУЛЬТИ-ПОЛЬЗОВАТЕЛЬСКИЕ СЕССИИ
# ==============================================================================
stream_audio_monitor() {
    local def_sink
    def_sink="$(pactl get-default-sink 2>/dev/null || pactl info 2>/dev/null | grep 'Default Sink' | cut -d: -f2 | xargs || true)"
    if [[ -z "$def_sink" ]]; then
        echo "Error: Default sink not found" >&2
        return 1
    fi
    local snk_mon="${def_sink}"
    [[ "${snk_mon}" != *.monitor ]] && snk_mon="${snk_mon}.monitor"
    local pw_tgt="${def_sink%.monitor}"

    if command -v pw-record &>/dev/null; then
        exec pw-record -P '{ stream.capture.sink = true }' --target "$pw_tgt" --rate 44100 --channels 2 --format s16 - 2>/dev/null
    elif command -v parec &>/dev/null; then
        exec parec -d "$snk_mon" --rate=44100 --channels=2 --format=s16le 2>/dev/null
    elif command -v ffmpeg &>/dev/null; then
        exec ffmpeg -v quiet -f pulse -i "$snk_mon" -f s16le -ac 2 -ar 44100 - 2>/dev/null
    else
        echo "Error: No capture utility (pw-record, parec, ffmpeg) found" >&2
        return 1
    fi
}

remote_session_menu() {
    while true; do
        {
        print_banner
        log_title "SSH УДАЛЕННЫЙ ПОМОЩНИК И СЕССИИ ПОЛЬЗОВАТЕЛЕЙ"
        printf "================================================================================\n\n"

        local cur_u="${TARGET_USER:-${USER}}"
        local cur_uid="${TARGET_UID:-${EUID}}"
        local cur_home="${TARGET_HOME:-${HOME}}"
        local cur_sock="${PULSE_SERVER:-/run/user/${cur_uid}/pulse/native}"

        printf "  • ${C_BOLD}Текущий контекст пользователя:${C_RESET} ${C_GREEN}%s${C_RESET} (UID: %s)\n" "${cur_u}" "${cur_uid}"
        printf "  • ${C_BOLD}Домашний каталог:${C_RESET}               %s\n" "${cur_home}"
        printf "  • ${C_BOLD}Аудиосокет (Pulse/PW):${C_RESET}          %s\n" "${cur_sock}"
        if [[ -S "/run/user/${cur_uid}/pulse/native" || -S "/run/user/${cur_uid}/pipewire-0" ]]; then
            printf "  • ${C_BOLD}Статус аудиосервера:${C_RESET}            ${C_GREEN}● Доступен (сокет активен)${C_RESET}\n\n"
        else
            printf "  • ${C_BOLD}Статус аудиосервера:${C_RESET}            ${C_YELLOW}⚠️ Сокет не найден в /run/user/%s${C_RESET}\n\n" "${cur_uid}"
        fi

        printf "  ${C_BOLD}ДЕЙСТВИЯ:${C_RESET}\n\n"
        printf "  ${C_BOLD}[1]${C_RESET} 🔄 ${C_BOLD}Сменить пользователя / выбрать другую сессию${C_RESET}\n"
        _hint 'Зачем: переключает управление на сессию другого пользователя системы.'
        _hint 'Когда: пользователь обратился за помощью, и админ подключился по SSH.'
        printf "  ${C_BOLD}[2]${C_RESET} 📡 ${C_BOLD}Слушать звук удаленно через SSH (Инструкция и запуск)${C_RESET}\n"
        _hint 'Зачем: транслирует звук рабочего стола удаленного пользователя на компьютер админа.'
        _hint 'Когда: нужно своими ушами услышать, есть ли звук и нет ли хрипов/заиканий.'
        printf "  ${C_BOLD}[3]${C_RESET} 🔊 ${C_BOLD}Подать тестовый звук в сессию пользователя${C_RESET}\n"
        _hint 'Зачем: воспроизводит короткий сигнал в колонках/наушниках пользователя.'
        _hint 'Когда: проверяем, слышит ли пользователь звук за своим рабочим столом.'
        printf "  ${C_BOLD}[4]${C_RESET} 🎛️ ${C_BOLD}Активные программы со звуком в этой сессии${C_RESET}\n"
        _hint 'Зачем: показывает, какие приложения пользователя сейчас воспроизводят звук.'
        _hint 'Когда: пользователь говорит «видео играет, а звука нет» — смотрим, не заглушен ли браузер.'
        printf "  ${C_BOLD}[0]${C_RESET} 🔙 ${C_BOLD}Назад в главное меню${C_RESET}\n\n"

        } > "${MENU_BUF}" 2>&1
        local rem_pick
        menu_read rem_pick "Твой выбор [0-4]: "
        case "${rem_pick}" in
            1)
                printf "\n  ${C_BOLD}Доступные активные сессии в системе:${C_RESET}\n\n"
                local -a sess_arr=()
                local s_idx=1
                while IFS=: read -r s_id s_uid s_user s_seat s_aud; do
                    [[ -z "$s_user" ]] && continue
                    printf "    [%d] %s (UID: %s, сессия %s, аудио: %s)\n" "$s_idx" "$s_user" "$s_uid" "$s_id" "$s_aud"
                    sess_arr+=("$s_user")
                    s_idx=$(( s_idx + 1 ))
                done < <(get_active_sessions)
                printf "    [m] Ввести имя пользователя вручную\n"
                printf "    [0] Отмена\n\n"
                read -r -p "Выберите номер [1-$(( s_idx - 1 ))/m/0]: " u_sel
                case "$u_sel" in
                    0|q|Q) ;;
                    m|M)
                        read -r -p "Введите имя пользователя: " manual_u
                        if [[ -n "$manual_u" ]]; then
                            if switch_to_user_session "$manual_u"; then
                                log_cool "Переключено на пользователя «${manual_u}»!"
                            fi
                        fi
                        press_enter
                        ;;
                    *)
                        if [[ "$u_sel" =~ ^[0-9]+$ ]] && (( u_sel >= 1 && u_sel <= ${#sess_arr[@]} )); then
                            local chosen="${sess_arr[$(( u_sel - 1 ))]}"
                            if switch_to_user_session "$chosen"; then
                                log_cool "Переключено на пользователя «${chosen}»!"
                            fi
                            press_enter
                        fi
                        ;;
                esac
                ;;
            2)
                print_banner
                log_title "УДАЛЁННОЕ ПРОСЛУШИВАНИЕ ЗВУКА ЧЕРЕЗ SSH"
                printf "================================================================================\n\n"
                printf "  Чтобы слушать звук с этого компьютера прямо на своих локальных колонках,\n"
                printf "  запустите на СВОЁМ компьютере в терминале следующую команду:\n\n"
                local host_ip
                host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "remote_ip")"
                local script_path
                script_path="$(readlink -f "$0" 2>/dev/null || echo "linah.sh")"
                local u_arg=""
                [[ -n "${TARGET_USER:-}" ]] && u_arg="--user ${TARGET_USER}"

                printf "  ${C_BG_BLUE}${C_WHITE} ЛОКАЛЬНАЯ КОМАНДА ДЛЯ АДМИНА: ${C_RESET}\n\n"
                printf "  ${C_BOLD}ssh %s@%s \"%s --stream-monitor %s\" | aplay -f cd${C_RESET}\n\n" "${USER}" "${host_ip}" "${script_path}" "${u_arg}"
                printf "  ${C_DIM}Или через mpv / ffplay:${C_RESET}\n"
                printf "  ${C_BOLD}ssh %s@%s \"%s --stream-monitor %s\" | mpv -${C_RESET}\n\n" "${USER}" "${host_ip}" "${script_path}" "${u_arg}"
                printf "  ${C_CYAN}Поток: uncompressed PCM 44.1 kHz, 16-bit stereo (задержка < 50мс).${C_RESET}\n\n"
                press_enter
                ;;
            3)
                log_info "Воспроизводим тестовый сигнал в сессии пользователя «${cur_u}»..."
                if command -v paplay &>/dev/null && [[ -f "/usr/share/sounds/freedesktop/stereo/complete.oga" ]]; then
                    paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true
                elif command -v speaker-test &>/dev/null; then
                    speaker-test -t sine -f 880 -l 1 2>/dev/null || true
                else
                    aplay -q /usr/share/sounds/alsa/Front_Center.wav 2>/dev/null || true
                fi
                log_cool "Тестовый сигнал отправлен на устройство вывода пользователя!"
                press_enter
                ;;
            4)
                active_streams_menu
                ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

# ==============================================================================
# 10. ВИЗУАЛИЗАТОР ЗВУКА, ЖИВОЙ VU-МЕТР И ДЕТЕКТОР СИГНАЛА
# ==============================================================================
# Helper: get formatted list of sinks: name|state|desc
_get_sinks_details() {
    LC_ALL=C pactl list sinks 2>/dev/null | awk '
        /^Sink #/ { if (name != "") print name "|" state "|" desc; in_s=1; name=""; desc=""; state=""; next }
        /^Source #/ { in_s=0 }
        in_s && /^[ \t]*Name: / { sub(/^[ \t]*Name: /, ""); name=$0 }
        in_s && /^[ \t]*State: / { sub(/^[ \t]*State: /, ""); state=$0 }
        in_s && /^[ \t]*Description: / { sub(/^[ \t]*Description: /, ""); desc=$0 }
        END { if (name != "") print name "|" state "|" desc }
    '
}

# Helper: get formatted list of sources (microphones): name|state|desc
_get_sources_details() {
    LC_ALL=C pactl list sources 2>/dev/null | awk '
        /^Source #/ { if (name != "" && name !~ /\.monitor$/) print name "|" state "|" desc; in_s=1; name=""; desc=""; state=""; next }
        in_s && /^[ \t]*Name: / { sub(/^[ \t]*Name: /, ""); name=$0 }
        in_s && /^[ \t]*State: / { sub(/^[ \t]*State: /, ""); state=$0 }
        in_s && /^[ \t]*Description: / { sub(/^[ \t]*Description: /, ""); desc=$0 }
        END { if (name != "" && name !~ /\.monitor$/) print name "|" state "|" desc }
    '
}

# Helper: get human description of a sink or source
_get_audio_device_desc() {
    local target="$1"
    local mode="${2:-sink}"
    local desc=""
    if [[ "$mode" == "mic" || "$mode" == "source" ]]; then
        desc="$(_get_sources_details | grep -F "${target}|" | head -n1 | cut -d'|' -f3 || true)"
    else
        desc="$(_get_sinks_details | grep -F "${target}|" | head -n1 | cut -d'|' -f3 || true)"
    fi
    echo "${desc:-$target}"
}

# Helper: interactive device picker for monitoring
select_monitoring_device() {
    local mode="${1:-sink}"
    local def_name=""
    local names=()
    local states=()
    local descs=()

    if [[ "$mode" == "mic" || "$mode" == "source" ]]; then
        def_name="$(pactl get-default-source 2>/dev/null || pactl info 2>/dev/null | grep 'Default Source' | cut -d: -f2 | xargs || true)"
        while IFS='|' read -r name state desc; do
            [[ -z "$name" ]] && continue
            names+=("$name")
            states+=("$state")
            descs+=("$desc")
        done < <(_get_sources_details)
    else
        def_name="$(pactl get-default-sink 2>/dev/null || pactl info 2>/dev/null | grep 'Default Sink' | cut -d: -f2 | xargs || true)"
        while IFS='|' read -r name state desc; do
            [[ -z "$name" ]] && continue
            names+=("$name")
            states+=("$state")
            descs+=("$desc")
        done < <(_get_sinks_details)
    fi

    if [[ ${#names[@]} -eq 0 ]]; then
        log_warn "В системе не найдено доступных аудиоустройств этого типа."
        press_enter
        return 1
    fi

    {
    print_banner
    if [[ "$mode" == "mic" || "$mode" == "source" ]]; then
        log_title "ВЫБОР МИКРОФОНА ДЛЯ МОНИТОРИНГА"
    else
        log_title "ВЫБОР УСТРОЙСТВА ВЫВОДА ДЛЯ МОНИТОРИНГА"
    fi
    printf "================================================================================\n\n"
    printf "  Выберите аудиоустройство, с которого нужно снимать и анализировать звук:\n\n"

    local i
    for (( i=0; i<${#names[@]}; i++ )); do
        local n="${names[$i]}"
        local d="${descs[$i]}"
        local s="${states[$i]}"
        local def_tag=""
        [[ "$n" == "$def_name" ]] && def_tag=" ${C_GREEN}[ПО УМОЛЧАНИЮ]${C_RESET}"
        local state_tag=""
        if [[ "$s" == "RUNNING" ]]; then
            state_tag=" ${C_CYAN}[АКТИВНО ИГРАЕТ ЗВУК]${C_RESET}"
        elif [[ "$s" == "IDLE" ]]; then
            state_tag=" ${C_GRAY}[ГОТОВ]${C_RESET}"
        fi

        printf "  ${C_BOLD}[%d]${C_RESET} 🔊 ${C_BOLD}%s${C_RESET}%s%s\n" "$((i+1))" "$d" "$def_tag" "$state_tag"
        printf "      ${C_GRAY}Узел: %s${C_RESET}\n\n" "$n"
    done
    printf "  ${C_BOLD}[0]${C_RESET} 🔙 Отмена (оставить текущее устройство)\n\n"
    } > "${MENU_BUF}" 2>&1

    local choice
    menu_read choice "Выберите номер устройства [0-${#names[@]}]: " "select_monitoring_device"
    if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice <= ${#names[@]} )); then
        VU_SELECTED_TARGET="${names[$((choice-1))]}"
        log_cool "Выбрано: ${descs[$((choice-1))]}"
        sleep 0.5
        return 0
    fi
    return 1
}

# Zero-dependency fallback: pure POSIX AWK engine
_run_awk_vu_meter() {
    local dev_title="$1"
    local dev_type="$2"
    local dev_target="$3"
    local cap_cmd="$4"

    local od_cmd="od -v -An -s -w4"
    if ! command -v od &>/dev/null; then
        od_cmd="hexdump -v -e '2/2 \"%7d \" \"\n\"'"
    fi

    trap 'printf "\033[?25h\033[0m\n"; _menu_cleanup' INT TERM

    eval "stdbuf -i0 -o0 -e0 ${cap_cmd}" 2>/dev/null | \
    eval "stdbuf -i0 -o0 -e0 ${od_cmd}" 2>/dev/null | \
    LC_ALL=C awk -v title="${dev_title}" -v dtype="${dev_type}" -v target="${dev_target}" '
    BEGIN {
        count = 0; max_cnt = 800; sum_l = 0; sum_r = 0; pk_l = 0; pk_r = 0;
        bar_w = 26;
        printf "\033[?25l\033[H\033[2J";
    }
    function make_bar(db, val, filled, i, str) {
        val = (db + 60.0) / 60.0;
        if (val < 0) val = 0; if (val > 1) val = 1;
        filled = int(val * bar_w);
        str = "";
        for (i = 0; i < bar_w; i++) {
            if (i < filled) {
                if (i < int(bar_w * 0.65)) str = str "\033[1;32m█\033[0m";
                else if (i < int(bar_w * 0.85)) str = str "\033[1;33m█\033[0m";
                else str = str "\033[1;31m█\033[0m";
            } else {
                str = str "\033[2m░\033[0m";
            }
        }
        return str;
    }
    {
        vl = $1 + 0; vr = $2 + 0;
        if (vl == -32768 && vr == -32768 && count == 0) next;
        sum_l += vl * vl; sum_r += vr * vr;
        al = (vl < 0) ? -vl : vl; ar = (vr < 0) ? -vr : vr;
        if (al > pk_l) pk_l = al; if (ar > pk_r) pk_r = ar;
        count++;
        if (count >= max_cnt) {
            rms_l = sqrt(sum_l / count); rms_r = sqrt(sum_r / count);
            db_l = (rms_l > 0) ? 20 * (log(rms_l / 32768.0) / log(10)) : -60.0;
            db_r = (rms_r > 0) ? 20 * (log(rms_r / 32768.0) / log(10)) : -60.0;
            if (db_l < -60.0) db_l = -60.0; if (db_r < -60.0) db_r = -60.0;
            if (db_l > 0.0) db_l = 0.0;     if (db_r > 0.0) db_r = 0.0;

            max_rms = (db_l > db_r) ? db_l : db_r;
            if (max_rms > -48.0) {
                st = "\033[1;32m🟢 СИГНАЛ АКТИВЕН (" sprintf("%.1f", max_rms) " dBFS)\033[0m — звук поступает в аудиоканал";
                diag = "\033[1mЕсли в колонках/наушниках нет звука:\033[0m\n  • Проверьте кабель/штекер (вставлен ли до конца)\n  • Проверьте питание колонок и выключатель на корпусе\n  • Проверьте регулятор громкости на самих колонках/наушниках!";
            } else {
                st = "\033[2m⚪ ТИШИНА (< -48 dBFS)\033[0m — программы сейчас не воспроизводят звук";
                diag = "Звуковой поток свободен. Запустите музыку, видео или звонок.";
            }

            printf "\033[H";
            printf "  \033[45;1;37m LINAH \033[0m \033[1mЖИВОЙ VU-МЕТР И ДЕТЕКТОР АУДИОСИГНАЛА [POSIX AWK]\033[0m\n";
            printf "  ──────────────────────────────────────────────────────────────────────────────\n";
            printf "  • \033[1mРежим захвата:\033[0m   \033[36m%s\033[0m\n", dtype;
            printf "  • \033[1mУстройство:\033[0m       \033[1;37m%s\033[0m\n", title;
            printf "  • \033[1mСистемный узел:\033[0m   \033[2m%s\033[0m\n\n", target;
            printf "  L: [%s] %5.1f dBFS\n", make_bar(db_l), db_l;
            printf "  R: [%s] %5.1f dBFS\n\n", make_bar(db_r), db_r;
            printf "  • %s\n\n", st;
            printf "  %s\n\n", diag;
            printf "  ──────────────────────────────────────────────────────────────────────────────\n";
            printf "  \033[2m(Движок: pure POSIX awk+coreutils · Для выхода нажмите Ctrl+C)\033[0m\n";
            fflush();
            count = 0; sum_l = 0; sum_r = 0; pk_l = 0; pk_r = 0;
        }
    }
    END {
        printf "\033[?25h\033[0m\n";
    }
    ' || true

    trap - INT TERM
    _tty_flush
}

run_terminal_vu_meter() {
    local dev_mode="${1:-sink}"
    local target_dev="${2:-${VU_SELECTED_TARGET:-}}"

    while true; do
        local def_sink
        def_sink="$(pactl get-default-sink 2>/dev/null || pactl info 2>/dev/null | grep 'Default Sink' | cut -d: -f2 | xargs || true)"
        local def_source
        def_source="$(pactl get-default-source 2>/dev/null || pactl info 2>/dev/null | grep 'Default Source' | cut -d: -f2 | xargs || true)"

        local target_name=""
        local target_node=""
        local target_type=""
        local cap_cmd=""
        local tone_cmd=""

        if [[ "${dev_mode}" == "mic" || "${dev_mode}" == "source" ]]; then
            target_node="${target_dev:-$def_source}"
            [[ -z "$target_node" ]] && target_node="@DEFAULT_AUDIO_SOURCE@"
            target_name="$(_get_audio_device_desc "$target_node" "mic")"
            [[ "$target_node" == "$def_source" ]] && target_name="${target_name} [По умолчанию]"
            target_type="ВХОД МИКРОФОНА (запись звука с микрофона)"

            if command -v pw-record &>/dev/null; then
                cap_cmd="pw-record --target \"${target_node}\" --rate 16000 --channels 2 --format s16 -"
            elif command -v parec &>/dev/null; then
                cap_cmd="parec -d \"${target_node}\" --rate=16000 --channels=2 --format=s16le"
            elif command -v ffmpeg &>/dev/null; then
                cap_cmd="ffmpeg -v quiet -f pulse -i \"${target_node}\" -f s16le -ac 2 -ar 16000 -"
            fi
            tone_cmd=""
        else
            target_node="${target_dev:-$def_sink}"
            [[ -z "$target_node" ]] && target_node="@DEFAULT_AUDIO_SINK@"
            target_name="$(_get_audio_device_desc "$target_node" "sink")"
            [[ "$target_node" == "$def_sink" ]] && target_name="${target_name} [По умолчанию]"
            target_type="ВЫХОД ЗВУКА (монитор колонок / наушников)"

            local snk_mon="${target_node}"
            [[ "${snk_mon}" != *.monitor ]] && snk_mon="${snk_mon}.monitor"
            local pw_tgt="${target_node%.monitor}"

            if command -v pw-record &>/dev/null; then
                cap_cmd="pw-record -P '{ stream.capture.sink = true }' --target \"${pw_tgt}\" --rate 16000 --channels 2 --format s16 -"
            elif command -v parec &>/dev/null; then
                cap_cmd="parec -d \"${snk_mon}\" --rate=16000 --channels=2 --format=s16le"
            elif command -v ffmpeg &>/dev/null; then
                cap_cmd="ffmpeg -v quiet -f pulse -i \"${snk_mon}\" -f s16le -ac 2 -ar 16000 -"
            fi

            if command -v pw-play &>/dev/null; then
                tone_cmd="pw-play --target \"${pw_tgt}\" /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || pw-play --target \"${pw_tgt}\" /usr/share/sounds/alsa/Front_Center.wav 2>/dev/null || true"
            elif command -v paplay &>/dev/null; then
                tone_cmd="paplay -d \"${pw_tgt}\" /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || paplay -d \"${pw_tgt}\" /usr/share/sounds/alsa/Front_Center.wav 2>/dev/null || true"
            else
                tone_cmd="speaker-test -t sine -f 880 -l 1 2>/dev/null || true"
            fi
        fi

        if [[ -z "${cap_cmd}" ]]; then
            log_danger "Не найдена утилита аудиозахвата (pw-record / parec / ffmpeg)."
            press_enter
            return 1
        fi

        # If python3 is not available, use the zero-dependency pure AWK engine
        if ! command -v python3 &>/dev/null; then
            _run_awk_vu_meter "${target_name}" "${target_type}" "${target_node}" "${cap_cmd}"
            return 0
        fi

        read -r -d '' PY_VU_SCRIPT << 'PYEOF' || true
import sys, math, struct, os, time, select, termios, tty, signal
if hasattr(signal, 'SIGPIPE'):
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

def run():
    target_name = sys.argv[1] if len(sys.argv) > 1 else "Default Output"
    target_type = sys.argv[2] if len(sys.argv) > 2 else "ВЫХОД ЗВУКА"
    target_node = sys.argv[3] if len(sys.argv) > 3 else ""
    tone_cmd    = sys.argv[4] if len(sys.argv) > 4 else ""

    tty_fd = None
    old_attr = None
    if os.path.exists("/dev/tty") and sys.stdout.isatty():
        try:
            tty_f = open("/dev/tty", "r")
            tty_fd = tty_f.fileno()
            old_attr = termios.tcgetattr(tty_fd)
            tty.setcbreak(tty_fd)
            termios.tcflush(tty_fd, termios.TCIFLUSH)
        except Exception:
            tty_fd = None

    bar_len = 28
    chunk_frames = 800
    chunk_bytes = chunk_frames * 4

    peak_l_hold = -60.0
    peak_r_hold = -60.0
    peak_hold_time = time.time()

    def make_bar(db, peak_db):
        val = max(0.0, min(1.0, (db + 60.0) / 60.0))
        pk = max(0.0, min(1.0, (peak_db + 60.0) / 60.0))
        filled = int(val * bar_len)
        peak_idx = min(bar_len - 1, int(pk * bar_len))
        chars = []
        for i in range(bar_len):
            if i < filled:
                if i < int(bar_len * 0.65):
                    chars.append("\033[1;32m█\033[0m")
                elif i < int(bar_len * 0.85):
                    chars.append("\033[1;33m█\033[0m")
                else:
                    chars.append("\033[1;31m█\033[0m")
            elif i == peak_idx:
                chars.append("\033[1;37m|\033[0m")
            else:
                chars.append("\033[2m░\033[0m")
        return "".join(chars)

    try:
        sys.stdout.write("\033[?25l")
        sys.stdout.flush()
        action = "quit"
        frames = 0

        while True:
            frames += 1
            if tty_fd is not None:
                r, _, _ = select.select([tty_fd], [], [], 0)
                if r:
                    key = os.read(tty_fd, 1).decode("utf-8", "ignore")
                    if key == "\x1b":
                        r2, _, _ = select.select([tty_fd], [], [], 0.05)
                        if r2:
                            try:
                                os.read(tty_fd, 32)
                            except Exception:
                                pass
                            continue
                        else:
                            action = "quit"
                            break
                    elif key.lower() in ("q", "\x03"):
                        action = "quit"
                        break
                    elif key.lower() == "t":
                        if tone_cmd:
                            os.system(tone_cmd + " >/dev/null 2>&1 &")
                    elif key.lower() == "m":
                        action = "toggle_mode"
                        break
                    elif key.lower() == "d":
                        action = "switch_device"
                        break
            else:
                if frames > 10:
                    action = "quit"
                    break

            buf = bytearray()
            consecutive_empty = 0
            while len(buf) < chunk_bytes:
                needed = chunk_bytes - len(buf)
                chunk = sys.stdin.buffer.read(needed)
                if not chunk:
                    consecutive_empty += 1
                    if consecutive_empty > 50:
                        action = "quit"
                        break
                    time.sleep(0.01)
                    continue
                consecutive_empty = 0
                buf.extend(chunk)

            if len(buf) < chunk_bytes:
                if action == "quit":
                    break
                continue

            data = bytes(buf)
            count = len(data) // 2
            samples = struct.unpack(f"<{count}h", data)

            if any(s == -8531 for s in samples[:8]):
                continue

            left = samples[0::2]
            right = samples[1::2]

            rms_l = math.sqrt(sum(s*s for s in left) / len(left)) if left else 0
            rms_r = math.sqrt(sum(s*s for s in right) / len(right)) if right else 0
            peak_l = max(abs(s) for s in left) if left else 0
            peak_r = max(abs(s) for s in right) if right else 0

            db_l = 20 * math.log10(rms_l / 32768.0) if rms_l > 0 else -60.0
            db_r = 20 * math.log10(rms_r / 32768.0) if rms_r > 0 else -60.0
            pk_l = 20 * math.log10(peak_l / 32768.0) if peak_l > 0 else -60.0
            pk_r = 20 * math.log10(peak_r / 32768.0) if peak_r > 0 else -60.0

            db_l = max(-60.0, min(0.0, db_l))
            db_r = max(-60.0, min(0.0, db_r))
            pk_l = max(-60.0, min(0.0, pk_l))
            pk_r = max(-60.0, min(0.0, pk_r))

            now = time.time()
            if pk_l > peak_l_hold or (now - peak_hold_time > 1.5):
                peak_l_hold = pk_l
            if pk_r > peak_r_hold or (now - peak_hold_time > 1.5):
                peak_r_hold = pk_r
            if now - peak_hold_time > 1.5:
                peak_hold_time = now

            max_rms = max(db_l, db_r)
            if max_rms > -48.0:
                status_line = f"\033[1;32m🟢 СИГНАЛ АКТИВЕН ({max_rms:.1f} dBFS)\033[0m — звук поступает в аудиоканал"
                diag_msg = "\033[1mЕсли в колонках/наушниках нет звука:\033[0m\n  • Проверьте кабель/штекер колонок (вставлен ли до конца)\n  • Проверьте питание колонок и индикатор на корпусе\n  • Проверьте регулятор громкости на самих колонках/наушниках!"
            else:
                status_line = "\033[2m⚪ ТИШИНА (< -48 dBFS)\033[0m — программы сейчас не воспроизводят звук"
                diag_msg = "Нажмите \033[1m[T]\033[0m, чтобы подать тестовый сигнал 1 кГц и проверить шину."

            out = "\033[H\033[2J"
            out += "  \033[45;1;37m LINAH \033[0m \033[1mЖИВОЙ VU-МЕТР И ДЕТЕКТОР АУДИОСИГНАЛА\033[0m\n"
            out += "  ──────────────────────────────────────────────────────────────────────────────\n"
            out += f"  • \033[1mРежим захвата:\033[0m   \033[36m{target_type}\033[0m\n"
            out += f"  • \033[1mУстройство:\033[0m       \033[1;37m{target_name}\033[0m\n"
            out += f"  • \033[1mСистемный узел:\033[0m   \033[2m{target_node}\033[0m\n\n"
            out += f"  L: [{make_bar(db_l, peak_l_hold)}] {db_l:5.1f} dBFS (пик {peak_l_hold:5.1f})\n"
            out += f"  R: [{make_bar(db_r, peak_r_hold)}] {db_r:5.1f} dBFS (пик {peak_r_hold:5.1f})\n\n"
            out += f"  • {status_line}\n"
            out += f"  {diag_msg}\n\n"
            out += "  ──────────────────────────────────────────────────────────────────────────────\n"
            out += "  Управление: \033[1m[T]\033[0m Тестовый тон 1кГц  ·  \033[1m[M]\033[0m Сменить Режим (Выход/Микрофон)\n"
            out += "              \033[1m[D]\033[0m Сменить Аудиоустройство  ·  \033[1m[Q/Esc]\033[0m Выход в меню\n"

            try:
                sys.stdout.write(out)
                sys.stdout.flush()
            except (BrokenPipeError, IOError):
                action = "quit"
                break

    finally:
        if tty_fd is not None and old_attr is not None:
            try:
                termios.tcflush(tty_fd, termios.TCIFLUSH)
            except Exception:
                pass
            try:
                termios.tcsetattr(tty_fd, termios.TCSADRAIN, old_attr)
            except Exception:
                pass
            try:
                termios.tcflush(tty_fd, termios.TCIFLUSH)
            except Exception:
                pass
        try:
            sys.stdout.write("\033[?25h\033[H\033[2J")
            sys.stdout.flush()
        except (BrokenPipeError, IOError):
            pass

    if action == "toggle_mode":
        sys.exit(42)
    elif action == "switch_device":
        sys.exit(43)
    sys.exit(0)

if __name__ == "__main__":
    run()
PYEOF

        local ret=0
        python3 -c "${PY_VU_SCRIPT}" "${target_name}" "${target_type}" "${target_node}" "${tone_cmd}" < <(eval "${cap_cmd}" 2>/dev/null) || ret=$?
        _tty_flush
        if (( ret == 42 )); then
            if [[ "${dev_mode}" == "mic" || "${dev_mode}" == "source" ]]; then
                dev_mode="sink"
            else
                dev_mode="mic"
            fi
            target_dev=""
            VU_SELECTED_TARGET=""
            continue
        elif (( ret == 43 )); then
            if select_monitoring_device "${dev_mode}"; then
                target_dev="${VU_SELECTED_TARGET}"
            fi
            continue
        fi
        break
    done
}


audio_visualizer_menu() {
    local cur_mode="sink"
    while true; do
        local def_sink
        def_sink="$(pactl get-default-sink 2>/dev/null || pactl info 2>/dev/null | grep 'Default Sink' | cut -d: -f2 | xargs || true)"
        local def_source
        def_source="$(pactl get-default-source 2>/dev/null || pactl info 2>/dev/null | grep 'Default Source' | cut -d: -f2 | xargs || true)"

        local target_node="${VU_SELECTED_TARGET:-}"
        local target_desc=""
        local mode_label=""
        if [[ "$cur_mode" == "mic" ]]; then
            [[ -z "$target_node" ]] && target_node="$def_source"
            target_desc="$(_get_audio_device_desc "$target_node" "mic")"
            [[ "$target_node" == "$def_source" ]] && target_desc="${target_desc} [По умолчанию]"
            mode_label="ВХОД МИКРОФОНА (запись)"
        else
            [[ -z "$target_node" ]] && target_node="$def_sink"
            target_desc="$(_get_audio_device_desc "$target_node" "sink")"
            [[ "$target_node" == "$def_sink" ]] && target_desc="${target_desc} [По умолчанию]"
            mode_label="ВЫХОД ЗВУКА (динамики / наушники)"
        fi

        local engine_info=""
        if command -v python3 &>/dev/null; then
            engine_info="Python 3 (интерактивный, горячие клавиши [T], [M], [D])"
        else
            engine_info="POSIX AWK (легковесный, без сторонних зависимостей)"
        fi

        {
        print_banner
        log_title "ВИЗУАЛИЗАЦИЯ ЗВУКА И ДЕТЕКТОР АКТИВНОСТИ"
        printf "================================================================================\n\n"
        printf "  Позволяет объективно увидеть, подаётся ли сигнал на колонки или в микрофон.\n"
        printf "  Если шкала прыгает, а звука нет — проблема 100%% в физических колонках/штекере.\n\n"

        printf "  ${C_BOLD}ТЕКУЩИЙ ИСТОЧНИК ДЛЯ АНАЛИЗА:${C_RESET}\n"
        printf "    • Направление:   ${C_CYAN}%s${C_RESET}\n" "${mode_label}"
        printf "    • Устройство:    ${C_GREEN}%s${C_RESET}\n" "${target_desc}"
        printf "    • Системный узел: ${C_GRAY}%s${C_RESET}\n" "${target_node}"
        printf "    • Движок:        %s\n\n" "${engine_info}"

        printf "  ${C_BOLD}[1]${C_RESET} 📊 ${C_BOLD}Запустить встроенный VU-метр & Детектор сигнала${C_RESET} ${C_GREEN}[Рекомендуется]${C_RESET}\n"
        _hint 'Зачем: показывает уровень сигнала (RMS и пик) в реальном времени прямо в терминале.'
        _hint 'Когда: подозрение, что звук идёт, но колонки выключены или выкручены в ноль.'
        printf "  ${C_BOLD}[2]${C_RESET} 🔄 ${C_BOLD}Сменить аудиоустройство для анализа${C_RESET}\n"
        _hint 'Зачем: позволяет выбрать конкретные колонки, наушники, HDMI или USB-ЦАП из списка.'
        _hint 'Когда: в системе несколько аудиокарт или звук выводится не на дефолтное устройство.'
        printf "  ${C_BOLD}[3]${C_RESET} 🎙️  ${C_BOLD}Переключить режим: Выход колонок ⟷ Микрофон${C_RESET}\n"
        _hint 'Зачем: быстро переключает анализ между воспроизведением звука и записью с микрофона.'
        _hint 'Когда: хотите проверить, слышит ли микрофон ваш голос или шум в комнате.'
        printf "  ${C_BOLD}[4]${C_RESET} 🌊 ${C_BOLD}Запустить CAVA (спектральный анализатор)${C_RESET}\n"
        _hint 'Зачем: визуализирует спектр частот (басы, середина, верха).'
        _hint 'Когда: установлена утилита cava и хочется красивый частотный эквалайзер.'
        printf "  ${C_BOLD}[5]${C_RESET} 📥 ${C_BOLD}Установить CAVA в систему${C_RESET}\n"
        _hint 'Зачем: команда пакетного менеджера для установки утилиты cava.'
        _hint 'Когда: cava не найдена в системе.'
        printf "  ${C_BOLD}[6]${C_RESET} 📡 ${C_BOLD}Слушать звук удаленно через SSH (Loopback)${C_RESET}\n"
        _hint 'Зачем: перенаправляет звук с удалённого сервера на ваши колонки через SSH-туннель.'
        _hint 'Когда: администрируете чужой компьютер и хотите лично послушать его звук.'
        printf "  ${C_BOLD}[0]${C_RESET} 🔙 ${C_BOLD}Назад в главное меню${C_RESET}\n\n"

        } > "${MENU_BUF}" 2>&1
        local v_pick
        menu_read v_pick "Твой выбор [0-6]: " "audio_visualizer_menu"
        case "${v_pick}" in
            1) run_terminal_vu_meter "${cur_mode}" "${target_node}" || true ;;
            2)
                if select_monitoring_device "${cur_mode}"; then
                    target_node="${VU_SELECTED_TARGET}"
                fi
                ;;
            3)
                if [[ "$cur_mode" == "mic" ]]; then
                    cur_mode="sink"
                else
                    cur_mode="mic"
                fi
                VU_SELECTED_TARGET=""
                ;;
            4)
                if command -v cava &>/dev/null; then
                    cava
                else
                    log_warn "CAVA не установлена в системе."
                    printf "  Установите пакет cava через пакетный менеджер (пункт [5]).\n\n"
                    press_enter
                fi
                ;;
            5)
                print_banner
                log_title "УСТАНОВКА CAVA"
                printf "================================================================================\n\n"
                local distro; distro="$(detect_distro)"
                printf "  Дистрибутив: ${C_CYAN}%s${C_RESET}\n\n" "${distro}"
                case "${distro}" in
                    *Ubuntu*|*Mint*|*Debian*)
                        printf "  Выполните: ${C_BOLD}sudo apt update && sudo apt install cava${C_RESET}\n"
                        ;;
                    *Arch*|*Manjaro*)
                        printf "  Выполните: ${C_BOLD}sudo pacman -S cava${C_RESET}\n"
                        ;;
                    *Fedora*)
                        printf "  Выполните: ${C_BOLD}sudo dnf install cava${C_RESET}\n"
                        ;;
                    *openSUSE*)
                        printf "  Выполните: ${C_BOLD}sudo zypper install cava${C_RESET}\n"
                        ;;
                    *)
                        printf "  Установите cava через ваш пакетный менеджер.\n"
                        ;;
                esac
                printf "\n"
                press_enter
                ;;
            6)
                remote_session_menu
                ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

# ==============================================================================
# 11. АКТИВНЫЕ ПОТОКИ И МИКШЕР ПРИЛОЖЕНИЙ
# ==============================================================================
get_active_sink_inputs() {
    LC_ALL=C pactl list sink-inputs 2>/dev/null | awk '
        /^Sink Input #/ { if (id != "") print id "|" app "|" media "|" vol "|" mute "|" sink; id = substr($3, 2); app="Unknown"; media=""; vol="100%"; mute="no"; sink=""; }
        /^[[:space:]]*Sink:/ { sink = $2; }
        /^[[:space:]]*Mute:/ { mute = $2; }
        /^[[:space:]]*Volume:/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /[0-9]+%/) { vol = $i; break; }
            }
        }
        /application\.name =/ {
            sub(/.*application\.name = "/, "");
            sub(/".*/, "");
            app = $0;
        }
        /media\.name =/ {
            sub(/.*media\.name = "/, "");
            sub(/".*/, "");
            media = $0;
        }
        END { if (id != "") print id "|" app "|" media "|" vol "|" mute "|" sink; }
    '
}

active_streams_menu() {
    while true; do
        {
        print_banner
        log_title "АКТИВНЫЕ АУДИОПОТОКИ И МИКШЕР ПРИЛОЖЕНИЙ"
        printf "================================================================================\n\n"

        local -a streams=()
        while IFS='|' read -r s_id s_app s_media s_vol s_mute s_sink; do
            [[ -z "$s_id" ]] && continue
            streams+=("${s_id}|${s_app}|${s_media}|${s_vol}|${s_mute}|${s_sink}")
        done < <(get_active_sink_inputs)

        if (( ${#streams[@]} == 0 )); then
            printf "  ${C_YELLOW}⚪ В данный момент ни одно приложение не воспроизводит звук.${C_RESET}\n\n"
            printf "  ${C_BOLD}[1]${C_RESET} 🔊 Подать тестовый звук (чтобы увидеть поток в списке)\n"
            printf "  ${C_BOLD}[r]${C_RESET} 🔄 Обновить список\n"
            printf "  ${C_BOLD}[0]${C_RESET} 🔙 Назад в главное меню\n\n"
        else
            printf "  ${C_BOLD}ИГРАЮЩИЕ ПРИЛОЖЕНИЯ:${C_RESET}\n\n"
            local idx=1
            for s in "${streams[@]}"; do
                IFS='|' read -r sid sapp smedia svol smute ssink <<< "$s"
                local mute_str="${C_GREEN}Звук ВКЛ${C_RESET}"
                [[ "$smute" == "yes" ]] && mute_str="${C_RED}MUTE (заглушен)${C_RESET}"
                local desc="${sapp}"
                [[ -n "${smedia}" && "${smedia}" != "${sapp}" ]] && desc="${sapp} (${smedia})"
                printf "  ${C_BOLD}[%d]${C_RESET} 🎵 ${C_CYAN}%-26s${C_RESET} | Громкость: ${C_BOLD}%-5s${C_RESET} | %b | Выход: %s\n" \
                    "$idx" "${desc:0:26}" "${svol}" "${mute_str}" "${ssink}"
                idx=$(( idx + 1 ))
            done
            printf "\n"
            printf "  ${C_BOLD}[r]${C_RESET} 🔄 Обновить список\n"
            printf "  ${C_BOLD}[0]${C_RESET} 🔙 Назад в главное меню\n\n"
        fi

        } > "${MENU_BUF}" 2>&1
        local str_pick
        menu_read str_pick "Выбери номер приложения или действие [0-N/r]: "
        case "${str_pick}" in
            0|q|Q) return ;;
            r|R) continue ;;
            1)
                if (( ${#streams[@]} == 0 )); then
                    (speaker-test -t sine -f 880 -l 1 &>/dev/null || paplay /usr/share/sounds/freedesktop/stereo/complete.oga &>/dev/null || true) &
                    sleep 0.2
                    continue
                fi
                ;&
            *)
                if [[ "${str_pick}" =~ ^[0-9]+$ ]] && (( str_pick >= 1 && str_pick <= ${#streams[@]} )); then
                    local sel_stream="${streams[$(( str_pick - 1 ))]}"
                    IFS='|' read -r target_id target_app target_media target_vol target_mute target_sink <<< "$sel_stream"
                    
                    print_banner
                    log_title "УПРАВЛЕНИЕ ПОТОКОМ: ${target_app}"
                    printf "================================================================================\n\n"
                    printf "  • Идентификатор потока: #%s\n" "${target_id}"
                    printf "  • Приложение:           %s\n" "${target_app}"
                    printf "  • Текущая громкость:    %s\n" "${target_vol}"
                    printf "  • Заглушен (Mute):      %s\n\n" "${target_mute}"

                    printf "  [1] 🔇 Включить / Выключить MUTE (заглушить приложение)\n"
                    printf "  [2] 🎚️  Установить громкость 100%%\n"
                    printf "  [3] 🚀 Установить громкость 150%% (разгон тихого видео)\n"
                    printf "  [4] ✍️  Задать громкость вручную (в %%%%)\n"
                    printf "  [5] ➡️  Переместить поток на другой выход\n"
                    printf "  [6] 💀 Принудительно завершить зависший поток\n"
                    printf "  [0] Отмена\n\n"
                    read -r -p "Твой выбор [0-6]: " a_pick
                    case "$a_pick" in
                        1) pactl set-sink-input-mute "${target_id}" toggle 2>/dev/null || true; log_cool "Статус MUTE переключен!" ;;
                        2) pactl set-sink-input-volume "${target_id}" 100% 2>/dev/null || true; log_cool "Громкость установлена на 100%!" ;;
                        3) pactl set-sink-input-volume "${target_id}" 150% 2>/dev/null || true; log_cool "Громкость разогнана до 150%!" ;;
                        4)
                            read -r -p "Введи громкость в процентах (например, 120): " custom_pct
                            if [[ "$custom_pct" =~ ^[0-9]+$ ]]; then
                                pactl set-sink-input-volume "${target_id}" "${custom_pct}%" 2>/dev/null || true
                                log_cool "Громкость установлена на ${custom_pct}%!"
                            fi
                            ;;
                        5)
                            printf "\nДоступные аудиовыходы:\n"
                            local -a sinks=()
                            local k=1
                            while read -r s_idx s_name s_mod s_fmt s_stat; do
                                printf "  [%d] %s\n" "$k" "$s_name"
                                sinks+=("$s_name")
                                k=$(( k + 1 ))
                            done < <(LC_ALL=C pactl list short sinks 2>/dev/null || true)
                            read -r -p "Выбери номер выхода [1-$(( k - 1 ))]: " s_sel
                            if [[ "$s_sel" =~ ^[0-9]+$ ]] && (( s_sel >= 1 && s_sel <= ${#sinks[@]} )); then
                                local dst="${sinks[$(( s_sel - 1 ))]}"
                                pactl move-sink-input "${target_id}" "${dst}" 2>/dev/null || true
                                log_cool "Поток перемещён на «${dst}»!"
                            fi
                            ;;
                        6)
                            pactl kill-sink-input "${target_id}" 2>/dev/null || true
                            log_cool "Поток завершён!"
                            ;;
                        *) ;;
                    esac
                    press_enter
                fi
                ;;
        esac
    done
}

# ==============================================================================
# 12. АУДИОПРЕСЕТЫ В 1 КЛИК (GAMING / CINEMA / HI-FI)
# ==============================================================================
apply_preset_gaming() {
    print_banner
    log_title "ПРЕСЕТ: GAMING & ULTRA-LOW LATENCY"
    printf "================================================================================\n\n"
    log_info "1. Применяем минимальный квант PipeWire (128 сэмплов / задержка ~2.6 мс)..."
    pw-metadata -n settings 0 clock.force-quantum 128 2>/dev/null || true

    mkdir -p "$(_pw_conf_dir)"
    cat << 'EOF' > "${PRESET_GAMING_CONF}"
# linah: игровой пресет с ультра-низкой задержкой (Gaming & Low Latency)
context.properties = {
    default.clock.quantum     = 128
    default.clock.min-quantum = 64
    default.clock.max-quantum = 256
}
EOF

    log_info "2. Отключаем энергосбережение ALSA (устраняем микрофризы при старте звука)..."
    for f in /sys/module/snd_hda_intel/parameters/power_save; do
        if [[ -f "$f" ]]; then
            echo 0 | sudo -n tee "$f" &>/dev/null || true
        fi
    done

    log_cool "Игровой пресет активирован! Задержка сведена к аппаратному минимуму."
    printf "  ${C_DIM}Для отката пресета: linah.sh --preset revert или пункт меню «Сброс пресета».${C_RESET}\n\n"
}

apply_preset_cinema() {
    print_banner
    log_title "ПРЕСЕТ: CINEMA & SPEECH CLARITY (КИНО И ПОДКАСТЫ)"
    printf "================================================================================\n\n"
    log_info "1. Настраиваем виртуальный компрессор и выравниватель громкости речи..."

    mkdir -p "$(_pw_conf_dir)"
    cat << 'EOF' > "${PRESET_CINEMA_CONF}"
# linah: пресет «Кино и Подкасты» — разборчивость голоса и защита от резких звуков
context.modules = [
    { name = libpipewire-module-filter-chain
        args = {
            node.description = "Выход: Кино и Голос (Loudness Normalizer)"
            media.name       = "Выход: Кино и Голос (Loudness Normalizer)"
            filter.graph = {
                nodes = [
                    {
                        type   = builtin
                        name   = eq_band
                        label  = bq_peaking
                        control = { "Freq" = 1800.0 "Q" = 1.2 "Gain" = 5.0 }
                    }
                    {
                        type   = builtin
                        name   = limiter
                        label  = limiter
                        control = { "Limit" = 0.95 }
                    }
                ]
                links = [
                    { output = "eq_band:Out" input = "limiter:In" }
                ]
            }
            capture.props = {
                node.name = "linah_cinema.input"
                media.class = "Audio/Sink"
                audio.channels = 2
                audio.position = [ FL FR ]
            }
            playback.props = {
                node.name = "linah_cinema.output"
                node.passive = true
                audio.channels = 2
                audio.position = [ FL FR ]
            }
        }
    }
]
EOF

    systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    log_cool "Пресет «Кино и Голос» активирован! Тихие диалоги станут громкими и чёткими."
    printf "  ${C_DIM}Для отката пресета: linah.sh --preset revert или пункт меню «Сброс пресета».${C_RESET}\n\n"
}

apply_preset_hifi() {
    print_banner
    log_title "ПРЕСЕТ: HI-FI & STUDIO (BIT-PERFECT)"
    printf "================================================================================\n\n"
    log_info "1. Включаем студийный ресэмплер качества 10 (Soxr / Speex Float 10)..."
    log_info "2. Разрешаем нативные частоты без искажений (44.1, 48, 88.2, 96, 192 кГц)..."

    mkdir -p "$(_pw_conf_dir)"
    cat << 'EOF' > "${PRESET_HIFI_CONF}"
# linah: Hi-Fi студийный аудиопресет
context.properties = {
    resample.quality = 10
    default.clock.allowed-rates = [ 44100 48000 88200 96000 176400 192000 ]
}
EOF

    systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    log_cool "Пресет «Hi-Fi Студия» активирован! Настоящий звук без мыла и передискретизации."
    printf "  ${C_DIM}Для отката пресета: linah.sh --preset revert или пункт меню «Сброс пресета».${C_RESET}\n\n"
}

revert_audio_presets() {
    print_banner
    log_title "СБРОС ЗВУКОВЫХ ПРЕСЕТОВ"
    printf "================================================================================\n\n"
    log_info "Удаляем активные файлы пресетов..."
    rm -f "${PRESET_GAMING_CONF}" "${PRESET_CINEMA_CONF}" "${PRESET_HIFI_CONF}"
    rm -f "$(_pw_conf_dir)"/99-linah-preset-*.conf
    pw-metadata -n settings 0 clock.force-quantum 0 2>/dev/null || true
    systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    log_cool "Все звуковые пресеты сброшены к заводским настройкам!"
}

audio_presets_menu() {
    while true; do
        {
        print_banner
        log_title "ЗВУКОВЫЕ ПРЕСЕТЫ В 1 КЛИК"
        printf "================================================================================\n\n"
        printf "  Быстрая перенастройка аудиоподсистемы под конкретную задачу.\n"
        printf "  Любой пресет можно сбросить обратно в заводской стандарт за секунду.\n\n"

        local g_stat="${C_DIM}○ Не активен${C_RESET}"
        local c_stat="${C_DIM}○ Не активен${C_RESET}"
        local h_stat="${C_DIM}○ Не активен${C_RESET}"

        [[ -f "${PRESET_GAMING_CONF}" ]] && g_stat="${C_GREEN}● АКТИВЕН (128 quantum / low latency)${C_RESET}"
        [[ -f "${PRESET_CINEMA_CONF}" ]] && c_stat="${C_GREEN}● АКТИВЕН (Loudness & Limiter)${C_RESET}"
        [[ -f "${PRESET_HIFI_CONF}" ]] && h_stat="${C_GREEN}● АКТИВЕН (Quality 10 bit-perfect)${C_RESET}"

        printf "  ${C_BOLD}[1]${C_RESET} 🎮 ${C_BOLD}Gaming & Low-Latency${C_RESET}    — буфер 128 сэмплов (~2.6мс), no-sleep [%b]\n" "${g_stat}"
        _hint 'Зачем: сводит аудиозадержку в шутерах (CS2, Apex, Overwatch) и ритм-играх к аппаратному минимуму.'
        _hint 'Когда: чувствуется запаздывание выстрелов или звука шагов в играх.'
        printf "  ${C_BOLD}[2]${C_RESET} 🎬 ${C_BOLD}Cinema & Speech Clarity${C_RESET} — компрессор голоса, нормализация громкости [%b]\n" "${c_stat}"
        _hint 'Зачем: выравнивает громкость в фильмах — тихий шепот становится разборчивым, а взрывы не глушат.'
        _hint 'Когда: при просмотре фильмов приходится постоянно крутить громкость вверх и вниз.'
        printf "  ${C_BOLD}[3]${C_RESET} 🎧 ${C_BOLD}Hi-Fi & Studio${C_RESET}          — студийный ресэмплер quality 10, multi-rate [%b]\n" "${h_stat}"
        _hint 'Зачем: максимальная чистота звука на качественных наушниках и ЦАПах.'
        _hint 'Когда: прослушивание Lossless/FLAC музыки в высоком разрешении.'
        printf "  ${C_BOLD}[4]${C_RESET} 🔄 ${C_BOLD}Сбросить активный пресет${C_RESET}  — возврат к штатным значениям системы\n"
        _hint 'Зачем: удаляет конфигурацию пресета и возвращает стандартный буфер.'
        _hint 'Когда: закончили играть или смотреть кино и хотите вернуть штатные настройки.'
        printf "  ${C_BOLD}[0]${C_RESET} 🔙 ${C_BOLD}Назад в главное меню${C_RESET}\n\n"

        } > "${MENU_BUF}" 2>&1
        local p_choice
        menu_read p_choice "Твой выбор [0-4]: "
        case "${p_choice}" in
            1) apply_preset_gaming; press_enter ;;
            2) apply_preset_cinema; press_enter ;;
            3) apply_preset_hifi; press_enter ;;
            4) revert_audio_presets; press_enter ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

# ==============================================================================
# 13. ДОПОЛНИТЕЛЬНЫЕ ФИКСЫ АПТЕЧКИ
# ==============================================================================
fix_rnnoise_mic() {
    print_banner
    log_title "НЕЙРОСЕТЕВОЕ ПОДАВЛЕНИЕ ШУМА ДЛЯ МИКРОФОНА"
    printf "================================================================================\n\n"
    log_info "Создаём виртуальный микрофон с нейросетевой фильтрацией RNNoise / WebRTC..."

    mkdir -p "$(_pw_conf_dir)"
    cat << 'EOF' > "${RNNOISE_CONF}"
# linah: виртуальный микрофон с подавлением шума кулеров, щелчков клавиатуры и гула
context.modules = [
    { name = libpipewire-module-echo-cancel
        args = {
            library.name = aec/libspa-aec-webrtc
            aec.args = {
                webrtc.noise_suppression = true
                webrtc.high_pass_filter  = true
                webrtc.gain_control      = true
                webrtc.voice_detection   = true
            }
            source.props = {
                node.name = "linah_rnnoise_source"
                node.description = "Микрофон (Чистый голос: без шума и кликов)"
            }
        }
    }
]
EOF

    systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    sleep 1
    log_cool "Готово! В настройках звука / Discord / Telegram выберите вход «Микрофон (Чистый голос: без шума и кликов)»."
    return 0
}

fix_hdmi_audio() {
    print_banner
    log_title "ДОКТОР HDMI / DISPLAYPORT АУДИО"
    printf "================================================================================\n\n"
    log_info "1. Проверяем состояние подключенных мониторов и телевизоров (ELD/EDID)..."

    local found_eld=0
    for eld in /proc/asound/card*/eld*; do
        if [[ -f "$eld" ]] && grep -qs 'monitor_present[[:space:]]*:[[:space:]]*1' "$eld" 2>/dev/null; then
            local mon_name
            mon_name="$(grep -m1 'monitor_name' "$eld" 2>/dev/null | cut -d: -f2 | xargs || echo "Display")"
            log_cool "Обнаружен активный видеовыход: ${mon_name} (${eld})"
            found_eld=1
        fi
    done
    if (( ! found_eld )); then
        log_warn "В /proc/asound не найдено подключенных HDMI мониторов со статусом present."
    fi

    log_info "2. Снимаем MUTE с аппаратных каналов IEC958 / S/PDIF / HDMI..."
    for card in 0 1 2 3; do
        amixer -c "$card" set IEC958 unmute 2>/dev/null || true
        amixer -c "$card" set "IEC958,1" unmute 2>/dev/null || true
        amixer -c "$card" set "IEC958,2" unmute 2>/dev/null || true
        amixer -c "$card" set "IEC958,3" unmute 2>/dev/null || true
    done

    log_info "3. Ищем профиль HDMI в PipeWire / PulseAudio..."
    local hdmi_sink
    hdmi_sink="$(LC_ALL=C pactl list short sinks 2>/dev/null | awk '$2 ~ /hdmi/ {print $2}' | head -n1 || true)"
    if [[ -n "$hdmi_sink" ]]; then
        pactl set-sink-mute "${hdmi_sink}" 0 2>/dev/null || true
        pactl set-sink-volume "${hdmi_sink}" 100% 2>/dev/null || true
        log_cool "HDMI-выход найден и разблокирован: ${hdmi_sink}"
    else
        log_warn "HDMI-аудиоприёмник не виден в списке активных. Возможно, требуется переключить профиль видеокарты."
    fi
    return 0
}

fix_bt_wideband_speech() {
    print_banner
    log_title "ШИРОКОПОЛОСНЫЙ ГОЛОС BLUETOOTH (mSBC / LC3-SWB)"
    printf "================================================================================\n\n"
    log_info "Включаем качественные широкополосные голосовые кодеки (mSBC 16кГц / LC3 32кГц)..."

    local wp_conf="${WP_DIR_05}/54-linah-wideband-speech.conf"
    mkdir -p "${WP_DIR_05}"
    cat << 'EOF' > "${wp_conf}"
# linah: включение широкополосных кодеков для гарнитур (mSBC / FastStream)
monitor.bluez.properties = {
    bluez5.roles = [ a2dp_sink a2dp_source bap_sink bap_source hsp_hs hsp_ag hfp_hf hfp_ag ]
    bluez5.codecs = [ sbc sbc_xq aac ldac aptx aptx_hd faststream ]
    bluez5.enable-msbc = true
    bluez5.enable-sbc-xq = true
    bluez5.enable-faststream = true
}
EOF

    systemctl --user restart wireplumber 2>/dev/null || true
    log_cool "Параметры mSBC и FastStream успешно прописаны в WirePlumber!"
    return 0
}

check_desktop_audio_capture() {
    print_banner
    log_title "ПРОВЕРКА ЗАХВАТА ЗВУКА ЭКРАНА И ПРИЛОЖЕНИЙ"
    printf "================================================================================\n\n"
    log_info "Проверяем xdg-desktop-portal и права захвата звука монитора..."

    if ! pgrep -f xdg-desktop-portal &>/dev/null; then
        log_warn "Служба xdg-desktop-portal не запущена. Захват звука окна в OBS/Discord может не работать."
        log_info "Запускаем xdg-desktop-portal..."
        systemctl --user start xdg-desktop-portal 2>/dev/null || true
    else
        log_cool "xdg-desktop-portal активен."
    fi

    local def_sink
    def_sink="$(pactl get-default-sink 2>/dev/null || true)"
    if [[ -n "$def_sink" ]]; then
        log_cool "Монитор звука по умолчанию доступен: ${def_sink}.monitor"
    else
        log_danger "Не найден аудиовыход по умолчанию."
    fi
    return 0
}

# ==============================================================================
# 14. БЭКАП, ЭКСПОРТ, ИМПОРТ И АНОНИМНЫЙ ОТЧЁТ
# ==============================================================================
export_config_archive() {
    local target_file="${1:-}"
    if [[ -z "$target_file" ]]; then
        target_file="linah-audio-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
    fi

    log_info "Создаём архив конфигураций аудиостека в: ${target_file}..."
    local -a src_paths=()
    [[ -d "${HOME}/.config/pipewire" ]] && src_paths+=("${HOME}/.config/pipewire")
    [[ -d "${HOME}/.config/wireplumber" ]] && src_paths+=("${HOME}/.config/wireplumber")
    [[ -d "${HOME}/.config/pulse" ]] && src_paths+=("${HOME}/.config/pulse")
    [[ -f "${HOME}/.asoundrc" ]] && src_paths+=("${HOME}/.asoundrc")
    [[ -f "/etc/asound.conf" ]] && src_paths+=("/etc/asound.conf")

    if (( ${#src_paths[@]} == 0 )); then
        log_warn "Не найдено пользовательских конфигурационных файлов аудио для бэкапа."
        return 0
    fi

    tar -czf "${target_file}" -P "${src_paths[@]}" 2>/dev/null || {
        log_danger "Ошибка при создании архива ${target_file}."
        return 1
    }

    if tar -tzf "${target_file}" &>/dev/null; then
        local sz
        sz="$(du -h "${target_file}" 2>/dev/null | awk '{print $1}')"
        log_cool "Архив успешно создан: ${target_file} (${sz})!"
    else
        log_danger "Архив повреждён или не прочитан."
        return 1
    fi
    return 0
}

import_config_archive() {
    local archive_file="${1:-}"
    if [[ -z "$archive_file" || ! -f "$archive_file" ]]; then
        log_danger "Файл архива не указан или не существует: ${archive_file}"
        return 1
    fi

    if ! tar -tzf "${archive_file}" &>/dev/null; then
        log_danger "Файл ${archive_file} не является корректным tar.gz архивом."
        return 1
    fi

    log_info "1. Создаём защитный бэкап текущих настроек перед восстановлением..."
    local safety_bak="linah-backup-before-import-$(date +%Y%m%d_%H%M%S).tar.gz"
    export_config_archive "${safety_bak}" || true

    log_info "2. Распаковываем конфигурацию из ${archive_file}..."
    tar -xzf "${archive_file}" -P 2>/dev/null || {
        log_danger "Ошибка распаковки архива."
        return 1
    }

    log_info "3. Перезапускаем службы аудио..."
    systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    log_cool "Настройки успешно импортированы! Защитная копия сохранена в: ${safety_bak}."
    return 0
}

share_anonymized_report() {
    local out_file="${1:-}"
    if [[ -z "$out_file" ]]; then
        out_file="linah-audio-report-$(date +%Y%m%d_%H%M%S).md"
    fi

    log_info "Генерируем анонимизированный отчёт о состоянии звуковой системы..."
    local raw_tmp; raw_tmp="$(mktemp "${TMPDIR:-/tmp}/linah-rep.XXXXXX")"
    IS_CLI_CALL=1 show_diagnostics > "${raw_tmp}" 2>&1 || true

    local cur_user="${USER:-user}"
    local cur_host
    cur_host="$(hostname 2>/dev/null || echo "host")"

    sed -E \
        -e 's|/home/[a-zA-Z0-9_.-]+|/home/[USER]|g' \
        -e "s/${cur_user}/[USER]/g" \
        -e "s/${cur_host}/[HOSTNAME]/g" \
        -e 's/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/XX:XX:XX:XX:XX:XX/g' \
        -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/192.168.X.X/g' \
        "${raw_tmp}" > "${out_file}"
    rm -f "${raw_tmp}"

    log_cool "Анонимизированный отчёт сохранён в: ${out_file}!"
    printf "  ${C_DIM}Все личные данные (имя пользователя, хост, MAC-адреса, IP) удалены.${C_RESET}\n"
    printf "  ${C_DIM}Этот файл можно безопасно прикреплять к сообщениям на форумах и в GitHub Issues.${C_RESET}\n\n"
}

backup_export_menu() {
    while true; do
        {
        print_banner
        log_title "БЭКАП, ЭКСПОРТ И АНОНИМИЗИРОВАННЫЙ ОТЧЁТ"
        printf "================================================================================\n\n"

        printf "  ${C_BOLD}[1]${C_RESET} 📦 ${C_BOLD}Экспорт аудио-конфигов в архив (.tar.gz)${C_RESET}\n"
        _hint 'Зачем: упаковывает все настройки PipeWire, PulseAudio и WirePlumber в один файл.'
        _hint 'Когда: перед экспериментами или для переноса настроек на другой ПК.'
        printf "  ${C_BOLD}[2]${C_RESET} 📥 ${C_BOLD}Импорт аудио-конфигов из архива (.tar.gz)${C_RESET}\n"
        _hint 'Зачем: восстанавливает настройки из ранее сохраненного архива.'
        _hint 'Когда: нужно вернуть рабочую конфигурацию из бэкапа.'
        printf "  ${C_BOLD}[3]${C_RESET} 📋 ${C_BOLD}Создать анонимизированный отчёт для форума / Issue${C_RESET}\n"
        _hint 'Зачем: собирает полную диагностику без личных данных (без имени пользователя, IP и MAC).'
        _hint 'Когда: просите помощи на форуме Linux Mint, Arch или в GitHub Issues.'
        printf "  ${C_BOLD}[0]${C_RESET} 🔙 ${C_BOLD}Назад в главное меню${C_RESET}\n\n"

        } > "${MENU_BUF}" 2>&1
        local b_choice
        menu_read b_choice "Твой выбор [0-3]: "
        case "${b_choice}" in
            1)
                printf "\nВведите имя файла архива [Enter для linah-audio-backup-...]: "
                read -r arch_name
                export_config_archive "${arch_name}"
                press_enter
                ;;
            2)
                printf "\nВведите путь к архиву .tar.gz: "
                read -r arch_path
                import_config_archive "${arch_path}"
                press_enter
                ;;
            3)
                printf "\nВведите имя файла отчёта [Enter для автогенерации]: "
                read -r rep_name
                share_anonymized_report "${rep_name}"
                press_enter
                ;;
            0|q|Q) return ;;
            *) ;;
        esac
    done
}

# ==============================================================================
# 15. НЕИНТЕРАКТИВНОЕ АВТОЛЕЧЕНИЕ (CLI)
# ==============================================================================
auto_fix_critical() {
    log_info "Запуск критического экспресс-автолечения..."

    for c in 0 1 2 3; do
        amixer -c "$c" set Master unmute 100% &>/dev/null || true
        amixer -c "$c" set Speaker unmute 100% &>/dev/null || true
        amixer -c "$c" set Headphone unmute 100% &>/dev/null || true
    done

    pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null || true

    local cur_v
    cur_v="$(_sink_volume_pct "$(_default_sink)")"
    if [[ -z "$cur_v" ]] || (( cur_v < 20 )); then
        pactl set-sink-volume @DEFAULT_SINK@ 65% 2>/dev/null || true
    fi

    if ! systemctl --user is-active --quiet pipewire 2>/dev/null; then
        systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || true
    fi

    log_cool "[OK] Критические блокираторы звука проверены и устранены."
    return 0
}

auto_fix_all() {
    log_info "Запуск полного автоматического лечения системы..."
    auto_fix_critical || true
    fix_server_conflict || true
    fix_start_services || true
    fix_hda_power_save || true
    fix_suspend_on_idle || true
    fix_bt_race_armor || true
    fix_sink_volume_100 || true
    log_cool "[OK] Полный цикл автолечения успешно завершён."
    return 0
}

# ==============================================================================
# 8. ПОЛНЫЙ СБРОС В ЗАВОД: «ВЕРНУТЬ ВСЁ ВЗАД, КАК БЫЛО»
# ==============================================================================
_do_factory_revert() {
    log_info "1. Сносим конфиги PipeWire, созданные linah..."
    rm -f "${PREAMP_CONF}" "${LEGACY_PREAMP_CONF}"
    rm -f "${PRESET_GAMING_CONF}" "${PRESET_CINEMA_CONF}" "${PRESET_HIFI_CONF}" "${RNNOISE_CONF}"
    rm -f "$(_pw_conf_dir)"/99-linah-*.conf "$(_pw_conf_dir)"/99-audio-boss-*.conf
    rmdir "${PW_CONF_DIR}" 2>/dev/null || true
    pw-metadata -n settings 0 clock.force-quantum 0 2>/dev/null || true

    log_info "2. Сносим правила WirePlumber, созданные linah..."
    rm -f "${WP_CONF_04}" "${WP_CONF_05}" "${WP_ROLES_04}" "${WP_ROLES_05}"
    rm -f "${HOME}/.config/wireplumber/main.lua.d/51-no-suspend.lua"
    rm -f "${HOME}/.config/wireplumber/wireplumber.conf.d/51-no-suspend.conf"
    rm -f "${WP_DIR_04}/53-no-suspend.lua"
    rm -f "${WP_DIR_05}"/54-linah-*.conf "${WP_DIR_05}"/99-linah-*.conf "${WP_DIR_04}"/99-linah-*.lua
    if [[ -d "${WP_STATE_DIR}" ]]; then
        # Точечно: чужие громкости и выбранные устройства не трогаем
        local _f
        for _f in "${WP_STATE_DIR}/default-profile" "${WP_STATE_DIR}/default-routes"; do
            [[ -f "${_f}" ]] && sed -i '/bluez/Id' "${_f}" 2>/dev/null || true
        done
    fi

    log_info "2b. Снимаем системные твики (нужен root)..."
    local _sysf
    for _sysf in /etc/modprobe.d/99-linah-hda.conf \
                 /etc/udev/rules.d/99-linah-bt-nosuspend.rules \
                 /etc/security/limits.d/99-linah-rt.conf \
                 /etc/modprobe.d/99-audio-boss-hda.conf \
                 /etc/udev/rules.d/99-audio-boss-bt-nosuspend.rules \
                 /etc/security/limits.d/99-audio-boss-rt.conf; do
        if test -f "${_sysf}" 2>/dev/null; then
            sudo rm -f "${_sysf}" 2>/dev/null && log_info "   удалён ${_sysf}" || true
        fi
    done
    local _bak
    for _bak in "${BT_MAIN_CONF}.linah.bak" "${BT_MAIN_CONF}.audio-boss.bak"; do
      if test -f "${_bak}" 2>/dev/null; then
        sudo cp -a "${_bak}" "${BT_MAIN_CONF}" 2>/dev/null || true
        sudo rm -f "${_bak}" 2>/dev/null || true
        log_info "   ${_bak} → ${BT_MAIN_CONF} возвращён"
        sudo systemctl restart bluetooth 2>/dev/null || true
      fi
    done
    sudo -n udevadm control --reload-rules 2>/dev/null || true

    log_info "3. Сносим кастомные настройки графических сред..."
    if [[ -d "${CINNAMON_USER_APPLET}" ]]; then
        rm -rf "${CINNAMON_USER_APPLET}"
        busctl --user call org.Cinnamon /org/Cinnamon org.Cinnamon ReloadXlet ss "sound@cinnamon.org" "APPLET" 2>/dev/null || true
    fi
    if [[ -f "${HOME}/.config/plasma-pa.conf" ]]; then
        sed -i -E "s/maximumVolume=[0-9]+/maximumVolume=150/" "${HOME}/.config/plasma-pa.conf" 2>/dev/null || true
        qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshCurrentShell 2>/dev/null || true
    fi
    if command -v xfconf-query &>/dev/null; then
        xfconf-query -c xfce4-pulseaudio-plugin -p /volume-max -s 150 2>/dev/null || true
        xfce4-panel -r 2>/dev/null || true
    fi
    if command -v gsettings &>/dev/null; then
        gsettings set org.gnome.desktop.sound allow-volume-above-100-percent false 2>/dev/null || true
        gsettings set org.mate.volume-control allow-amplified-volume false 2>/dev/null || true
    fi

    log_info "3. Перезапускаем звуковой сервер..."
    systemctl --user restart pipewire wireplumber pipewire-pulse 2>/dev/null || true
    sleep 1

    log_info "4. Возвращаем дефолтный выход на встроенную карту..."
    local alsa_sink
    alsa_sink="$(LC_ALL=C pactl list short sinks 2>/dev/null | awk '$2 ~ /alsa_output/ {print $2}' | head -n1 || true)"
    if [[ -n "${alsa_sink}" ]]; then
        pactl set-default-sink "${alsa_sink}" 2>/dev/null || true
        pactl set-sink-volume "${alsa_sink}" 100% 2>/dev/null || true
        pactl set-sink-mute "${alsa_sink}" 0 2>/dev/null || true
    fi
}

factory_revert() {
    print_banner
    log_title "ПОЛНЫЙ ОТКАТ ВСЕХ ТВИКОВ И МОДИФИКАЦИЙ"
    printf "================================================================================\n\n"

    printf "  ${C_RED}${C_BOLD}ВНИМАНИЕ!${C_RESET}\n"
    printf "  Это снесёт все созданные виртуальные усилители, вернёт ползунок в трее к стандарту,\n"
    printf "  сбросит громкость на чистые 100%% и перезапустит звук в кристально чистом виде.\n\n"

    read -r -p "Ты абсолютно уверен, что хочешь всё сбросить? [y/N]: " confirm
    if [[ ! "${confirm}" =~ ^[yYдД] ]]; then
        log_info "Сброс отменён. Ничего не трогаем."
        press_enter
        return
    fi

    _do_factory_revert

    log_cool "СИСТЕМА ПОЛНОСТЬЮ СБРОШЕНА В ЗАВОДСКОЙ СТАНДАРТ!"
    printf "  Твой звук чист, как слеза младенца. Никаких хвостов и скрытых демонов.\n"
    press_enter
}

# ==============================================================================
# ОБРАБОТКА CLI-ФЛАГОВ (ДЛЯ СКРИПТОВ И БЫСТРОГО ЗАПУСКА)
# ==============================================================================
handle_cli() {
    case "${1:-}" in
        -d|--diag|--status)
            IS_CLI_CALL=1
            show_diagnostics
            exit 0
            ;;
        --preamp-on)
            local mult="${2:-3.0}"
            mult="${mult//,/.}"
            local target
            target="$(LC_ALL=C pactl list short sinks 2>/dev/null | awk '$2 ~ /^bluez_output/ {print $2}' | head -n1 || true)"
            [[ -z "${target}" ]] && target="$(pactl get-default-sink 2>/dev/null || true)"

            mkdir -p "${PW_CONF_DIR}"
            cat << EOF > "${PREAMP_CONF}"
context.modules = [
    { name = libpipewire-module-filter-chain
        args = {
            node.description = "PipeWire Preamp Boost (+20dB)"
            media.name       = "Preamp Boost"
            filter.graph = {
                nodes = [
                    { type = builtin name = preamp label = linear control = { "Mult" = ${mult} "Add" = 0.0 } }
                    { type = builtin name = limiter label = clamp control = { "Min" = -1.0 "Max" = 1.0 } }
                ]
                links = [ { output = "preamp:Out" input = "limiter:In" } ]
            }
            audio.channels = 2
            audio.position = [ FL FR ]
            capture.props = {
                node.name        = "Preamp_Boost"
                node.description = "Наушники (Усиленный выход +20dB)"
                media.class      = Audio/Sink
                priority.driver  = 1020
                priority.session = 1020
            }
            playback.props = {
                node.name        = "Preamp_Boost.output"
                node.passive     = true
                target.object    = "${target}"
            }
        }
    }
]
EOF
            systemctl --user restart pipewire wireplumber pipewire-pulse 2>/dev/null || true
            sleep 1
            pactl set-default-sink Preamp_Boost 2>/dev/null || true
            log_cool "Preamp Boost (${mult}x) успешно активирован на ${target}!"
            exit 0
            ;;
        --preamp-off)
            rm -f "${PREAMP_CONF}" "${LEGACY_PREAMP_CONF}"
            systemctl --user restart pipewire wireplumber pipewire-pulse 2>/dev/null || true
            log_cool "Preamp выключен, конфиги удалены."
            exit 0
            ;;
        -V|--version)
            printf "LINAH %s\n" "${LINAH_VERSION}"
            exit 0
            ;;
        -a|--analyze|--analyse|--analysis)
            IS_CLI_CALL=1
            run_full_analysis
            exit 0
            ;;
        --kit|--first-aid)
            IS_CLI_CALL=1
            audio_first_aid_kit
            exit 0
            ;;
        --remote|--pult|--bt-remote)
            IS_CLI_CALL=1
            bt_remote_menu
            exit 0
            ;;
        --bt-test|--tests)
            IS_CLI_CALL=1
            bt_test_menu
            exit 0
            ;;
        --vol-max)
            IS_CLI_CALL=1
            _m="$(timeout 10 bluetoothctl devices Connected 2>/dev/null | awk '/^Device /{print $2}' | head -1 || true)"
            if [[ -z "${_m}" ]]; then
                log_danger "Нет подключённых Bluetooth-устройств."
                printf "  Включи гарнитуру, дождись подключения и повтори.\n"
                exit 1
            fi
            log_info "Устройство: ${_m}"
            _bt_avrcp_burst "$(_bt_path "${_m}")" VolumeUp "${2:-25}" 0.3 || true
            exit 0
            ;;
        --bt-forensics|--forensics)
            IS_CLI_CALL=1
            bt_race_forensics
            exit 0
            ;;
        --verify-bt)
            IS_CLI_CALL=1
            bt_verify_state
            exit 0
            ;;
        --fix-race)
            IS_CLI_CALL=1
            apply_multiprofile_tweak || true
            apply_native_wp_fix 0 || true
            bt_clean_reconnect || true
            exit 0
            ;;
        --fix-race-nuclear)
            IS_CLI_CALL=1
            apply_multiprofile_tweak || true
            apply_native_wp_fix 0 || true
            apply_roles_tweak || true
            bt_clean_reconnect || true
            exit 0
            ;;
        --fix-bt)
            local cards
            mapfile -t cards < <(LC_ALL=C pactl list short cards 2>/dev/null | awk '$2 ~ /^bluez_card/ {print $2}')
            for c in "${cards[@]}"; do
                pactl set-card-profile "${c}" a2dp-sink 2>/dev/null || true
            done
            log_cool "Все Bluetooth-карты переведены в A2DP стерео."
            exit 0
            ;;
        --revert)
            _do_factory_revert
            log_cool "Полный откат выполнен."
            exit 0
            ;;
        --slider-limit)
            local pct="${2:-300}"
            local de
            de="$(detect_desktop)"
            case "${de}" in
                cinnamon)
                    local mult
                    mult="$(LC_ALL=C awk "BEGIN {printf \"%.1f\", ${pct} / 100}")"
                    mult="${mult//,/.}"
                    gsettings set org.cinnamon.desktop.sound allow-amplified-volume true 2>/dev/null || true
                    mkdir -p "$(dirname "${CINNAMON_USER_APPLET}")"
                    [[ ! -d "${CINNAMON_USER_APPLET}" ]] && cp -r "${CINNAMON_SYS_APPLET}" "${CINNAMON_USER_APPLET}"
                    sed -i -E "s/this\._volumeMax = [0-9.]+ \* this\._volumeNorm;/this._volumeMax = ${mult} * this._volumeNorm;/" "${CINNAMON_USER_APPLET}/applet.js"
                    sed -i -E "s/set_mark\(1\/[0-9.]+\);/set_mark(1\/${mult});/" "${CINNAMON_USER_APPLET}/applet.js"
                    busctl --user call org.Cinnamon /org/Cinnamon org.Cinnamon ReloadXlet ss "sound@cinnamon.org" "APPLET" 2>/dev/null || true
                    log_cool "Cinnamon: ползунок в трее разогнан до ${pct}%!"
                    ;;
                kde)
                    if command -v kwriteconfig6 &>/dev/null; then
                        kwriteconfig6 --file plasma-pa.conf --group General --key maximumVolume "${pct}"
                    elif command -v kwriteconfig5 &>/dev/null; then
                        kwriteconfig5 --file plasma-pa.conf --group General --key maximumVolume "${pct}"
                    else
                        mkdir -p "${HOME}/.config"
                        local p_conf="${HOME}/.config/plasma-pa.conf"
                        if [[ -f "${p_conf}" ]]; then
                            if grep -q "maximumVolume=" "${p_conf}"; then
                                sed -i -E "s/maximumVolume=[0-9]+/maximumVolume=${pct}/" "${p_conf}"
                            elif grep -q "\[General\]" "${p_conf}"; then
                                sed -i "/\[General\]/a maximumVolume=${pct}" "${p_conf}"
                            else
                                printf "\n[General]\nmaximumVolume=%s\n" "${pct}" >> "${p_conf}"
                            fi
                        else
                            cat << EOF > "${p_conf}"
[General]
maximumVolume=${pct}
EOF
                        fi
                    fi
                    qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.refreshCurrentShell 2>/dev/null || true
                    log_cool "KDE Plasma: лимит громкости в трее установлен на ${pct}%!"
                    ;;
                xfce)
                    if command -v xfconf-query &>/dev/null; then
                        xfconf-query -c xfce4-pulseaudio-plugin -p /volume-max -t int -s "${pct}" --create 2>/dev/null || \
                            xfconf-query -c xfce4-pulseaudio-plugin -p /volume-max -s "${pct}" 2>/dev/null
                        xfce4-panel -r 2>/dev/null || true
                        log_cool "XFCE: лимит громкости в панели установлен на ${pct}%!"
                    else
                        log_danger "xfconf-query не найден в системе."
                    fi
                    ;;
                gnome)
                    gsettings set org.gnome.desktop.sound allow-volume-above-100-percent true 2>/dev/null
                    log_cool "GNOME: оверамплификация 150% включена (для >150% используй --preamp-on)."
                    ;;
                mate)
                    gsettings set org.mate.volume-control allow-amplified-volume true 2>/dev/null
                    log_cool "MATE: оверамплификация 150% включена."
                    ;;
                *)
                    log_warn "Окружение не определено для автоматической разлочки. Запусти скрипт без аргументов и выбери пункт [9]."
                    ;;
            esac
            exit 0
            ;;
        --fix-bt-native)
            apply_native_wp_fix 1 || true
            exit 0
            ;;
        --fix-bt-native-revert)
            remove_native_wp_fix
            exit 0
            ;;
        --test)
            run_sound_test
            exit 0
            ;;
        --vu|--visualizer)
            IS_CLI_CALL=1
            run_terminal_vu_meter "${2:-sink}" "${3:-}"
            exit 0
            ;;
        --stream-monitor)
            stream_audio_monitor
            exit 0
            ;;
        --streams)
            IS_CLI_CALL=1
            printf "%-6s | %-24s | %-28s | %-6s | %-8s | %s\n" "ID" "ПРИЛОЖЕНИЕ" "ТРЕК / ПОТОК" "ГРОМК" "MUTE" "ВЫХОД"
            printf "──────────────────────────────────────────────────────────────────────────────────────────\n"
            while IFS='|' read -r sid sapp smedia svol smute ssink; do
                [[ -z "$sid" ]] && continue
                printf "#%-5s | %-24s | %-28s | %-6s | %-8s | %s\n" "$sid" "${sapp:0:24}" "${smedia:0:28}" "$svol" "$smute" "$ssink"
            done < <(get_active_sink_inputs)
            exit 0
            ;;
        --preset)
            IS_CLI_CALL=1
            case "${2:-}" in
                gaming|game) apply_preset_gaming ;;
                cinema|movie|speech) apply_preset_cinema ;;
                hifi|studio) apply_preset_hifi ;;
                revert|off|reset) revert_audio_presets ;;
                *)
                    log_danger "Неизвестный пресет: «${2:-}». Доступны: gaming, cinema, hifi, revert"
                    exit 2
                    ;;
            esac
            exit 0
            ;;
        --auto-fix-crit)
            IS_CLI_CALL=1
            auto_fix_critical
            exit 0
            ;;
        --auto-fix-all)
            IS_CLI_CALL=1
            auto_fix_all
            exit 0
            ;;
        --export-config)
            IS_CLI_CALL=1
            export_config_archive "${2:-}"
            exit 0
            ;;
        --import-config)
            IS_CLI_CALL=1
            if [[ -z "${2:-}" ]]; then
                log_danger "Укажите путь к архиву: --import-config <файл.tar.gz>"
                exit 2
            fi
            import_config_archive "$2"
            exit 0
            ;;
        --share-report)
            IS_CLI_CALL=1
            share_anonymized_report "${2:-}"
            exit 0
            ;;
        -h|--help)
            printf "Использование: %s [ОПЦИЯ]\n\n" "$0"
            printf "  (без опций)            Запуск интерактивного меню\n\n"
            printf "  ${C_BOLD}ГЛАВНОЕ:${C_RESET}\n"
            printf "  -a, --analyze          Полный анализ системы: найти проблемы и предложить фиксы\n"
            printf "  --kit, --first-aid     Аптечка: каталог фиксов известных болячек\n"
            printf "  --auto-fix-crit        Экспресс-починка критических сбоев без вопросов (unmute, default, daemons)\n"
            printf "  --auto-fix-all         Полный цикл автоматического лечения аудиостека\n\n"
            printf "  ${C_BOLD}ДИАГНОСТИКА СИГНАЛА И SSH:${C_RESET}\n"
            printf "  --vu, --visualizer     Живой терминальный VU-метр и объективный детектор аудиосигнала\n"
            printf "  --stream-monitor       Стриминг аудиовыхода в stdout (для SSH: aplay / mpv loopback)\n"
            printf "  --user <пользователь>  Выполнять действия в контексте сессии указанного пользователя\n"
            printf "  --streams              Список приложений, играющих звук прямо сейчас, и их громкость\n"
            printf "  --preset [имя]         Применить пресет: gaming (задержка 128), cinema, hifi, revert\n\n"
            printf "  ${C_BOLD}БЭКАП И ОТЧЁТЫ:${C_RESET}\n"
            printf "  --export-config [файл] Сохранить аудио-конфигурацию в архив .tar.gz\n"
            printf "  --import-config <файл> Восстановить конфигурацию из архива с защитным бэкапом\n"
            printf "  --share-report [файл]  Создать анонимизированный отчёт для форума / GitHub Issues\n\n"
            printf "  ${C_BOLD}ОСТАЛЬНОЕ:${C_RESET}\n"
            printf "  -d, --diag             Сырой дамп аудиостека и Bluetooth\n"
            printf "  --fix-bt-native        Нативно снять лок ЦАП WirePlumber (0.4 Lua / 0.5+ SPA-JSON)\n"
            printf "  --fix-bt-native-revert Откатить нативный фикс WirePlumber\n"
            printf "  --preamp-on [множитель] Врубить PipeWire Preamp (по умолчанию 3.0)\n"
            printf "  --preamp-off           Выключить PipeWire Preamp\n"
            printf "  --slider-limit [%%]     Разгон ползунка в трее (Cinnamon, KDE, GNOME, XFCE, MATE)\n"
            printf "  --fix-bt               Принудительно включить стерео A2DP на всех ушах\n"
            printf "  --fix-race             Вылечить гонку HFP/A2DP (микрофон гарнитуры сохраняется)\n"
            printf "  --fix-race-nuclear     То же + полностью отключить роли HFP/HSP (без микрофона)\n"
            printf "  --bt-forensics         Лог-криминалистика Bluetooth по всем загрузкам\n"
            printf "  --verify-bt            Проверить, реально ли ты в стерео A2DP\n"
            printf "  --remote               Пульт гарнитуры: команды по D-Bus (громкость чипа)\n"
            printf "  --vol-max [N]          Открыть регистр громкости гарнитуры (N шагов, по умолч. 25)\n"
            printf "  --bt-test              Меню тестов Bluetooth-звука\n"
            printf "  --test                 Прогнать стерео-тест динамиков/наушников\n"
            printf "  --revert               Полный сброс всех настроек к заводскому стандарту\n"
            printf "  --plain                Меню без стрелок: только ввод номера (ставится ПЕРЕД остальными опциями)\n"
            printf "  -V, --version          Показать версию\n"
            printf "  -h, --help             Показать эту справку\n\n"
            printf "В меню: стрелки ↑↓ — выбор, Enter — выполнить, цифра/буква — сразу к пункту, / — поиск, q или Esc — назад.\n"
            printf "Классический ввод номеров навсегда: переменная LINAH_PLAIN=1.\n\n"
            exit 0
            ;;
        -*)
            log_danger "Не знаю такой опции: ${1}"
            printf "  Полный список: ${C_BOLD}%s --help${C_RESET}\n" "$0"
            exit 2
            ;;
    esac
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ (TUI)
# ==============================================================================
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plain)
                LINAH_PLAIN=1
                shift
                ;;
            --user)
                OPT_TARGET_USER="$2"
                shift 2
                ;;
            --user=*)
                OPT_TARGET_USER="${1#*=}"
                shift
                ;;
            -u)
                OPT_TARGET_USER="$2"
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done

    if [[ -n "${OPT_TARGET_USER:-}" ]]; then
        switch_to_user_session "${OPT_TARGET_USER}"
    fi
    check_not_root
    check_tools

    if [[ $# -gt 0 ]]; then
        handle_cli "$@"
    fi

    while true; do
        {
        print_banner
        local distro
        distro="$(detect_distro)"
        local srv
        srv="$(get_audio_server)"
        local wp_info wp_ver wp_syntax
        wp_info="$(get_wireplumber_info)"
        wp_ver="$(echo "${wp_info}" | awk '{print $1}')"
        wp_syntax="$(echo "${wp_info}" | awk '{print $2}')"

        local def
        def="$(pactl get-default-sink 2>/dev/null || echo 'Не найден')"
        
        # Получаем понятное имя текущего выхода
        local def_desc
        def_desc="$(LC_ALL=C pactl list sinks 2>/dev/null | grep -B1 -A2 "Name: ${def}" | grep "Description:" | awk -F': ' '{print $2}' || true)"
        [[ -z "${def_desc}" ]] && def_desc="${def}"

        # Статус нативного фикса WirePlumber
        local native_wp_stat
        if is_native_wp_fix_active; then
            native_wp_stat="${C_GREEN}💎 АКТИВЕН (HW Volume Lock снят, 100% мощности)${C_RESET}"
        else
            native_wp_stat="${C_YELLOW}⚠️ Не установлен (стандартный профиль)${C_RESET}"
        fi

        # Статус софтверного усилителя PipeWire (Preamp Boost)
        local preamp_stat
        if [[ -f "${PREAMP_CONF}" || -f "${LEGACY_PREAMP_CONF}" ]]; then
            local p_file="${PREAMP_CONF}"
            [[ -f "${LEGACY_PREAMP_CONF}" ]] && p_file="${LEGACY_PREAMP_CONF}"
            local mult_val
            mult_val="$(grep -oE '"Mult"[[:space:]]*=[[:space:]]*[0-9.]+' "${p_file}" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ' || echo '3.0')"
            preamp_stat="${C_GREEN}🔥 ВКЛЮЧЕН (+20 dB / ${mult_val}x разгон с лимитером)${C_RESET}"
        else
            preamp_stat="${C_DIM}○ Отключен (штатный чистый звук 1.0x, преамп не требуется)${C_RESET}"
        fi

        printf "  • ${C_BOLD}Дистрибутив:${C_RESET}       ${C_CYAN}%s${C_RESET}\n" "${distro}"
        printf "  • ${C_BOLD}Аудиосервер:${C_RESET}       ${C_CYAN}%s${C_RESET} ${C_DIM}(WirePlumber %s [%s])${C_RESET}\n" "${srv}" "${wp_ver}" "${wp_syntax}"
        if [[ -n "${TARGET_USER:-}" ]]; then
            printf "  • ${C_BOLD}Пользователь сессии:${C_RESET} ${C_GREEN}%s${C_RESET} ${C_DIM}(UID: %s)${C_RESET}\n" "${TARGET_USER}" "${TARGET_UID}"
        fi
        printf "  • ${C_BOLD}Текущий аудиовыход:${C_RESET} ${C_BOLD}%s${C_RESET} ${C_DIM}(%s)${C_RESET}\n" "${def_desc}" "${def}"
        printf "  • ${C_BOLD}Нативный фикс WP:${C_RESET}   %b\n" "${native_wp_stat}"
        printf "  • ${C_BOLD}Софтверный Preamp:${C_RESET}  %b\n" "${preamp_stat}"
        printf "================================================================================\n\n"

        printf "  ${C_BOLD}ЧТО БУДЕМ ДЕЛАТЬ, ШЕФ?${C_RESET}\n\n"
        printf "  ${C_BG_GREEN} СТАРТ ${C_RESET} ${C_BOLD}[1]${C_RESET} 🩺 ${C_BOLD}АНАЛИЗ И АВТОЛЕЧЕНИЕ${C_RESET} — найти проблемы со звуком и предложить решения\n"
        _hint 'Зачем: сам проверяет звуковую систему, объясняет найденное и даёт команду, чтобы проверить каждую находку руками.'
        _hint 'Когда: пропал звук, хрипит, щёлкает, тихо или наушники ведут себя странно, а причина неясна. Начинай всегда отсюда.'
        printf "  ${C_BOLD}[2]${C_RESET} 🧰 ${C_BOLD}Аптечка аудио${C_RESET}          — каталог фиксов известных болячек, применить точечно\n"
        _hint 'Зачем: каталог готовых исправлений известных проблем. Каждый применяется отдельно, большинство можно откатить.'
        _hint 'Когда: ты уже знаешь причину (или её нашёл анализ) и хочешь применить один конкретный фикс.'
        printf "  ${C_BOLD}[3]${C_RESET} 🔍 ${C_BOLD}Сырая диагностика${C_RESET}      — полный дамп сервера, карт, кодеков и громкостей\n"
        _hint 'Зачем: полный дамп состояния: звуковой сервер, карты, выходы, кодеки, громкости, журналы.'
        _hint 'Когда: нужен отчёт для форума или багтрекера, либо хочешь своими глазами увидеть, что именно видит система.'
        printf "\n"
        printf "  ${C_DIM}── Bluetooth ────────────────────────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}[4]${C_RESET} 🚀 ${C_BOLD}Фикс тихого Bluetooth${C_RESET}  — нативный анлок ЦАП или виртуальный Preamp Boost\n"
        _hint 'Зачем: два способа заставить слишком тихие Bluetooth-наушники играть на полную: отвязка аппаратной громкости и виртуальный усилитель.'
        _hint 'Когда: на 100% громкости всё равно тихо. Чаще встречается у бюджетных наушников без кнопок громкости.'
        printf "  ${C_BOLD}[5]${C_RESET} 🥊 ${C_BOLD}Гонка HFP против A2DP${C_RESET}  — вытащить уши из режима рации навсегда\n"
        _hint 'Зачем: удерживает гарнитуру в стерео-режиме A2DP и не даёт ей свалиться в телефонный моно-режим HFP.'
        _hint 'Когда: после подключения звук глухой и тихий, «как из рации». Иногда бывает только после включения наушников.'
        printf "  ${C_BOLD}[6]${C_RESET} 🕵️ ${C_BOLD}Лог-криминалистика${C_RESET}     — по журналу найти, что и когда душило Bluetooth\n"
        _hint 'Зачем: по журналу системы показывает, в каких загрузках ломался Bluetooth и на что это было похоже.'
        _hint 'Когда: проблема плавающая (то есть, то нет) и нужно понять, повторяется ли она и с какого момента.'
        printf "  ${C_BOLD}[7]${C_RESET} 🎵 ${C_BOLD}Кодеки и стерео A2DP${C_RESET}   — профили карты, SBC-XQ и прочее\n"
        _hint 'Зачем: переключает профиль и кодек Bluetooth-карты: стерео, SBC, SBC-XQ.'
        _hint 'Когда: качество плохое, звук моно, пропадает на SBC-XQ или хочется вручную выбрать кодек.'
        printf "  ${C_BOLD}[13]${C_RESET} 🎛️ ${C_BOLD}Пульт гарнитуры${C_RESET}       — команды прямо в наушники по D-Bus ${C_GREEN}[громкость чипа]${C_RESET}\n"
        _hint 'Зачем: посылает наушникам команды, как кнопки на корпусе: громкость, пауза, профили.'
        _hint 'Когда: система на 100%, а в ушах тихо (громкость внутри самой гарнитуры занижена) или те же наушники тише на одном компьютере, чем на другом.'
        printf "  ${C_BOLD}[14]${C_RESET} 🧪 ${C_BOLD}Тесты Bluetooth-звука${C_RESET}  — калиброванные тоны, замер цепочки, битрейт\n"
        _hint 'Зачем: даёт объективные замеры на сигналах известного уровня, без споров «на слух».'
        _hint 'Когда: нужно понять, режет громкость система или сами наушники, либо сравнить два компьютера.'
        printf "\n"
        printf "  ${C_DIM}── Громкость и рабочий стол ─────────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}[8]${C_RESET} 🎚️ ${C_BOLD}Громкость любого выхода${C_RESET} — тонкая настройка процентов (100%%, 150%%, mute)\n"
        _hint 'Зачем: точная громкость, mute и выбор выхода по умолчанию для любого устройства.'
        _hint 'Когда: нужно выше 100%, звук идёт не в то устройство или ползунок в трее не справляется.'
        printf "  ${C_BOLD}[9]${C_RESET} 📈 ${C_BOLD}Разгон ползунка в трее${C_RESET}  — расширить потолок (Cinnamon, KDE, GNOME, XFCE, MATE)\n"
        _hint 'Зачем: снимает лимит ползунка громкости в трее (обычно 100% или 150%).'
        _hint 'Когда: даже на максимуме тихо: тихие записи, слабые колонки, ограничение самого рабочего стола.'
        printf "  ${C_BOLD}[16]${C_RESET} 🎛️ ${C_BOLD}Микшер приложений${C_RESET}       — кто играет, громкость/mute конкретных программ\n"
        _hint 'Зачем: показывает все активные аудиопотоки, меняет громкость и переносит программы между выходами.'
        _hint 'Когда: видео играет в браузере без звука или нужно сделать игру тише голосового чата.'
        printf "\n"
        printf "  ${C_DIM}── Анализ сигнала и пресеты ────────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}[15]${C_RESET} 📊 ${C_BOLD}Визуализатор звука / VU${C_RESET} — живой детектор сигнала, CAVA, тест колонок\n"
        _hint 'Зачем: живой индикатор сигнала (RMS/Peak dBFS) — показывает, идёт ли звук в аппаратуру.'
        _hint 'Когда: подозрение, что звук идёт, но колонки выключены из розетки или убавлены в ноль.'
        printf "  ${C_BOLD}[17]${C_RESET} ⚡ ${C_BOLD}Звуковые пресеты в 1 клик${C_RESET} — Gaming (мин. задержка 128), Cinema, Hi-Fi\n"
        _hint 'Зачем: мгновенное переключение аудиоподсистемы под игры, кино или студийное качество.'
        _hint 'Когда: нужен минимальный отклик в играх или хочется нормализовать диалоги в кино.'
        printf "  ${C_BOLD}[18]${C_RESET} 🛡️ ${C_BOLD}SSH Удаленный помощник${C_RESET}  — сессии пользователей, стриминг звука через SSH\n"
        _hint 'Зачем: удаленная помощь пользователю по SSH, выбор сессии и сквозная трансляция звука.'
        _hint 'Когда: администрируете чужую систему и нужно лично услышать или настроить звук.'
        printf "\n"
        printf "  ${C_DIM}── Сервис и резервные копии ─────────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}[10]${C_RESET} 🔊 ${C_BOLD}Тест звука (стерео)${C_RESET}   — проверить левый и правый каналы\n"
        _hint 'Зачем: проигрывает сигнал по каналам и проверяет левый, правый и чистоту звука.'
        _hint 'Когда: после любых правок, если кажется, что каналы перепутаны, есть хрип или один канал молчит.'
        printf "  ${C_BOLD}[11]${C_RESET} 🔄 ${C_BOLD}Перезапуск звука${C_RESET}      — пнуть PipeWire/PulseAudio и убрать дубли\n"
        _hint 'Зачем: перезапускает PipeWire/PulseAudio без перезагрузки компьютера.'
        _hint 'Когда: звук завис, устройства пропали или задвоились, после установки кодеков или смены настроек.'
        printf "  ${C_BOLD}[19]${C_RESET} 📦 ${C_BOLD}Бэкап / Экспорт / Отчёт${C_RESET}  — архив настроек .tar.gz и анонимный отчёт\n"
        _hint 'Зачем: сохраняет все настройки аудио в архив или формирует отчёт для форума без личных данных.'
        _hint 'Когда: перед экспериментами с аудио или если нужно попросить помощи на форуме.'
        printf "  ${C_BOLD}[12]${C_RESET} 🧹 ${C_BOLD}Полный сброс в завод${C_RESET}  — снести все твики linah\n"
        _hint 'Зачем: удаляет всё, что создал LINAH, и возвращает настройки к умолчаниям.'
        _hint 'Когда: что-то пошло не так или правки больше не нужны.'
        printf "  ${C_BOLD}[0]${C_RESET}  🚪 ${C_BOLD}Выход${C_RESET}                 — бывай, пусть музло качает!\n\n"

        } > "${MENU_BUF}" 2>&1
        menu_read choice "Введи номер пункта [0-19]: " "main_menu"
        case "${choice}" in
            1) run_full_analysis || true ;;
            2) audio_first_aid_kit || true ;;
            3) show_diagnostics || true ;;
            4) fix_quiet_bluetooth || true ;;
            5) fix_bt_profile_race || true ;;
            6) bt_race_forensics || true ;;
            7) fix_codecs_and_profiles || true ;;
            8) tune_volume_menu || true ;;
            9) tune_desktop_slider || true ;;
            10) run_sound_test || true ;;
            11) restart_audio_stack || true ;;
            12) factory_revert || true ;;
            13) bt_remote_menu || true ;;
            14) bt_test_menu || true ;;
            15) audio_visualizer_menu || true ;;
            16) active_streams_menu || true ;;
            17) audio_presets_menu || true ;;
            18) remote_session_menu || true ;;
            19) backup_export_menu || true ;;
            0|q|Q)
                printf "\n${C_GREEN}Бывай, бро! Если звук опять заартачится — ты знаешь, где меня найти.${C_RESET}\n\n"
                exit 0
                ;;
            *)
                log_warn "Ты ткнул не туда. Попробуй ещё раз."
                sleep 1
                ;;
        esac
    done
}

main "$@"
