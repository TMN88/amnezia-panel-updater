#!/usr/bin/env bash
# Amnezia Web Panel updater for PRVTPRO/Amnezia-Web-Panel.
# Safe-by-default updater for existing Python/venv installations.
set -Eeuo pipefail
umask 077

REPO_URL="https://github.com/PRVTPRO/Amnezia-Web-Panel.git"
REPO_SLUG="PRVTPRO/Amnezia-Web-Panel"
DEFAULT_PROJECT="/root/Amnezia-Web-Panel"
BACKUP_ROOT="/root/Amnezia-Web-Panel-backups"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/amnezia-panel-updater.log"
HEALTH_TIMEOUT=45

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ $EUID -eq 0 ]] || { echo "Запусти от root: sudo bash update.sh" >&2; exit 1; }
mkdir -p "$BACKUP_ROOT" "$LOG_DIR"
touch "$LOG_FILE"

for cmd in git python3 tar curl; do have "$cmd" || die "Не найдена обязательная команда: $cmd"; done

# Resolve project directory. Override with PROJECT_DIR=/path if needed.
PROJECT="${PROJECT_DIR:-$DEFAULT_PROJECT}"
if [[ ! -d "$PROJECT/.git" ]]; then
  # Find a checkout with the expected origin if the default path is absent.
  CANDIDATE=""
  while IFS= read -r gitdir; do
    dir="${gitdir%/.git}"
    origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    if [[ "$origin" == *"$REPO_SLUG"* ]]; then CANDIDATE="$dir"; break; fi
  done < <(find /root /opt /srv -maxdepth 5 -type d -name .git -print 2>/dev/null || true)
  [[ -n "$CANDIDATE" ]] || die "Не найден git-каталог панели. Укажи PROJECT_DIR=/путь/к/Amnezia-Web-Panel."
  PROJECT="$CANDIDATE"
fi
[[ -f "$PROJECT/app.py" ]] || die "В $PROJECT нет app.py; не похоже на исходную Python-установку."
ORIGIN="$(git -C "$PROJECT" remote get-url origin 2>/dev/null || true)"
[[ "$ORIGIN" == *"$REPO_SLUG"* ]] || die "Origin проекта не похож на $REPO_SLUG: $ORIGIN"

cd "$PROJECT"
log "Проект: $PROJECT"
log "Origin: $ORIGIN"

# Detect the environment used by the existing app.py process (preserve its runtime env).
find_panel_pids() {
  local proc pid cwd cmd
  for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    [[ "$pid" != "$$" ]] || continue
    [[ -r "$proc/cmdline" ]] || continue
    cwd="$(readlink -f "$proc/cwd" 2>/dev/null || true)"
    [[ "$cwd" == "$PROJECT" ]] || continue
    cmd="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
    if [[ "$cmd" == *app.py* && "$cmd" == *python* ]]; then echo "$pid"; fi
  done
}
mapfile -t OLD_PIDS < <(find_panel_pids)
MAIN_PID="${OLD_PIDS[0]:-}"
PYTHON="$PROJECT/venv/bin/python"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"

# Grab environment from the first live app process. Sensitive values remain in root-only temp files.
ENV_JSON="$(mktemp /root/.amnezia-panel-env.XXXXXX)"
cleanup() { rm -f "$ENV_JSON"; }
trap cleanup EXIT
if [[ -n "$MAIN_PID" && -r "/proc/$MAIN_PID/environ" ]]; then
  python3 - "$MAIN_PID" "$ENV_JSON" <<'PY'
import json, os, sys
pid, out = sys.argv[1], sys.argv[2]
env = {}
try:
    raw = open(f"/proc/{pid}/environ", "rb").read().split(b"\0")
    for entry in raw:
        if b"=" in entry:
            k, v = entry.split(b"=", 1)
            env[k.decode(errors="replace")] = v.decode(errors="replace")
except Exception:
    pass
with open(out, "w") as f:
    json.dump(env, f)
os.chmod(out, 0o600)
PY
else
  python3 - "$ENV_JSON" "$PROJECT" <<'PY'
import json, os, sys
out, project = sys.argv[1:]
env = dict(os.environ)
env["PWD"] = project
env.setdefault("PATH", project + "/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
env.setdefault("VIRTUAL_ENV", project + "/venv")
with open(out, "w") as f: json.dump(env, f)
os.chmod(out, 0o600)
PY
fi
if [[ -x "$PROJECT/venv/bin/python" ]]; then PYTHON="$PROJECT/venv/bin/python"; fi

# Require a clean tracked worktree before touching source files. Ignore runtime data/logs.
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "В git-рабочем дереве есть tracked-изменения. Сначала проверь: git -C '$PROJECT' status --short"
fi

# Determine the newest stable vX.Y.Z tag from origin; ignore prerelease tags.
log "Получаю список релизов..."
git fetch --tags --force origin
TARGET="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)"
[[ -n "$TARGET" ]] || die "Не удалось определить стабильный тег vX.Y.Z."
PREVIOUS_COMMIT="$(git rev-parse HEAD)"
PREVIOUS_TAG="$(git describe --tags --exact-match HEAD 2>/dev/null || echo 'нет точного тега')"
log "Текущая версия: $PREVIOUS_TAG ($PREVIOUS_COMMIT)"
log "Целевая версия: $TARGET"

if [[ "$(git rev-parse "$TARGET")" == "$PREVIOUS_COMMIT" ]]; then
  log "Уже установлена последняя версия."
  CODE="$(curl --silent --output /dev/null --max-time 5 --write-out '%{http_code}' http://127.0.0.1:5000/login 2>/dev/null || true)"
  [[ "$CODE" =~ ^[1-4][0-9][0-9]$ ]] || die "Версия актуальна, но /login не отвечает на 127.0.0.1:5000. Лог: $LOG_FILE"
  log "Панель отвечает на HTTP ($CODE). Ничего не менял."
  exit 0
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP="$BACKUP_ROOT/panel-backup-$STAMP"
mkdir -p "$BACKUP"
log "Создаю резервную копию в $BACKUP"
# Preserve config/database first; archive everything except git metadata, virtualenv and logs.
[[ -f "$PROJECT/data.json" ]] && cp -a "$PROJECT/data.json" "$BACKUP/data.json"
tar -czf "$BACKUP/project-files.tar.gz" --exclude='./.git' --exclude='./venv' --exclude='./__pycache__' --exclude='./*.log' -C "$PROJECT" .
git -C "$PROJECT" rev-parse HEAD > "$BACKUP/previous-commit.txt"
printf '%s\n' "$TARGET" > "$BACKUP/target-tag.txt"
cp -a "$ENV_JSON" "$BACKUP/runtime-env.json"
chmod 600 "$BACKUP/runtime-env.json"

# Remember Docker container state; we do not stop/recreate any containers.
if have docker; then docker ps --format '{{.Names}} {{.Status}}' | grep -E 'amnezia-awg' > "$BACKUP/vpn-containers.txt" || true; fi

rollback() {
  local reason="$1"
  log "Обновление не прошло проверку: $reason"
  # Stop only Python panel processes whose cwd is this project.
  mapfile -t pids < <(find_panel_pids)
  for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  sleep 2
  git -C "$PROJECT" switch --detach "$PREVIOUS_COMMIT" || die "КРИТИЧНО: автоматический откат Git не удался. Проверь проект вручную: $PROJECT"
  if [[ -f "$PROJECT/requirements.txt" && -x "$PROJECT/venv/bin/python" ]]; then
    "$PROJECT/venv/bin/python" -m pip install -r "$PROJECT/requirements.txt" >> "$LOG_FILE" 2>&1 || log "Зависимости для отката восстановить не удалось."
  fi
  start_panel || log "Не удалось запустить исходную версию; смотри $LOG_FILE."
  die "Выполнен откат к $PREVIOUS_COMMIT. Резервная копия: $BACKUP"
}
start_panel() {
  python3 - "$PROJECT" "$ENV_JSON" "$LOG_FILE" <<'PY'
import json, os, subprocess, sys
project, env_file, log_file = sys.argv[1:]
with open(env_file) as f: env = os.environ.copy() | json.load(f)
env["PWD"] = project
python = os.path.join(project, "venv", "bin", "python")
if not os.path.isfile(python): python = sys.executable
with open(log_file, "ab", buffering=0) as log:
    p = subprocess.Popen([python, "app.py"], cwd=project, env=env,
                         stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True, close_fds=True)
print(p.pid)
PY
}
wait_http() {
  local end=$((SECONDS + HEALTH_TIMEOUT)) code
  while (( SECONDS < end )); do
    code="$(curl --silent --show-error --output /dev/null --max-time 3 --write-out '%{http_code}' 'http://127.0.0.1:5000/login' 2>/dev/null || true)"
    if [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]; then return 0; fi
    sleep 2
  done
  return 1
}

log "Переключаю исходный код на $TARGET"
git switch --detach "$TARGET" >> "$LOG_FILE" 2>&1 || rollback "git switch завершился ошибкой"
[[ -x "$PROJECT/venv/bin/python" ]] || rollback "не найден Python из venv"
"$PROJECT/venv/bin/python" -m pip install -r "$PROJECT/requirements.txt" >> "$LOG_FILE" 2>&1 || rollback "pip install завершился ошибкой"
"$PROJECT/venv/bin/python" -m pip check >> "$LOG_FILE" 2>&1 || rollback "pip check обнаружил конфликт зависимостей"
"$PROJECT/venv/bin/python" -m py_compile "$PROJECT/app.py" >> "$LOG_FILE" 2>&1 || rollback "py_compile не прошёл"

if (("${#OLD_PIDS[@]}" > 0)); then
  log "Останавливаю процесс(ы) панели: ${OLD_PIDS[*]}"
  for p in "${OLD_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  for _ in $(seq 1 15); do
    alive=0
    for p in "${OLD_PIDS[@]}"; do [[ -d "/proc/$p" ]] && alive=1; done
    (( alive == 0 )) && break
    sleep 1
  done
  for p in "${OLD_PIDS[@]}"; do kill -9 "$p" 2>/dev/null || true; done
fi

NEW_PID="$(start_panel)"
log "Запущен процесс панели PID $NEW_PID"
if ! wait_http; then rollback "HTTP-проверка /login на 127.0.0.1:5000 не прошла"
fi

log "Успешно обновлено до $TARGET"
log "Проверка: HTTP /login отвечает. Лог: $LOG_FILE"
log "Резервная копия: $BACKUP"
if have docker; then
  log "Контейнеры amnezia-awg* не останавливались и не пересоздавались."
fi
exit 0
