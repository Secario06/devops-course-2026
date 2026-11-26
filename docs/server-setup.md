# Настройка сервера devops-vm

## 1. Параметры машины
- Гипервизор: VirtualBox, виртуальная машина `devops-vm`
- ОС: Ubuntu 26.04.1 LTS (amd64)
- Ресурсы: ОЗУ 2048 МБ, процессоров: 2, корневой том LVM 12 ГБ
- Имя узла: `devops-vm`, полное имя (FQDN): `devops-vm.devops.local`

## 2. Сетевые интерфейсы
| Интерфейс | Режим | Адрес |
|-----------|-------|-------|
| enp0s3 | NAT | 10.0.2.15/24 |
| enp0s8 | Host-only | 192.168.56.103/24 |

Имя `devops.local` прописано в файле hosts на хосте и указывает на 192.168.56.103.

## 3. Проброс портов
NAT-правило VirtualBox: `ssh`, TCP, 127.0.0.1:2222 → гостевой порт 2222.

## 4. Учётные записи
- `devops`: рабочая учётная запись администратора (входит в группу sudo), вход по ключу.
- Вход `root` по SSH запрещён (`PermitRootLogin no`).

## 5. SSH
Файл `/etc/ssh/sshd_config.d/99-hardening.conf`:
- `Port 2222`
- `PermitRootLogin no`
- `PasswordAuthentication no`
- `MaxAuthTries 3`
- `AllowUsers devops`

Активация через `ssh.socket` отключена, служба слушает порт 2222 напрямую.

## 6. Правила UFW
Политика по умолчанию: входящие запрещены, исходящие разрешены.

| Порт | Действие | Назначение |
|------|----------|------------|
| 2222/tcp | LIMIT IN | SSH с ограничением частоты подключений |
| 80/tcp | ALLOW IN | HTTP (перенаправление на HTTPS) |
| 443/tcp | ALLOW IN | HTTPS |

## 7. Снимки
- `01-clean-install`: чистая установка
- `02-keys-configured`: настроен вход по ключам
- `03-ssh-hardened`: SSH ужесточён, настроен ufw
- `04-nginx-https`: веб-сервер с HTTPS

## 8. Веб-сервер
- Пакет: `nginx` 1.28.3 (Ubuntu), служба `nginx.service`, процесс-мастер от root, рабочие процессы от `www-data`.
- Конфигурация сайта: `/etc/nginx/sites-available/devops-site`, включена ссылкой в `sites-enabled`; сайт по умолчанию отключён. Применение: `sudo nginx -t && sudo systemctl reload nginx`.
- Каталог сайта: `/var/www/devops-site`, владелец `devops:devops`, права каталога 755, файлов 644 (`www-data` только читает).
- Сертификат: `/etc/ssl/certs/devops.crt` (root:root, 644), `CN=devops.local`, самоподписанный с SAN, срок действия с 29.10.2026 по 29.10.2027 (365 дней).
- Закрытый ключ: `/etc/ssl/private/devops.key`, root:root, права 600; каталог `/etc/ssl/private` 700.
- Генерация: `openssl req -x509 -nodes -newkey rsa:2048 -days 365 -keyout /etc/ssl/private/devops.key -out /etc/ssl/certs/devops.crt -subj "/CN=devops.local" -addext "subjectAltName=DNS:devops.local"`
- Протоколы: TLS 1.2 и 1.3. HTTP на порту 80 перенаправляется на HTTPS кодом 301. HSTS не включён.
- Журналы: `/var/log/nginx/devops-site.access.log` и `devops-site.error.log`.
- Доставка содержимого: `scripts/deploy.sh` (rsync с `--delete --chmod=D755,F644`, проверка доступности по HTTPS после доставки).
- Проверка состояния: `sudo ./scripts/audit.sh`, раздел `[4] Веб-сервер`.

## 9. Контейнеризация
- Docker Engine: установлен из официального репозитория Docker (`download.docker.com`, источник `/etc/apt/sources.list.d/docker.sources`, ключ `/etc/apt/keyrings/docker.asc`). Пакеты: `docker-ce` 29.9.2, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` 5.6.1. Пакет `docker.io` из репозитория дистрибутива не используется. Служба `docker.service` включена.
- Группа `docker`: участник только `devops` (учётная запись имеет право sudo). Членство в группе равносильно правам root, поэтому в неё включаются только учётные записи с sudo.
- Проект на сервере: `/home/devops/app` (`~/app`); исходный код хранится в каталоге `app/` репозитория и доставляется командой `rsync -avz --delete --chmod=D755,F644 --exclude=.env app/ devops:app/`.
- Файл `.env`: `/home/devops/app/.env`, владелец `devops:devops`, права 600. Содержит `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` (случайный, `openssl rand -hex 16`) и `DB_HOST=db`. В репозиторий не добавляется (запись в `.gitignore`), шаблон хранится в `app/.env.example`.
- Сервисы Compose: `app` (образ `devops-app:1.0`, собирается из `app/Dockerfile`, процесс `gunicorn` от пользователя `app`, uid 999) и `db` (`postgres:16-alpine`, проверка готовности `pg_isready`).
- Публикуемые порты: приложение `127.0.0.1:5000 -> 5000/tcp`; порт СУБД (5432) не публикуется и доступен только внутри сети проекта. Прямого доступа к приложению из сети нет.
- Сеть: `app_backend` (bridge); приложение обращается к СУБД по имени сервиса `db`.
- Именованные тома: `app_db_data`, подключён к `/var/lib/postgresql/data` (данные СУБД); сохраняется при `docker compose down`, удаляется при `docker compose down -v`.
- Обратный прокси-сервер: в блок HTTPS файла `/etc/nginx/sites-available/devops-site` добавлено `location /app/ { proxy_pass http://127.0.0.1:5000/; ... }` с заголовками `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`; статический ресурс по адресу `/` сохранён. При остановке приложения Nginx возвращает 502, запись об этом попадает в `/var/log/nginx/devops-site.error.log`.
- Управление: `cd ~/app && docker compose up -d --build`, `docker compose ps`, `docker compose stop app` и `start app`, `docker compose down`.
- Снимок состояния: `05-docker-compose`.

## 10. Ansible
- Расположение проекта: каталог `ansible/` этого репозитория (ветка `feature/ansible`). Запуск выполняется из каталога `ansible/` на управляющем узле, рабочая копия лежит в файловой системе WSL (`~/devops-course-2026/ansible`), а не на `/mnt/c`, иначе `ansible.cfg` игнорируется.
- Управляющий узел: WSL Ubuntu 26.04, `ansible-core` 2.20.1, `sshpass` 1.10; коллекции из `ansible/requirements.yml`: `ansible.posix` 1.6.2, `community.docker` 4.5.0, `community.general` 9.5.0.
- Управляемый узел: VM `devops-vm` (Ubuntu Server 26.04.1 LTS amd64), Host-only адрес `192.168.56.103`, SSH на порту 22. Исходное состояние: снимок `01-clean-install`.
- Inventory: `inventory/bootstrap.ini` (первичный запуск от `student` по паролю, `--ask-pass --ask-become-pass`) и `inventory/prod.ini` (последующие запуски от `devops` по ключу `~/.ssh/devops_vm`, без интерактивного ввода; выбирается по умолчанию через `ansible.cfg`).
- Учётные записи: `student` — только bootstrap; `devops` — автоматизация, ключ в `/home/devops/.ssh/authorized_keys`, `/etc/sudoers.d/devops` (`NOPASSWD:ALL`, учебное допущение), член группы `docker`.
- Особенность Ubuntu 26.04: `/usr/bin/sudo` указывает на `sudo-rs`, приглашение которого Ansible не распознаёт. В `group_vars/all.yml` задано `ansible_become_exe: sudo.ws` (классический sudo).
- Роли: `base` — проверка ОС, базовые пакеты (`python3-debian`, `python3-requests`), официальный репозиторий Docker (`deb822_repository`), Docker Engine; `ssh` — пользователь `devops`, ключ, sudo, `/etc/ssh/sshd_config.d/00-ansible-hardening.conf` (пароли и root запрещены), UFW (22/tcp, 80/tcp, deny incoming); `nginx` — reverse proxy `/etc/nginx/sites-available/devops-ci-app` на `127.0.0.1:5000`, default site отключён, handlers `nginx -t` → reload; `app` — загрузка образа, контейнер, проверка `/health`.
- `ansible.cfg`: `force_handlers = True`, `host_key_checking = True`, `pipelining = True`.
- Образ: `ghcr.io/secario06/devops-ci-app`, тег — полный SHA `5e0d80cf1f7a0b4c551db096f711bda5c759a2c6` (переменная `app_tag` в `group_vars/all.yml`); `latest` не используется.
- Контейнер: `devops-ci-app`, `restart_policy: unless-stopped`, порт `127.0.0.1:5000 -> 5000/tcp` (только loopback, снаружи доступ через Nginx на 80).
- Health endpoint: `http://127.0.0.1:5000/health` на VM и `http://192.168.56.103/health` снаружи, ответ `{"status":"ok"}`.
- Первичный запуск: `ansible-playbook -i inventory/bootstrap.ini site.yml --ask-pass --ask-become-pass`.
- Повторный запуск/деплой: `ansible-playbook site.yml` (ожидается `changed=0` при отсутствии drift).
- Read-only аудит: `ansible-playbook verify.yml` (sshd -T, состояние контейнера, `/health`; всегда `changed=0`).