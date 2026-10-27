# 3. Путь 2: мост go2rtc + rtsp-to-onvif

## 3.1. Зачем

- **go2rtc** открывает ровно одну RTSP-сессию на камеру и раздаёт поток
  любому числу потребителей (Protect, Frigate, Home Assistant, VLC). Снимает
  лимит сессий Tapo.
- **rtsp-to-onvif** создаёт по одной виртуальной ONVIF-камере на каждый
  поток, с собственным IP и MAC. UniFi Protect считает каждый ONVIF-сервер
  одной камерой и требует для неё отдельный IP, поэтому обойтись одним
  go2rtc (его встроенный ONVIF-сервер отдаёт все потоки на одном адресе и
  не умеет WS-Discovery) нельзя. rtsp-to-onvif проверен с Protect 5.0.40+.

```
Tapo C200 #1 ──RTSP──▶ go2rtc ──RTSP──▶ rtsp-to-onvif (вирт. IP .60) ──ONVIF──▶ UniFi Protect
Tapo C200 #2 ──RTSP──▶   │    ──RTSP──▶ rtsp-to-onvif (вирт. IP .61) ──ONVIF──▶ UniFi Protect
                         └───RTSP/WebRTC──▶ Frigate, Home Assistant, браузер
```

## 3.2. Требования

- Linux-хост с Docker и Docker Compose в **той же L2-сети (VLAN), что и
  Protect-консоль**, иначе Protect не увидит виртуальные камеры через
  WS-Discovery. Подойдёт любой мини-ПК, Raspberry Pi 4, NAS с Docker.
- Хост подключён **кабелем**: виртуальные MAC на Wi-Fi-интерфейсе
  большинство точек доступа не пропускают.
- Контейнеры работают в `network_mode: host` с `NET_ADMIN` (rtsp-to-onvif
  сам добавляет виртуальные IP на интерфейс `dev`).

## 3.3. Установка

```bash
cd bridge
cp .env.example .env            # вписать IP камер и аккаунт камеры
cp go2rtc/go2rtc.example.yaml go2rtc/go2rtc.yaml
cp rtsp-to-onvif/config.example.yaml rtsp-to-onvif/config.yaml
# в обоих файлах заменить значения-плейсхолдеры (см. комментарии внутри)
docker compose up -d
docker compose logs -f
```

Проверки:

```bash
# go2rtc видит камеры: откройте http://<host>:1984 → Streams, оба online
# RTSP от go2rtc играет:
ffplay rtsp://bridge:bridgepass@<host>:7554/c200_1
# виртуальные IP поднялись:
ip addr show dev eth0 | grep inet
```

## 3.4. Адопт в Protect

1. В UniFi Network → Client Devices должны появиться два новых клиента с
   MAC вида `1A:11:B0:xx:xx:xx` (rtsp-to-onvif генерирует их сам и
   записывает в `config.yaml`; при желании задайте свои LAA-MAC заранее и
   сделайте Fixed IP до первого запуска).
2. Protect → Devices → камеры `TapoHall` и `TapoYard` (имена из
   `config.yaml`) → Adopt. Логин и пароль: **те, что заданы в секции `rtsp:`
   файла go2rtc.yaml** (`bridge` / `bridgepass` в примере), а не аккаунт Tapo.
3. Убедиться, что в UniFi MAC виртуальной камеры привязан к тому IP, который
   показывает Protect, иначе адопт зависнет.

## 3.5. Ограничения моста

- Protect получает только HQ-поток (1080p). LQ (`stream2`) в rtsp-to-onvif
  появился бы как отдельная камера, поэтому не публикуется.
- Снапшоты не реализованы в rtsp-to-onvif: превью в списке камер может
  быть пустым, запись и live при этом работают.
- Аудио, PTZ и AI-детекции через Protect недоступны (ограничение Protect
  для сторонних камер).
- Если в `config.yaml` поменять `uuid`, Protect увидит «новую» камеру и
  потеряет связь с архивом старой.

## 3.6. Вариант без go2rtc

Если кроме Protect потоки никому не нужны, в `rtsp-to-onvif/config.yaml`
можно указать `target.hostname` = IP самой камеры, порт 554, путь
`/stream1`, а при адопте ввести аккаунт камеры Tapo. Тогда сервис go2rtc
в compose можно закомментировать. Лимит сессий камеры при этом остаётся.
