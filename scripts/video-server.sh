#!/usr/bin/env bash
# Stream a USB-C capture card over RTSP with ffmpeg.
#
# ffmpeg's RTSP muxer is a client: it publishes to an RTSP server, it cannot listen. So an RTSP
# server must accept the stream (mediamtx, default port 8554). If `mediamtx` is on PATH and nothing
# listens on the port, this script starts it and stops it on exit.
#
# Usage: scripts/video-server.sh [options]
#   -d, --device <name|index>  capture device (macOS: avfoundation name or index; Linux: /dev/videoN)
#                              default: first device whose name matches "UGREEN", else 0 / /dev/video0
#   -u, --url <rtsp-url>       where to publish (default rtsp://127.0.0.1:8554/live)
#                              Audio goes out as Opus, which WebRTC (WHEP) plays. The same video is
#                              also published at <url>-aac with AAC audio for players without Opus.
#   -a, --audio <name|index|none>
#                              audio device (macOS avfoundation). Default: same name as the video
#                              device when that is a name, else none. Linux: none unless given
#                              (ALSA, e.g. hw:1)
#   -r, --fps <n>            framerate (default 30)
#   -s, --size <WxH>           video size; the card gives ~10 fps at 1080p (default 1280x720)
#   -l, --list                 list capture devices and exit
#   -n, --dry-run              print the ffmpeg command and exit
#   -h, --help                 print this header
#
# Settings can also come from a .env file at the repo root (see .env.example). Flags win over it;
# the file is parsed as plain KEY=VALUE lines, never sourced. Keys: VIDEO_DEVICE, AUDIO_DEVICE,
# VIDEO_SIZE, VIDEO_FPS, RTSP_URL. Empty values are ignored. Override the path with ENV_FILE.
#
# stdout (machine readable):
#   STREAMING <url>   ffmpeg started (printed before it runs), once per published url
#   DEVICES           followed by the ffmpeg device listing (--list)
#   COMMAND <cmd>     the ffmpeg command (--dry-run)
# Everything else goes to stderr.
#
# Exit codes: 0 ok, 2 usage, 3 ffmpeg missing, 4 no RTSP server, 5 no device.
set -euo pipefail

EXIT_USAGE=2
EXIT_NO_FFMPEG=3
EXIT_NO_SERVER=4
EXIT_NO_DEVICE=5

DEFAULT_URL="rtsp://127.0.0.1:8554/live"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_VIDEO_DEVICE=""
ENV_AUDIO_DEVICE=""
ENV_VIDEO_SIZE=""
ENV_VIDEO_FPS=""
ENV_RTSP_URL=""
MEDIAMTX_PID=""
MEDIAMTX_CONF=""

usage() {
  awk 'NR == 1 { next } /^set -/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

die() {
  local code="$1"
  shift
  echo "error: $*" >&2
  exit "$code"
}

cleanup() {
  if [ -n "$MEDIAMTX_PID" ]; then
    kill "$MEDIAMTX_PID" 2>/dev/null || true
  fi
  if [ -n "$MEDIAMTX_CONF" ]; then
    rm -f "$MEDIAMTX_CONF"
  fi
}

# trim <string>: print it without surrounding whitespace and one pair of quotes.
trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# load_env: read KEY=VALUE lines of the .env file into the ENV_* globals. Never sources the file.
load_env() {
  local file="${ENV_FILE:-$SCRIPT_DIR/../.env}" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      '' | '#'* | [[:space:]]'#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    case "$key" in
      VIDEO_DEVICE) ENV_VIDEO_DEVICE="$value" ;;
      AUDIO_DEVICE) ENV_AUDIO_DEVICE="$value" ;;
      VIDEO_SIZE) ENV_VIDEO_SIZE="$value" ;;
      VIDEO_FPS) ENV_VIDEO_FPS="$value" ;;
      RTSP_URL) ENV_RTSP_URL="$value" ;;
    esac
  done < "$file"
}

# url_port <rtsp-url>: print the port, 554 when absent.
url_port() {
  local hostport
  hostport="${1#rtsp://}"
  hostport="${hostport%%/*}"
  case "$hostport" in
    *:*) echo "${hostport##*:}" ;;
    *) echo 554 ;;
  esac
}

# url_host <rtsp-url>: print the host.
url_host() {
  local hostport
  hostport="${1#rtsp://}"
  hostport="${hostport%%/*}"
  echo "${hostport%%:*}"
}

# port_open <host> <port>: true when something accepts TCP connections.
port_open() {
  (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null
}

# list_devices: print the capture devices of this OS to stdout.
list_devices() {
  case "$(uname -s)" in
    Darwin)
      ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true
      ;;
    *)
      ls /dev/video* 2>/dev/null || true
      ;;
  esac
}

# find_device: print the first video device named like the UGREEN capture card, else the first one.
find_device() {
  local name
  case "$(uname -s)" in
    Darwin)
      name="$(list_devices | awk '/video devices/ { v = 1; next } /audio devices/ { v = 0 }
        v && /UGREEN/ { print; exit }' | sed -E 's/^.*\] \[[0-9]+\] //')"
      echo "${name:-0}"
      ;;
    *)
      echo /dev/video0
      ;;
  esac
}

# default_audio <device>: same name as the video device on macOS when it is a name, else none.
default_audio() {
  case "$(uname -s)" in
    Darwin)
      case "$1" in
        '' | *[!0-9]*) echo "$1" ;;
        *) echo none ;;
      esac
      ;;
    *) echo none ;;
  esac
}

# build_input <device> <audio> <fps> <size>: set INPUT_ARGS (array) and AUDIO_INPUT for the OS.
build_input() {
  local device="$1" audio="$2" fps="$3" size="$4"
  case "$(uname -s)" in
    Darwin)
      # avfoundation asks for yuv420p by default, which capture cards do not offer; nv12 is 4:2:0
      # too and videotoolbox encodes it without a conversion.
      INPUT_ARGS=(-f avfoundation -pixel_format nv12 -video_size "$size" -framerate "$fps"
        -i "${device}:${audio}")
      AUDIO_INPUT=0
      ;;
    *)
      INPUT_ARGS=(-f v4l2 -framerate "$fps" -video_size "$size" -i "$device")
      AUDIO_INPUT=1
      if [ "$audio" != none ]; then
        INPUT_ARGS+=(-f alsa -i "$audio")
      fi
      ;;
  esac
}

# build_encoder <audio> <fps>: set ENCODER_ARGS (array): hardware H.264 on macOS, x264 elsewhere.
# With audio it encodes it twice: Opus as the first audio stream, AAC as the second.
build_encoder() {
  local fps="$2"
  case "$(uname -s)" in
    Darwin) ENCODER_ARGS=(-c:v h264_videotoolbox -b:v 4M -bf 0 -realtime 1) ;;
    *) ENCODER_ARGS=(-c:v libx264 -preset ultrafast -tune zerolatency -b:v 4M -bf 0) ;;
  esac
  ENCODER_ARGS+=(-pix_fmt yuv420p -r "$fps" -fps_mode cfr -g 60)
  if [ "$1" = none ]; then
    ENCODER_ARGS+=(-an)
  else
    ENCODER_ARGS+=(-af aresample=async=1 -ar 48000 -c:a:0 libopus -b:a:0 96k -c:a:1 aac -b:a:1 128k)
  fi
}

# build_output <audio> <url>: set OUTPUT_ARGS (array). Without audio, <url> only; with it, one
# ffmpeg publishes <url> (Opus) and <url>-aac (AAC) through the tee muxer, so the video is encoded
# once. onfail=ignore keeps <url> streaming if <url>-aac fails.
build_output() {
  local slave="f=rtsp:rtsp_transport=tcp:onfail=ignore"
  if [ "$1" = none ]; then
    OUTPUT_ARGS=(-map 0:v -f rtsp -rtsp_transport tcp "$2")
  else
    OUTPUT_ARGS=(-map 0:v -map "$AUDIO_INPUT:a" -map "$AUDIO_INPUT:a" -f tee
      "[select=\\'v:0,a:0\\':$slave]$2|[select=\\'v:0,a:1\\':$slave]$2-aac")
  fi
}

# ensure_server <url>: make sure an RTSP server listens, starting mediamtx when possible.
ensure_server() {
  local host port i
  host="$(url_host "$1")"
  port="$(url_port "$1")"
  if port_open "$host" "$port"; then
    return 0
  fi
  case "$host" in
    127.0.0.1 | localhost) ;;
    *) die "$EXIT_NO_SERVER" "no RTSP server at $host:$port" ;;
  esac
  if ! command -v mediamtx >/dev/null 2>&1; then
    die "$EXIT_NO_SERVER" "no RTSP server at $host:$port and mediamtx not found (brew install mediamtx)"
  fi
  # The packaged binary may find no config; this one accepts any path.
  MEDIAMTX_CONF="$(mktemp)"
  printf "paths:\n  all_others:\n" > "$MEDIAMTX_CONF"
  mediamtx "$MEDIAMTX_CONF" >&2 &
  MEDIAMTX_PID=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if port_open "$host" "$port"; then
      return 0
    fi
    sleep 0.5
  done
  die "$EXIT_NO_SERVER" "mediamtx did not open $host:$port"
}

main() {
  local device="" audio="" url="$DEFAULT_URL" fps=30 size=1280x720 list=0 dry=0

  load_env
  device="$ENV_VIDEO_DEVICE"
  audio="$ENV_AUDIO_DEVICE"
  [ -z "$ENV_RTSP_URL" ] || url="$ENV_RTSP_URL"
  [ -z "$ENV_VIDEO_FPS" ] || fps="$ENV_VIDEO_FPS"
  [ -z "$ENV_VIDEO_SIZE" ] || size="$ENV_VIDEO_SIZE"

  while [ $# -gt 0 ]; do
    case "$1" in
      -d | --device) device="${2:?missing value for $1}"; shift 2 ;;
      -u | --url) url="${2:?missing value for $1}"; shift 2 ;;
      -a | --audio) audio="${2:?missing value for $1}"; shift 2 ;;
      -r | --fps) fps="${2:?missing value for $1}"; shift 2 ;;
      -s | --size) size="${2:?missing value for $1}"; shift 2 ;;
      -l | --list) list=1; shift ;;
      -n | --dry-run) dry=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "error: unknown option: $1" >&2; usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done

  command -v ffmpeg >/dev/null 2>&1 || die "$EXIT_NO_FFMPEG" "ffmpeg not found"

  if [ "$list" = 1 ]; then
    echo DEVICES
    list_devices
    exit 0
  fi

  case "$url" in
    rtsp://*) ;;
    *) die "$EXIT_USAGE" "url must start with rtsp://: $url" ;;
  esac
  case "$fps" in
    '' | *[!0-9]*) die "$EXIT_USAGE" "fps must be a number: $fps" ;;
  esac

  if [ -z "$device" ]; then
    device="$(find_device)"
  fi
  [ -n "$device" ] || die "$EXIT_NO_DEVICE" "no capture device found (try --list)"

  if [ -z "$audio" ]; then
    audio="$(default_audio "$device")"
  fi
  build_input "$device" "$audio" "$fps" "$size"
  build_encoder "$audio" "$fps"
  build_output "$audio" "$url"
  local cmd=(ffmpeg -hide_banner -loglevel warning "${INPUT_ARGS[@]}" "${ENCODER_ARGS[@]}"
    "${OUTPUT_ARGS[@]}")

  if [ "$dry" = 1 ]; then
    printf 'COMMAND'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    exit 0
  fi

  trap cleanup EXIT
  ensure_server "$url"
  echo "STREAMING $url"
  [ "$audio" = none ] || echo "STREAMING $url-aac"
  "${cmd[@]}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
