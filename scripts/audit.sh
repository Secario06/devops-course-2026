#!/usr/bin/env bash
# Аудит конфигурации сервера devops-vm
# Использование: sudo ./audit.sh
# Переменные: CERT_MIN_DAYS (по умолчанию 30), CERT_FILE, KEY_FILE, SITE_DIR
set -u

CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"
CERT_FILE="${CERT_FILE:-/etc/ssl/certs/devops.crt}"
KEY_FILE="${KEY_FILE:-/etc/ssl/private/devops.key}"
SITE_DIR="${SITE_DIR:-/var/www/devops-site}"
FAIL=0

ok()  { echo "  [OK]   $1"; }
bad() { echo "  [FAIL] $1"; FAIL=1; }
check() {
  local desc="$1"; shift
  if "$@"; then ok "${desc}"; else bad "${desc}"; fi
}

if [[ $EUID -ne 0 ]]; then
  echo "Ошибка: запустите скрипт через sudo" >&2
  exit 2
fi

echo "[1] SSH"
SSH_CFG="$(sshd -T)"
port="$(awk '$1=="port"{print $2}' <<<"${SSH_CFG}")"
if [[ "${port}" != "22" ]]; then ok "порт SSH ${port} (не 22)"; else bad "порт SSH равен 22"; fi
tries="$(awk '$1=="maxauthtries"{print $2}' <<<"${SSH_CFG}")"
if [[ "${tries}" == "3" ]]; then ok "MaxAuthTries = 3"; else bad "MaxAuthTries = ${tries}, ожидалось 3"; fi

echo "[2] Файрвол"
if ufw status verbose | grep -q 'Default: deny (incoming)'; then
  ok "ufw: входящие по умолчанию запрещены"
else
  bad "ufw: политика входящих не deny"
fi

echo "[3] Учётные записи"
root_login="$(awk '$1=="permitrootlogin"{print $2}' <<<"${SSH_CFG}")"
if [[ "${root_login}" == "no" ]]; then ok "вход root по SSH запрещён"; else bad "PermitRootLogin = ${root_login}"; fi

echo "[4] Веб-сервер"
if systemctl is-active --quiet nginx; then ok "nginx активен"; else bad "nginx не запущен"; fi
if nginx -t >/dev/null 2>&1; then ok "nginx -t: конфигурация корректна"; else bad "nginx -t: ошибка конфигурации"; fi
if openssl x509 -checkend $(( CERT_MIN_DAYS * 86400 )) -noout -in "${CERT_FILE}" >/dev/null 2>&1; then
  ok "сертификат действителен ещё минимум ${CERT_MIN_DAYS} дн."
else
  bad "сертификат истекает менее чем через ${CERT_MIN_DAYS} дн. (или не читается)"
fi
if [[ -z "$(find "${SITE_DIR}" -perm -o+w 2>/dev/null)" ]]; then
  ok "в ${SITE_DIR} нет файлов, доступных на запись всем"
else
  bad "в ${SITE_DIR} есть файлы, доступные на запись всем"
fi
key_mode="$(stat -c %a "${KEY_FILE}" 2>/dev/null || echo "нет файла")"
if [[ "${key_mode}" == "600" ]]; then ok "права закрытого ключа 600"; else bad "права закрытого ключа ${key_mode}, ожидалось 600"; fi

echo "[5] Контейнеризация"
ENV_FILE="${ENV_FILE:-/home/devops/app/.env}"
db_healthy()    { [[ "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)" == "healthy" ]]; }
ports_local_only() { ! ss -tln | awk 'NR>1 {print $4}' | grep -E ':(5000|5432)$' | grep -qvE '^127\.0\.0\.1:'; }
env_mode_600()  { [[ "$(stat -c '%a' "${ENV_FILE}" 2>/dev/null)" == "600" ]]; }
check "служба docker активна" systemctl is-active --quiet docker
check "контейнер СУБД app-db-1 в состоянии healthy" db_healthy
check "порты 5000 и 5432 не прослушиваются вне 127.0.0.1" ports_local_only
check "права файла ${ENV_FILE} равны 600" env_mode_600

echo
if (( FAIL )); then echo "Итог: есть замечания"; exit 1; fi
echo "Итог: всё в порядке"
