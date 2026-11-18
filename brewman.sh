#!/usr/bin/env bash
# ══════════════════════════════════════════════════
#  Brewman – интерактивный менеджер Homebrew в терминале
#  Просмотр, поиск, установка, удаление и обновление пакетов,
#  сервисы, репозитории (tap), закрепление версий (pin),
#  резервная копия Brewfile, очистка и диагностика.
#  Совместим с bash 3.2 (macOS по умолчанию) и bash 4/5 (Linux).
#
#  Запуск:             bash brewman.sh
#  Установка команды:  bash brewman.sh --install  (далее просто brewman)
#  Справка:            brewman --help
# ══════════════════════════════════════════════════

VERSION="1.6.0"
APP_NAME="brewman"
INSTALL_DIR="$HOME/.local/bin"
DATA_DIR="$HOME/.local/share/brewman"
UPDATE_REPO="aa9010x-prog/brewman"
UPDATE_BRANCH="main"
UPDATE_KEYCHAIN="brewman-github"

export HOMEBREW_NO_ENV_HINTS=1

# === Цвета (отключаются, если вывод не в терминал или задан NO_COLOR) ===
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_B=$'\033[1m'; C_D=$'\033[2m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
  C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_D=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

# === Калибровка ширины значков под текущий терминал ===
ICON_TARGET=2
CALIB_OK=0
if [ -t 0 ] && [ -w /dev/tty ]; then
  _old_stty=$(stty -g < /dev/tty 2>/dev/null)
  stty -echo < /dev/tty 2>/dev/null
  printf '\033[6n' > /dev/tty
  IFS='[;' read -r -s -d 'R' -t 1 _esc _row _col < /dev/tty
  printf '\r\033[K' > /dev/tty
  [ -n "$_old_stty" ] && stty "$_old_stty" < /dev/tty 2>/dev/null
  case "$_col" in ''|*[!0-9]*) CALIB_OK=0 ;; *) CALIB_OK=1 ;; esac
fi
measure_icon() {
  local s="$1" esc row col old_stty=""
  [ "$CALIB_OK" -eq 1 ] || { echo "$ICON_TARGET"; return; }
  old_stty=$(stty -g < /dev/tty 2>/dev/null)
  stty -echo < /dev/tty 2>/dev/null
  printf '\r%s\033[6n' "$s" > /dev/tty
  IFS='[;' read -r -s -d 'R' -t 1 esc row col < /dev/tty
  printf '\r\033[K' > /dev/tty
  [ -n "$old_stty" ] && stty "$old_stty" < /dev/tty 2>/dev/null
  case "$col" in ''|*[!0-9]*) echo "$ICON_TARGET" ;; *) echo $((col - 1)) ;; esac
}
icon() {
  local s="$1" w pad=""
  w=$(measure_icon "$s")
  case "$w" in ''|*[!0-9]*) w=$ICON_TARGET ;; esac
  while [ "$w" -lt "$ICON_TARGET" ]; do pad="$pad "; w=$((w+1)); done
  printf '%s%s ' "$s" "$pad"
}
I_BEER=$(icon "🍺"); I_STEP=$(icon "▶️"); I_OK=$(icon "✅"); I_ERR=$(icon "❌")
I_WARN=$(icon "⚠️"); I_INFO=$(icon "ℹ️"); I_WAIT=$(icon "⏳"); I_Q=$(icon "❓")
I_PTR=$(icon "👉"); I_STOP=$(icon "🛑"); I_LIST=$(icon "📋"); I_PKG=$(icon "📦")
I_ARR=$(icon "➡️"); I_DONE=$(icon "✨"); I_SEARCH=$(icon "🔎"); I_DEL=$(icon "🗑️")
I_UPD=$(icon "🔄"); I_SVC=$(icon "⚙️"); I_PIN=$(icon "📌"); I_TAP=$(icon "🚰")
I_SAVE=$(icon "💾"); I_CLEAN=$(icon "🧹"); I_MODE=$(icon "🔀"); I_EXIT=$(icon "🚪")
I_BACK=$(icon "↩️"); I_LOCK=$(icon "🔒")

# === Глобальное состояние ===
USE_FZF=0; IS_MAC=0; DIRTY=1; GREEDY=0; INDEX_UPDATED=0
CLEAR=1; [ -n "${BREWMAN_NO_CLEAR:-}" ] && CLEAR=0
BREW_VER=""; CNT_F=0; CNT_C=0
LIST=(); LIST_DESC=(); TYPES=(); SEL=(); SEL_IDX=(); ITEMS=()
PICK_PREVIEW=""; CASK_EXTRA=""; ANSWER=""; ASK_RC=0; CASK_FALLBACK=0; TRUST_FLAG=""; CONFLICT_FLAG=""
UPDATE_METHOD=""; REMOTE_VERSION=""

LINE2="══════════════════════════════════════════════════"
LINE1="──────────────────────────────────────────────────"

# Ctrl+C прерывает текущую команду brew, но не всё приложение
trap 'echo ""; echo "${I_STOP}Прервано (Ctrl+C)."' INT

# Временная папка сеанса: список пакетов, которым пользователь отказал в доверии
SESSION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/brewman.XXXXXX")
: > "$SESSION_DIR/declined"
trap 'rm -rf "$SESSION_DIR"' EXIT

# ══════════════════════════════════════════════════
#  Вспомогательные функции вывода и ввода
# ══════════════════════════════════════════════════
title()   { echo ""; echo "$LINE2"; echo "  ${C_B}$1${C_0}"; echo "$LINE2"; echo ""; }
section() { echo "$LINE1"; echo "  ${C_B}$1${C_0}"; echo "$LINE1"; }
step()    { echo "${I_STEP}${C_B}$1${C_0}"; }
ok()      { echo "${I_OK}${C_G}$1${C_0}"; }
err()     { echo "${I_ERR}${C_R}$1${C_0}"; }
warn()    { echo "${I_WARN}${C_Y}$1${C_0}"; }
info()    { echo "${I_INFO}$1"; }
stopped() { echo "${I_STOP}${1:-Отменено.}"; }
mitem()   { echo "  $1"; }

# Ввод строки: результат в ANSWER, код возврата read в ASK_RC
ask() {
  printf "%s%s" "$I_PTR" "$1"
  IFS= read -r ANSWER
  ASK_RC=$?
  [ "$ASK_RC" -ne 0 ] && { echo ""; ANSWER=""; return "$ASK_RC"; }
  ANSWER=$(printf '%s' "$ANSWER" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  return 0
}

# Подтверждение: по умолчанию «нет»; принимает y/yes/да
confirm() {
  local a
  printf "%s%s [y/N]: " "${2:-$I_Q}" "$1"
  IFS= read -r a || { echo ""; return 1; }
  case "$a" in
    [yYдД]*) return 0 ;;
    *) return 1 ;;
  esac
}
confirm_danger() { confirm "$1" "$I_WARN"; }

pause() {
  echo ""
  printf "%sEnter – продолжить..." "$I_PTR"
  IFS= read -r _dummy
  echo ""
}

clear_screen() { [ "$CLEAR" -eq 1 ] && [ -t 1 ] && printf '\033[H\033[2J'; }

# Разбивка ввода по пробелам и запятым без раскрытия шаблонов * ?
split_input() {
  local x
  set -f
  for x in $(printf '%s' "$1" | tr ',' ' '); do printf '%s\n' "$x"; done
  set +f
}

kind_label() {
  case "$1" in
    formula) echo "формула" ;;
    cask) echo "приложение" ;;
    *) echo "" ;;
  esac
}

expand_path() {
  case "$1" in
    "~") echo "$HOME" ;;
    "~/"*) echo "$HOME/${1#\~/}" ;;
    *) echo "$1" ;;
  esac
}

# ══════════════════════════════════════════════════
#  Доверие к сторонним репозиториям (Homebrew 6+)
# ══════════════════════════════════════════════════
is_trust_error() { grep -q 'untrusted tap' "$1" 2>/dev/null; }

# Разбор ошибки «Refusing to load … from untrusted tap …» и предложение brew trust.
# $1 – текст ошибки. Код 0 – доверие выдано, можно повторить команду.
trust_offer() {
  local text="$1" item tap what
  item=$(printf '%s\n' "$text" | sed -n 's/.*Run `brew trust \([^`]*\)` or `brew trust \([^`]*\)`.*/\1/p' | head -1)
  tap=$(printf '%s\n' "$text" | sed -n 's/.*Run `brew trust \([^`]*\)` or `brew trust \([^`]*\)`.*/\2/p' | head -1)
  [ -z "$tap" ] && tap=$(printf '%s\n' "$text" | sed -n 's/.*from untrusted tap \([^ ]*\)\.$/\1/p' | head -1)
  [ -z "$item" ] && [ -z "$tap" ] && return 1
  what=$(printf '%s\n' "$text" | sed -n 's/.*Refusing to load \(.*\) from untrusted tap.*/\1/p' | head -1)
  [ -z "$what" ] && what="${item##* }"
  grep -qxF "${item:-$tap}" "$SESSION_DIR/declined" 2>/dev/null && return 1

  echo ""
  section "${I_LOCK}Нужно доверие к стороннему репозиторию"
  warn "Homebrew отказался загрузить $what из непроверенного репозитория $tap."
  info "Доверие означает, что код этого пакета будет выполняться с правами вашего пользователя."
  [ -n "$item" ] && mitem "1) Доверять только этому пакету (рекомендуется)"
  [ -n "$tap" ] && mitem "2) Доверять всему репозиторию $tap (включая будущие пакеты)"
  mitem "0) Не доверять"
  echo "$LINE1"
  if ! ask "Выбор [0]: "; then ANSWER=0; fi
  case "$ANSWER" in
    1) [ -n "$item" ] || { err "Вариант недоступен."; return 1; }
       echo "${C_D}\$ brew trust $item${C_0}"
       if brew trust $item; then ok "Доверие выдано: ${item##* }"; return 0; fi ;;
    2) [ -n "$tap" ] || { err "Вариант недоступен."; return 1; }
       echo "${C_D}\$ brew trust $tap${C_0}"
       if brew trust "$tap"; then ok "Доверие выдано репозиторию $tap"; return 0; fi ;;
    *) printf '%s\n' "${item:-$tap}" >> "$SESSION_DIR/declined"
       stopped "Доверие не выдано. В этом сеансе вопрос больше не появится."
       return 1 ;;
  esac
  err "Не удалось выдать доверие."
  return 1
}

# Конфликт «It seems there is already an App at '…'»: объяснение и выбор решения.
# $1 – файл с ошибками, $2 – подкоманда brew. Результат – флаг в CONFLICT_FLAG.
# Код 0 – повторить команду с этим флагом.
conflict_offer() {
  local errf="$1" cmd="$2" path
  CONFLICT_FLAG=""
  path=$(sed -n "s/.*It seems there is already .* at '\([^']*\)'.*/\1/p" "$errf" | head -1)
  echo ""
  section "${I_WARN}Конфликт файлов приложения"
  case "$cmd" in
    uninstall)
      info "При удалении Homebrew возвращает приложение в свою служебную папку, а там уже лежит копия:"
      echo "   ${path:-путь не определён}"
      info "Обычно это остаток прошлой неудачной установки или удаления. Флаг --force перезапишет эту копию и доведёт удаление до конца."
      if confirm "Повторить удаление с --force?"; then CONFLICT_FLAG="--force"; return 0; fi ;;
    install|reinstall|upgrade)
      info "По месту установки уже есть приложение:"
      echo "   ${path:-путь не определён}"
      info "Скорее всего, оно установлено вручную (не через Homebrew) или осталось от прошлой установки."
      mitem "1) Взять под управление Homebrew (--adopt) – приложение остаётся, Homebrew начинает его учитывать и обновлять; сработает, если версия совпадает"
      mitem "2) Перезаписать версией из Homebrew (--force)"
      mitem "0) Отмена"
      if ask "Выбор [0]: "; then
        case "$ANSWER" in
          1) CONFLICT_FLAG="--adopt"; return 0 ;;
          2) confirm_danger "Перезаписать $path?" && { CONFLICT_FLAG="--force"; return 0; } ;;
        esac
      fi ;;
    *) return 1 ;;
  esac
  stopped
  return 1
}

# Ошибка «Please enable Full Disk Access for your terminal»: инструкция и открытие настроек.
# $1 – команда brew (без слова brew) для повтора после перезапуска терминала.
fda_offer() {
  local cmd="$1" term
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) term="Терминал (Программы ➡️ Утилиты)" ;;
    iTerm.app) term="iTerm2" ;;
    vscode) term="Visual Studio Code" ;;
    WarpTerminal) term="Warp" ;;
    ghostty) term="Ghostty" ;;
    WezTerm) term="WezTerm" ;;
    "") term="ваш терминал" ;;
    *) term="$TERM_PROGRAM" ;;
  esac
  echo ""
  section "${I_LOCK}Нужен «Полный доступ к диску»"
  info "macOS не даёт программам из терминала удалять файлы в защищённых местах без этого разрешения – даже с паролем администратора."
  echo "   Что сделать:"
  if [ -n "${SSH_CONNECTION:-}" ]; then
    echo "   1. Вы подключены по SSH. На Mac откройте Системные настройки ➡️ Основные ➡️ Общий доступ ➡️ Удалённый вход ➡️ (i) и включите «Разрешить полный доступ к диску для удалённых пользователей»."
    echo "   2. Отключитесь и подключитесь по SSH заново."
  else
    echo "   1. В разделе «Полный доступ к диску» включите переключатель у приложения: $term. Если его нет в списке – добавьте кнопкой «+»."
    echo "   2. Полностью закройте терминал (Cmd+Q) и откройте заново – разрешение действует только после перезапуска."
  fi
  echo "   3. Повторите команду (в brewman или напрямую):"
  echo "      brew $cmd"
  info "Разрешение даёт программам из терминала доступ ко всем вашим файлам. Если оно не нужно постоянно, выключите его после удаления."
  if [ "$IS_MAC" -eq 1 ] && [ -z "${SSH_CONNECTION:-}" ] && command -v open >/dev/null 2>&1; then
    if confirm "Открыть раздел «Полный доступ к диску» сейчас?"; then
      if open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"; then
        ok "Настройки открыты."
      else
        err "Не удалось открыть настройки – откройте вручную: Системные настройки ➡️ Конфиденциальность и безопасность ➡️ Полный доступ к диску."
      fi
    fi
  fi
}

# Запуск brew с показом команды. Ошибки дублируются в файл, чтобы распознать
# отказ из-за непроверенного репозитория или конфликт файлов, предложить решение
# и повторить команду.
run_brew() {
  local errf rc=0 tries=0 conflict_done=0 sub
  errf=$(mktemp "${TMPDIR:-/tmp}/brewman.XXXXXX")
  while :; do
    echo "${C_D}\$ brew $*${C_0}"
    { brew "$@" 2>&1 1>&3 3>&- | tee "$errf" 1>&2; rc=${PIPESTATUS[0]}; } 3>&1
    if [ "$rc" -ne 0 ] && is_trust_error "$errf" && [ "$tries" -lt 10 ]; then
      tries=$((tries+1))
      if trust_offer "$(cat "$errf")"; then
        echo "${I_UPD}Повторяю команду..."
        continue
      fi
    fi
    if [ "$rc" -ne 0 ] && [ "$conflict_done" -eq 0 ] && grep -q 'It seems there is already' "$errf" 2>/dev/null; then
      conflict_done=1
      sub="$1"
      if conflict_offer "$errf" "$sub"; then
        shift
        set -- "$sub" "$CONFLICT_FLAG" "$@"
        echo "${I_UPD}Повторяю команду с $CONFLICT_FLAG..."
        continue
      fi
    fi
    break
  done
  if [ "$rc" -ne 0 ] && grep -q 'Full Disk Access' "$errf" 2>/dev/null; then
    fda_offer "$*"
  fi
  if [ "$rc" -ne 0 ] && grep -q 'not trusted' "$errf" 2>/dev/null; then
    info "Есть непроверенные репозитории – доверием можно управлять в пункте 9 главного меню."
  fi
  rm -f "$errf"
  return "$rc"
}

# Тихий запуск brew для получения списков: вывод – в stdout, вопросы о доверии – в stderr
bq() {
  local errf out rc=0 tries=0
  errf=$(mktemp "${TMPDIR:-/tmp}/brewman.XXXXXX")
  while :; do
    out=$(brew "$@" 2>"$errf"); rc=$?
    if [ "$rc" -ne 0 ] && is_trust_error "$errf" && [ "$tries" -lt 10 ]; then
      tries=$((tries+1))
      trust_offer "$(cat "$errf")" >&2 && continue
    fi
    break
  done
  if [ "$rc" -ne 0 ] && is_trust_error "$errf"; then
    warn "Часть данных не загружена: есть пакет из непроверенного репозитория (brew $1)." >&2
  fi
  rm -f "$errf"
  [ -n "$out" ] && printf '%s\n' "$out"
  return "$rc"
}

# ══════════════════════════════════════════════════
#  Загрузка списков (LIST – имена, LIST_DESC – описания, TYPES – тип)
# ══════════════════════════════════════════════════
reset_lists() { LIST=(); LIST_DESC=(); TYPES=(); }

load_formulae() {
  reset_lists
  local name vers
  while read -r name vers; do
    [ -z "$name" ] && continue
    LIST+=("$name"); LIST_DESC+=("$vers"); TYPES+=("formula")
  done < <(bq list --formula --versions)
}

# Список приложений из папки Caskroom: «имя версия» (не требует загрузки описаний)
caskroom_list() {
  local room d v
  room=$(brew --caskroom 2>/dev/null)
  [ -d "$room" ] || return 1
  for d in "$room"/*/; do
    [ -d "$d" ] || continue
    v=$(ls -1 "$d" 2>/dev/null | grep -v '^\.' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    printf '%s %s\n' "$(basename "$d")" "$v"
  done
}

load_casks() {
  reset_lists
  CASK_FALLBACK=0
  [ "$IS_MAC" -eq 1 ] || return 0
  local name vers out
  out=$(bq list --cask --versions)
  if [ $? -ne 0 ] || [ -z "$out" ]; then
    out=$(caskroom_list)
    [ -n "$out" ] && CASK_FALLBACK=1
  fi
  while read -r name vers; do
    [ -z "$name" ] && continue
    LIST+=("$name"); LIST_DESC+=("$vers"); TYPES+=("cask")
  done <<< "$out"
}

# Диагностика, если список приложений cask пуст
cask_empty_diag() {
  local room cnt p other=""
  warn "Homebrew не вернул ни одного установленного приложения (cask)."
  room=$(brew --caskroom 2>/dev/null)
  if [ -d "$room" ]; then
    cnt=$(ls -1 "$room" 2>/dev/null | wc -l | tr -d ' ')
    info "Папка приложений Homebrew: $room (записей: $cnt)"
  else
    info "Папка приложений Homebrew (${room:-не определена}) не существует – через brew не установлено ни одного приложения."
  fi
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$p" ] || continue
    [ "$("$p" --prefix 2>/dev/null)" = "$(brew --prefix 2>/dev/null)" ] && continue
    other="$p"
  done
  if [ -n "$other" ]; then
    warn "На компьютере есть вторая установка Homebrew: $other"
    info "Приложения могут числиться за ней. Сейчас используется: $(command -v brew)"
  fi
  info "Программы, установленные вручную (перетаскиванием в папку «Программы») или из App Store, Homebrew не видит."
  info "Чтобы передать такую программу под управление Homebrew, используйте: brew install --cask --adopt <имя>"
}

load_leaves() {
  reset_lists
  local names name vers
  names=$(bq leaves --installed-on-request 2>/dev/null) || names=$(bq leaves)
  [ -z "$names" ] && return 0
  set -f
  while read -r name vers; do
    [ -z "$name" ] && continue
    LIST+=("$name"); LIST_DESC+=("$vers"); TYPES+=("formula")
  done < <(bq list --formula --versions $names)
  set +f
}

load_pinned() {
  reset_lists
  local name vers
  while read -r name vers; do
    [ -z "$name" ] && continue
    LIST+=("$name"); LIST_DESC+=("$vers"); TYPES+=("formula")
  done < <(bq list --pinned --versions)
}

load_all_installed() {
  local f_l=() f_d=() i
  load_formulae
  for i in "${!LIST[@]}"; do f_l+=("${LIST[$i]}"); f_d+=("формула  ${LIST_DESC[$i]}"); done
  load_casks
  local c_l=() c_d=()
  for i in "${!LIST[@]}"; do c_l+=("${LIST[$i]}"); c_d+=("приложение  ${LIST_DESC[$i]}"); done
  reset_lists
  for i in "${!f_l[@]}"; do LIST+=("${f_l[$i]}"); LIST_DESC+=("${f_d[$i]}"); TYPES+=("formula"); done
  for i in "${!c_l[@]}"; do LIST+=("${c_l[$i]}"); LIST_DESC+=("${c_d[$i]}"); TYPES+=("cask"); done
}

# Устаревшие пакеты: «имя (текущая) < новая» → имя|текущая|новая|хвост
parse_outdated() {
  sed -E 's/^([^ ]+) \((.*)\) (<|!=) ([^ ]+)(.*)$/\1|\2|\4|\5/' | grep '|'
}

load_outdated() {
  reset_lists
  local name cur new rest gflag=""
  [ "$GREEDY" -eq 1 ] && gflag="--greedy"
  while IFS='|' read -r name cur new rest; do
    [ -z "$name" ] && continue
    rest=${rest/pinned at/закреплена на}
    LIST+=("$name"); TYPES+=("formula")
    LIST_DESC+=("$cur ${I_ARR}$new  формула$rest")
  done < <(bq outdated --formula --verbose | parse_outdated)
  if [ "$IS_MAC" -eq 1 ]; then
    while IFS='|' read -r name cur new rest; do
      [ -z "$name" ] && continue
      LIST+=("$name"); TYPES+=("cask")
      LIST_DESC+=("$cur ${I_ARR}$new  приложение$rest")
    done < <(bq outdated --cask --verbose $gflag | parse_outdated)
  fi
  # Запасной вариант, если формат вывода brew изменился
  if [ ${#LIST[@]} -eq 0 ]; then
    while read -r name; do
      [ -z "$name" ] && continue
      LIST+=("$name"); TYPES+=(""); LIST_DESC+=("")
    done < <(bq outdated --quiet $gflag 2>/dev/null)
  fi
}

load_search() {
  local q="$1" mode="$2" line name desc base k kinds="formula" inst dflag=""
  reset_lists
  [ "$IS_MAC" -eq 1 ] && kinds="formula cask"
  [ "$mode" = "desc" ] && dflag="--desc"
  for k in $kinds; do
    inst=" $(brew list --"$k" -1 2>/dev/null | tr '\n' ' ') "
    while IFS= read -r line; do
      case "$line" in ""|"==>"*|"No "*|"If you meant"*|"Error"*|"Warning"*) continue ;; esac
      if [ "$mode" = "desc" ]; then
        name=${line%%: *}; desc=${line#*: }
        [ "$name" = "$line" ] && desc=""
      else
        name=${line%% *}; desc=""
      fi
      name=${name%%✔*}
      [ -z "$name" ] && continue
      base=${name##*/}
      case "$inst" in *" $base "*) desc="[установлено] $desc" ;; esac
      LIST+=("$name"); TYPES+=("$k"); LIST_DESC+=("$(kind_label "$k")  $desc")
    done < <(brew search $dflag --"$k" "$q" 2>/dev/null)
  done
}

load_services() {
  reset_lists
  local name status rest d
  while read -r name status rest; do
    [ -z "$name" ] && continue
    case "$status" in
      started) d="запущен" ;;
      stopped|none) d="остановлен" ;;
      error) d="ошибка" ;;
      scheduled) d="по расписанию" ;;
      *) d="$status" ;;
    esac
    LIST+=("$name"); LIST_DESC+=("$d"); TYPES+=("")
  done < <(brew services list 2>/dev/null | tail -n +2)
}

load_taps() {
  reset_lists
  local t
  while read -r t; do
    [ -z "$t" ] && continue
    LIST+=("$t"); LIST_DESC+=(""); TYPES+=("")
  done < <(brew tap 2>/dev/null)
}

# ══════════════════════════════════════════════════
#  Вывод списков и выбор элементов
# ══════════════════════════════════════════════════
name_width() {
  local i w=0
  for i in "$@"; do [ ${#LIST[$i]} -gt $w ] && w=${#LIST[$i]}; done
  [ $w -gt 40 ] && w=40
  echo "$w"
}

print_rows() {
  local i k=1 w
  w=$(name_width "$@")
  for i in "$@"; do
    printf "  %3d) %-*s  %s\n" "$k" "$w" "${LIST[$i]}" "${C_D}${LIST_DESC[$i]:-}${C_0}"
    k=$((k+1))
  done
}

print_list() {
  if [ ${#LIST[@]} -eq 0 ]; then info "Список пуст."; return 1; fi
  print_rows "${!LIST[@]}"
  echo ""
  info "Всего: ${#LIST[@]}"
}

add_sel() {
  local j
  for j in "${SEL_IDX[@]}"; do [ "$j" = "$1" ] && return; done
  SEL_IDX+=("$1"); SEL+=("${LIST[$1]}")
}

# Выбор из LIST. $1 – подпись, $2 – 1 (несколько) или 0 (один).
# Результат: SEL (имена) и SEL_IDX (индексы). Код 1 – отмена.
pick() {
  local label="$1" multi="${2:-1}" n=${#LIST[@]} i
  SEL=(); SEL_IDX=()
  if [ "$n" -eq 0 ]; then info "Список пуст."; return 1; fi

  if [ "$USE_FZF" -eq 1 ]; then
    local mflag="" out line hdr
    [ "$multi" = "1" ] && mflag="-m"
    hdr="Enter – подтвердить, Esc – отмена"
    [ "$multi" = "1" ] && hdr="Tab – отметить несколько, $hdr"
    out=$(for i in "${!LIST[@]}"; do printf '%s\t%s\t%s\n' "$i" "${LIST[$i]}" "${LIST_DESC[$i]:-}"; done |
      fzf $mflag --delimiter='\t' --with-nth=2,3 --reverse --height=90% \
        --prompt="$label > " --header="$hdr" \
        --preview="brew info $PICK_PREVIEW {2} 2>/dev/null | head -60" \
        --preview-window=right:55%:wrap)
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      add_sel "${line%%$'\t'*}"
    done <<< "$out"
    if [ ${#SEL[@]} -eq 0 ]; then stopped "Ничего не выбрано."; return 1; fi
    info "Выбрано: ${SEL[*]}"
    return 0
  fi

  # Режим выбора по номерам
  local filter="" shown=()
  if [ "$n" -gt 25 ]; then
    ask "Фильтр по названию (Enter – показать все $n): " || return 1
    filter="$ANSWER"
  fi
  shopt -s nocasematch
  for i in "${!LIST[@]}"; do
    if [ -z "$filter" ]; then
      shown+=("$i")
    else
      case "${LIST[$i]}" in *"$filter"*) shown+=("$i") ;; esac
    fi
  done
  shopt -u nocasematch
  if [ ${#shown[@]} -eq 0 ]; then info "По фильтру «$filter» ничего не найдено."; return 1; fi

  echo ""
  print_rows "${shown[@]}"
  echo ""
  if [ "$multi" = "1" ]; then
    info "Номера через пробел или запятую, диапазоны (1-5), «все» или названия."
  else
    info "Укажите один номер или название."
  fi
  ask "$label – ваш выбор (Enter – отмена): " || return 1
  if [ -z "$ANSWER" ]; then stopped; return 1; fi

  local t a b j m=${#shown[@]} found
  for t in $(split_input "$ANSWER"); do
    case "$t" in
      все|Все|ВСЕ|all|ALL|'*')
        for j in "${shown[@]}"; do add_sel "$j"; done ;;
      *[!0-9-]*|-*|*-)
        found=0
        for j in "${!LIST[@]}"; do
          if [ "${LIST[$j]}" = "$t" ]; then add_sel "$j"; found=1; break; fi
        done
        [ "$found" -eq 0 ] && warn "«$t» нет в списке – пропущено." ;;
      *-*)
        a=${t%%-*}; b=${t#*-}
        case "$a$b" in *[!0-9]*|"") warn "Неверный диапазон: $t"; continue ;; esac
        if [ "$a" -lt 1 ] || [ "$b" -gt "$m" ] || [ "$a" -gt "$b" ]; then
          warn "Диапазон вне списка: $t"; continue
        fi
        for ((j=a; j<=b; j++)); do add_sel "${shown[$((j-1))]}"; done ;;
      *)
        if [ "$t" -lt 1 ] || [ "$t" -gt "$m" ]; then warn "Нет пункта №$t"; continue; fi
        add_sel "${shown[$((t-1))]}" ;;
    esac
  done

  if [ ${#SEL[@]} -eq 0 ]; then stopped "Ничего не выбрано."; return 1; fi
  if [ "$multi" != "1" ] && [ ${#SEL[@]} -gt 1 ]; then
    SEL=("${SEL[0]}"); SEL_IDX=("${SEL_IDX[0]}")
  fi
  info "Выбрано: ${SEL[*]}"
  return 0
}

# Выбранное → ITEMS в виде «тип:имя»
sel_items() {
  local i
  ITEMS=()
  for i in "${SEL_IDX[@]}"; do ITEMS+=("${TYPES[$i]:-}:${LIST[$i]}"); done
}

# ══════════════════════════════════════════════════
#  Пакетное выполнение с блоками и итогом
#  $1 – действие brew (install, uninstall, upgrade, pin, services start…)
#  далее элементы «тип:имя»
# ══════════════════════════════════════════════════
batch_run() {
  local action="$1"; shift
  local item kind name flags ok_list="" fail_list="" n_ok=0 n_fail=0 deps
  echo ""
  for item in "$@"; do
    kind="${item%%:*}"; name="${item#*:}"
    flags=""
    case "$action" in
      install|uninstall|upgrade|reinstall)
        case "$kind" in
          formula) flags="--formula" ;;
          cask) flags="--cask $CASK_EXTRA" ;;
        esac ;;
    esac
    echo "▼─── $name ───▼"
    if run_brew $action $flags "$name"; then
      ok "$name: успешно."
      ok_list="$ok_list $name"; n_ok=$((n_ok+1))
    else
      err "$name: ошибка."
      fail_list="$fail_list $name"; n_fail=$((n_fail+1))
      if [ "$action" = "uninstall" ] && [ "$kind" != "cask" ]; then
        deps=$(brew uses --installed "$name" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        [ -n "$deps" ] && info "От пакета зависят: $deps"
      fi
    fi
    echo "▲────────────────────────▲"
    echo ""
  done
  DIRTY=1
  section "${I_LIST}Итог"
  [ $n_ok -gt 0 ] && echo "${I_OK}Успешно ($n_ok):$ok_list"
  [ $n_fail -gt 0 ] && echo "${I_ERR}С ошибкой ($n_fail):$fail_list"
  echo "$LINE1"
}

show_items() {
  local item k
  for item in "$@"; do
    k=$(kind_label "${item%%:*}")
    echo "   • ${item#*:}${k:+ ${C_D}($k)${C_0}}"
  done
}

# ══════════════════════════════════════════════════
#  1. Установленные пакеты
# ══════════════════════════════════════════════════
installed_menu() {
  while true; do
    echo ""
    section "${I_LIST}Установленные пакеты"
    mitem "1) Все формулы (консольные программы и библиотеки)"
    mitem "2) Формулы, установленные вручную (без зависимостей)"
    [ "$IS_MAC" -eq 1 ] && mitem "3) Приложения (cask)"
    mitem "4) Закреплённые версии (pin)"
    mitem "5) Дерево зависимостей установленных формул"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Пункт: " || return
    echo ""
    case "$ANSWER" in
      1) echo "${I_WAIT}Загрузка..."; load_formulae; print_list ;;
      2) echo "${I_WAIT}Загрузка..."; load_leaves; print_list ;;
      3) if [ "$IS_MAC" -eq 1 ]; then
           echo "${I_WAIT}Загрузка..."; load_casks
           if [ ${#LIST[@]} -eq 0 ]; then
             cask_empty_diag
           else
             print_list
             [ "$CASK_FALLBACK" -eq 1 ] && info "Список и версии взяты из папки Caskroom – brew list не смог загрузить все описания."
           fi
         else
           warn "Приложения (cask) доступны только в macOS."
         fi ;;
      4) load_pinned; print_list ;;
      5) echo "${I_WAIT}Построение дерева..."; run_brew deps --tree --installed ;;
      0|"") return ;;
      *) err "Нет такого пункта: $ANSWER" ;;
    esac
    pause
  done
}

# ══════════════════════════════════════════════════
#  2. Поиск и установка
# ══════════════════════════════════════════════════
search_menu() {
  local mode q
  while true; do
    echo ""
    section "${I_SEARCH}Поиск пакетов"
    mitem "1) По названию"
    mitem "2) По описанию (например, «pdf editor»)"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Пункт: " || return
    case "$ANSWER" in
      1) mode="name" ;;
      2) mode="desc" ;;
      0|"") return ;;
      *) err "Нет такого пункта: $ANSWER"; continue ;;
    esac
    ask "Поисковый запрос (можно /регулярное выражение/): " || continue
    q="$ANSWER"
    if [ -z "$q" ]; then stopped "Пустой запрос."; continue; fi
    echo ""
    echo "${I_WAIT}Ищу «$q»..."
    load_search "$q" "$mode"
    if [ ${#LIST[@]} -eq 0 ]; then
      info "Ничего не найдено."
      pause; continue
    fi
    ok "Найдено: ${#LIST[@]}"
    PICK_PREVIEW=""
    pick "Пакеты" 1 || { pause; continue; }
    sel_items
    echo ""
    mitem "1) ${I_PKG}Установить выбранное"
    mitem "2) ${I_INFO}Показать информацию"
    mitem "0) ${I_BACK}Назад"
    ask "Действие: " || continue
    case "$ANSWER" in
      1)
        echo ""; info "Будут установлены:"; show_items "${ITEMS[@]}"
        if confirm "Установить ${#ITEMS[@]} шт.?"; then batch_run install "${ITEMS[@]}"; else stopped; fi ;;
      2)
        local it
        for it in "${ITEMS[@]}"; do show_info "${it#*:}" "${it%%:*}"; done
        if confirm "Установить показанные пакеты?"; then batch_run install "${ITEMS[@]}"; fi ;;
      *) ;;
    esac
    pause
  done
}

# ══════════════════════════════════════════════════
#  3. Установка по названию
# ══════════════════════════════════════════════════
install_by_name() {
  local kind="" x
  echo ""
  section "${I_PKG}Установка по названию"
  mitem "1) Автоопределение"
  mitem "2) Формула (консольная программа или библиотека)"
  [ "$IS_MAC" -eq 1 ] && mitem "3) Приложение (cask, программа с графическим интерфейсом)"
  mitem "0) ${I_BACK}Назад"
  echo "$LINE1"
  ask "Тип [1]: " || return
  case "$ANSWER" in
    1|"") kind="" ;;
    2) kind="formula" ;;
    3) if [ "$IS_MAC" -eq 1 ]; then kind="cask"; else err "Приложения (cask) доступны только в macOS."; pause; return; fi ;;
    0) return ;;
    *) err "Нет такого пункта: $ANSWER"; pause; return ;;
  esac
  ask "Названия пакетов (через пробел или запятую): " || return
  if [ -z "$ANSWER" ]; then stopped "Ничего не введено."; pause; return; fi
  ITEMS=()
  for x in $(split_input "$ANSWER"); do ITEMS+=("$kind:$x"); done
  echo ""
  info "Будут установлены:"; show_items "${ITEMS[@]}"
  if confirm "Установить ${#ITEMS[@]} шт.?"; then
    batch_run install "${ITEMS[@]}"
  else
    stopped
  fi
  pause
}

# ══════════════════════════════════════════════════
#  4. Удаление
# ══════════════════════════════════════════════════
autoremove_offer() {
  local out
  echo "${I_WAIT}Проверяю ненужные зависимости..."
  out=$(brew autoremove -n 2>&1)
  if ! printf '%s' "$out" | grep -q 'Would'; then
    ok "Ненужных зависимостей нет."
    return 0
  fi
  info "Больше не нужны другим пакетам:"
  printf '%s\n' "$out" | grep -v '^==>' | sed 's/^/   • /'
  if confirm_danger "Удалить эти зависимости?"; then
    run_brew autoremove && ok "Зависимости удалены."
    DIRTY=1
  else
    stopped
  fi
}

uninstall_menu() {
  while true; do
    echo ""
    section "${I_DEL}Удаление пакетов"
    mitem "1) Формулы, установленные вручную (рекомендуется)"
    mitem "2) Все формулы (включая зависимости)"
    [ "$IS_MAC" -eq 1 ] && mitem "3) Приложения (cask)"
    mitem "4) Только ненужные зависимости (autoremove)"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Пункт: " || return
    echo ""
    CASK_EXTRA=""
    case "$ANSWER" in
      1) echo "${I_WAIT}Загрузка..."; load_leaves; PICK_PREVIEW="--formula" ;;
      2) echo "${I_WAIT}Загрузка..."; load_formulae; PICK_PREVIEW="--formula" ;;
      3) if [ "$IS_MAC" -ne 1 ]; then warn "Приложения (cask) доступны только в macOS."; pause; continue; fi
         echo "${I_WAIT}Загрузка..."; load_casks; PICK_PREVIEW="--cask"
         if [ ${#LIST[@]} -eq 0 ]; then cask_empty_diag; pause; continue; fi ;;
      4) autoremove_offer; pause; continue ;;
      0|"") return ;;
      *) err "Нет такого пункта: $ANSWER"; pause; continue ;;
    esac
    pick "Удалить" 1 || { pause; continue; }
    sel_items
    if [ "${ITEMS[0]%%:*}" = "cask" ]; then
      info "Режим --zap удаляет также настройки, кэш и данные приложения."
      confirm "Удалить вместе с настройками и данными (--zap)?" && CASK_EXTRA="--zap"
    fi
    echo ""
    warn "Будут удалены:"; show_items "${ITEMS[@]}"
    if confirm_danger "Удалить ${#ITEMS[@]} шт.? Действие необратимо."; then
      batch_run uninstall "${ITEMS[@]}"
      echo ""
      autoremove_offer
    else
      stopped
    fi
    CASK_EXTRA=""
    pause
  done
}

# ══════════════════════════════════════════════════
#  5. Обновления
# ══════════════════════════════════════════════════
update_index() {
  echo "${I_WAIT}Обновляю индекс пакетов Homebrew..."
  if run_brew update; then
    ok "Индекс обновлён."
    INDEX_UPDATED=1
  else
    err "Не удалось обновить индекс. Проверьте подключение к интернету."
  fi
  echo ""
}

maybe_update_index() {
  [ "$INDEX_UPDATED" -eq 1 ] && return 0
  info "Индекс пакетов в этом сеансе ещё не обновлялся – список устаревших может быть неполным."
  confirm "Сначала обновить индекс (brew update)?" && update_index
}

updates_menu() {
  local gl
  while true; do
    gl="выкл"; [ "$GREEDY" -eq 1 ] && gl="вкл"
    echo ""
    section "${I_UPD}Обновления"
    mitem "1) Обновить индекс Homebrew (brew update)"
    mitem "2) Показать устаревшие пакеты"
    mitem "3) Обновить все пакеты"
    mitem "4) Обновить выбранные пакеты"
    [ "$IS_MAC" -eq 1 ] && mitem "5) Учитывать приложения с автообновлением (greedy): $gl"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Пункт: " || return
    echo ""
    case "$ANSWER" in
      1) update_index ;;
      2)
        maybe_update_index
        echo "${I_WAIT}Проверяю устаревшие пакеты..."
        load_outdated
        if [ ${#LIST[@]} -eq 0 ]; then ok "Все пакеты актуальны."; else print_list; fi ;;
      3)
        maybe_update_index
        echo "${I_WAIT}Проверяю устаревшие пакеты..."
        load_outdated
        if [ ${#LIST[@]} -eq 0 ]; then
          ok "Все пакеты актуальны."
        else
          print_list
          echo ""
          if confirm "Обновить все пакеты (${#LIST[@]} шт.)?"; then
            if [ "$GREEDY" -eq 1 ]; then run_brew upgrade --greedy; else run_brew upgrade; fi
            if [ $? -eq 0 ]; then ok "Обновление завершено."; else err "Обновление завершилось с ошибками – см. вывод выше."; fi
            DIRTY=1
          else
            stopped
          fi
        fi ;;
      4)
        maybe_update_index
        echo "${I_WAIT}Проверяю устаревшие пакеты..."
        load_outdated
        if [ ${#LIST[@]} -eq 0 ]; then
          ok "Все пакеты актуальны."
        else
          PICK_PREVIEW=""
          if pick "Обновить" 1; then
            sel_items
            [ "$GREEDY" -eq 1 ] && CASK_EXTRA="--greedy"
            if confirm "Обновить ${#ITEMS[@]} шт.?"; then batch_run upgrade "${ITEMS[@]}"; else stopped; fi
            CASK_EXTRA=""
          fi
        fi ;;
      5)
        if [ "$IS_MAC" -eq 1 ]; then
          if [ "$GREEDY" -eq 1 ]; then GREEDY=0; else GREEDY=1; fi
          info "Приложения, которые обновляются сами (например, браузеры), по умолчанию пропускаются."
          ok "Режим greedy: $([ "$GREEDY" -eq 1 ] && echo "включён" || echo "выключен")."
        else
          err "Нет такого пункта: $ANSWER"
        fi ;;
      0|"") return ;;
      *) err "Нет такого пункта: $ANSWER" ;;
    esac
    pause
  done
}

# ══════════════════════════════════════════════════
#  6. Информация о пакете
# ══════════════════════════════════════════════════
show_info() {
  local name="$1" kind="$2" flag="" uses
  case "$kind" in formula) flag="--formula" ;; cask) flag="--cask" ;; esac
  echo ""
  echo "▼─── $name ───▼"
  brew info $flag "$name"
  if [ "$kind" != "cask" ] && brew info --formula "$name" >/dev/null 2>&1; then
    echo ""
    echo "  ${C_B}Зависимости:${C_0}"
    brew deps --tree "$name" 2>/dev/null | sed 's/^/    /'
    uses=$(brew uses --installed "$name" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    echo "  ${C_B}Используется установленными пакетами:${C_0} ${uses:-нет}"
  fi
  echo "▲────────────────────────▲"
}

info_menu() {
  local x it
  while true; do
    echo ""
    section "${I_INFO}Информация о пакете"
    ask "Названия через пробел (Enter – выбрать из установленных, 0 – назад): " || return
    case "$ANSWER" in
      0) return ;;
      "")
        echo "${I_WAIT}Загрузка..."
        load_all_installed; PICK_PREVIEW=""
        pick "Информация" 1 || { pause; continue; }
        sel_items ;;
      *)
        ITEMS=()
        for x in $(split_input "$ANSWER"); do ITEMS+=(":$x"); done ;;
    esac
    for it in "${ITEMS[@]}"; do show_info "${it#*:}" "${it%%:*}"; done
    echo ""
    section "${I_LIST}Действия с пакетом"
    mitem "1) ${I_PKG}Установить"
    mitem "2) ${I_DEL}Удалить"
    mitem "3) ${I_SEARCH}Открыть сайт пакета"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Действие [0]: " || return
    case "$ANSWER" in
      1) if confirm "Установить ${#ITEMS[@]} шт.?"; then batch_run install "${ITEMS[@]}"; else stopped; fi ;;
      2) if confirm_danger "Удалить ${#ITEMS[@]} шт.? Действие необратимо."; then batch_run uninstall "${ITEMS[@]}"; else stopped; fi ;;
      3) for it in "${ITEMS[@]}"; do run_brew home "${it#*:}"; done ;;
      *) continue ;;
    esac
    pause
  done
}

# ══════════════════════════════════════════════════
#  7. Сервисы
# ══════════════════════════════════════════════════
services_menu() {
  local act
  while true; do
    echo ""
    section "${I_SVC}Сервисы (фоновые службы: базы данных, веб-серверы и т.п.)"
    load_services
    if [ ${#LIST[@]} -eq 0 ]; then
      info "Установленных пакетов с сервисами нет."
      pause; return
    fi
    print_rows "${!LIST[@]}"
    echo "$LINE1"
    mitem "1) Запустить (и включить автозапуск)"
    mitem "2) Остановить (и выключить автозапуск)"
    mitem "3) Перезапустить"
    mitem "4) Запустить один раз (без автозапуска)"
    mitem "5) Подробности о сервисе"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Действие: " || return
    case "$ANSWER" in
      1) act="services start" ;;
      2) act="services stop" ;;
      3) act="services restart" ;;
      4) act="services run" ;;
      5) act="services info" ;;
      0|"") return ;;
      *) err "Нет такого пункта: $ANSWER"; pause; continue ;;
    esac
    PICK_PREVIEW=""
    pick "Сервисы" 1 || { pause; continue; }
    sel_items
    if [ "$act" = "services stop" ]; then
      confirm_danger "Остановить ${#ITEMS[@]} шт.?" || { stopped; pause; continue; }
    fi
    batch_run "$act" "${ITEMS[@]}"
    pause
  done
}

# ══════════════════════════════════════════════════
#  8. Закрепление версий (pin)
# ══════════════════════════════════════════════════
pin_menu() {
  while true; do
    echo ""
    section "${I_PIN}Закрепление версий (pin – запрет обновления формулы)"
    mitem "1) Показать закреплённые"
    mitem "2) Закрепить формулы"
    mitem "3) Открепить формулы"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Пункт: " || return
    echo ""
    case "$ANSWER" in
      1) load_pinned; print_list ;;
      2)
        echo "${I_WAIT}Загрузка..."; load_leaves; PICK_PREVIEW="--formula"
        if pick "Закрепить" 1; then sel_items; batch_run pin "${ITEMS[@]}"; fi ;;
      3)
        load_pinned; PICK_PREVIEW="--formula"
        if pick "Открепить" 1; then sel_items; batch_run unpin "${ITEMS[@]}"; fi ;;
      0|"") return ;;
      *) err "Нет такого пункта: $ANSWER" ;;
    esac
    pause
  done
}

# ══════════════════════════════════════════════════
#  9. Репозитории (tap)
# ══════════════════════════════════════════════════
taps_menu() {
  local x
  while true; do
    echo ""
    section "${I_TAP}Репозитории (tap – сторонние источники пакетов)"
    mitem "1) Показать подключённые"
    mitem "2) Подключить репозиторий"
    mitem "3) Отключить репозиторий"
    mitem "4) ${I_LOCK}Доверие к репозиториям и пакетам (brew trust)"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Пункт: " || return
    echo ""
    case "$ANSWER" in
      1) load_taps; print_list ;;
      2)
        info "Формат: владелец/репозиторий, например hashicorp/tap"
        ask "Репозитории (через пробел или запятую): " || continue
        if [ -z "$ANSWER" ]; then
          stopped "Ничего не введено."
        else
          ITEMS=()
          for x in $(split_input "$ANSWER"); do ITEMS+=(":$x"); done
          batch_run tap "${ITEMS[@]}"
          info "Чтобы ставить пакеты из стороннего репозитория по короткому имени, ему нужно доверие – пункт 4."
        fi ;;
      3)
        load_taps; PICK_PREVIEW=""
        if pick "Отключить" 1; then
          sel_items
          info "Отключить репозиторий можно, только если из него не установлены пакеты."
          if confirm_danger "Отключить ${#ITEMS[@]} шт.?"; then batch_run untap "${ITEMS[@]}"; else stopped; fi
        fi ;;
      4) trust_menu; continue ;;
      0|"") return ;;
      *) err "Нет такого пункта: $ANSWER" ;;
    esac
    pause
  done
}

# Сторонние (неофициальные) репозитории – в LIST
load_thirdparty_taps() {
  local t
  reset_lists
  while read -r t; do
    [ -z "$t" ] && continue
    case "$t" in homebrew/*) continue ;; esac
    LIST+=("$t"); LIST_DESC+=(""); TYPES+=("")
  done < <(brew tap 2>/dev/null)
}

# Выбор типа пакета для trust/untrust: результат в TRUST_FLAG
ask_trust_kind() {
  mitem "1) Формула"
  [ "$IS_MAC" -eq 1 ] && mitem "2) Приложение (cask)"
  mitem "3) Внешняя команда brew"
  ask "Тип пакета [1]: " || return 1
  case "$ANSWER" in
    1|"") TRUST_FLAG="--formula" ;;
    2) TRUST_FLAG="--cask" ;;
    3) TRUST_FLAG="--command" ;;
    *) err "Нет такого пункта: $ANSWER"; return 1 ;;
  esac
  info "Нужно полное имя: владелец/репозиторий/пакет, например macos-fuse-t/cask/fuse-t-sshfs"
  ask "Полные имена (через пробел или запятую): " || return 1
  [ -n "$ANSWER" ] || { stopped "Ничего не введено."; return 1; }
  return 0
}

trust_menu() {
  local x
  while true; do
    echo ""
    section "${I_LOCK}Доверие к сторонним репозиториям (Homebrew 6+)"
    info "Пакеты из непроверенных репозиториев Homebrew не загружает: команды с ними завершаются ошибкой."
    mitem "1) Показать, чему выдано доверие"
    mitem "2) Показать непроверенные репозитории и пакеты"
    mitem "3) Доверять репозиторию целиком"
    mitem "4) Доверять отдельному пакету (рекомендуется)"
    mitem "5) Отозвать доверие у репозитория"
    mitem "6) Отозвать доверие у отдельного пакета"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Пункт: " || return
    echo ""
    case "$ANSWER" in
      1) run_brew trust ;;
      2) run_brew untrust ;;
      3)
        load_thirdparty_taps; PICK_PREVIEW=""
        if [ ${#LIST[@]} -eq 0 ]; then
          info "Сторонних репозиториев не подключено."
        elif pick "Доверять" 1; then
          sel_items
          warn "Все нынешние и будущие пакеты из выбранных репозиториев смогут выполнять код с правами вашего пользователя."
          if confirm_danger "Выдать доверие ${#ITEMS[@]} репозиториям?"; then
            batch_run trust "${ITEMS[@]}"; : > "$SESSION_DIR/declined"
          else
            stopped
          fi
        fi ;;
      4)
        if ask_trust_kind; then
          ITEMS=()
          for x in $(split_input "$ANSWER"); do ITEMS+=(":$x"); done
          if confirm "Выдать доверие ${#ITEMS[@]} шт.?"; then
            batch_run "trust $TRUST_FLAG" "${ITEMS[@]}"; : > "$SESSION_DIR/declined"
          else
            stopped
          fi
        fi ;;
      5)
        load_thirdparty_taps; PICK_PREVIEW=""
        if [ ${#LIST[@]} -eq 0 ]; then
          info "Сторонних репозиториев не подключено."
        elif pick "Отозвать" 1; then
          sel_items
          if confirm_danger "Отозвать доверие у ${#ITEMS[@]} репозиториев? Команды с их пакетами начнут завершаться ошибкой."; then
            batch_run untrust "${ITEMS[@]}"
          else
            stopped
          fi
        fi ;;
      6)
        if ask_trust_kind; then
          ITEMS=()
          for x in $(split_input "$ANSWER"); do ITEMS+=(":$x"); done
          if confirm_danger "Отозвать доверие у ${#ITEMS[@]} шт.?"; then
            batch_run "untrust $TRUST_FLAG" "${ITEMS[@]}"
          else
            stopped
          fi
        fi ;;
      0|"") return ;;
      *) err "Нет такого пункта: $ANSWER" ;;
    esac
    pause
  done
}

# ══════════════════════════════════════════════════
#  10. Brewfile
# ══════════════════════════════════════════════════
ask_brewfile() {
  local def
  def=$(ls -t "$HOME"/Brewfile* 2>/dev/null | head -1)
  [ -z "$def" ] && def="$HOME/Brewfile"
  ask "Путь к Brewfile (Enter – $def): " || return 1
  BREWFILE=$(expand_path "${ANSWER:-$def}")
  if [ ! -f "$BREWFILE" ]; then err "Файл не найден: $BREWFILE"; return 1; fi
  return 0
}

brewfile_menu() {
  local def p out cnt
  while true; do
    echo ""
    section "${I_SAVE}Brewfile – список пакетов для резервной копии и переноса"
    mitem "1) Сохранить список установленного в Brewfile"
    mitem "2) Проверить, всё ли из Brewfile установлено"
    mitem "3) Установить всё из Brewfile"
    mitem "4) Найти пакеты, которых нет в Brewfile (и удалить их)"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Пункт: " || return
    echo ""
    case "$ANSWER" in
      1)
        def="$HOME/Brewfile_$(date +%d.%m.%Y_%H-%M)"
        ask "Куда сохранить (Enter – $def): " || continue
        p=$(expand_path "${ANSWER:-$def}")
        if [ -e "$p" ] && ! confirm_danger "Файл $p уже существует. Перезаписать?"; then
          stopped
        else
          echo "${I_WAIT}Сохраняю..."
          if run_brew bundle dump --file="$p" --force --describe; then
            cnt=$(grep -cv -e '^#' -e '^[[:space:]]*$' "$p")
            ok "Сохранено: $p (записей: $cnt)"
          else
            err "Не удалось сохранить Brewfile."
          fi
        fi ;;
      2)
        ask_brewfile || { pause; continue; }
        if run_brew bundle check --verbose --file="$BREWFILE"; then ok "Всё из Brewfile установлено."; else warn "Установлено не всё – см. список выше."; fi ;;
      3)
        ask_brewfile || { pause; continue; }
        if confirm "Установить всё недостающее из $BREWFILE?"; then
          run_brew bundle install --file="$BREWFILE" && ok "Готово." || err "Установка завершилась с ошибками."
          DIRTY=1
        else
          stopped
        fi ;;
      4)
        ask_brewfile || { pause; continue; }
        echo "${I_WAIT}Сравниваю..."
        out=$(brew bundle cleanup --file="$BREWFILE" 2>&1)
        if ! printf '%s' "$out" | grep -q 'Would'; then
          ok "Лишних пакетов нет – установлено ровно то, что в Brewfile."
        else
          printf '%s\n' "$out"
          echo ""
          if confirm_danger "Удалить все перечисленные пакеты? Действие необратимо."; then
            run_brew bundle cleanup --file="$BREWFILE" --force && ok "Лишние пакеты удалены."
            DIRTY=1
          else
            stopped
          fi
        fi ;;
      0|"") return ;;
      *) err "Нет такого пункта: $ANSWER" ;;
    esac
    pause
  done
}

# ══════════════════════════════════════════════════
#  11. Обслуживание
# ══════════════════════════════════════════════════
cleanup_flow() {
  local extra="" out cnt size
  mitem "1) Обычная – старые версии пакетов и устаревший кэш"
  mitem "2) Полная – весь кэш загрузок (--prune=all)"
  ask "Режим [1]: " || return
  [ "$ANSWER" = "2" ] && extra="--prune=all"
  echo "${I_WAIT}Оцениваю объём очистки..."
  out=$(brew cleanup -n $extra 2>&1)
  cnt=$(printf '%s\n' "$out" | grep -c '^Would remove')
  size=$(printf '%s\n' "$out" | sed -n 's/.*approximately \([^ ]*\) of disk space.*/\1/p' | tail -1)
  if [ "$cnt" -eq 0 ] && [ -z "$size" ]; then ok "Очищать нечего."; return; fi
  info "Объектов к удалению: $cnt"
  [ -n "$size" ] && info "Освободится примерно: $size"
  if confirm "Показать список объектов?"; then
    printf '%s\n' "$out" | grep '^Would remove' | sed 's/^Would remove: /   • /'
  fi
  if confirm_danger "Выполнить очистку?"; then
    run_brew cleanup $extra && ok "Очистка завершена."
  else
    stopped
  fi
}

disk_usage() {
  local d
  echo "${I_WAIT}Подсчёт размера..."
  d=$(brew --cellar 2>/dev/null)
  [ -d "$d" ] && echo "   • Формулы ($d): $(du -sh "$d" 2>/dev/null | cut -f1)"
  if [ "$IS_MAC" -eq 1 ]; then
    d=$(brew --caskroom 2>/dev/null)
    [ -d "$d" ] && echo "   • Приложения cask ($d): $(du -sh "$d" 2>/dev/null | cut -f1)"
  fi
  d=$(brew --cache 2>/dev/null)
  [ -d "$d" ] && echo "   • Кэш загрузок ($d): $(du -sh "$d" 2>/dev/null | cut -f1)"
  info "Размер приложений в /Applications сюда не входит."
}

maint_menu() {
  local out
  while true; do
    echo ""
    section "${I_CLEAN}Обслуживание и очистка"
    mitem "1) Диагностика проблем (brew doctor)"
    mitem "2) Очистка старых версий и кэша (brew cleanup)"
    mitem "3) Удаление ненужных зависимостей (brew autoremove)"
    mitem "4) Поиск отсутствующих зависимостей (brew missing)"
    mitem "5) Занимаемое место на диске"
    mitem "6) Конфигурация Homebrew (brew config)"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Пункт: " || return
    echo ""
    case "$ANSWER" in
      1) echo "${I_WAIT}Проверяю..."; run_brew doctor && ok "Проблем не найдено." ;;
      2) cleanup_flow ;;
      3) autoremove_offer ;;
      4)
        out=$(brew missing 2>&1)
        if [ -z "$out" ]; then
          ok "Все зависимости на месте."
        else
          printf '%s\n' "$out"
          confirm "Переустановить недостающие зависимости?" && run_brew install $(printf '%s\n' "$out" | sed 's/^[^:]*: //' | tr ' ' '\n' | sort -u) && DIRTY=1
        fi ;;
      5) disk_usage ;;
      6) run_brew config ;;
      0|"") return ;;
      *) err "Нет такого пункта: $ANSWER" ;;
    esac
    pause
  done
}

# ══════════════════════════════════════════════════
#  12. Режим выбора (fzf / номера)
# ══════════════════════════════════════════════════
toggle_fzf() {
  echo ""
  if ! command -v fzf >/dev/null 2>&1; then
    warn "Утилита fzf не установлена."
    info "fzf – интерактивный выбор из списка: поиск по мере ввода, отметка нескольких пунктов клавишей Tab, справа – brew info по выбранному пакету."
    if confirm "Установить fzf через Homebrew?"; then
      if run_brew install fzf; then USE_FZF=1; DIRTY=1; ok "fzf установлен, режим выбора: fzf."; fi
    else
      stopped
    fi
  else
    if [ "$USE_FZF" -eq 1 ]; then USE_FZF=0; ok "Режим выбора: по номерам."; else USE_FZF=1; ok "Режим выбора: fzf."; fi
  fi
  pause
}

# ══════════════════════════════════════════════════
#  Самоустановка и справка
# ══════════════════════════════════════════════════
# ══════════════════════════════════════════════════
#  13. Обновление самого brewman из приватного репозитория GitHub
# ══════════════════════════════════════════════════

# Запуск команды с ограничением по времени (в macOS нет утилиты timeout).
# $1 – секунды, далее команда. Код 124 – превышено время.
with_timeout() {
  local t="$1" pid i=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((t * 10)) ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid"
}

# Сравнение версий: код 0, если $1 новее $2
version_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); k = (n > m ? n : m)
    for (i = 1; i <= k; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 1 }'
}

fmt_epoch() {
  date -r "$1" '+%d.%m.%Y %H:%M' 2>/dev/null || date -d "@$1" '+%d.%m.%Y %H:%M' 2>/dev/null || echo "$1"
}

# Токен доступа: переменная BREWMAN_GITHUB_TOKEN или связка ключей macOS (служба brewman-github)
update_token() {
  if [ -n "${BREWMAN_GITHUB_TOKEN:-}" ]; then printf '%s' "$BREWMAN_GITHUB_TOKEN"; return 0; fi
  if command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$UPDATE_KEYCHAIN" -w 2>/dev/null && return 0
  fi
  return 1
}

# Способ доступа к репозиторию: gh | token | none
update_access() {
  if command -v gh >/dev/null 2>&1 && with_timeout 10 gh auth status >/dev/null 2>&1; then
    echo "gh"
  elif update_token >/dev/null 2>&1; then
    echo "token"
  else
    echo "none"
  fi
}

access_label() {
  case "$1" in
    gh) echo "утилита gh" ;;
    token) echo "токен доступа" ;;
    *) echo "не настроен" ;;
  esac
}

# Скачать файл из репозитория в stdout. $1 – путь к файлу в репозитории.
remote_get() {
  local path="$1" tok
  case "$UPDATE_METHOD" in
    gh)
      gh api -H "Accept: application/vnd.github.raw" "repos/$UPDATE_REPO/contents/$path?ref=$UPDATE_BRANCH" ;;
    token)
      tok=$(update_token) || return 1
      # Токен передаётся через stdin, чтобы не светиться в списке процессов
      printf 'header = "Authorization: Bearer %s"\n' "$tok" |
        curl -fsSL --max-time 60 -K - -H "Accept: application/vnd.github.raw" \
          "https://api.github.com/repos/$UPDATE_REPO/contents/$path?ref=$UPDATE_BRANCH" ;;
    *) return 1 ;;
  esac
}

# Проверка новой версии. $1=1 – тихий режим. Результат в REMOTE_VERSION.
# Код 0 – есть новее, 1 – установлена последняя, 2 – проверить не удалось.
update_check() {
  local quiet="${1:-0}" tmp
  REMOTE_VERSION=""
  mkdir -p "$DATA_DIR" 2>/dev/null
  date +%s > "$DATA_DIR/last_check" 2>/dev/null
  UPDATE_METHOD=$(update_access)
  if [ "$UPDATE_METHOD" = "none" ]; then
    [ "$quiet" -eq 1 ] || warn "Доступ к репозиторию $UPDATE_REPO не настроен."
    return 2
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/brewman.XXXXXX")
  if ! with_timeout 20 remote_get VERSION > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    [ "$quiet" -eq 1 ] || err "Не удалось получить версию из $UPDATE_REPO (нет сети или доступа к репозиторию)."
    return 2
  fi
  REMOTE_VERSION=$(tr -d '[:space:]' < "$tmp")
  rm -f "$tmp"
  case "$REMOTE_VERSION" in
    ''|*[!0-9.]*)
      [ "$quiet" -eq 1 ] || err "В репозитории некорректный номер версии: «$REMOTE_VERSION»."
      REMOTE_VERSION=""
      return 2 ;;
  esac
  version_gt "$REMOTE_VERSION" "$VERSION"
}

# Изменения новее версии $1 из журнала CHANGELOG.md репозитория
show_changes() {
  local since="$1" log
  log=$(with_timeout 20 remote_get CHANGELOG.md 2>/dev/null) || return 0
  [ -n "$log" ] || return 0
  printf '%s\n' "$log" | awk -v cur="$since" '
    function gt(a, b,   x, y, n, m, k, i) {
      n = split(a, x, "."); m = split(b, y, "."); k = (n > m ? n : m)
      for (i = 1; i <= k; i++) { if (x[i] + 0 > y[i] + 0) return 1; if (x[i] + 0 < y[i] + 0) return 0 }
      return 0 }
    /^## / { show = gt($2, cur) }
    show && NF { sub(/^## /, ""); print "   " $0 }'
}

# Установка новой версии. $1=1 – перезапустить brewman после обновления.
update_apply() {
  local restart="${1:-0}" tmpd new_ver dest="$INSTALL_DIR/$APP_NAME"
  [ -n "$REMOTE_VERSION" ] || { err "Сначала нужна проверка версии."; return 1; }
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/brewman.XXXXXX")

  step "Шаг 1: загрузка brewman $REMOTE_VERSION"
  if ! with_timeout 60 remote_get brewman.sh > "$tmpd/brewman" 2> "$tmpd/err"; then
    err "Не удалось скачать файл."
    sed 's/^/   /' "$tmpd/err"
    rm -rf "$tmpd"
    return 1
  fi
  ok "Загружено: $(wc -c < "$tmpd/brewman" | tr -d ' ') байт."
  echo ""

  step "Шаг 2: проверка файла"
  if ! bash -n "$tmpd/brewman" 2>/dev/null; then
    err "В загруженном файле синтаксические ошибки – обновление отменено."
    rm -rf "$tmpd"; return 1
  fi
  if ! grep -q '^APP_NAME="brewman"$' "$tmpd/brewman"; then
    err "Загруженный файл не похож на brewman – обновление отменено."
    rm -rf "$tmpd"; return 1
  fi
  new_ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$tmpd/brewman" | head -1)
  if [ "$new_ver" != "$REMOTE_VERSION" ]; then
    err "Версия в файле ($new_ver) не совпадает с объявленной ($REMOTE_VERSION) – обновление отменено."
    rm -rf "$tmpd"; return 1
  fi
  ok "Файл в порядке, версия $new_ver."
  echo ""

  step "Шаг 3: установка"
  mkdir -p "$INSTALL_DIR" "$DATA_DIR"
  if [ -f "$dest" ]; then
    cp "$dest" "$DATA_DIR/brewman.prev" && info "Предыдущая версия сохранена – вернуть её можно командой brewman --rollback."
  fi
  # Замена через mv: запущенная копия продолжает читать старый файл и не ломается
  if cp "$tmpd/brewman" "$dest.new" && chmod +x "$dest.new" && mv -f "$dest.new" "$dest"; then
    ok "brewman обновлён: $VERSION ${I_ARR}$new_ver ($dest)"
    rm -f "$DATA_DIR/skip_version"
  else
    rm -f "$dest.new"
    err "Не удалось записать $dest."
    rm -rf "$tmpd"; return 1
  fi
  rm -rf "$tmpd"
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) warn "Папки $INSTALL_DIR нет в PATH – запустите bash \"$dest\" --install, чтобы это исправить." ;;
  esac
  if [ "$restart" -eq 1 ]; then
    echo ""
    echo "${I_UPD}Перезапускаю brewman..."
    rm -rf "$SESSION_DIR"
    exec bash "$dest"
  fi
  return 0
}

update_rollback() {
  local prev="$DATA_DIR/brewman.prev" dest="$INSTALL_DIR/$APP_NAME" pv cv tmp
  if [ ! -f "$prev" ]; then info "Резервной копии нет – откатываться не на что."; return 1; fi
  pv=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$prev" | head -1)
  cv=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$dest" 2>/dev/null | head -1)
  info "Установлена: ${cv:-нет}, резервная копия: ${pv:-неизвестно}"
  if ! bash -n "$prev" 2>/dev/null; then err "Резервная копия повреждена."; return 1; fi
  if ! confirm_danger "Вернуть версию ${pv:-из резервной копии}?"; then stopped; return 1; fi
  tmp="$DATA_DIR/brewman.swap"
  [ -f "$dest" ] && cp "$dest" "$tmp"
  if cp "$prev" "$dest.new" && chmod +x "$dest.new" && mv -f "$dest.new" "$dest"; then
    [ -f "$tmp" ] && mv -f "$tmp" "$prev"
    ok "Возвращена версия $pv. Отменить откат можно повторной командой brewman --rollback."
    # Автопроверка не будет предлагать версию, от которой откатились
    [ -n "$cv" ] && echo "$cv" > "$DATA_DIR/skip_version"
    return 0
  fi
  rm -f "$dest.new" "$tmp"
  err "Не удалось выполнить откат."
  return 1
}

# Настройка доступа к приватному репозиторию
update_access_setup() {
  local m
  echo ""
  section "${I_LOCK}Доступ к репозиторию $UPDATE_REPO"
  info "Репозиторий приватный, поэтому для скачивания обновлений нужен вход в GitHub."
  mitem "1) Через утилиту gh – официальный клиент GitHub (рекомендуется)"
  mitem "2) Через токен доступа с правом только на чтение этого репозитория"
  mitem "0) ${I_BACK}Назад"
  echo "$LINE1"
  ask "Способ: " || return 1
  echo ""
  case "$ANSWER" in
    1)
      if ! command -v gh >/dev/null 2>&1; then
        warn "Утилита gh не установлена."
        if confirm "Установить gh через Homebrew?"; then
          run_brew install gh || { err "Не удалось установить gh."; return 1; }
        else
          stopped; return 1
        fi
      fi
      if with_timeout 10 gh auth status >/dev/null 2>&1; then
        ok "gh уже авторизован в GitHub."
      else
        info "Сейчас запустится вход в GitHub. Выберите: GitHub.com ➡️ HTTPS ➡️ Login with a web browser."
        info "Войдите под аккаунтом, у которого есть доступ к $UPDATE_REPO."
        gh auth login || { err "Вход не выполнен."; return 1; }
      fi ;;
    2)
      info "Создайте токен: https://github.com/settings/personal-access-tokens/new"
      echo "   • Repository access: Only select repositories ➡️ brewman"
      echo "   • Permissions ➡️ Repository permissions ➡️ Contents: Read-only"
      echo "   • Срок действия – на ваше усмотрение; по истечении токен нужно будет заменить."
      if [ "$IS_MAC" -eq 1 ] && command -v security >/dev/null 2>&1; then
        info "Токен сохранится в связке ключей macOS (служба $UPDATE_KEYCHAIN). Вставьте его дважды, символы не отображаются."
        security add-generic-password -U -a "$USER" -s "$UPDATE_KEYCHAIN" -w || { err "Токен не сохранён."; return 1; }
        ok "Токен сохранён."
      else
        info "Добавьте в файл настроек оболочки строку и откройте новое окно терминала:"
        echo "   export BREWMAN_GITHUB_TOKEN=\"ваш_токен\""
        return 0
      fi ;;
    *) return 1 ;;
  esac
  echo ""
  echo "${I_WAIT}Проверяю доступ к $UPDATE_REPO..."
  m=$(update_access)
  UPDATE_METHOD="$m"
  if [ "$m" != "none" ] && with_timeout 20 remote_get VERSION >/dev/null 2>&1; then
    ok "Доступ есть ($(access_label "$m"))."
    return 0
  fi
  err "Доступа к $UPDATE_REPO нет. Проверьте аккаунт gh или права токена."
  return 1
}

# Проверка при запуске – не чаще раза в сутки
auto_update_check() {
  local last now rc skip
  [ -n "${BREWMAN_NO_UPDATE_CHECK:-}" ] && return 0
  [ -f "$DATA_DIR/no_autocheck" ] && return 0
  last=$(cat "$DATA_DIR/last_check" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  now=$(date +%s)
  [ $((now - last)) -lt 86400 ] && return 0

  step "Шаг 3: проверка обновлений brewman"
  update_check 1
  rc=$?
  case "$rc" in
    0)
      skip=$(cat "$DATA_DIR/skip_version" 2>/dev/null)
      if [ "$skip" = "$REMOTE_VERSION" ]; then
        info "Доступна версия $REMOTE_VERSION, от которой вы откатились, – пропускаю."
      else
        warn "Доступна новая версия brewman: $VERSION ${I_ARR}$REMOTE_VERSION"
        show_changes "$VERSION"
        if confirm "Обновить сейчас?"; then
          echo ""
          update_apply 1
        else
          info "Обновиться можно позже: пункт 13 главного меню или команда brewman --update."
        fi
      fi ;;
    1) ok "Установлена последняя версия ($VERSION)." ;;
    *)
      if [ "$UPDATE_METHOD" = "none" ]; then
        info "Проверка обновлений не настроена – пункт 13 главного меню."
      else
        info "Проверить обновления не удалось – попробую завтра."
      fi ;;
  esac
  echo ""
}

selfupdate_menu() {
  local last ac rc
  while true; do
    last=$(cat "$DATA_DIR/last_check" 2>/dev/null)
    ac="вкл"; [ -f "$DATA_DIR/no_autocheck" ] && ac="выкл"
    echo ""
    section "${I_UPD}Обновление brewman"
    echo "   Установленная версия: $VERSION"
    echo "   Репозиторий: $UPDATE_REPO (приватный)"
    echo "   Последняя проверка: $( [ -n "$last" ] && fmt_epoch "$last" || echo "ещё не было")"
    echo "$LINE1"
    mitem "1) Проверить наличие новой версии"
    mitem "2) Обновить brewman"
    mitem "3) Откатиться на предыдущую версию"
    mitem "4) Журнал изменений"
    mitem "5) Автопроверка при запуске (раз в сутки): $ac"
    mitem "6) Настроить доступ к GitHub"
    mitem "0) ${I_BACK}Назад"
    echo "$LINE1"
    ask "Пункт: " || return
    echo ""
    case "$ANSWER" in
      1|2)
        echo "${I_WAIT}Проверяю $UPDATE_REPO..."
        update_check 0
        rc=$?
        case "$rc" in
          0)
            warn "Доступна новая версия: $VERSION ${I_ARR}$REMOTE_VERSION"
            show_changes "$VERSION"
            if [ "$ANSWER" = "2" ] || confirm "Обновить сейчас?"; then
              echo ""
              update_apply 1
            fi ;;
          1) ok "Установлена последняя версия ($VERSION)." ;;
          *) [ "$UPDATE_METHOD" = "none" ] && confirm "Настроить доступ сейчас?" && update_access_setup ;;
        esac ;;
      3)
        if update_rollback; then
          echo ""
          info "Перезапускаю brewman..."
          rm -rf "$SESSION_DIR"
          exec bash "$INSTALL_DIR/$APP_NAME"
        fi ;;
      4)
        UPDATE_METHOD=$(update_access)
        if [ "$UPDATE_METHOD" = "none" ]; then
          warn "Доступ к репозиторию не настроен – пункт 6."
        else
          echo "${I_WAIT}Загружаю журнал..."
          with_timeout 20 remote_get CHANGELOG.md 2>/dev/null | sed 's/^/   /' || err "Не удалось загрузить журнал."
        fi ;;
      5)
        mkdir -p "$DATA_DIR"
        if [ -f "$DATA_DIR/no_autocheck" ]; then
          rm -f "$DATA_DIR/no_autocheck"; ok "Автопроверка включена."
        else
          touch "$DATA_DIR/no_autocheck"; ok "Автопроверка выключена. Проверять можно вручную – пункт 1."
        fi ;;
      6) update_access_setup ;;
      0|"") return ;;
      *) err "Нет такого пункта: $ANSWER" ;;
    esac
    pause
  done
}

# Обновление из командной строки: brewman --update
cli_update() {
  local rc
  title "${I_UPD}Обновление brewman"
  echo "${I_WAIT}Проверяю $UPDATE_REPO..."
  update_check 0
  rc=$?
  case "$rc" in
    0)
      warn "Доступна новая версия: $VERSION ${I_ARR}$REMOTE_VERSION"
      show_changes "$VERSION"
      echo ""
      if confirm "Обновить?"; then update_apply 0 || return 1; else stopped; fi ;;
    1) ok "Установлена последняя версия ($VERSION)." ;;
    *)
      if [ "$UPDATE_METHOD" = "none" ] && confirm "Настроить доступ к GitHub сейчас?"; then
        update_access_setup && cli_update
        return $?
      fi
      return 1 ;;
  esac
  echo ""
  echo "${I_DONE}Готово."
  echo ""
}

usage() {
  cat <<'USAGE_TEXT'

brewman – интерактивный менеджер Homebrew

Использование:
  brewman              запуск интерактивного меню
  brewman --install    установить brewman как команду (~/.local/bin/brewman)
  brewman --remove     удалить установленную команду
  brewman --update     проверить и установить новую версию brewman
  brewman --rollback   вернуть предыдущую версию brewman
  brewman --help       эта справка
  brewman --version    версия

Переменные окружения:
  BREWMAN_NO_CLEAR=1   не очищать экран перед главным меню
  BREWMAN_NO_FZF=1     не использовать fzf, даже если он установлен
  NO_COLOR=1           вывод без цветов
  BREWMAN_NO_UPDATE_CHECK=1   не проверять обновления brewman при запуске
  BREWMAN_GITHUB_TOKEN=…      токен доступа к приватному репозиторию (вместо gh)

USAGE_TEXT
}

self_install() {
  local src="$0" dest="$INSTALL_DIR/$APP_NAME" rc
  case "$src" in /*) ;; *) src="$PWD/$src" ;; esac
  title "${I_PKG}Установка brewman как команды"

  step "Шаг 1: копирование файла"
  info "Источник: $src"
  info "Назначение: $dest"
  if [ -e "$dest" ] && [ "$src" -ef "$dest" ]; then
    ok "Эта копия уже установлена."
  else
    [ -e "$dest" ] && warn "Файл уже существует – будет заменён этой версией."
    if ! confirm "Продолжить?"; then stopped; return 0; fi
    if mkdir -p "$INSTALL_DIR" && cp "$src" "$dest" && chmod +x "$dest"; then
      ok "Скопировано."
    else
      err "Не удалось скопировать файл."
      return 1
    fi
  fi
  echo ""

  step "Шаг 2: проверка PATH"
  case ":$PATH:" in
    *":$INSTALL_DIR:"*)
      ok "Папка $INSTALL_DIR уже в PATH." ;;
    *)
      case "${SHELL##*/}" in
        zsh) rc="$HOME/.zshrc" ;;
        bash) if [ "$(uname -s)" = "Darwin" ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
        *) rc="$HOME/.profile" ;;
      esac
      if grep -qs '\.local/bin' "$rc"; then
        info "В $rc уже есть строка с .local/bin – откройте новое окно терминала."
      elif confirm "Добавить $INSTALL_DIR в PATH (файл $rc)?"; then
        printf '\n# brewman\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
        ok "Добавлено в $rc. Откройте новое окно терминала."
      else
        warn "PATH не изменён – запускайте по полному пути: $dest"
      fi ;;
  esac
  echo ""
  echo "${I_DONE}Готово. Команда для запуска: ${C_B}$APP_NAME${C_0}"
  echo ""
}

self_remove() {
  local dest="$INSTALL_DIR/$APP_NAME"
  echo ""
  if [ ! -e "$dest" ]; then info "Команда не установлена ($dest не найден)."; echo ""; return 0; fi
  if confirm_danger "Удалить $dest?"; then
    rm -f "$dest" && ok "Удалено." && info "Строку PATH в файле настроек оболочки можно оставить – она ничему не мешает."
  else
    stopped
  fi
  echo ""
}

# ══════════════════════════════════════════════════
#  Запуск: проверки и главное меню
# ══════════════════════════════════════════════════
load_brew_env() {
  local p
  command -v brew >/dev/null 2>&1 && return 0
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
    if [ -x "$p" ]; then eval "$("$p" shellenv)"; return 0; fi
  done
  return 1
}

startup_checks() {
  local script
  title "${I_BEER}Brewman – менеджер Homebrew"

  step "Шаг 1: проверка Homebrew"
  if ! load_brew_env; then
    warn "Homebrew не найден."
    if ! confirm "Установить Homebrew официальным скриптом с brew.sh?"; then
      stopped "Без Homebrew работа невозможна. Выход."
      return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then err "Для установки нужен curl."; return 1; fi
    echo "${I_WAIT}Загружаю установщик..."
    script=$(curl -fsSL --max-time 60 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)
    if [ -z "$script" ]; then err "Не удалось загрузить установщик. Проверьте сеть."; return 1; fi
    /bin/bash -c "$script"
    if ! load_brew_env; then err "Homebrew так и не найден после установки."; return 1; fi
    ok "Homebrew установлен."
    info "Чтобы brew работал в новых окнах терминала, выполните команды из блока «Next steps» выше."
  fi
  BREW_VER=$(brew --version 2>/dev/null | head -1 | awk '{print $2}')
  ok "Homebrew $BREW_VER ($(brew --prefix))"
  [ "$(uname -s)" = "Darwin" ] && IS_MAC=1
  echo ""

  step "Шаг 2: дополнительные утилиты"
  if [ -z "${BREWMAN_NO_FZF:-}" ] && command -v fzf >/dev/null 2>&1; then
    USE_FZF=1
    ok "fzf найден – выбор из списков через fzf."
  else
    info "Выбор из списков по номерам (fzf можно включить в пункте 12)."
  fi
  echo ""

  auto_update_check
}

refresh_stats() {
  [ "$DIRTY" -eq 1 ] || return 0
  CNT_F=$(brew list --formula -1 2>/dev/null | wc -l | tr -d ' ')
  if [ "$IS_MAC" -eq 1 ]; then
    CNT_C=$(caskroom_list 2>/dev/null | wc -l | tr -d ' ')
  else
    CNT_C="только macOS"
  fi
  DIRTY=0
}

quit() {
  echo ""
  echo "${I_DONE}Готово. До встречи!"
  echo ""
  exit 0
}

main_loop() {
  local mode first=1
  while true; do
    refresh_stats
    [ "$first" -eq 0 ] && clear_screen
    first=0
    mode="номера"; [ "$USE_FZF" -eq 1 ] && mode="fzf"
    title "${I_BEER}Brewman – менеджер Homebrew  ${C_D}v$VERSION${C_0}"
    echo "  Homebrew $BREW_VER  │  Формулы: $CNT_F  │  Приложения: $CNT_C  │  Выбор: $mode"
    echo ""
    section "${I_LIST}Главное меню"
    mitem " 1) ${I_LIST}Установленные пакеты"
    mitem " 2) ${I_SEARCH}Поиск и установка"
    mitem " 3) ${I_PKG}Установка по названию"
    mitem " 4) ${I_DEL}Удаление"
    mitem " 5) ${I_UPD}Обновления"
    mitem " 6) ${I_INFO}Информация о пакете"
    mitem " 7) ${I_SVC}Сервисы"
    mitem " 8) ${I_PIN}Закрепление версий (pin)"
    mitem " 9) ${I_TAP}Репозитории (tap) и доверие"
    mitem "10) ${I_SAVE}Brewfile: резервная копия и восстановление"
    mitem "11) ${I_CLEAN}Обслуживание и очистка"
    mitem "12) ${I_MODE}Режим выбора: fzf или номера"
    mitem "13) ${I_UPD}Обновление brewman"
    mitem " 0) ${I_EXIT}Выход"
    echo "$LINE1"
    if ! ask "Пункт меню: "; then
      [ "$ASK_RC" -eq 1 ] && quit
      continue
    fi
    case "$ANSWER" in
      1) installed_menu ;;
      2) search_menu ;;
      3) install_by_name ;;
      4) uninstall_menu ;;
      5) updates_menu ;;
      6) info_menu ;;
      7) services_menu ;;
      8) pin_menu ;;
      9) taps_menu ;;
      10) brewfile_menu ;;
      11) maint_menu ;;
      12) toggle_fzf ;;
      13) selfupdate_menu ;;
      0|q|Q|й|Й|exit|выход) quit ;;
      "") ;;
      *) err "Нет такого пункта: $ANSWER"; sleep 1 ;;
    esac
  done
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -v|--version) echo "$APP_NAME $VERSION"; exit 0 ;;
  --install) self_install; exit $? ;;
  --remove) self_remove; exit 0 ;;
  --update|--rollback)
    [ "$(uname -s)" = "Darwin" ] && IS_MAC=1
    load_brew_env
    if [ "$1" = "--update" ]; then
      cli_update; exit $?
    fi
    echo ""
    update_rollback; rc=$?; echo ""; exit $rc ;;
  "") ;;
  *) err "Неизвестный параметр: $1"; usage; exit 1 ;;
esac

startup_checks || exit 1
main_loop
