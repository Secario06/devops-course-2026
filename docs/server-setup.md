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
