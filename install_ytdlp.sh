#!/usr/bin/env bash

# ==============================================================================
# Script Tự Động Cài Đặt, Cấu Hình & Quản Lý Hệ Thống Tải Video Đa Nền Tảng
# Nền tảng lõi: yt-dlp (https://github.com/yt-dlp/yt-dlp)
# Triển khai: Docker & Docker Compose
# Giao diện: MeTube Web UI + Telegram Bot Tự Động Tải Video + CLI Wrapper ytdl
# Hỗ trợ tải: YouTube, TikTok, Facebook, Instagram, Twitter/X, Bilibili, Douyin,...
# Hệ điều hành hỗ trợ: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, RockyLinux, Fedora
# ==============================================================================

set -e

# Màu sắc hiển thị terminal
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Thư mục và file cấu hình mặc định
INSTALL_DIR="/opt/ytdlp"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
DOWNLOAD_DIR_DEFAULT="$INSTALL_DIR/downloads"
COOKIES_DIR="$INSTALL_DIR/cookies"
BOT_DIR="$INSTALL_DIR/bot"
DEFAULT_PORT="8282"
CLI_WRAPPER="/usr/local/bin/ytdl"
CLI_WRAPPER_ALT="/usr/local/bin/yt-dlp"

# Hiển thị banner
show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${CYAN}${BOLD}   HỆ THỐNG TẢI VIDEO ĐA NỀN TẢNG (YT-DLP & DOCKER ECOSYSTEM)   ${NC}"
    echo -e "${CYAN}${BOLD}   MeTube Web UI + Telegram Bot Tải Video Tự Động + CLI ytdl     ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"
}

# Kiểm tra quyền root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}✗ Lỗi: Script yêu cầu quyền root để cài đặt Docker và mở Firewall.${NC}"
        echo -e "${YELLOW}ℹ Vui lòng chạy lại bằng lệnh:${NC} ${BOLD}sudo bash $0${NC}\n"
        exit 1
    fi
}

# Phát hiện hệ điều hành
detect_os() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    DISTRO="unknown"
    PKG_MANAGER=""

    if [ "$OS" != "Linux" ]; then
        echo -e "${RED}✗ Lỗi: Trình cài đặt này được thiết kế tối ưu cho máy chủ Linux.${NC}"
        echo -e "${YELLOW}Hệ điều hành hiện tại: $OS ($ARCH)${NC}\n"
        exit 1
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO="${ID:-unknown}"
    elif [ -f /etc/redhat-release ]; then
        DISTRO="centos"
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
    fi

    case "$DISTRO" in
        ubuntu|debian)
            PKG_MANAGER="apt-get"
            ;;
        centos|rhel|almalinux|rocky|fedora)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        *)
            PKG_MANAGER="apt-get"
            ;;
    esac
}

# Lấy địa chỉ IP máy chủ
get_server_ips() {
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    PUBLIC_IP=$(curl -s4 --max-time 3 https://ifconfig.me 2>/dev/null || \
                curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null || \
                curl -s4 --max-time 3 https://icanhazip.com 2>/dev/null || \
                echo "$LOCAL_IP")
}

# Mở Firewall Port (UFW, Firewalld, iptables)
open_firewall_port() {
    local port="${1:-$DEFAULT_PORT}"
    echo -e "\n${BLUE}ℹ Đang kiểm tra và mở tường lửa cho Port ${BOLD}${port}/tcp${NC}...${NC}"

    local opened=false

    # 1. UFW (Ubuntu/Debian)
    if command -v ufw >/dev/null 2>&1; then
        UFW_STATUS=$(ufw status 2>/dev/null | grep -i "Status: active" || true)
        if [ -n "$UFW_STATUS" ]; then
            ufw allow "${port}/tcp" comment "yt-dlp Web UI MeTube" >/dev/null 2>&1 || ufw allow "${port}" >/dev/null 2>&1
            ufw reload >/dev/null 2>&1 || true
            echo -e "   ${GREEN}✓ Đã mở port ${port} trên UFW!${NC}"
            opened=true
        fi
    fi

    # 2. Firewalld (CentOS, RHEL, Rocky, AlmaLinux)
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            echo -e "   ${GREEN}✓ Đã mở port ${port} trên Firewalld!${NC}"
            opened=true
        fi
    fi

    # 3. Iptables fallback
    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
        fi
        opened=true
    fi

    if [ "$opened" = true ]; then
        echo -e "${GREEN}✓ Hoàn tất cấu hình tường lửa cho cổng ${port}/tcp.${NC}"
    else
        echo -e "${YELLOW}ℹ Không phát hiện firewall nội bộ chặn port ${port}.${NC}"
    fi

    echo -e "${MAGENTA}${BOLD}👉 LƯU Ý VỀ CLOUD VPS:${NC}"
    echo -e "   Nếu bạn dùng AWS EC2, GCP, Azure, Oracle, DigitalOcean: Hãy mở ${BOLD}Inbound Port ${port}/tcp${NC}"
    echo -e "   trên trang quản trị Security Group / Firewall Rules của nhà cung cấp.\n"
}

# Cài đặt Docker & Docker Compose nếu chưa có
ensure_docker_and_compose() {
    echo -e "${BLUE}ℹ Đang kiểm tra Docker & Docker Compose...${NC}"
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}ℹ Chưa tìm thấy Docker, đang tiến hành cài đặt Docker Engine chính thức...${NC}"
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        systemctl enable --now docker
        echo -e "${GREEN}✓ Cài đặt Docker thành công!${NC}"
    fi

    systemctl start docker 2>/dev/null || true

    # Kiểm tra Docker Compose plugin hoặc standalone
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        echo -e "${YELLOW}ℹ Đang cài đặt Docker Compose plugin...${NC}"
        if [ "$PKG_MANAGER" = "apt-get" ]; then
            apt-get update -qq
            apt-get install -y -qq docker-compose-plugin || true
        elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
            $PKG_MANAGER install -y -q docker-compose-plugin || true
        fi
    fi
    echo -e "${GREEN}✓ Docker & Docker Compose đã sẵn sàng.${NC}"
}

# Lệnh chạy docker compose tương thích
run_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# Đọc cấu hình hiện tại từ file .env
load_config() {
    if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$ENV_FILE" 2>/dev/null || true
    fi
    PORT="${YTDLP_PORT:-$DEFAULT_PORT}"
    DOWNLOAD_PATH="${YTDLP_DOWNLOAD_DIR:-$DOWNLOAD_DIR_DEFAULT}"
    BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
}

# Lưu cấu hình vào file .env
save_config() {
    cat > "$ENV_FILE" <<EOF
YTDLP_PORT=${PORT}
YTDLP_DOWNLOAD_DIR=${DOWNLOAD_PATH}
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_ALLOWED_USERS=${ALLOWED_USERS}
PUBLIC_IP=${PUBLIC_IP}
EOF
    chmod 600 "$ENV_FILE"
}

# Khởi tạo mã nguồn cho Telegram Bot container
generate_bot_files() {
    mkdir -p "$BOT_DIR"

    # 1. Dockerfile cho Telegram Bot
    cat > "$BOT_DIR/Dockerfile" << 'EOF'
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY bot.py /app/bot.py

CMD ["python", "-u", "bot.py"]
EOF

    # 2. requirements.txt
    cat > "$BOT_DIR/requirements.txt" << 'EOF'
pyTelegramBotAPI>=4.20.0
yt-dlp>=2025.01.01
requests>=2.31.0
EOF

    # 3. bot.py (Xử lý tin nhắn trực tiếp, tag nhóm, tải video/audio & gửi lại Telegram)
    cat > "$BOT_DIR/bot.py" << 'EOF'
import os
import re
import sys
import time
import shutil
import logging
import threading
import telebot
import yt_dlp

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

BOT_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN', '').strip()
ALLOWED_USERS_RAW = os.getenv('TELEGRAM_ALLOWED_USERS', '').strip()
PUBLIC_IP = os.getenv('PUBLIC_IP', 'localhost').strip()
WEB_PORT = os.getenv('WEB_PORT', '8282').strip()
DOWNLOAD_DIR = os.getenv('DOWNLOAD_DIR', '/downloads').strip()
COOKIES_FILE = '/cookies/cookies.txt'

MAX_TG_SIZE_BYTES = 49 * 1024 * 1024  # 49 MB (ngưỡng an toàn dưới 50MB của Telegram Bot API)
URL_REGEX = re.compile(r'(https?://[^\s<>"]+|www\.[^\s<>"]+)')

if not BOT_TOKEN:
    logging.warning("Chưa cấu hình TELEGRAM_BOT_TOKEN. Telegram Bot chuyển sang trạng thái chờ.")
    while True:
        time.sleep(3600)

ALLOWED_USERS = set()
if ALLOWED_USERS_RAW:
    for uid in ALLOWED_USERS_RAW.split(','):
        uid = uid.strip()
        if uid.lstrip('-').isdigit():
            ALLOWED_USERS.add(int(uid))

bot = telebot.TeleBot(BOT_TOKEN, parse_mode='HTML')
try:
    BOT_INFO = bot.get_me()
    BOT_USERNAME = (BOT_INFO.username or '').lower()
    logging.info(f"Bot khởi động thành công: @{BOT_INFO.username} (ID: {BOT_INFO.id})")
except Exception as e:
    logging.error(f"Lỗi kết nối Telegram API: {e}")
    BOT_USERNAME = ""


def is_authorized(user_id: int, chat_id: int) -> bool:
    if not ALLOWED_USERS:
        return True
    return (user_id in ALLOWED_USERS) or (chat_id in ALLOWED_USERS)


def extract_url(message) -> str:
    # 1. Tìm trong text của tin nhắn
    text = message.text or message.caption or ""
    urls = URL_REGEX.findall(text)
    if urls:
        return urls[0]
    # 2. Nếu là tin reply, tìm trong tin nhắn gốc
    if message.reply_to_message:
        rep_text = message.reply_to_message.text or message.reply_to_message.caption or ""
        rep_urls = URL_REGEX.findall(rep_text)
        if rep_urls:
            return rep_urls[0]
    return ""


def get_cookie_file() -> str:
    """Kiểm tra và chuẩn bị file cookie tạm thời có quyền ghi để tránh lỗi Read-only."""
    if not os.path.exists(COOKIES_FILE):
        return ""
    try:
        has_real_cookie = False
        with open(COOKIES_FILE, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    has_real_cookie = True
                    break
        if not has_real_cookie:
            return ""
        # Copy cookie ra thư mục /tmp có toàn quyền đọc/ghi để yt-dlp có thể cập nhật session
        tmp_cookie = f"/tmp/cookies_{int(time.time() * 1000)}_{threading.get_ident()}.txt"
        shutil.copyfile(COOKIES_FILE, tmp_cookie)
        os.chmod(tmp_cookie, 0o666)
        return tmp_cookie
    except Exception as e:
        logging.warning(f"Lỗi chuẩn bị cookie file: {e}")
        return ""


def download_and_process(chat_id: int, msg_id: int, user_id: int, url: str, is_audio: bool = False):
    status_msg = None
    tmp_cookie = None
    try:
        status_msg = bot.send_message(
            chat_id,
            f"⏳ <b>Đang phân tích link và tải về...</b>\n🔗 <code>{url}</code>\n<i>Vui lòng đợi giây lát!</i>",
            reply_to_message_id=msg_id
        )

        timestamp = int(time.time())
        out_template = os.path.join(DOWNLOAD_DIR, f"%(title).60s [%(id)s]_{timestamp}.%(ext)s")

        ydl_opts = {
            'outtmpl': out_template,
            'quiet': True,
            'no_warnings': True,
            'noplaylist': True,
            'socket_timeout': 30,
        }

        tmp_cookie = get_cookie_file()
        if tmp_cookie:
            ydl_opts['cookiefile'] = tmp_cookie

        if is_audio:
            ydl_opts.update({
                'format': 'bestaudio/best',
                'postprocessors': [{
                    'key': 'FFmpegExtractAudio',
                    'preferredcodec': 'mp3',
                    'preferredquality': '192',
                }],
            })
        else:
            ydl_opts.update({
                'format': 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best',
                'merge_output_format': 'mp4',
            })

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)
            title = info.get('title', 'Video')
            duration = info.get('duration', 0)
            width = info.get('width', 0)
            height = info.get('height', 0)
            uploader = info.get('uploader', 'N/A')

            filepath = None
            if 'requested_downloads' in info and info['requested_downloads']:
                filepath = info['requested_downloads'][0].get('filepath')

            if not filepath or not os.path.exists(filepath):
                base_name = ydl.prepare_filename(info)
                if is_audio:
                    base, _ = os.path.splitext(base_name)
                    filepath = base + ".mp3"
                else:
                    base, _ = os.path.splitext(base_name)
                    filepath = base + ".mp4"

        if not filepath or not os.path.exists(filepath):
            raise Exception("Không tìm thấy tệp video sau khi tải về.")

        filesize = os.path.getsize(filepath)
        filesize_mb = filesize / (1024 * 1024)
        filename = os.path.basename(filepath)

        if filesize <= MAX_TG_SIZE_BYTES:
            try:
                bot.edit_message_text(
                    f"📤 <b>Đang gửi tệp lên Telegram ({filesize_mb:.1f} MB)...</b>",
                    chat_id=chat_id,
                    message_id=status_msg.message_id
                )
            except Exception:
                pass

            if is_audio:
                bot.send_chat_action(chat_id, 'upload_document')
                with open(filepath, 'rb') as af:
                    bot.send_audio(
                        chat_id,
                        audio=af,
                        caption=f"🎵 <b>{title}</b>\n👤 Kênh: {uploader}\n📦 Dung lượng: {filesize_mb:.1f} MB",
                        reply_to_message_id=msg_id,
                        duration=duration,
                        performer=uploader,
                        title=title
                    )
            else:
                bot.send_chat_action(chat_id, 'upload_video')
                with open(filepath, 'rb') as vf:
                    bot.send_video(
                        chat_id,
                        video=vf,
                        caption=f"🎬 <b>{title}</b>\n👤 Kênh: {uploader}\n📦 Dung lượng: {filesize_mb:.1f} MB",
                        reply_to_message_id=msg_id,
                        duration=duration,
                        width=width,
                        height=height,
                        supports_streaming=True
                    )

            try:
                bot.delete_message(chat_id, status_msg.message_id)
            except Exception:
                pass
        else:
            # Dung lượng > 50MB (vượt giới hạn Telegram API)
            bot.edit_message_text(
                f"✅ <b>Tải về máy chủ thành công!</b>\n\n"
                f"🎬 <b>Tiêu đề:</b> {title}\n"
                f"📦 <b>Dung lượng:</b> {filesize_mb:.1f} MB (Vượt quá giới hạn 50MB của Telegram Bot)\n\n"
                f"🔗 <b>Xem hoặc tải trực tiếp tại Web UI:</b>\n"
                f"http://{PUBLIC_IP}:{WEB_PORT}/\n\n"
                f"📁 <i>Tên tệp:</i> <code>{filename}</code>",
                chat_id=chat_id,
                message_id=status_msg.message_id
            )

    except Exception as e:
        logging.error(f"Lỗi khi xử lý link {url}: {e}")
        err_msg = str(e)
        if "Sign in to confirm you're not a bot" in err_msg:
            hint = "YouTube yêu cầu xác minh bot. Hãy bổ sung cookies.txt vào hệ thống."
        elif "Private video" in err_msg or "Video unavailable" in err_msg:
            hint = "Video ở chế độ riêng tư hoặc đã bị xóa."
        else:
            hint = err_msg[:150]

        reply_err = (
            f"❌ <b>Không thể tải video từ link!</b>\n"
            f"⚠️ <i>Nguyên nhân:</i> {hint}\n"
            f"🔗 <code>{url}</code>"
        )
        if status_msg:
            try:
                bot.edit_message_text(reply_err, chat_id=chat_id, message_id=status_msg.message_id)
            except Exception:
                bot.send_message(chat_id, reply_err, reply_to_message_id=msg_id)
        else:
            bot.send_message(chat_id, reply_err, reply_to_message_id=msg_id)
    finally:
        if tmp_cookie and os.path.exists(tmp_cookie):
            try:
                os.remove(tmp_cookie)
            except Exception:
                pass


@bot.message_handler(commands=['start', 'help'])
def handle_start(message):
    if not is_authorized(message.from_user.id, message.chat.id):
        bot.reply_to(message, "⛔ Bạn không có quyền sử dụng bot này.")
        return

    welcome_text = (
        f"👋 <b>Chào mừng bạn đến với Bot Tải Video Đa Nền Tảng!</b>\n"
        f"<i>(Được vận hành bởi lõi yt-dlp & Docker Engine)</i>\n\n"
        f"🚀 <b>CÁCH SỬ DỤNG:</b>\n"
        f"1. <b>Chat 1-1 với Bot:</b> Gửi trực tiếp bất kỳ đường link video nào (YouTube, TikTok, Facebook, Reels, Instagram, Twitter/X, Douyin,...)\n"
        f"2. <b>Trong Nhóm Chat:</b> Tag <code>@{BOT_USERNAME} [link]</code> hoặc Reply tin nhắn có link video và tag <code>@{BOT_USERNAME}</code>\n"
        f"3. <b>Tải chỉ tệp âm thanh (MP3):</b> Gõ lệnh <code>/mp3 [link]</code>\n\n"
        f"🌐 <b>Giao diện Web MeTube:</b>\n"
        f"<code>http://{PUBLIC_IP}:{WEB_PORT}</code>\n\n"
        f"💡 <i>Lưu ý: Nếu video > 50MB (giới hạn Telegram), bot sẽ lưu vào máy chủ và gửi link web để bạn tải trực tiếp!</i>"
    )
    bot.reply_to(message, welcome_text)


@bot.message_handler(commands=['mp3'])
def handle_mp3_command(message):
    if not is_authorized(message.from_user.id, message.chat.id):
        return

    url = extract_url(message)
    if not url:
        bot.reply_to(message, "ℹ Vui lòng nhập link video kèm theo lệnh. Ví dụ:\n<code>/mp3 https://vt.tiktok.com/...</code>")
        return

    threading.Thread(
        target=download_and_process,
        args=(message.chat.id, message.message_id, message.from_user.id, url, True)
    ).start()


@bot.message_handler(func=lambda m: True, content_types=['text'])
def handle_text_messages(message):
    if not is_authorized(message.from_user.id, message.chat.id):
        return

    text = message.text or ""
    is_group = message.chat.type in ['group', 'supergroup']
    
    # Kiểm tra xem có tag bot hoặc gọi bot trong nhóm không
    is_tagged = False
    if is_group:
        if BOT_USERNAME and f"@{BOT_USERNAME}" in text.lower():
            is_tagged = True
        elif message.reply_to_message and message.reply_to_message.from_user and message.reply_to_message.from_user.username:
            if message.reply_to_message.from_user.username.lower() == BOT_USERNAME:
                is_tagged = True
        elif text.startswith(('/dl', f'/dl@{BOT_USERNAME}')):
            is_tagged = True
    else:
        # Chat riêng 1-1 với Bot
        is_tagged = True

    url = extract_url(message)
    if url and is_tagged:
        is_audio = text.startswith('/mp3')
        threading.Thread(
            target=download_and_process,
            args=(message.chat.id, message.message_id, message.from_user.id, url, is_audio)
        ).start()


if __name__ == '__main__':
    logging.info("Telegram Bot đang lắng nghe tin nhắn...")
    bot.infinity_polling(skip_pending=True)
EOF
}

# Tạo docker-compose.yml
generate_docker_compose() {
    local port="$1"
    local download_dir="$2"

    mkdir -p "$download_dir"
    mkdir -p "$COOKIES_DIR"
    chmod 777 "$COOKIES_DIR" 2>/dev/null || true
    generate_bot_files

    # Tạo tệp cookies.txt mẫu nếu chưa có
    if [ ! -f "$COOKIES_DIR/cookies.txt" ]; then
        cat > "$COOKIES_DIR/cookies.txt" << 'EOF'
# Netscape HTTP Cookie File
# Dán nội dung cookie xuất từ trình duyệt (bằng extension "Get cookies.txt LOCALLY") vào đây
# để vượt kiểm tra bot/đăng nhập của YouTube, Facebook, TikTok.
EOF
    fi
    chmod 666 "$COOKIES_DIR/cookies.txt" 2>/dev/null || true

    # Kiểm tra xem cookies.txt có dữ liệu thực hay chỉ có chú thích
    local metube_cookie_env=""
    if grep -q -v '^[[:space:]]*#' "$COOKIES_DIR/cookies.txt" 2>/dev/null && grep -q -v '^[[:space:]]*$' "$COOKIES_DIR/cookies.txt" 2>/dev/null; then
        metube_cookie_env='- YTDL_OPTIONS={"cookiefile":"/cookies/cookies.txt"}'
    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  metube:
    image: ghcr.io/alexta69/metube:latest
    container_name: ytdlp-metube
    restart: unless-stopped
    ports:
      - "0.0.0.0:${port}:8081"
    volumes:
      - "${download_dir}:/downloads"
      - "${COOKIES_DIR}:/cookies"
    environment:
      - PUID=0
      - PGID=0
      - TZ=Asia/Ho_Chi_Minh
      - DOWNLOAD_DIR=/downloads
      - STATE_DIR=/downloads/.metube
      - CUSTOM_DIRS=true
      - CREATE_CUSTOM_DIRS=true
      - OUTPUT_TEMPLATE=%(title)s.%(ext)s
      ${metube_cookie_env}
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  telegram-bot:
    build:
      context: ./bot
      dockerfile: Dockerfile
    container_name: ytdlp-telegram-bot
    restart: unless-stopped
    volumes:
      - "${download_dir}:/downloads"
      - "${COOKIES_DIR}:/cookies"
    environment:
      - TELEGRAM_BOT_TOKEN=\${TELEGRAM_BOT_TOKEN:-}
      - TELEGRAM_ALLOWED_USERS=\${TELEGRAM_ALLOWED_USERS:-}
      - PUBLIC_IP=\${PUBLIC_IP:-localhost}
      - WEB_PORT=${port}
      - DOWNLOAD_DIR=/downloads
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    depends_on:
      - metube

networks:
  default:
    name: ytdlp_network
EOF
    chmod 644 "$COMPOSE_FILE"
}

# Cài đặt CLI Wrapper /usr/local/bin/ytdl và /usr/local/bin/yt-dlp
install_cli_wrapper() {
    echo -e "${BLUE}ℹ Đang cài đặt công cụ dòng lệnh toàn cục: ${BOLD}ytdl${NC} & ${BOLD}yt-dlp${NC}...${NC}"

    cat > "$CLI_WRAPPER" << 'EOF'
#!/usr/bin/env bash
# yt-dlp Docker CLI Wrapper
# Cho phép gọi lệnh yt-dlp tải video trực tiếp từ terminal vào thư mục hiện tại

COOKIES_ARG=""
if [ -f "/opt/ytdlp/cookies/cookies.txt" ] && grep -q -v '^[[:space:]]*#' "/opt/ytdlp/cookies/cookies.txt" 2>/dev/null; then
    COOKIES_ARG="-v /opt/ytdlp/cookies:/cookies --cookiefile /cookies/cookies.txt"
fi

# Chạy container ghcr.io/alexta69/metube kèm ffmpeg
docker run --rm -i \
    -v "$(pwd)":/workdir \
    -w /workdir \
    ghcr.io/alexta69/metube:latest \
    yt-dlp "$@"
EOF

    chmod +x "$CLI_WRAPPER"
    ln -sf "$CLI_WRAPPER" "$CLI_WRAPPER_ALT" 2>/dev/null || true
    echo -e "${GREEN}✓ Đã tạo lệnh ${BOLD}ytdl${NC} và ${BOLD}yt-dlp${NC} thành công tại /usr/local/bin!${NC}"
}

# Triển khai cài đặt hệ thống yt-dlp, MeTube & Telegram Bot
deploy_ytdlp() {
    ensure_docker_and_compose
    detect_os
    get_server_ips
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$COOKIES_DIR"
    mkdir -p "$BOT_DIR"
    cd "$INSTALL_DIR"

    echo -e "\n${CYAN}${BOLD}--- CẤU HÌNH THÔNG SỐ YT-DLP, METUBE & TELEGRAM BOT ---${NC}\n"

    # Nhập cổng Web UI
    read -rp "$(echo -e "${BOLD}1. Cổng Web UI (Port)${NC} [Mặc định: ${GREEN}${DEFAULT_PORT}${NC}]: ")" INPUT_PORT
    PORT="${INPUT_PORT:-$DEFAULT_PORT}"

    # Nhập thư mục lưu video tải về
    read -rp "$(echo -e "${BOLD}2. Thư mục lưu trữ video trên Server${NC} [Mặc định: ${GREEN}${DOWNLOAD_DIR_DEFAULT}${NC}]: ")" INPUT_DIR
    DOWNLOAD_PATH="${INPUT_DIR:-$DOWNLOAD_DIR_DEFAULT}"
    mkdir -p "$DOWNLOAD_PATH"

    # Nhập Telegram Bot Token
    echo -e "\n${BOLD}3. Cấu hình Telegram Bot Token:${NC}"
    echo -e "   Tạo bot tại ${CYAN}@BotFather${NC} trên Telegram để lấy API Token (dạng: 123456789:ABCdef...)"
    read -rp "$(echo -e "   Nhập Telegram Bot Token [Bỏ trống nếu chưa dùng]: ")" INPUT_BOT_TOKEN
    BOT_TOKEN="${INPUT_BOT_TOKEN:-$BOT_TOKEN}"

    # Ghi cấu hình ra .env
    save_config

    # Tạo docker-compose.yml và bot files
    generate_docker_compose "$PORT" "$DOWNLOAD_PATH"

    # Cài đặt CLI wrapper
    install_cli_wrapper

    # Mở tường lửa
    open_firewall_port "$PORT"

    # Tắt phiên bản cũ nếu đang chạy
    if [ -f "$COMPOSE_FILE" ]; then
        run_compose down 2>/dev/null || true
    fi

    echo -e "\n${BLUE}ℹ Đang tải Image Docker và xây dựng dịch vụ...${NC}"
    run_compose pull metube
    run_compose build telegram-bot
    run_compose up -d

    echo -e "\n${GREEN}${BOLD}✓ Khởi tạo toàn bộ hệ thống tải video thành công!${NC}"
    post_install_guide
}

# Cấu hình hoặc đổi Telegram Bot Token
configure_telegram_bot() {
    load_config
    get_server_ips
    echo -e "\n${CYAN}${BOLD}=== CẤU HÌNH TELEGRAM BOT TẢI VIDEO TỰ ĐỘNG ===${NC}\n"
    if [ -n "$BOT_TOKEN" ]; then
        echo -e "Token hiện tại: ${GREEN}${BOT_TOKEN:0:10}****************${NC}"
    else
        echo -e "Token hiện tại: ${YELLOW}(Chưa cấu hình)${NC}"
    fi

    echo -e "\n${BOLD}Hướng dẫn tạo Telegram Bot:${NC}"
    echo -e "1. Mở ứng dụng Telegram, tìm kiếm: ${CYAN}@BotFather${NC}"
    echo -e "2. Gõ lệnh: ${BOLD}/newbot${NC} và đặt tên cho bot."
    echo -e "3. Copy chuỗi ${BOLD}HTTP API Token${NC} dán vào dưới đây."
    echo -e "4. ${YELLOW}MẸO CHO NHÓM:${NC} Trong chat với @BotFather, gõ ${BOLD}/setprivacy${NC} -> Chọn bot của bạn -> Chọn ${BOLD}Disable${NC} (để bot có thể nhận diện link trong nhóm mà không cần quyền Admin).\n"

    read -rp "Nhập Telegram Bot Token mới [Enter để giữ nguyên]: " NEW_TOKEN
    if [ -n "$NEW_TOKEN" ]; then
        echo -e "\n${BLUE}ℹ Đang kiểm tra tính hợp lệ của Token với Telegram API...${NC}"
        BOT_CHECK=$(curl -s --max-time 5 "https://api.telegram.org/bot${NEW_TOKEN}/getMe" || true)
        if echo "$BOT_CHECK" | grep -q '"ok":true'; then
            TG_NAME=$(echo "$BOT_CHECK" | grep -o '"username":"[^"]*"' | cut -d'"' -f4 || echo "Bot")
            echo -e "${GREEN}✓ Kết nối thành công tới Bot: ${BOLD}@${TG_NAME}${NC}!"
            BOT_TOKEN="$NEW_TOKEN"
        else
            echo -e "${RED}✗ Token không hợp lệ hoặc không thể kết nối tới Telegram API!${NC}"
            echo -e "Phản hồi API: $BOT_CHECK"
            read -rp "Bạn vẫn muốn lưu token này chứ? (y/N): " FORCE_SAVE
            if [[ "$FORCE_SAVE" =~ ^[Yy]$ ]]; then
                BOT_TOKEN="$NEW_TOKEN"
            else
                return 1
            fi
        fi
    fi

    read -rp "Nhập ID người dùng / Nhóm được phép tải (Cách nhau bởi dấu phẩy, để trống để cho phép tất cả): " NEW_ALLOWED
    if [ -n "$NEW_ALLOWED" ]; then
        ALLOWED_USERS="$NEW_ALLOWED"
    fi

    save_config
    generate_docker_compose "$PORT" "$DOWNLOAD_PATH"

    cd "$INSTALL_DIR"
    echo -e "\n${BLUE}ℹ Đang khởi động lại dịch vụ Telegram Bot...${NC}"
    run_compose build telegram-bot
    run_compose up -d --force-recreate telegram-bot

    echo -e "${GREEN}${BOLD}✓ Cấu hình Telegram Bot thành công!${NC}"
    echo -e "Bây giờ bạn có thể chat trực tiếp hoặc thêm bot vào nhóm và gửi link video để tải!\n"
}

# Hướng dẫn chi tiết sau khi cài đặt
post_install_guide() {
    load_config
    get_server_ips

    echo -e "\n${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${GREEN}${BOLD}   🎉 HỆ THỐNG YT-DLP, METUBE & TELEGRAM BOT ĐÃ SẴN SÀNG!        ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"

    echo -e "${BOLD}📌 1. TRUY CẬP GIAO DIỆN WEB (TRÌNH DUYỆT ĐIỆN THOẠI / MÁY TÍNH):${NC}"
    echo -e "   • Truy cập từ Internet:      ${GREEN}${BOLD}http://${PUBLIC_IP}:${PORT}${NC}"
    echo -e "   • Truy cập nội bộ mạng LAN:  ${GREEN}${BOLD}http://${LOCAL_IP}:${PORT}${NC}"
    echo -e "   • Localhost:                 ${GREEN}http://127.0.0.1:${PORT}${NC}"
    echo -e "   ${YELLOW}→ Dán link YouTube, TikTok, Facebook, Instagram,... chọn độ phân giải / MP3 rồi bấm Tải!${NC}"

    echo -e "\n${BOLD}🤖 2. TẢI VIDEO QUA TELEGRAM BOT (CHAT RIÊNG & NHÓM):${NC}"
    if [ -n "$BOT_TOKEN" ]; then
        echo -e "   • ${GREEN}Trạng thái: ĐÃ KÍCH HOẠT${NC}"
        echo -e "   • Gửi link trực tiếp trong chat 1-1 với Bot để tải video."
        echo -e "   • Trong nhóm chat: Tag ${BOLD}@bot_username [link]${NC} hoặc Reply tin nhắn có link kèm tag bot."
        echo -e "   • Tách nhạc MP3: Gõ lệnh ${BOLD}/mp3 [link]${NC}."
    else
        echo -e "   • ${YELLOW}Trạng thái: CHƯA CẤU HÌNH TOKEN${NC}"
        echo -e "   • Chọn lựa chọn số ${BOLD}2${NC} trong Menu để cấu hình Telegram Bot Token bất kỳ lúc nào."
    fi

    echo -e "\n${BOLD}💻 3. TẢI VIDEO TRỰC TIẾP TỪ DÒNG LỆNH (CLI):${NC}"
    echo -e "   • Tải video chất lượng tốt nhất:"
    echo -e "     ${GREEN}ytdl \"https://www.youtube.com/watch?v=VIDEO_ID\"${NC}"
    echo -e "   • Tải tách lấy file âm thanh MP3:"
    echo -e "     ${GREEN}ytdl -x --audio-format mp3 \"https://vt.tiktok.com/ZSxxxx/\"${NC}"

    echo -e "\n${BOLD}📁 4. THƯ MỤC LƯU TRỮ TRÊN MÁY CHỦ:${NC}"
    echo -e "   • Thư mục video đã tải:  ${MAGENTA}${BOLD}${DOWNLOAD_PATH}${NC}"
    echo -e "   • Thư mục cookies:       ${MAGENTA}${COOKIES_DIR}/cookies.txt${NC}"

    echo -e "\n${BOLD}📋 5. LỆNH QUẢN LÝ NHANH DỊCH VỤ:${NC}"
    echo -e "   • Xem logs tải video:    ${BOLD}cd ${INSTALL_DIR} && docker compose logs -f${NC}"
    echo -e "   • Khởi động lại:         ${BOLD}cd ${INSTALL_DIR} && docker compose restart${NC}"
    echo -e "   • Dừng dịch vụ:          ${BOLD}cd ${INSTALL_DIR} && docker compose stop${NC}"
    echo -e "\n${CYAN}=================================================================${NC}\n"
}

# Kiểm tra trạng thái dịch vụ
check_status() {
    load_config
    get_server_ips

    echo -e "\n${CYAN}${BOLD}=== KIỂM TRA TRẠNG THÁI HỆ THỐNG YT-DLP ===${NC}\n"

    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        run_compose ps
    else
        echo -e "${RED}✗ Chưa tìm thấy thư mục cài đặt tại ${INSTALL_DIR}.${NC}"
        return 1
    fi

    echo -e "\n${BLUE}ℹ Kiểm tra Port ${PORT}:${NC}"
    if command -v ss >/dev/null 2>&1; then
        PORT_CHECK=$(ss -tlpn 2>/dev/null | grep ":${PORT} " || true)
    elif command -v netstat >/dev/null 2>&1; then
        PORT_CHECK=$(netstat -tlpn 2>/dev/null | grep ":${PORT} " || true)
    else
        PORT_CHECK=""
    fi

    if [ -n "$PORT_CHECK" ]; then
        echo -e "${GREEN}✓ Port ${PORT} đang mở và lắng nghe kết nối!${NC}"
    else
        echo -e "${YELLOW}⚠ Chưa thấy Port ${PORT} hoạt động. Hãy kiểm tra logs container.${NC}"
    fi

    echo -e "\n${BLUE}ℹ Kiểm tra phản hồi Web UI:${NC}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "http://127.0.0.1:${PORT}" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✓ MeTube Web UI phản hồi HTTP 200 OK! Hoạt động hoàn hảo.${NC}"
    else
        echo -e "${YELLOW}⚠ Phản hồi HTTP: ${HTTP_CODE}. Đang khởi động hoặc có lỗi cấu hình.${NC}"
    fi

    echo -e "\n${BLUE}ℹ Kiểm tra Telegram Bot:${NC}"
    if [ -n "$BOT_TOKEN" ]; then
        BOT_RUNNING=$(docker ps --filter "name=ytdlp-telegram-bot" --format "{{.Status}}" || true)
        if [ -n "$BOT_RUNNING" ]; then
            echo -e "${GREEN}✓ Telegram Bot Container đang chạy: ${BOT_RUNNING}${NC}"
        else
            echo -e "${YELLOW}⚠ Telegram Bot Container chưa chạy. Hãy kiểm tra log.${NC}"
        fi
    else
        echo -e "${YELLOW}ℹ Telegram Bot chưa cấu hình Token.${NC}"
    fi

    # Thống kê dung lượng thư mục tải về
    if [ -d "$DOWNLOAD_PATH" ]; then
        FILE_COUNT=$(find "$DOWNLOAD_PATH" -maxdepth 2 -type f 2>/dev/null | wc -l || echo "0")
        TOTAL_SIZE=$(du -sh "$DOWNLOAD_PATH" 2>/dev/null | cut -f1 || echo "0B")
        echo -e "\n${BLUE}ℹ Thư mục tải về (${DOWNLOAD_PATH}):${NC}"
        echo -e "   • Số tệp tin: ${BOLD}${FILE_COUNT}${NC}"
        echo -e "   • Tổng dung lượng: ${BOLD}${TOTAL_SIZE}${NC}"
    fi
}

# Tải video tương tác từ terminal
download_video_interactive() {
    load_config
    echo -e "\n${CYAN}${BOLD}=== TẢI VIDEO BẰNG ĐƯỜNG LINK (CLI DOWNLOADER) ===${NC}\n"
    read -rp "$(echo -e "${BOLD}Nhập URL video cần tải (YouTube, TikTok, Facebook, ...):${NC} ")" TARGET_URL

    if [ -z "$TARGET_URL" ]; then
        echo -e "${RED}✗ URL không được để trống!${NC}"
        return 1
    fi

    echo -e "\n${BOLD}Chọn chế độ tải:${NC}"
    echo -e "   1) ${GREEN}Tải video chất lượng tốt nhất (MP4/MKV + Âm thanh cao nhất)${NC}"
    echo -e "   2) ${YELLOW}Tải tách lấy tệp âm thanh (MP3 - 320kbps/VBR tốt nhất)${NC}"
    echo -e "   3) ${BLUE}Tải video 1080p Full HD (tiết kiệm dung lượng)${NC}"
    echo -e "   4) Tùy chọn nâng cao (Hiển thị danh sách định dạng -F)"
    read -rp "Lựa chọn [1-4] (Mặc định: 1): " DL_MODE
    DL_MODE="${DL_MODE:-1}"

    mkdir -p "$DOWNLOAD_PATH"
    cd "$DOWNLOAD_PATH"

    echo -e "\n${BLUE}ℹ Đang bắt đầu tải vào thư mục ${BOLD}${DOWNLOAD_PATH}${NC}...${NC}\n"

    case "$DL_MODE" in
        1)
            ytdl --embed-metadata --embed-thumbnail -f "bestvideo+bestaudio/best" "$TARGET_URL"
            ;;
        2)
            ytdl -x --audio-format mp3 --audio-quality 0 --embed-thumbnail --embed-metadata "$TARGET_URL"
            ;;
        3)
            ytdl -f "bestvideo[height<=1080]+bestaudio/best[height<=1080]/best" "$TARGET_URL"
            ;;
        4)
            ytdl -F "$TARGET_URL"
            echo -e "\n${YELLOW}Nhập mã format ID bạn muốn tải (VD: 137+140 hoặc b):${NC}"
            read -rp "Format ID: " FID
            if [ -n "$FID" ]; then
                ytdl -f "$FID" "$TARGET_URL"
            fi
            ;;
    esac

    echo -e "\n${GREEN}✓ Hoàn tất xử lý yêu cầu tải video!${NC}"
}

# Xem logs thời gian thực
view_logs() {
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${BOLD}Chọn dịch vụ muốn xem Log:${NC}"
        echo -e "   1) ${GREEN}Xem toàn bộ logs (Cả MeTube & Telegram Bot)${NC}"
        echo -e "   2) ${BLUE}Chỉ xem logs MeTube Web UI${NC}"
        echo -e "   3) ${CYAN}Chỉ xem logs Telegram Bot${NC}"
        read -rp "Lựa chọn [1-3] (Mặc định: 1): " LOG_CHOICE
        LOG_CHOICE="${LOG_CHOICE:-1}"

        echo -e "\n${BLUE}ℹ Đang hiển thị live log (Nhấn Ctrl+C để thoát)...${NC}\n"
        case "$LOG_CHOICE" in
            1) run_compose logs -f ;;
            2) run_compose logs -f metube ;;
            3) run_compose logs -f telegram-bot ;;
        esac
    else
        echo -e "${RED}✗ Chưa tìm thấy thư mục cài đặt ${INSTALL_DIR}.${NC}"
    fi
}

# Quản lý file đã tải về
manage_downloads() {
    load_config
    echo -e "\n${CYAN}${BOLD}=== DANH SÁCH FILE ĐÃ TẢI VỀ (${DOWNLOAD_PATH}) ===${NC}\n"
    if [ ! -d "$DOWNLOAD_PATH" ]; then
        echo -e "${YELLOW}Thư mục ${DOWNLOAD_PATH} chưa có dữ liệu.${NC}"
        return
    fi

    echo -e "${BOLD}Các tệp mới nhất (tối đa 15 tệp):${NC}"
    ls -lhpt "$DOWNLOAD_PATH" | grep -v '^total' | grep -v '^d' | head -n 15 || echo "Không có tệp nào."

    TOTAL_SIZE=$(du -sh "$DOWNLOAD_PATH" 2>/dev/null | cut -f1 || echo "0B")
    echo -e "\n${BLUE}Tổng dung lượng thư mục:${NC} ${BOLD}${TOTAL_SIZE}${NC}\n"

    echo -e "Bạn có muốn dọn dẹp xóa tệp trong thư mục tải về không?"
    echo -e "   1) Giữ nguyên (Quay lại menu)"
    echo -e "   2) ${RED}Xóa toàn bộ file trong thư mục downloads${NC}"
    read -rp "Lựa chọn [1-2] (Mặc định: 1): " CLEAN_CHOICE
    CLEAN_CHOICE="${CLEAN_CHOICE:-1}"

    if [ "$CLEAN_CHOICE" = "2" ]; then
        read -rp "Gõ 'xoa' để xác nhận xóa toàn bộ file tải về: " CONFIRM_CLEAN
        if [ "$CONFIRM_CLEAN" = "xoa" ]; then
            rm -rf "${DOWNLOAD_PATH:?}"/*
            echo -e "${GREEN}✓ Đã làm trống thư mục ${DOWNLOAD_PATH}!${NC}"
        else
            echo -e "${YELLOW}Hủy bỏ thao tác xóa.${NC}"
        fi
    fi
}

# Hướng dẫn cấu hình Cookie chống chặn bot
configure_cookies() {
    echo -e "\n${CYAN}${BOLD}=== HƯỚNG DẪN CẤU HÌNH COOKIE (VƯỢT BOT CHECK / PRIVATE VIDEO) ===${NC}\n"
    echo -e "Một số nền tảng (YouTube Sign in to confirm you're not a bot, Facebook nhóm kín, TikTok) yêu cầu Cookie để tải."
    echo -e "\n${BOLD}Cách thiết lập:${NC}"
    echo -e "1. Cài Extension trình duyệt trên máy tính: ${GREEN}Get cookies.txt LOCALLY${NC} (Chrome / Edge / Firefox)."
    echo -e "2. Đăng nhập tài khoản YouTube / Facebook trên trình duyệt máy tính của bạn."
    echo -e "3. Bấm vào Extension, tải về file ${BOLD}cookies.txt${NC} (chuẩn Netscape)."
    echo -e "4. Có 2 cách đưa cookie vào hệ thống:"
    echo -e "   • ${BOLD}Cách 1 (Nhanh nhất):${NC} Mở giao diện MeTube Web UI (${GREEN}http://${PUBLIC_IP}:${PORT}${NC}) -> Bấm ${BOLD}Advanced Options${NC} -> Bấm ${BOLD}Upload Cookies${NC} và chọn file cookies.txt."
    echo -e "   • ${BOLD}Cách 2 (Qua Terminal):${NC} Copy nội dung cookies dán vào file: ${MAGENTA}${COOKIES_DIR}/cookies.txt${NC} trên máy chủ."
    echo -e "\n${BLUE}ℹ Vị trí tệp cookie hiện tại trên server:${NC} ${COOKIES_DIR}/cookies.txt\n"

    read -rp "Bạn có muốn mở nano để dán nội dung cookie ngay bây giờ không? (y/N): " OPEN_NANO
    if [[ "$OPEN_NANO" =~ ^[Yy]$ ]]; then
        mkdir -p "$COOKIES_DIR"
        nano "$COOKIES_DIR/cookies.txt"
        echo -e "${GREEN}✓ Đã lưu cookie. Đang khởi động lại dịch vụ để áp dụng...${NC}"
        restart_service
    fi
}

# Cập nhật Docker Image & yt-dlp lên bản mới nhất
update_system() {
    echo -e "\n${BLUE}ℹ Đang kiểm tra và cập nhật hệ thống lên phiên bản mới nhất...${NC}"
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        run_compose pull metube
        run_compose build --no-cache telegram-bot
        run_compose up -d --force-recreate
        install_cli_wrapper
        echo -e "${GREEN}✓ Cập nhật thành công lên bản phát hành mới nhất!${NC}\n"
    else
        echo -e "${RED}✗ Chưa cài đặt dịch vụ.${NC}"
    fi
}

# Khởi động lại dịch vụ
restart_service() {
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${BLUE}ℹ Đang khởi động lại toàn bộ containers yt-dlp...${NC}"
        run_compose restart
        echo -e "${GREEN}✓ Đã khởi động lại thành công!${NC}"
    fi
}

# Dừng dịch vụ
stop_service() {
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${YELLOW}ℹ Đang dừng container yt-dlp / MeTube / Telegram Bot...${NC}"
        run_compose stop
        echo -e "${GREEN}✓ Đã dừng dịch vụ.${NC}"
    fi
}

# Gỡ bỏ dịch vụ
uninstall_ytdlp() {
    echo -e "\n${RED}${BOLD}⚠ CẢNH BÁO: BẠN CÓ CHẮC CHẮN MUỐN GỠ BỎ HỆ THỐNG YT-DLP?${NC}"
    read -rp "Xác nhận gỡ bỏ? (gõ 'yes' để xác nhận): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}Hủy bỏ thao tác gỡ bỏ.${NC}"
        return 0
    fi

    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        run_compose down -v --remove-orphans 2>/dev/null || true
    fi

    rm -f "$CLI_WRAPPER" "$CLI_WRAPPER_ALT" 2>/dev/null || true

    echo -e "Bạn có muốn xóa luôn toàn bộ thư mục dữ liệu và video đã tải (${INSTALL_DIR}) không?"
    read -rp "(gõ 'delete' để xóa hết, hoặc Enter để giữ lại video): " DEL_DATA
    if [ "$DEL_DATA" = "delete" ]; then
        rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}✓ Đã xóa toàn bộ thư mục cài đặt và video.${NC}"
    else
        echo -e "${YELLOW}ℹ Giữ lại thư mục ${INSTALL_DIR}/downloads để bảo toàn file tải về.${NC}"
        rm -f "$COMPOSE_FILE" "$ENV_FILE" 2>/dev/null || true
        rm -rf "$BOT_DIR" 2>/dev/null || true
    fi

    echo -e "${GREEN}✓ Đã gỡ bỏ hệ thống yt-dlp khỏi máy chủ thành công.${NC}\n"
}

# Menu chính tương tác
main_menu() {
    show_banner
    detect_os
    load_config
    get_server_ips

    echo -e "${BOLD}Chọn tác vụ bạn muốn thực hiện:${NC}"
    echo -e "   1) ${GREEN}${BOLD}Cài đặt & Khởi chạy Toàn bộ Hệ thống (Web UI + Telegram Bot + CLI)${NC}"
    echo -e "   2) ${MAGENTA}${BOLD}Cấu hình Telegram Bot Token (Chat riêng hoặc Tag nhóm tự tải)${NC}"
    echo -e "   3) ${YELLOW}Tải video ngay bằng Link từ dòng lệnh (Interactive Downloader)${NC}"
    echo -e "   4) ${CYAN}Kiểm tra trạng thái hệ thống & Cổng Web (${PORT})${NC}"
    echo -e "   5) Xem Live Logs thời gian thực (MeTube / Telegram Bot)"
    echo -e "   6) ${BLUE}Quản lý danh sách video đã tải (${DOWNLOAD_PATH})${NC}"
    echo -e "   7) Cấu hình Cookie (Vượt bot check YouTube / FaceBook / TikTok)"
    echo -e "   8) ${GREEN}Cập nhật yt-dlp & MeTube lên bản mới nhất${NC}"
    echo -e "   9) Khởi động lại dịch vụ (Restart)"
    echo -e "  10) Dừng dịch vụ (Stop)"
    echo -e "  11) ${RED}Gỡ bỏ hệ thống hoàn toàn${NC}"
    echo -e "   0) Thoát"

    echo ""
    read -rp "Nhập lựa chọn của bạn [0-11] (Mặc định: 1): " MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE:-1}"

    case "$MENU_CHOICE" in
        1)
            deploy_ytdlp
            ;;
        2)
            configure_telegram_bot
            ;;
        3)
            download_video_interactive
            ;;
        4)
            check_status
            ;;
        5)
            view_logs
            ;;
        6)
            manage_downloads
            ;;
        7)
            configure_cookies
            ;;
        8)
            update_system
            ;;
        9)
            restart_service
            ;;
        10)
            stop_service
            ;;
        11)
            uninstall_ytdlp
            ;;
        0)
            echo -e "${GREEN}Tạm biệt! Chúc bạn trải nghiệm tải video vui vẻ.${NC}\n"
            exit 0
            ;;
        *)
            echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
            ;;
    esac
}

# Điểm khởi chạy
check_root
main_menu
