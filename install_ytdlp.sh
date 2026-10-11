#!/usr/bin/env bash

# ==============================================================================
# Script Tự Động Cài Đặt, Cấu Hình & Quản Lý Hệ Thống Tải Video Đa Nền Tảng
# Nền tảng lõi: yt-dlp (https://github.com/yt-dlp/yt-dlp)
# Triển khai: Docker & Docker Compose
# Giao diện: MeTube Web UI + Giao diện Web Cấu hình Bot Token & Video Mờ (Spoiler) + CLI ytdl
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
NGINX_CONF="$INSTALL_DIR/nginx.conf"
ENV_FILE="$INSTALL_DIR/.env"
CONFIG_DIR="$INSTALL_DIR/config"
DOWNLOAD_DIR_DEFAULT="$INSTALL_DIR/downloads"
COOKIES_DIR="$INSTALL_DIR/cookies"
BOT_DIR="$INSTALL_DIR/bot"
DEFAULT_PORT="8282"
DEFAULT_BOT_PORT="8283"
CLI_WRAPPER="/usr/local/bin/ytdl"
CLI_WRAPPER_ALT="/usr/local/bin/yt-dlp"

# Hiển thị banner
show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${CYAN}${BOLD}   HỆ THỐNG TẢI VIDEO ĐA NỀN TẢNG (YT-DLP & DOCKER ECOSYSTEM)   ${NC}"
    echo -e "${CYAN}${BOLD}   MeTube Web UI + Web Cấu Hình Bot & Video Mờ + CLI ytdl        ${NC}"
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
            ufw allow "${port}/tcp" comment "yt-dlp Video Downloader" >/dev/null 2>&1 || ufw allow "${port}" >/dev/null 2>&1
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
    BOT_PORT="${YTDLP_BOT_PORT:-$DEFAULT_BOT_PORT}"
    DOWNLOAD_PATH="${YTDLP_DOWNLOAD_DIR:-$DOWNLOAD_DIR_DEFAULT}"
    BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
    SEND_SPOILER="${TELEGRAM_SEND_SPOILER:-false}"
}

# Lưu cấu hình vào file .env
save_config() {
    cat > "$ENV_FILE" <<EOF
YTDLP_PORT=${PORT}
YTDLP_BOT_PORT=${BOT_PORT}
YTDLP_DOWNLOAD_DIR=${DOWNLOAD_PATH}
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_ALLOWED_USERS=${ALLOWED_USERS}
TELEGRAM_SEND_SPOILER=${SEND_SPOILER}
PUBLIC_IP=${PUBLIC_IP}
EOF
    chmod 600 "$ENV_FILE"
}

# Tạo mã nguồn cho Telegram Bot container kèm Web Settings Dashboard
generate_bot_files() {
    mkdir -p "$BOT_DIR"
    mkdir -p "$CONFIG_DIR"

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

EXPOSE 5000
CMD ["python", "-u", "bot.py"]
EOF

    # 2. requirements.txt
    cat > "$BOT_DIR/requirements.txt" << 'EOF'
pyTelegramBotAPI>=4.20.0
yt-dlp>=2025.01.01
requests>=2.31.0
flask>=3.0.0
EOF

    # 3. bot.py: Tích hợp Flask Web UI để cấu hình Bot Token, Video Mờ (Spoiler), Cookie & Telegram Worker
    cat > "$BOT_DIR/bot.py" << 'EOF'
import os
import re
import sys
import time
import json
import shutil
import logging
import threading
import telebot
import requests
import yt_dlp
from flask import Flask, request, jsonify, render_template_string

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

CONFIG_FILE = os.getenv('CONFIG_FILE', '/config/bot_config.json')
COOKIES_FILE = '/cookies/cookies.txt'
DOWNLOAD_DIR = os.getenv('DOWNLOAD_DIR', '/downloads').strip()
PUBLIC_IP = os.getenv('PUBLIC_IP', 'localhost').strip()
WEB_PORT = os.getenv('WEB_PORT', '8282').strip()

MAX_TG_SIZE_BYTES = 49 * 1024 * 1024  # 49 MB (ngưỡng an toàn dưới 50MB)
URL_REGEX = re.compile(r'(https?://[^\s<>"]+|www\.[^\s<>"]+)')

# Biến cấu hình toàn cục
CONFIG_LOCK = threading.Lock()
CURRENT_CONFIG = {
    'bot_token': os.getenv('TELEGRAM_BOT_TOKEN', '').strip(),
    'allowed_users': os.getenv('TELEGRAM_ALLOWED_USERS', '').strip(),
    'send_spoiler': os.getenv('TELEGRAM_SEND_SPOILER', 'false').lower() in ('true', '1', 'yes'),
}

# Tải cấu hình từ JSON file nếu có
def load_saved_config():
    global CURRENT_CONFIG
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
                data = json.load(f)
                CURRENT_CONFIG.update(data)
                logging.info(f"Đã nạp cấu hình từ {CONFIG_FILE}")
        except Exception as e:
            logging.error(f"Lỗi đọc file cấu hình: {e}")

load_saved_config()

# Biến bot instance
bot_instance = None
bot_username = ""
bot_polling_thread = None
stop_polling_flag = False


def get_cookie_file() -> str:
    """Kiểm tra và chuẩn bị file cookie tạm thời trong /tmp có quyền ghi."""
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
        tmp_cookie = f"/tmp/cookies_{int(time.time() * 1000)}_{threading.get_ident()}.txt"
        shutil.copyfile(COOKIES_FILE, tmp_cookie)
        os.chmod(tmp_cookie, 0o666)
        return tmp_cookie
    except Exception as e:
        logging.warning(f"Lỗi chuẩn bị cookie file: {e}")
        return ""


def is_authorized(user_id: int, chat_id: int) -> bool:
    allowed_str = CURRENT_CONFIG.get('allowed_users', '').strip()
    if not allowed_str:
        return True
    allowed_set = set()
    for uid in allowed_str.split(','):
        uid = uid.strip()
        if uid.lstrip('-').isdigit():
            allowed_set.add(int(uid))
    return (user_id in allowed_set) or (chat_id in allowed_set)


def extract_url(message) -> str:
    text = message.text or message.caption or ""
    urls = URL_REGEX.findall(text)
    if urls:
        return urls[0]
    if message.reply_to_message:
        rep_text = message.reply_to_message.text or message.reply_to_message.caption or ""
        rep_urls = URL_REGEX.findall(rep_text)
        if rep_urls:
            return rep_urls[0]
    return ""


def download_and_process(bot, chat_id: int, msg_id: int, user_id: int, url: str, is_audio: bool = False, force_spoiler: bool = None):
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

        # Quyết định có làm mờ (spoiler) video hay không
        if force_spoiler is not None:
            use_spoiler = force_spoiler
        else:
            use_spoiler = CURRENT_CONFIG.get('send_spoiler', False)

        if filesize <= MAX_TG_SIZE_BYTES:
            try:
                bot.edit_message_text(
                    f"📤 <b>Đang gửi tệp lên Telegram ({filesize_mb:.1f} MB)...</b>" +
                    (" <i>(Chế độ mờ/Spoiler)</i>" if use_spoiler and not is_audio else ""),
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
                        reply_to_message_id=msg_id,
                        duration=duration,
                        width=width,
                        height=height,
                        supports_streaming=True,
                        has_spoiler=use_spoiler  # <-- Gửi video dạng mờ (Spoiler)
                    )

            # Dọn dẹp tệp trên máy chủ ngay sau khi gửi thành công vào Telegram để giải phóng dung lượng
            try:
                if filepath and os.path.exists(filepath):
                    os.remove(filepath)
                    logging.info(f"Đã dọn dẹp file sau khi gửi Telegram: {filepath}")
                # Xóa các tệp phụ/thumbnail tạm nếu có
                base_path, _ = os.path.splitext(filepath)
                for ext in ('.jpg', '.png', '.webp', '.part', '.temp', '.info.json', '.description'):
                    extra_f = base_path + ext
                    if os.path.exists(extra_f):
                        try:
                            os.remove(extra_f)
                        except Exception:
                            pass
            except Exception as del_err:
                logging.warning(f"Lỗi khi dọn dẹp file {filepath}: {del_err}")

            try:
                bot.delete_message(chat_id, status_msg.message_id)
            except Exception:
                pass
        else:
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
            hint = "YouTube yêu cầu xác minh bot. Hãy dán cookies.txt vào phần quản lý Cookie."
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


# Thiết lập các lệnh cho Bot
def setup_bot_handlers(bot):
    @bot.message_handler(commands=['start', 'help'])
    def handle_start(message):
        if not is_authorized(message.from_user.id, message.chat.id):
            bot.reply_to(message, "⛔ Bạn không có quyền sử dụng bot này.")
            return

        spoiler_status = "BẬT (Mờ)" if CURRENT_CONFIG.get('send_spoiler') else "TẮT (Rõ)"
        welcome_text = (
            f"👋 <b>Chào mừng bạn đến với Bot Tải Video Đa Nền Tảng!</b>\n\n"
            f"🚀 <b>CÁCH SỬ DỤNG:</b>\n"
            f"1. <b>Chat 1-1:</b> Gửi trực tiếp bất kỳ link video nào (YouTube, TikTok, Facebook, Instagram,...)\n"
            f"2. <b>Trong Nhóm Chat:</b> Tag <code>@{bot_username} [link]</code> hoặc Reply tin nhắn có link kèm tag bot.\n"
            f"3. <b>Tải chỉ tệp âm thanh (MP3):</b> Gõ <code>/mp3 [link]</code>\n"
            f"4. <b>Chế độ Video Mờ (Spoiler):</b>\n"
            f"   • Trạng thái mặc định hiện tại: <b>{spoiler_status}</b>\n"
            f"   • Tải video dạng mờ: <code>/spoiler [link]</code>\n"
            f"   • Tải video rõ nét bình thường: <code>/nospoiler [link]</code>\n"
            f"   • Đổi mặc định: <code>/spoiler on</code> hoặc <code>/spoiler off</code>\n\n"
            f"🌐 <b>Giao diện Web Cấu hình & Tải video:</b>\n"
            f"<code>http://{PUBLIC_IP}:{WEB_PORT}/settings</code>"
        )
        bot.reply_to(message, welcome_text)

    @bot.message_handler(commands=['spoiler', 'nospoiler'])
    def handle_spoiler_command(message):
        if not is_authorized(message.from_user.id, message.chat.id):
            return

        cmd = message.text.split()[0].lower()
        args = message.text[len(cmd):].strip()

        if cmd.startswith('/spoiler'):
            if args.lower() in ('on', 'bat', 'true'):
                CURRENT_CONFIG['send_spoiler'] = True
                save_config_file()
                bot.reply_to(message, "✅ Đã <b>BẬT</b> chế độ gửi video dạng mờ (Spoiler) làm mặc định.")
                return
            elif args.lower() in ('off', 'tat', 'false'):
                CURRENT_CONFIG['send_spoiler'] = False
                save_config_file()
                bot.reply_to(message, "✅ Đã <b>TẮT</b> chế độ gửi video dạng mờ. Video sẽ gửi ở dạng xem trước bình thường.")
                return
            else:
                url = extract_url(message)
                if url:
                    threading.Thread(
                        target=download_and_process,
                        args=(bot, message.chat.id, message.message_id, message.from_user.id, url, False, True)
                    ).start()
                    return
                else:
                    bot.reply_to(message, "ℹ Gõ <code>/spoiler [link]</code> để tải video dạng mờ, hoặc <code>/spoiler on</code> / <code>/spoiler off</code>.")
                    return

        if cmd.startswith('/nospoiler'):
            url = extract_url(message)
            if url:
                threading.Thread(
                    target=download_and_process,
                    args=(bot, message.chat.id, message.message_id, message.from_user.id, url, False, False)
                ).start()
                return

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
            args=(bot, message.chat.id, message.message_id, message.from_user.id, url, True, None)
        ).start()

    @bot.message_handler(func=lambda m: True, content_types=['text'])
    def handle_text_messages(message):
        if not is_authorized(message.from_user.id, message.chat.id):
            return

        text = message.text or ""
        is_group = message.chat.type in ['group', 'supergroup']
        is_tagged = False

        if is_group:
            if bot_username and f"@{bot_username}" in text.lower():
                is_tagged = True
            elif message.reply_to_message and message.reply_to_message.from_user and message.reply_to_message.from_user.username:
                if message.reply_to_message.from_user.username.lower() == bot_username:
                    is_tagged = True
            elif text.startswith(('/dl', f'/dl@{bot_username}')):
                is_tagged = True
        else:
            is_tagged = True

        url = extract_url(message)
        if url and is_tagged:
            is_audio = text.startswith('/mp3')
            threading.Thread(
                target=download_and_process,
                args=(bot, message.chat.id, message.message_id, message.from_user.id, url, is_audio, None)
            ).start()


def save_config_file():
    with CONFIG_LOCK:
        try:
            os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
            with open(CONFIG_FILE, 'w', encoding='utf-8') as f:
                json.dump(CURRENT_CONFIG, f, ensure_ascii=False, indent=2)
            logging.info("Đã lưu cấu hình vào file JSON.")
        except Exception as e:
            logging.error(f"Lỗi ghi cấu hình: {e}")


def start_bot_worker():
    global bot_instance, bot_username, stop_polling_flag
    token = CURRENT_CONFIG.get('bot_token', '').strip()
    if not token:
        logging.warning("Chưa cấu hình Telegram Bot Token. Đang chờ nhập qua Giao diện Web hoặc CLI.")
        return

    try:
        b = telebot.TeleBot(token, parse_mode='HTML')
        info = b.get_me()
        bot_username = (info.username or '').lower()
        bot_instance = b
        setup_bot_handlers(b)
        logging.info(f"Bot Telegram đã kích hoạt: @{bot_username} (ID: {info.id})")
        stop_polling_flag = False

        def poll_loop():
            while not stop_polling_flag:
                try:
                    b.infinity_polling(timeout=20, long_polling_timeout=20, skip_pending=True)
                except Exception as ex:
                    logging.error(f"Lỗi polling: {ex}")
                    time.sleep(5)

        t = threading.Thread(target=poll_loop, daemon=True)
        t.start()
    except Exception as e:
        logging.error(f"Không thể khởi chạy bot với token hiện tại: {e}")
        bot_instance = None
        bot_username = ""


# ==============================================================================
# FLASK WEB APPLICATION (Giao diện Web HTML Cấu hình Bot Token & Video Mờ)
# ==============================================================================
app = Flask(__name__)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Cấu hình Telegram Bot & Tải Video (yt-dlp)</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap" rel="stylesheet">
  <style>
    body { font-family: 'Plus Jakarta Sans', sans-serif; }
    .glass-card { background: rgba(30, 41, 59, 0.7); backdrop-filter: blur(12px); border: 1px solid rgba(255, 255, 255, 0.08); }
    .glow-cyan { box-shadow: 0 0 25px rgba(6, 182, 212, 0.25); }
    .toggle-checkbox:checked { right: 0; border-color: #06b6d4; }
    .toggle-checkbox:checked + .toggle-label { background-color: #06b6d4; }
  </style>
</head>
<body class="bg-slate-950 text-slate-100 min-h-screen">
  <!-- Thanh Header Điều Hướng -->
  <header class="border-b border-slate-800 bg-slate-900/60 sticky top-0 z-50 backdrop-blur-md">
    <div class="max-w-6xl mx-auto px-4 py-3 flex items-center justify-between">
      <div class="flex items-center space-x-3">
        <div class="w-10 h-10 rounded-xl bg-gradient-to-tr from-cyan-500 to-blue-600 flex items-center justify-center text-white font-bold text-xl shadow-lg shadow-cyan-500/20">
          🎬
        </div>
        <div>
          <h1 class="font-bold text-lg text-white">YT-DLP Downloader</h1>
          <p class="text-xs text-slate-400">Giao diện Cấu hình Telegram Bot & Quản lý Video</p>
        </div>
      </div>
      <div class="flex items-center space-x-3">
        <a href="/" target="_blank" class="px-4 py-2 text-xs font-semibold rounded-lg bg-slate-800 hover:bg-slate-700 text-cyan-400 border border-slate-700 flex items-center space-x-1.5 transition">
          <span>🚀 Mở MeTube Web UI</span>
          <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"></path></svg>
        </a>
      </div>
    </div>
  </header>

  <main class="max-w-6xl mx-auto px-4 py-8">
    <!-- Hàng Thông Tin Trạng Thái -->
    <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-8">
      <div class="glass-card rounded-2xl p-5">
        <div class="text-xs font-semibold uppercase tracking-wider text-slate-400 mb-1">Trạng Thái Telegram Bot</div>
        <div class="flex items-center space-x-2 mt-2" id="botStatusBadge">
          <div class="w-3 h-3 rounded-full bg-amber-400 animate-pulse"></div>
          <span class="font-bold text-sm text-slate-200">Đang kiểm tra...</span>
        </div>
        <div class="text-xs text-slate-400 mt-2" id="botUsernameText">Chưa cấu hình</div>
      </div>

      <div class="glass-card rounded-2xl p-5">
        <div class="text-xs font-semibold uppercase tracking-wider text-slate-400 mb-1">Chế Độ Video Mờ (Spoiler)</div>
        <div class="flex items-center space-x-2 mt-2" id="spoilerStatusBadge">
          <span class="font-bold text-base text-cyan-400">---</span>
        </div>
        <div class="text-xs text-slate-400 mt-2">Che mờ video Telegram để chống xem trộm</div>
      </div>

      <div class="glass-card rounded-2xl p-5">
        <div class="text-xs font-semibold uppercase tracking-wider text-slate-400 mb-1">Thư Mục Tải Về (/downloads)</div>
        <div class="flex items-baseline space-x-2 mt-2">
          <span class="font-extrabold text-2xl text-white" id="fileCountText">0</span>
          <span class="text-xs text-slate-400">tệp tin</span>
          <span class="text-xs text-cyan-400 ml-auto font-medium" id="totalSizeText">0 MB</span>
        </div>
        <div class="text-xs text-slate-400 mt-2">Lưu trữ trên máy chủ</div>
      </div>
    </div>

    <!-- Khối Cấu Hình Chính -->
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
      <!-- Cột Trái: Form Cấu Hình Bot & Spoiler (2 cột) -->
      <div class="lg:col-span-2 space-y-6">
        <div class="glass-card rounded-2xl p-6 glow-cyan">
          <h2 class="text-lg font-bold text-white mb-1 flex items-center space-x-2">
            <span>🤖 Cấu Hình Telegram Bot Token & Tùy Chọn</span>
          </h2>
          <p class="text-xs text-slate-400 mb-6">Nhập token từ @BotFather để bot tự động lấy link tải video và gửi lại vào chat Telegram.</p>

          <form id="botConfigForm" class="space-y-5">
            <!-- Bot Token Input -->
            <div>
              <label class="block text-xs font-bold text-slate-300 uppercase tracking-wider mb-2">Telegram Bot Token</label>
              <div class="relative">
                <input type="password" id="inputBotToken" placeholder="VD: 123456789:ABCdefGhI..." class="w-full bg-slate-900 border border-slate-700 focus:border-cyan-500 rounded-xl px-4 py-3 text-sm text-white focus:outline-none focus:ring-1 focus:ring-cyan-500 transition font-mono pr-24">
                <button type="button" onclick="toggleTokenVisibility()" class="absolute right-3 top-3 text-xs text-slate-400 hover:text-white">Hiện/Ẩn</button>
              </div>
              <div class="mt-2 flex items-center justify-between">
                <p class="text-xs text-slate-400">Tạo bot tại <a href="https://t.me/BotFather" target="_blank" class="text-cyan-400 underline">@BotFather</a></p>
                <button type="button" onclick="testBotToken()" class="text-xs px-3 py-1 bg-slate-800 hover:bg-slate-700 text-cyan-300 rounded-lg border border-slate-700 transition font-semibold">🔍 Kiểm tra kết nối</button>
              </div>
              <div id="testResult" class="mt-2 text-xs hidden"></div>
            </div>

            <!-- TÙY CHỌN: GỬI VIDEO DẠNG MỜ (SPOILER) -->
            <div class="p-4 rounded-xl bg-slate-900/80 border border-slate-800 hover:border-cyan-500/30 transition">
              <div class="flex items-center justify-between">
                <div class="pr-4">
                  <div class="font-bold text-sm text-white flex items-center space-x-2">
                    <span>✨ Gửi video dạng mờ (Spoiler)</span>
                    <span class="text-[10px] bg-cyan-500/20 text-cyan-300 px-2 py-0.5 rounded-full font-bold">KHUYÊN DÙNG</span>
                  </div>
                  <p class="text-xs text-slate-400 mt-1">
                    Khi bật, toàn bộ video gửi qua Telegram sẽ có hiệu ứng làm mờ lấp lánh (Spoiler effect). Người nhận hoặc thành viên trong nhóm phải chạm vào video mới có thể xem nội dung.
                  </p>
                </div>
                <div class="relative inline-block w-12 align-middle select-none">
                  <input type="checkbox" id="checkSendSpoiler" class="sr-only peer">
                  <label for="checkSendSpoiler" class="block overflow-hidden h-6 rounded-full bg-slate-700 cursor-pointer peer-checked:bg-cyan-500 transition-colors duration-300"></label>
                  <span class="absolute top-0.5 left-0.5 bg-white w-5 h-5 rounded-full transition-transform duration-300 transform peer-checked:translate-x-6"></span>
                </div>
              </div>
            </div>

            <!-- Allowed Users -->
            <div>
              <label class="block text-xs font-bold text-slate-300 uppercase tracking-wider mb-2">ID Người dùng / Nhóm được phép tải (Tùy chọn)</label>
              <input type="text" id="inputAllowedUsers" placeholder="VD: 12345678, -1001928374 (để trống để cho phép tất cả)" class="w-full bg-slate-900 border border-slate-700 focus:border-cyan-500 rounded-xl px-4 py-3 text-sm text-white focus:outline-none focus:ring-1 focus:ring-cyan-500 transition">
              <p class="text-xs text-slate-400 mt-1">Để trống nếu muốn bất kỳ ai gửi link hoặc tag bot trong nhóm cũng có thể tải.</p>
            </div>

            <!-- Nút Lưu Cấu Hình -->
            <div class="pt-2">
              <button type="submit" id="btnSaveConfig" class="w-full py-3.5 px-6 rounded-xl bg-gradient-to-r from-cyan-500 to-blue-600 hover:from-cyan-400 hover:to-blue-500 text-white font-bold text-sm shadow-lg shadow-cyan-500/25 transition flex items-center justify-center space-x-2">
                <span>💾 Lưu Cấu Hình & Khởi Động Bot</span>
              </button>
            </div>
            <div id="saveToast" class="text-xs text-center font-bold text-green-400 hidden py-2 bg-green-500/10 rounded-lg border border-green-500/20"></div>
          </form>
        </div>

        <!-- Quản lý Cookie -->
        <div class="glass-card rounded-2xl p-6">
          <h2 class="text-lg font-bold text-white mb-1 flex items-center space-x-2">
            <span>🍪 Quản Lý Cookie (Vượt bot check YouTube / TikTok / Facebook)</span>
          </h2>
          <p class="text-xs text-slate-400 mb-4">Dán nội dung file <code class="text-cyan-400">cookies.txt</code> (chuẩn Netscape) vào đây để vượt qua thông báo "Sign in to confirm you're not a bot".</p>

          <form id="cookieForm" class="space-y-4">
            <textarea id="cookiesTextarea" rows="6" placeholder="# Netscape HTTP Cookie File&#10;# Dán nội dung xuất từ extension 'Get cookies.txt LOCALLY' vào đây..." class="w-full bg-slate-900 border border-slate-700 focus:border-cyan-500 rounded-xl p-4 text-xs font-mono text-slate-300 focus:outline-none focus:ring-1 focus:ring-cyan-500 transition"></textarea>
            <div class="flex items-center justify-between">
              <span id="cookieStatusText" class="text-xs text-slate-400">Đang kiểm tra cookie...</span>
              <button type="submit" class="px-5 py-2.5 bg-slate-800 hover:bg-slate-700 text-cyan-400 border border-slate-700 rounded-xl text-xs font-bold transition">
                Lưu Cookies
              </button>
            </div>
            <div id="cookieToast" class="text-xs text-center font-bold text-green-400 hidden py-2 bg-green-500/10 rounded-lg"></div>
          </form>
        </div>
      </div>

      <!-- Cột Phải: Hướng Dẫn & Danh Sách Video Mới Tải (1 cột) -->
      <div class="space-y-6">
        <!-- Hướng dẫn sử dụng nhanh -->
        <div class="glass-card rounded-2xl p-6">
          <h3 class="text-sm font-bold text-white uppercase tracking-wider mb-3">💡 Mẹo Sử Dụng Bot Telegram</h3>
          <ul class="text-xs text-slate-300 space-y-2.5 leading-relaxed">
            <li>• <b>Trong Chat Riêng:</b> Gửi trực tiếp link TikTok, YouTube, Reels,...</li>
            <li>• <b>Trong Nhóm Chat:</b> Tag <code class="text-cyan-400">@bot_username [link]</code> hoặc Reply tin nhắn có link.</li>
            <li>• <b>Chế độ Mờ tức thì:</b> Gõ <code class="text-cyan-400">/spoiler [link]</code>.</li>
            <li>• <b>Chế độ Rõ tức thì:</b> Gõ <code class="text-cyan-400">/nospoiler [link]</code>.</li>
            <li>• <b>Tách nhạc MP3:</b> Gõ <code class="text-cyan-400">/mp3 [link]</code>.</li>
            <li>• <b>Cấu hình nhóm:</b> Tại @BotFather gõ <code class="text-cyan-400">/setprivacy</code> -> Chọn bot -> <b>Disable</b> để bot thấy tin nhắn nhóm.</li>
          </ul>
        </div>

        <!-- Danh sách tệp video đã tải -->
        <div class="glass-card rounded-2xl p-6">
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-sm font-bold text-white uppercase tracking-wider">📁 Tệp Video Gần Đây</h3>
            <button onclick="loadFilesList()" class="text-xs text-cyan-400 hover:underline">Làm mới</button>
          </div>
          <div id="filesListContainer" class="space-y-2 max-h-80 overflow-y-auto pr-1 text-xs">
            <div class="text-slate-400 py-4 text-center">Đang tải danh sách...</div>
          </div>
        </div>
      </div>
    </div>
  </main>

  <script>
    // Tải cấu hình khi mở trang
    async function loadStatus() {
      try {
        const res = await fetch('/api/status');
        const data = await res.json();

        // Bot status badge
        const badge = document.getElementById('botStatusBadge');
        const usernameText = document.getElementById('botUsernameText');
        if (data.bot_username) {
          badge.innerHTML = `<div class="w-3 h-3 rounded-full bg-green-400"></div><span class="font-bold text-sm text-green-400">Đang hoạt động</span>`;
          usernameText.innerHTML = `Bot: <b class="text-white">@${data.bot_username}</b>`;
        } else if (data.has_token) {
          badge.innerHTML = `<div class="w-3 h-3 rounded-full bg-amber-400 animate-pulse"></div><span class="font-bold text-sm text-amber-400">Đang khởi động...</span>`;
          usernameText.innerText = 'Token hợp lệ';
        } else {
          badge.innerHTML = `<div class="w-3 h-3 rounded-full bg-red-400"></div><span class="font-bold text-sm text-red-400">Chưa cấu hình Token</span>`;
          usernameText.innerText = 'Vui lòng nhập Token bên dưới';
        }

        // Spoiler Status badge
        const spoilerBadge = document.getElementById('spoilerStatusBadge');
        if (data.send_spoiler) {
          spoilerBadge.innerHTML = `<span class="px-2.5 py-1 rounded-lg bg-cyan-500/20 text-cyan-300 font-bold text-sm">✨ BẬT (Làm mờ)</span>`;
        } else {
          spoilerBadge.innerHTML = `<span class="px-2.5 py-1 rounded-lg bg-slate-800 text-slate-300 font-semibold text-sm">TẮT (Gửi rõ nét)</span>`;
        }

        // Điền form
        document.getElementById('inputBotToken').value = data.bot_token || '';
        document.getElementById('checkSendSpoiler').checked = !!data.send_spoiler;
        document.getElementById('inputAllowedUsers').value = data.allowed_users || '';

        // File stats
        document.getElementById('fileCountText').innerText = data.files_count || 0;
        document.getElementById('totalSizeText').innerText = data.total_size || '0 MB';

        // Cookie status
        const cookieStatus = document.getElementById('cookieStatusText');
        if (data.has_cookies) {
          cookieStatus.innerHTML = `<span class="text-green-400">✓ Đã nạp Cookie hợp lệ</span>`;
        } else {
          cookieStatus.innerHTML = `<span class="text-slate-400">Chưa có cookie (không bắt buộc)</span>`;
        }
      } catch (err) {
        console.error("Lỗi nạp status:", err);
      }
    }

    // Toggle password
    function toggleTokenVisibility() {
      const input = document.getElementById('inputBotToken');
      input.type = input.type === 'password' ? 'text' : 'password';
    }

    // Kiểm tra token
    async function testBotToken() {
      const token = document.getElementById('inputBotToken').value.trim();
      const resultDiv = document.getElementById('testResult');
      resultDiv.classList.remove('hidden');
      if (!token) {
        resultDiv.innerHTML = `<span class="text-red-400">Vui lòng nhập Token trước khi kiểm tra!</span>`;
        return;
      }
      resultDiv.innerHTML = `<span class="text-slate-400">Đang kiểm tra với Telegram API...</span>`;

      try {
        const res = await fetch('/api/test-token', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({ token })
        });
        const data = await res.json();
        if (data.ok) {
          resultDiv.innerHTML = `<span class="text-green-400 font-semibold">✓ Hợp lệ! Tên Bot: <b>@${data.username}</b> (${data.first_name})</span>`;
        } else {
          resultDiv.innerHTML = `<span class="text-red-400 font-semibold">✗ Không hợp lệ: ${data.error}</span>`;
        }
      } catch (err) {
        resultDiv.innerHTML = `<span class="text-red-400 font-semibold">✗ Lỗi kết nối API</span>`;
      }
    }

    // Lưu Cấu hình Bot & Spoiler
    document.getElementById('botConfigForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const token = document.getElementById('inputBotToken').value.trim();
      const send_spoiler = document.getElementById('checkSendSpoiler').checked;
      const allowed_users = document.getElementById('inputAllowedUsers').value.trim();
      const toast = document.getElementById('saveToast');

      toast.classList.remove('hidden');
      toast.className = 'text-xs text-center font-bold text-cyan-400 py-2 bg-cyan-500/10 rounded-lg';
      toast.innerText = 'Đang lưu cấu hình và kết nối lại bot...';

      try {
        const res = await fetch('/api/save-config', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({ token, send_spoiler, allowed_users })
        });
        const data = await res.json();
        if (data.ok) {
          toast.className = 'text-xs text-center font-bold text-green-400 py-2 bg-green-500/10 rounded-lg';
          toast.innerText = '✓ ' + data.message;
          setTimeout(() => { toast.classList.add('hidden'); }, 4000);
          loadStatus();
        } else {
          toast.className = 'text-xs text-center font-bold text-red-400 py-2 bg-red-500/10 rounded-lg';
          toast.innerText = '✗ ' + data.error;
        }
      } catch (err) {
        toast.className = 'text-xs text-center font-bold text-red-400 py-2 bg-red-500/10 rounded-lg';
        toast.innerText = '✗ Lỗi kết nối khi lưu cấu hình';
      }
    });

    // Lưu Cookies
    document.getElementById('cookieForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const content = document.getElementById('cookiesTextarea').value;
      const toast = document.getElementById('cookieToast');
      toast.classList.remove('hidden');
      toast.innerText = 'Đang lưu cookie...';

      try {
        const res = await fetch('/api/save-cookies', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({ content })
        });
        const data = await res.json();
        if (data.ok) {
          toast.className = 'text-xs text-center font-bold text-green-400 py-2 bg-green-500/10 rounded-lg';
          toast.innerText = '✓ Đã lưu nội dung cookie thành công!';
          setTimeout(() => { toast.classList.add('hidden'); }, 3000);
          loadStatus();
        } else {
          toast.className = 'text-xs text-center font-bold text-red-400 py-2 bg-red-500/10 rounded-lg';
          toast.innerText = '✗ ' + data.error;
        }
      } catch (err) {
        toast.innerText = '✗ Lỗi khi lưu cookies';
      }
    });

    // Tải nội dung cookie ban đầu
    async function loadCookieContent() {
      try {
        const res = await fetch('/api/get-cookies');
        const data = await res.json();
        if (data.content) {
          document.getElementById('cookiesTextarea').value = data.content;
        }
      } catch (err) {}
    }

    // Tải danh sách tệp video
    async function loadFilesList() {
      const container = document.getElementById('filesListContainer');
      container.innerHTML = `<div class="text-slate-400 py-4 text-center">Đang tải...</div>`;
      try {
        const res = await fetch('/api/files');
        const files = await res.json();
        if (!files.length) {
          container.innerHTML = `<div class="text-slate-500 py-4 text-center">Chưa có tệp video nào trong /downloads</div>`;
          return;
        }
        container.innerHTML = files.map(f => `
          <div class="p-2.5 rounded-xl bg-slate-900 border border-slate-800 flex items-center justify-between">
            <div class="truncate pr-2">
              <div class="font-semibold text-slate-200 truncate" title="${f.name}">${f.name}</div>
              <div class="text-[10px] text-slate-500">${f.time}</div>
            </div>
            <span class="text-xs font-mono text-cyan-400 font-bold whitespace-nowrap">${f.size}</span>
          </div>
        `).join('');
      } catch (err) {
        container.innerHTML = `<div class="text-red-400 py-2 text-center">Không thể tải danh sách</div>`;
      }
    }

    // Tải trang lần đầu
    loadStatus();
    loadCookieContent();
    loadFilesList();
  </script>
</body>
</html>
"""

@app.route('/')
@app.route('/settings')
@app.route('/bot')
def settings_page():
    return render_template_string(HTML_TEMPLATE)

@app.route('/api/status')
def api_status():
    files_count = 0
    total_size_mb = 0.0
    if os.path.exists(DOWNLOAD_DIR):
        try:
            for root, _, files in os.walk(DOWNLOAD_DIR):
                for f in files:
                    fp = os.path.join(root, f)
                    if os.path.isfile(fp):
                        files_count += 1
                        total_size_mb += os.path.getsize(fp) / (1024 * 1024)
        except Exception:
            pass

    has_real_cookie = False
    if os.path.exists(COOKIES_FILE):
        try:
            with open(COOKIES_FILE, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    if line.strip() and not line.strip().startswith('#'):
                        has_real_cookie = True
                        break
        except Exception:
            pass

    return jsonify({
        'bot_token': CURRENT_CONFIG.get('bot_token', ''),
        'has_token': bool(CURRENT_CONFIG.get('bot_token')),
        'bot_username': bot_username,
        'send_spoiler': CURRENT_CONFIG.get('send_spoiler', False),
        'allowed_users': CURRENT_CONFIG.get('allowed_users', ''),
        'has_cookies': has_real_cookie,
        'files_count': files_count,
        'total_size': f"{total_size_mb:.1f} MB",
        'public_ip': PUBLIC_IP,
        'web_port': WEB_PORT
    })

@app.route('/api/test-token', methods=['POST'])
def api_test_token():
    data = request.json or {}
    token = data.get('token', '').strip()
    if not token:
        return jsonify({'ok': False, 'error': 'Token rỗng'})

    try:
        r = requests.get(f"https://api.telegram.org/bot{token}/getMe", timeout=6)
        res = r.json()
        if res.get('ok'):
            user = res.get('result', {})
            return jsonify({
                'ok': True,
                'username': user.get('username', ''),
                'first_name': user.get('first_name', ''),
                'id': user.get('id')
            })
        else:
            return jsonify({'ok': False, 'error': res.get('description', 'Token không hợp lệ')})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)})

@app.route('/api/save-config', methods=['POST'])
def api_save_config():
    global bot_instance, bot_username, stop_polling_flag
    data = request.json or {}
    token = data.get('token', '').strip()
    send_spoiler = bool(data.get('send_spoiler', False))
    allowed_users = data.get('allowed_users', '').strip()

    CURRENT_CONFIG['bot_token'] = token
    CURRENT_CONFIG['send_spoiler'] = send_spoiler
    CURRENT_CONFIG['allowed_users'] = allowed_users
    save_config_file()

    # Khởi động lại Bot với token mới
    if token:
        try:
            r = requests.get(f"https://api.telegram.org/bot{token}/getMe", timeout=6).json()
            if not r.get('ok'):
                return jsonify({'ok': False, 'error': 'Token không hợp lệ theo Telegram API'})
        except Exception as e:
            return jsonify({'ok': False, 'error': f'Lỗi kiểm tra token: {e}'})

        stop_polling_flag = True
        time.sleep(1)
        start_bot_worker()
        return jsonify({'ok': True, 'message': f'Đã lưu cấu hình và kết nối thành công tới @{bot_username}!'})
    else:
        bot_username = ""
        return jsonify({'ok': True, 'message': 'Đã lưu cấu hình (chưa có token bot).'})

@app.route('/api/get-cookies')
def api_get_cookies():
    content = ""
    if os.path.exists(COOKIES_FILE):
        try:
            with open(COOKIES_FILE, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
        except Exception:
            pass
    return jsonify({'content': content})

@app.route('/api/save-cookies', methods=['POST'])
def api_save_cookies():
    data = request.json or {}
    content = data.get('content', '')
    try:
        os.makedirs(os.path.dirname(COOKIES_FILE), exist_ok=True)
        with open(COOKIES_FILE, 'w', encoding='utf-8') as f:
            f.write(content)
        os.chmod(COOKIES_FILE, 0o666)
        return jsonify({'ok': True})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)})

@app.route('/api/files')
def api_files():
    file_list = []
    if os.path.exists(DOWNLOAD_DIR):
        try:
            for f in sorted(os.listdir(DOWNLOAD_DIR), key=lambda x: os.path.getmtime(os.path.join(DOWNLOAD_DIR, x)) if os.path.isfile(os.path.join(DOWNLOAD_DIR, x)) else 0, reverse=True):
                fp = os.path.join(DOWNLOAD_DIR, f)
                if os.path.isfile(fp) and not f.startswith('.'):
                    size_mb = os.path.getsize(fp) / (1024 * 1024)
                    mtime = time.strftime('%H:%M %d/%m/%Y', time.localtime(os.path.getmtime(fp)))
                    file_list.append({
                        'name': f,
                        'size': f"{size_mb:.1f} MB",
                        'time': mtime
                    })
                    if len(file_list) >= 20:
                        break
        except Exception:
            pass
    return jsonify(file_list)


if __name__ == '__main__':
    # Bắt đầu bot worker
    start_bot_worker()
    # Chạy Flask Web UI
    logging.info("Khởi chạy Flask Web Settings Server tại cổng 5000...")
    app.run(host='0.0.0.0', port=5000, debug=False, use_reloader=False)
EOF
}

# Tạo cấu hình Nginx Reverse Proxy
generate_nginx_conf() {
    cat > "$NGINX_CONF" << 'EOF'
server {
    listen 80;
    server_name _;
    client_max_body_size 100M;

    # Giao diện Cấu hình Web: Bot Token, Video Mờ (Spoiler), Cookie
    location /settings {
        proxy_pass http://telegram-bot:5000/settings;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /bot {
        proxy_pass http://telegram-bot:5000/settings;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /api/ {
        proxy_pass http://telegram-bot:5000/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # Giao diện chính MeTube Web UI
    location / {
        proxy_pass http://metube:8081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
}

# Tạo docker-compose.yml
generate_docker_compose() {
    local port="$1"
    local bot_port="$2"
    local download_dir="$3"

    mkdir -p "$download_dir"
    mkdir -p "$COOKIES_DIR"
    mkdir -p "$CONFIG_DIR"
    chmod 777 "$COOKIES_DIR" "$CONFIG_DIR" 2>/dev/null || true
    generate_bot_files
    generate_nginx_conf

    # Tạo tệp cookies.txt mẫu nếu chưa có
    if [ ! -f "$COOKIES_DIR/cookies.txt" ]; then
        cat > "$COOKIES_DIR/cookies.txt" << 'EOF'
# Netscape HTTP Cookie File
# Dán nội dung cookie xuất từ trình duyệt vào đây hoặc dán qua Web UI (/settings)
EOF
    fi
    chmod 666 "$COOKIES_DIR/cookies.txt" 2>/dev/null || true

    # Tạo file cấu hình bot_config.json nếu chưa có
    if [ ! -f "$CONFIG_DIR/bot_config.json" ]; then
        cat > "$CONFIG_DIR/bot_config.json" << EOF
{
  "bot_token": "${BOT_TOKEN}",
  "allowed_users": "${ALLOWED_USERS}",
  "send_spoiler": ${SEND_SPOILER:-false}
}
EOF
    fi
    chmod 666 "$CONFIG_DIR/bot_config.json" 2>/dev/null || true

    # Kiểm tra xem cookies.txt có dữ liệu thực hay chỉ có chú thích
    local metube_cookie_env=""
    if grep -q -v '^[[:space:]]*#' "$COOKIES_DIR/cookies.txt" 2>/dev/null && grep -q -v '^[[:space:]]*$' "$COOKIES_DIR/cookies.txt" 2>/dev/null; then
        metube_cookie_env='- YTDL_OPTIONS={"cookiefile":"/cookies/cookies.txt"}'
    fi

    cat > "$COMPOSE_FILE" <<EOF
services:
  gateway:
    image: nginx:alpine
    container_name: ytdlp-gateway
    restart: unless-stopped
    ports:
      - "0.0.0.0:${port}:80"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - metube
      - telegram-bot

  metube:
    image: ghcr.io/alexta69/metube:latest
    container_name: ytdlp-metube
    restart: unless-stopped
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
    ports:
      - "0.0.0.0:${bot_port}:5000"
    volumes:
      - "${download_dir}:/downloads"
      - "${COOKIES_DIR}:/cookies"
      - "${CONFIG_DIR}:/config"
    environment:
      - TELEGRAM_BOT_TOKEN=\${TELEGRAM_BOT_TOKEN:-}
      - TELEGRAM_ALLOWED_USERS=\${TELEGRAM_ALLOWED_USERS:-}
      - TELEGRAM_SEND_SPOILER=\${TELEGRAM_SEND_SPOILER:-false}
      - PUBLIC_IP=\${PUBLIC_IP:-localhost}
      - WEB_PORT=${port}
      - DOWNLOAD_DIR=/downloads
      - CONFIG_FILE=/config/bot_config.json
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

# Triển khai cài đặt hệ thống yt-dlp, MeTube, Web Settings & Telegram Bot
deploy_ytdlp() {
    ensure_docker_and_compose
    detect_os
    get_server_ips
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$COOKIES_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$BOT_DIR"
    cd "$INSTALL_DIR"

    echo -e "\n${CYAN}${BOLD}--- CẤU HÌNH THÔNG SỐ HỆ THỐNG YT-DLP & DOCKER ---${NC}\n"

    # Nhập cổng Web UI chính
    read -rp "$(echo -e "${BOLD}1. Cổng Web UI chính (Port)${NC} [Mặc định: ${GREEN}${DEFAULT_PORT}${NC}]: ")" INPUT_PORT
    PORT="${INPUT_PORT:-$DEFAULT_PORT}"

    # Nhập cổng Web Settings trực tiếp
    read -rp "$(echo -e "${BOLD}2. Cổng Web Settings Bot trực tiếp${NC} [Mặc định: ${GREEN}${DEFAULT_BOT_PORT}${NC}]: ")" INPUT_BOT_PORT
    BOT_PORT="${INPUT_BOT_PORT:-$DEFAULT_BOT_PORT}"

    # Nhập thư mục lưu video tải về
    read -rp "$(echo -e "${BOLD}3. Thư mục lưu trữ video trên Server${NC} [Mặc định: ${GREEN}${DOWNLOAD_DIR_DEFAULT}${NC}]: ")" INPUT_DIR
    DOWNLOAD_PATH="${INPUT_DIR:-$DOWNLOAD_DIR_DEFAULT}"
    mkdir -p "$DOWNLOAD_PATH"

    # Nhập Telegram Bot Token
    echo -e "\n${BOLD}4. Cấu hình Telegram Bot Token:${NC}"
    echo -e "   (Bạn có thể cấu hình ngay hoặc để trống và cấu hình sau qua giao diện Web tại ${CYAN}http://${PUBLIC_IP}:${PORT}/settings${NC})"
    read -rp "$(echo -e "   Nhập Telegram Bot Token [Bỏ trống nếu cấu hình qua Web]: ")" INPUT_BOT_TOKEN
    BOT_TOKEN="${INPUT_BOT_TOKEN:-$BOT_TOKEN}"

    # Tùy chọn video mờ
    echo -e "\n${BOLD}5. Chế độ gửi video dạng mờ (Spoiler Effect):${NC}"
    echo -e "   Làm mờ thumbnail và nội dung video trên Telegram (người nhận chạm vào để xem)"
    read -rp "$(echo -e "   Bật mặc định không? (y/N) [Mặc định: n]: ")" INPUT_SPOILER
    if [[ "$INPUT_SPOILER" =~ ^[Yy]$ ]]; then
        SEND_SPOILER="true"
    else
        SEND_SPOILER="false"
    fi

    # Ghi cấu hình ra .env
    save_config

    # Tạo docker-compose.yml và bot files
    generate_docker_compose "$PORT" "$BOT_PORT" "$DOWNLOAD_PATH"

    # Cài đặt CLI wrapper
    install_cli_wrapper

    # Mở tường lửa cho cả 2 port
    open_firewall_port "$PORT"
    open_firewall_port "$BOT_PORT"

    # Tắt phiên bản cũ nếu đang chạy
    if [ -f "$COMPOSE_FILE" ]; then
        run_compose down 2>/dev/null || true
    fi

    echo -e "\n${BLUE}ℹ Đang tải Image Docker và xây dựng dịch vụ...${NC}"
    run_compose pull metube gateway
    run_compose build telegram-bot
    run_compose up -d

    echo -e "\n${GREEN}${BOLD}✓ Khởi tạo toàn bộ hệ thống tải video thành công!${NC}"
    post_install_guide
}

# Cấu hình hoặc đổi Telegram Bot Token & Video Mờ
configure_telegram_bot() {
    load_config
    get_server_ips
    echo -e "\n${CYAN}${BOLD}=== CẤU HÌNH TELEGRAM BOT & CHẾ ĐỘ VIDEO MỜ (SPOILER) ===${NC}\n"
    echo -e "💡 ${GREEN}GỢI Ý:${NC} Bạn có thể cấu hình trực tiếp qua Giao Diện Web cực kỳ tiện lợi tại:"
    echo -e "   👉 ${CYAN}${BOLD}http://${PUBLIC_IP}:${PORT}/settings${NC} hoặc ${CYAN}http://${PUBLIC_IP}:${BOT_PORT}/${NC}\n"

    if [ -n "$BOT_TOKEN" ]; then
        echo -e "Token hiện tại: ${GREEN}${BOT_TOKEN:0:10}****************${NC}"
    else
        echo -e "Token hiện tại: ${YELLOW}(Chưa cấu hình)${NC}"
    fi
    echo -e "Chế độ Video Mờ (Spoiler): ${CYAN}${SEND_SPOILER}${NC}\n"

    read -rp "Nhập Telegram Bot Token mới [Enter để giữ nguyên]: " NEW_TOKEN
    if [ -n "$NEW_TOKEN" ]; then
        BOT_TOKEN="$NEW_TOKEN"
    fi

    read -rp "Bật chế độ gửi video dạng mờ (Spoiler) mặc định? (y/N/Enter giữ nguyên): " NEW_SPOILER_CHOICE
    if [[ "$NEW_SPOILER_CHOICE" =~ ^[Yy]$ ]]; then
        SEND_SPOILER="true"
    elif [[ "$NEW_SPOILER_CHOICE" =~ ^[Nn]$ ]]; then
        SEND_SPOILER="false"
    fi

    read -rp "Nhập ID người dùng / Nhóm được phép tải (cách nhau dấu phẩy, Enter giữ nguyên): " NEW_ALLOWED
    if [ -n "$NEW_ALLOWED" ]; then
        ALLOWED_USERS="$NEW_ALLOWED"
    fi

    save_config
    generate_docker_compose "$PORT" "$BOT_PORT" "$DOWNLOAD_PATH"

    cd "$INSTALL_DIR"
    echo -e "\n${BLUE}ℹ Đang khởi động lại dịch vụ Telegram Bot...${NC}"
    run_compose build telegram-bot
    run_compose up -d --force-recreate telegram-bot gateway

    echo -e "${GREEN}${BOLD}✓ Cập nhật thành công!${NC}\n"
}

# Hướng dẫn chi tiết sau khi cài đặt
post_install_guide() {
    load_config
    get_server_ips

    echo -e "\n${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${GREEN}${BOLD}   🎉 HỆ THỐNG YT-DLP, METUBE & TELEGRAM BOT ĐÃ SẴN SÀNG!        ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"

    echo -e "${BOLD}🌐 1. TRUY CẬP GIAO DIỆN WEB:${NC}"
    echo -e "   • Giao diện Web Tải Video (MeTube):"
    echo -e "     👉 ${GREEN}${BOLD}http://${PUBLIC_IP}:${PORT}${NC}"
    echo -e "   • Giao diện Web Cấu Hình Bot Token & Video Mờ (Settings Dashboard):"
    echo -e "     👉 ${CYAN}${BOLD}http://${PUBLIC_IP}:${PORT}/settings${NC} (hoặc cổng ${CYAN}http://${PUBLIC_IP}:${BOT_PORT}/${NC})"
    echo -e "     ${YELLOW}→ Tại trang Settings bạn có thể nhập Token, bấm nút kiểm tra, bật/tắt video mờ (spoiler) và dán cookie trực tiếp!${NC}"

    echo -e "\n${BOLD}🤖 2. CÁC TÍNH NĂNG TELEGRAM BOT:${NC}"
    echo -e "   • ${BOLD}Tải video dạng mờ (Spoiler):${NC} Gửi lệnh ${CYAN}/spoiler [link]${NC}"
    echo -e "   • ${BOLD}Tải video bình thường:${NC} Gửi lệnh ${CYAN}/nospoiler [link]${NC}"
    echo -e "   • ${BOLD}Tách nhạc MP3:${NC} Gửi lệnh ${CYAN}/mp3 [link]${NC}"
    echo -e "   • ${BOLD}Bật/Tắt chế độ mờ trong chat:${NC} Gõ ${CYAN}/spoiler on${NC} hoặc ${CYAN}/spoiler off${NC}"

    echo -e "\n${BOLD}💻 3. TẢI VIDEO TỪ DÒNG LỆNH (CLI):${NC}"
    echo -e "   • ${GREEN}ytdl \"https://www.youtube.com/watch?v=VIDEO_ID\"${NC}"
    echo -e "   • ${GREEN}ytdl -x --audio-format mp3 \"https://vt.tiktok.com/ZSxxxx/\"${NC}"

    echo -e "\n${BOLD}📁 4. THƯ MỤC LƯU TRỮ TRÊN MÁY CHỦ:${NC}"
    echo -e "   • Thư mục video đã tải:  ${MAGENTA}${BOLD}${DOWNLOAD_PATH}${NC}"
    echo -e "   • Thư mục cookies:       ${MAGENTA}${COOKIES_DIR}/cookies.txt${NC}"
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

    echo -e "\n${BLUE}ℹ Kiểm tra Port chính ${PORT}:${NC}"
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

    echo -e "\n${BLUE}ℹ Kiểm tra phản hồi Web Gateway:${NC}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "http://127.0.0.1:${PORT}" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✓ MeTube Web UI phản hồi HTTP 200 OK! Hoạt động hoàn hảo.${NC}"
    else
        echo -e "${YELLOW}⚠ Phản hồi HTTP MeTube: ${HTTP_CODE}.${NC}"
    fi

    HTTP_CODE_SETTINGS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 "http://127.0.0.1:${PORT}/settings" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE_SETTINGS" = "200" ]; then
        echo -e "${GREEN}✓ Web Settings Dashboard (/settings) phản hồi HTTP 200 OK!${NC}"
    else
        echo -e "${YELLOW}⚠ Phản hồi HTTP Settings: ${HTTP_CODE_SETTINGS}.${NC}"
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
        echo -e "   1) ${GREEN}Xem toàn bộ logs hệ thống${NC}"
        echo -e "   2) ${CYAN}Chỉ xem logs Telegram Bot & Web Settings${NC}"
        echo -e "   3) ${BLUE}Chỉ xem logs MeTube Web UI${NC}"
        read -rp "Lựa chọn [1-3] (Mặc định: 1): " LOG_CHOICE
        LOG_CHOICE="${LOG_CHOICE:-1}"

        echo -e "\n${BLUE}ℹ Đang hiển thị live log (Nhấn Ctrl+C để thoát)...${NC}\n"
        case "$LOG_CHOICE" in
            1) run_compose logs -f ;;
            2) run_compose logs -f telegram-bot ;;
            3) run_compose logs -f metube ;;
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

# Cập nhật Docker Image & yt-dlp lên bản mới nhất
update_system() {
    echo -e "\n${BLUE}ℹ Đang kiểm tra và cập nhật hệ thống lên phiên bản mới nhất...${NC}"
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        generate_bot_files
        generate_nginx_conf
        run_compose pull metube gateway
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
        rm -f "$COMPOSE_FILE" "$ENV_FILE" "$NGINX_CONF" 2>/dev/null || true
        rm -rf "$BOT_DIR" "$CONFIG_DIR" 2>/dev/null || true
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
    echo -e "   1) ${GREEN}${BOLD}Cài đặt & Khởi chạy Toàn bộ Hệ thống (Web UI + Web Settings + Bot + CLI)${NC}"
    echo -e "   2) ${MAGENTA}${BOLD}Cấu hình Telegram Bot Token & Video Mờ (Spoiler) qua Terminal${NC}"
    echo -e "   3) ${YELLOW}Tải video ngay bằng Link từ dòng lệnh (Interactive Downloader)${NC}"
    echo -e "   4) ${CYAN}Kiểm tra trạng thái hệ thống & Các cổng Web (${PORT} / ${BOT_PORT})${NC}"
    echo -e "   5) Xem Live Logs thời gian thực (MeTube / Telegram Bot)"
    echo -e "   6) ${BLUE}Quản lý danh sách video đã tải (${DOWNLOAD_PATH})${NC}"
    echo -e "   7) ${GREEN}Cập nhật yt-dlp, MeTube & Bot lên bản mới nhất${NC}"
    echo -e "   8) Khởi động lại dịch vụ (Restart)"
    echo -e "   9) Dừng dịch vụ (Stop)"
    echo -e "  10) ${RED}Gỡ bỏ hệ thống hoàn toàn${NC}"
    echo -e "   0) Thoát"

    echo ""
    echo -e "👉 ${CYAN}${BOLD}GIAO DIỆN WEB:${NC}"
    echo -e "   • MeTube Web UI:     ${GREEN}http://${PUBLIC_IP}:${PORT}${NC}"
    echo -e "   • Web Cấu Hình Bot:  ${CYAN}http://${PUBLIC_IP}:${PORT}/settings${NC} (hoặc cổng ${CYAN}:${BOT_PORT}${NC})"
    echo ""
    read -rp "Nhập lựa chọn của bạn [0-10] (Mặc định: 1): " MENU_CHOICE
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
            update_system
            ;;
        8)
            restart_service
            ;;
        9)
            stop_service
            ;;
        10)
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
