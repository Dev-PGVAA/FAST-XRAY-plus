# FAST-XRAY-plus

Скрипт ставит VPN-сервер на чистый Ubuntu/Debian: Xray-core с VLESS+REALITY и Shadowsocks, по желанию ещё Telegram MTProto, Cloudflare WARP, мониторинг ресурсов и пара вещей для безопасности. Всё выбирается в одном чек-бокс меню — руками ничего в конфигах поправлять не придётся.

## Что ставит

Обязательно: Xray-core с VLESS+REALITY (основной порт и резервный) и Shadowsocks.

По выбору в меню:

- Telegram MTProto (mtg)
- Cloudflare WARP — заворачивает Google-трафик (`geosite:google`) через отдельный outbound. Полезно, если Google определяет вашу локацию неправильно из-за репутации IP-подсети хостера, а не из-за того, где сервер реально зарегистрирован
- Мониторинг: `btop`, `htop`, `iotop`, `ncdu`, `vnstat`, `iftop`
- fail2ban и unattended-upgrades
- BBR — туннель стабильнее держит скорость под нагрузкой

И по умолчанию: отдельный пользователь с sudo, настройка SSH (пароль, ключ или оба варианта), опция отключить root-логин, `ufw` под нужные порты, готовые ссылки для клиентов (`vless://`, `ss://`, `tg://proxy`) и QR-код для MTProto.

## Требования

Чистый VPS на Ubuntu 20.04+ или Debian 11+, root-доступ, публичный IPv4.

## Установка

```bash
curl -O https://raw.githubusercontent.com/DEV-PGVAA/FAST-XRAY-plus/main/setup_vpn.sh
bash setup_vpn.sh
```

Сначала пара вопросов — имя сервера, нужен ли отдельный пользователь, как входить по SSH. Потом открывается чек-бокс меню: по умолчанию отмечено всё, снимайте пробелом что не нужно.

## Компоненты меню

| Компонент | Что делает |
|---|---|
| Telegram MTProto | `mtg` на отдельном порту, плюс ссылка и QR для Telegram |
| Cloudflare WARP | `warp-cli`, outbound в Xray, роутинг Google через WARP, watchdog на переподключение |
| Мониторинг | CPU, RAM, диск, сеть — `btop`/`htop`/`iotop`/`ncdu`/`vnstat`/`iftop` |
| fail2ban | Бан на час после 5 неудачных попыток SSH за 10 минут |
| unattended-upgrades | Security-патчи ставятся сами, без вашего участия |
| BBR | Congestion control для более стабильной скорости туннеля |

## После установки

Ссылки и пароль выводятся один раз в конце установки и сохраняются в `/usr/local/etc/xray/client_configs/README.txt`. Сохраните их сразу — второй раз скрипт их не покажет.

Клиенты: v2RayTun или NekoBox на Android, Streisand или Shadowrocket на iOS, v2RayN или Hiddify на Windows, Hiddify или V2Box на macOS. Вставляете одну ссылку через «Добавить конфиг по ссылке» или весь набор через «Импорт по base64».

## Полезные команды

```bash
systemctl status xray            # статус Xray
systemctl status mtg             # статус MTProto, если включен
warp-cli status                  # статус WARP, если включен
btop                             # монитор CPU/RAM/диск/сеть
journalctl -u xray -n 50         # логи Xray
```

## Безопасность

Root-логин по SSH отключается по умолчанию, `ufw` работает в режиме deny-by-default, fail2ban ставится по желанию. Помимо этого стоит: заходить по SSH-ключу вместо пароля, где это возможно; изредка заглядывать в `journalctl -u fail2ban`, чтобы понимать, сколько сканеров долбится в порт; держать копию `client_configs/README.txt` где-то отдельно от самого сервера.

## Дисклеймер

Скрипт для личного использования в юрисдикциях, где обход сетевых ограничений законен. За соответствие законам своей страны отвечает тот, кто запускает скрипт.

## Лицензия

[MIT](LICENSE)
