<p align="center"><img src="assets/logo.png" width="140" alt="RB"></p>

# setup-caddy

Скрипт подготовки ноды **Remnawave** к работе за **Caddy**. Запускается один раз на сервере ноды и готовит всё, что нужно для дополнительных транспортов рядом с VLESS Reality на 443/tcp.

## Что делает

- Проверяет, что контейнер ноды запущен, 443/tcp слушается и `/dev/shm` проброшен в контейнер.
- Открывает в UFW порты выбранных транспортов и предупреждает, если порт занят чужим процессом (Caddy по умолчанию занимает 443/udp под HTTP/3).
- Для Hysteria2 находит сертификат Caddy (в Docker или на хосте) либо Let's Encrypt и кладёт его в `/dev/shm`.

| Транспорт | Порт |
|---|---|
| Hysteria2 | 443/udp |
| VLESS gRPC + Reality | 8443/tcp |
| VLESS XHTTP + Reality | 4443/tcp |

## Как работает сертификат

Скрипт ставит `/usr/local/sbin/remnanode-hy2-certsync` и задачу cron (при загрузке и каждый день в 04:00). Он сравнивает сертификат с копией в `/dev/shm` и перезапускает контейнер ноды **только если сертификат изменился**.

## Запуск

```bash
sudo bash setup-caddy.sh
```

Сертификат можно указать вручную, а имя контейнера — сменить:

```bash
CERT_PATH=/путь/fullchain.pem KEY_PATH=/путь/privkey.pem NODE_CONTAINER=remnanode sudo -E bash setup-caddy.sh
```

Требования: root, Docker, работающая нода Remnawave (контейнер `remnanode`), `ss`. UFW — по желанию.

## Чего скрипт не делает

Inbound'ы он не создаёт: их добавляют в Config Profile ноды в панели Remnawave, затем создают Host для каждого транспорта и включают inbound'ы в Squad.

---

Автор: РБ
