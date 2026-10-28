#!/usr/bin/env bash
# Проверка Tapo C200 перед подключением к UniFi Protect.
#
# Использование: ./check-camera.sh <IP> <camera_user> <camera_pass>
#   camera_user/pass — «аккаунт камеры» из приложения Tapo, не TP-Link ID.
#
# Проверяет: доступность портов 554 (RTSP), 2020 (ONVIF), 443 (Tapo);
# ответ ONVIF GetSystemDateAndTime (без авторизации) и расхождение часов;
# параметры потоков stream1/stream2 через ffprobe (если установлен).

set -u
IP="${1:-}"; USER="${2:-}"; PASS="${3:-}"
if [ -z "$IP" ] || [ -z "$USER" ] || [ -z "$PASS" ]; then
  echo "usage: $0 <camera-ip> <camera-user> <camera-pass>" >&2; exit 2
fi

ok()   { printf '  [OK]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }

port_open() {
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 "$IP" "$1" >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/$IP/$1") >/dev/null 2>&1
  fi
}

echo "== Порты $IP"
for p in 554:RTSP 2020:ONVIF 443:Tapo-app; do
  port="${p%%:*}"; name="${p##*:}"
  if port_open "$port"; then ok "$port/tcp ($name)"; else fail "$port/tcp ($name) закрыт"; fi
done

echo "== ONVIF GetSystemDateAndTime (порт 2020, без авторизации)"
SOAP='<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/></s:Body></s:Envelope>'
RESP=$(curl -sS -m 5 -H 'Content-Type: application/soap+xml; charset=utf-8' \
        --data "$SOAP" "http://$IP:2020/onvif/device_service" 2>/dev/null || true)
if [ -z "$RESP" ]; then
  fail "ONVIF не ответил. Проверьте, что в приложении Tapo создан аккаунт камеры и порт 2020 открыт."
else
  ok "ONVIF отвечает"
  # Вытаскиваем UTC-время камеры (префикс пространства имён может быть любым)
  # и сравниваем с часами этого хоста.
  utc=$(echo "$RESP" | tr -d '\n' | grep -o '<[A-Za-z0-9]*:*UTCDateTime>.*</[A-Za-z0-9]*:*UTCDateTime>' | head -1)
  f() { echo "$utc" | grep -o "<[A-Za-z0-9]*:*$1>[0-9]*" | head -1 | grep -o '[0-9]*$'; }
  y=$(f Year); mo=$(f Month); d=$(f Day); h=$(f Hour); mi=$(f Minute); s=$(f Second)
  if [ -n "$y" ] && [ -n "$h" ]; then
    cam_ts=$(date -u -d "$y-$mo-$d $h:$mi:${s:-0}" +%s 2>/dev/null \
          || date -u -j -f "%Y-%m-%d %H:%M:%S" "$y-$mo-$d $h:$mi:${s:-0}" +%s 2>/dev/null || echo "")
    now_ts=$(date -u +%s)
    if [ -n "$cam_ts" ]; then
      diff=$(( now_ts - cam_ts )); [ $diff -lt 0 ] && diff=$(( -diff ))
      if [ "$diff" -le 60 ]; then
        ok "часы камеры расходятся с хостом на ${diff} с (камера UTC: $y-$mo-$d $h:$mi:${s:-0})"
      else
        warn "часы камеры расходятся на ${diff} с. ONVIF-авторизация в Protect будет падать. Нужен NTP для камеры (docs/01-camera-prep.md)."
      fi
    else
      warn "не удалось разобрать время камеры: $utc"
    fi
  else
    warn "в ответе ONVIF нет UTCDateTime, пропускаю проверку часов"
  fi
fi

echo "== RTSP потоки (ffprobe)"
if ! command -v ffprobe >/dev/null 2>&1; then
  warn "ffprobe не установлен (apt install ffmpeg), пропускаю"
else
  for st in stream1 stream2; do
    url="rtsp://$USER:$PASS@$IP:554/$st"
    info=$(ffprobe -v error -rtsp_transport tcp -select_streams v:0 \
             -show_entries stream=codec_name,profile,width,height,avg_frame_rate,bit_rate \
             -of default=noprint_wrappers=1 "$url" 2>&1 | head -8)
    if echo "$info" | grep -q 'codec_name'; then
      ok "$st: $(echo "$info" | tr '\n' ' ')"
      if echo "$info" | grep -q 'codec_name=hevc'; then
        warn "$st в H.265. Protect пишет H.264 надёжнее: в приложении Tapo переключите кодирование на H.264."
      fi
    else
      fail "$st: $(echo "$info" | tr '\n' ' ')"
      case "$info" in
        *401*|*Unauthorized*) warn "неверный аккаунт камеры (нужен логин из Расширенные настройки -> Аккаунт камеры)";;
        *453*|*Not\ Enough\ Bandwidth*|*Service\ Unavailable*) warn "лимит RTSP-сессий камеры исчерпан: закройте приложение Tapo и другие клиенты";;
      esac
    fi
  done
fi
