#!/usr/bin/env bash

# ==============================================================================
# Script Tự Động Cài Đặt, Cấu Hình & Quản Lý Hệ Thống Tải Video Đa Nền Tảng
# Nền tảng lõi: yt-dlp (https://github.com/yt-dlp/yt-dlp)
# Triển khai: Docker & Docker Compose kèm Giao diện MeTube Web UI + CLI Wrapper ytdl
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
DEFAULT_PORT="8282"
CLI_WRAPPER="/usr/local/bin/ytdl"
CLI_WRAPPER_ALT="/usr/local/bin/yt-dlp"

# Hiển thị banner
show_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${CYAN}${BOLD}      HỆ THỐNG TẢI VIDEO ĐA NỀN TẢNG (YT-DLP & DOCKER)           ${NC}"
    echo -e "${CYAN}${BOLD}   Tích Hợp Giao Diện Web MeTube + Công Cụ Dòng Lệnh ytdl/yt-dlp  ${NC}"
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
}

# Tạo docker-compose.yml
generate_docker_compose() {
    local port="$1"
    local download_dir="$2"

    mkdir -p "$download_dir"
    mkdir -p "$COOKIES_DIR"

    # Tạo tệp cookies.txt mẫu nếu chưa có
    if [ ! -f "$COOKIES_DIR/cookies.txt" ]; then
        cat > "$COOKIES_DIR/cookies.txt" << 'EOF'
# Netscape HTTP Cookie File
# Dán nội dung cookie xuất từ trình duyệt (bằng extension "Get cookies.txt LOCALLY") vào đây
# để vượt kiểm tra bot/đăng nhập của YouTube, Facebook, TikTok.
EOF
        chmod 644 "$COOKIES_DIR/cookies.txt"
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
      - "${COOKIES_DIR}:/cookies:ro"
    environment:
      - PUID=0
      - PGID=0
      - TZ=Asia/Ho_Chi_Minh
      - DOWNLOAD_DIR=/downloads
      - STATE_DIR=/downloads/.metube
      - CUSTOM_DIRS=true
      - CREATE_CUSTOM_DIRS=true
      - OUTPUT_TEMPLATE=%(title)s.%(ext)s
      - YTDL_OPTIONS={"cookiefile":"/cookies/cookies.txt"}
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

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
if [ -f "/opt/ytdlp/cookies/cookies.txt" ] && [ -s "/opt/ytdlp/cookies/cookies.txt" ]; then
    COOKIES_ARG="-v /opt/ytdlp/cookies/cookies.txt:/cookies/cookies.txt:ro --cookiefile /cookies/cookies.txt"
fi

# Chạy container jauderho/yt-dlp hoặc ghcr.io/alexta69/metube kèm ffmpeg
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

# Triển khai cài đặt hệ thống yt-dlp & MeTube
deploy_ytdlp() {
    ensure_docker_and_compose
    detect_os
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$COOKIES_DIR"
    cd "$INSTALL_DIR"

    echo -e "\n${CYAN}${BOLD}--- CẤU HÌNH THÔNG SỐ YT-DLP & METUBE WEB UI ---${NC}\n"

    # Nhập cổng Web UI
    read -rp "$(echo -e "${BOLD}1. Cổng Web UI (Port)${NC} [Mặc định: ${GREEN}${DEFAULT_PORT}${NC}]: ")" INPUT_PORT
    PORT="${INPUT_PORT:-$DEFAULT_PORT}"

    # Nhập thư mục lưu video tải về
    read -rp "$(echo -e "${BOLD}2. Thư mục lưu trữ video trên Server${NC} [Mặc định: ${GREEN}${DOWNLOAD_DIR_DEFAULT}${NC}]: ")" INPUT_DIR
    DOWNLOAD_PATH="${INPUT_DIR:-$DOWNLOAD_DIR_DEFAULT}"
    mkdir -p "$DOWNLOAD_PATH"

    # Ghi cấu hình ra .env
    cat > "$ENV_FILE" <<EOF
YTDLP_PORT=${PORT}
YTDLP_DOWNLOAD_DIR=${DOWNLOAD_PATH}
EOF
    chmod 600 "$ENV_FILE"

    # Tạo docker-compose.yml
    generate_docker_compose "$PORT" "$DOWNLOAD_PATH"

    # Cài đặt CLI wrapper
    install_cli_wrapper

    # Mở tường lửa
    open_firewall_port "$PORT"

    # Tắt phiên bản cũ nếu đang chạy
    if [ -f "$COMPOSE_FILE" ]; then
        run_compose down 2>/dev/null || true
    fi

    echo -e "\n${BLUE}ℹ Đang tải Image Docker (ghcr.io/alexta69/metube:latest) và khởi động container...${NC}"
    run_compose pull
    run_compose up -d

    echo -e "\n${GREEN}${BOLD}✓ Khởi tạo hệ thống tải video yt-dlp thành công!${NC}"
    post_install_guide
}

# Hướng dẫn chi tiết sau khi cài đặt
post_install_guide() {
    load_config
    get_server_ips

    echo -e "\n${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${GREEN}${BOLD}    🎉 HỆ THỐNG YT-DLP & METUBE WEB UI ĐÃ SẴN SÀNG HOẠT ĐỘNG!    ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"

    echo -e "${BOLD}📌 1. TRUY CẬP GIAO DIỆN WEB (TRÌNH DUYỆT ĐIỆN THOẠI / MÁY TÍNH):${NC}"
    echo -e "   • Truy cập từ Internet:      ${GREEN}${BOLD}http://${PUBLIC_IP}:${PORT}${NC}"
    echo -e "   • Truy cập nội bộ mạng LAN:  ${GREEN}${BOLD}http://${LOCAL_IP}:${PORT}${NC}"
    echo -e "   • Localhost:                 ${GREEN}http://127.0.0.1:${PORT}${NC}"
    echo -e "   ${YELLOW}→ Dán link YouTube, TikTok, Facebook, Instagram,... chọn độ phân giải / MP3 rồi bấm Tải!${NC}"
    echo -e "   ${YELLOW}→ Web UI hỗ trợ tải trực tiếp tệp về máy tính / điện thoại của bạn.${NC}"

    echo -e "\n${BOLD}💻 2. TẢI VIDEO TRỰC TIẾP TỪ DÒNG LỆNH (CLI):${NC}"
    echo -e "   Bạn có thể dùng lệnh ${CYAN}${BOLD}ytdl${NC} hoặc ${CYAN}${BOLD}yt-dlp${NC} ở bất cứ thư mục nào trên máy chủ:"
    echo -e "   • Tải video chất lượng tốt nhất:"
    echo -e "     ${GREEN}ytdl \"https://www.youtube.com/watch?v=VIDEO_ID\"${NC}"
    echo -e "   • Tải tách lấy file âm thanh MP3:"
    echo -e "     ${GREEN}ytdl -x --audio-format mp3 \"https://www.youtube.com/watch?v=VIDEO_ID\"${NC}"
    echo -e "   • Tải video TikTok / Facebook / Douyin không logo / chất lượng cao:"
    echo -e "     ${GREEN}ytdl \"https://vt.tiktok.com/ZS...\"${NC}"
    echo -e "   • Xem danh sách định dạng có sẵn của link:"
    echo -e "     ${GREEN}ytdl -F \"LINK_VIDEO\"${NC}"

    echo -e "\n${BOLD}📁 3. THƯ MỤC LƯU TRỮ TRÊN MÁY CHỦ:${NC}"
    echo -e "   • Thư mục video đã tải:  ${MAGENTA}${BOLD}${DOWNLOAD_PATH}${NC}"
    echo -e "   • Thư mục cookies:       ${MAGENTA}${COOKIES_DIR}/cookies.txt${NC}"

    echo -e "\n${BOLD}📋 4. LỆNH QUẢN LÝ NHANH DỊCH VỤ:${NC}"
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
        echo -e "\n${BLUE}ℹ Đang hiển thị live log MeTube (Nhấn Ctrl+C để thoát)...${NC}\n"
        run_compose logs -f
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
        echo -e "${GREEN}✓ Đã lưu cookie. Đang khởi động lại container để áp dụng...${NC}"
        restart_service
    fi
}

# Cập nhật Docker Image & yt-dlp lên bản mới nhất
update_system() {
    echo -e "\n${BLUE}ℹ Đang kiểm tra và cập nhật Image yt-dlp / MeTube lên phiên bản mới nhất...${NC}"
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        run_compose pull
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
        echo -e "\n${BLUE}ℹ Đang khởi động lại container yt-dlp / MeTube...${NC}"
        run_compose restart
        echo -e "${GREEN}✓ Đã khởi động lại thành công!${NC}"
    fi
}

# Dừng dịch vụ
stop_service() {
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        echo -e "\n${YELLOW}ℹ Đang dừng container yt-dlp / MeTube...${NC}"
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
    echo -e "   1) ${GREEN}${BOLD}Cài đặt & Khởi chạy Hệ thống Tải Video (MeTube Web UI + ytdl CLI)${NC}"
    echo -e "   2) ${MAGENTA}${BOLD}Tải video ngay bằng Link từ dòng lệnh (Interactive Downloader)${NC}"
    echo -e "   3) ${YELLOW}Kiểm tra trạng thái hệ thống & Cổng Web (${PORT})${NC}"
    echo -e "   4) ${CYAN}Xem Live Logs tải video thời gian thực${NC}"
    echo -e "   5) ${BLUE}Quản lý danh sách video đã tải (${DOWNLOAD_PATH})${NC}"
    echo -e "   6) ${YELLOW}Cấu hình Cookie (Vượt bot check YouTube / FaceBook / TikTok)${NC}"
    echo -e "   7) ${GREEN}Cập nhật yt-dlp & MeTube lên bản mới nhất${NC}"
    echo -e "   8) Khởi động lại dịch vụ (Restart)"
    echo -e "   9) Dừng dịch vụ (Stop)"
    echo -e "  10) ${RED}Gỡ bỏ hệ thống hoàn toàn${NC}"
    echo -e "   0) Thoát"

    echo ""
    read -rp "Nhập lựa chọn của bạn [0-10] (Mặc định: 1): " MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE:-1}"

    case "$MENU_CHOICE" in
        1)
            deploy_ytdlp
            ;;
        2)
            download_video_interactive
            ;;
        3)
            check_status
            ;;
        4)
            view_logs
            ;;
        5)
            manage_downloads
            ;;
        6)
            configure_cookies
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
