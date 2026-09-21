#!/usr/bin/env bash

# ==============================================================================
# Script tự động cài đặt Docker cho macOS & Linux (Ubuntu/Debian/CentOS/v.v.)
# Tự nhận diện hệ điều hành, kiến trúc CPU (Apple Silicon / Intel / ARM / x86_64)
# ==============================================================================

set -e

# Màu sắc hiển thị
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "\n${CYAN}${BOLD}=================================================================${NC}"
echo -e "${CYAN}${BOLD}           SCRIPT TỰ ĐỘNG CÀI ĐẶT DOCKER (macOS & LINUX)         ${NC}"
echo -e "${CYAN}${BOLD}=================================================================${NC}\n"

# 1. Phát hiện hệ điều hành và kiến trúc chip
OS="$(uname -s)"
ARCH="$(uname -m)"

echo -e "${BLUE}ℹ Hệ điều hành phát hiện:${NC} ${BOLD}${OS}${NC}"
echo -e "${BLUE}ℹ Kiến trúc phần cứng:${NC} ${BOLD}${ARCH}${NC}"

# Kiểm tra Docker hiện tại
if command -v docker >/dev/null 2>&1; then
    DOCKER_VER=$(docker --version 2>/dev/null || echo "Unknown")
    echo -e "\n${YELLOW}⚠ Đã tìm thấy Docker trên hệ thống:${NC} ${BOLD}${DOCKER_VER}${NC}"
    read -rp "Bạn có muốn tiếp tục cài đặt / cấu hình lại không? [y/N]: " REINSTALL
    if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}✓ Giữ nguyên Docker hiện tại. Thoát script.${NC}\n"
        exit 0
    fi
fi

# ==============================================================================
# CÀI ĐẶT TRÊN MACOS
# ==============================================================================
install_macos() {
    echo -e "\n${CYAN}--- CÀI ĐẶT DOCKER CHO MACOS ---${NC}"
    echo "Chọn giải pháp Docker bạn muốn cài đặt:"
    echo "1) Docker Desktop chính thức (Khuyên dùng - GUI đầy đủ)"
    echo "2) OrbStack (Cực nhẹ, khởi động nhanh, tiết kiệm RAM/Pin trên Mac)"
    echo "3) Colima + Docker CLI (Dành cho command-line, không cần GUI)"
    echo "4) Tải trực tiếp Docker Desktop .dmg từ trang chủ (Không dùng Homebrew)"
    read -rp "Lựa chọn [1/2/3/4] (Mặc định: 1): " MAC_CHOICE
    MAC_CHOICE="${MAC_CHOICE:-1}"

    case "$MAC_CHOICE" in
        1)
            if command -v brew >/dev/null 2>&1; then
                echo -e "\n${BLUE}ℹ Đang cài đặt Docker Desktop qua Homebrew...${NC}"
                brew install --cask docker
            else
                echo -e "\n${YELLOW}Chưa cài Homebrew. Tự động chuyển sang tải file .dmg chính thức...${NC}"
                install_macos_dmg
            fi
            ;;
        2)
            if ! command -v brew >/dev/null 2>&1; then
                echo -e "${RED}Lỗi: Cần có Homebrew để cài OrbStack (https://brew.sh)${NC}"
                exit 1
            fi
            echo -e "\n${BLUE}ℹ Đang cài đặt OrbStack qua Homebrew...${NC}"
            brew install --cask orbstack
            echo -e "${GREEN}✓ Cài đặt OrbStack hoàn tất! Mở ứng dụng để bắt đầu sử dụng:${NC}"
            echo -e "   👉 ${CYAN}open -a OrbStack${NC}"
            return 0
            ;;
        3)
            if ! command -v brew >/dev/null 2>&1; then
                echo -e "${RED}Lỗi: Cần có Homebrew để cài Colima (https://brew.sh)${NC}"
                exit 1
            fi
            echo -e "\n${BLUE}ℹ Đang cài đặt Docker CLI và Colima...${NC}"
            brew install docker docker-compose colima
            echo -e "${GREEN}✓ Đã cài Colima. Để khởi động Docker runtime:${NC}"
            echo -e "   👉 ${CYAN}colima start${NC}"
            return 0
            ;;
        4)
            install_macos_dmg
            ;;
        *)
            echo -e "${RED}Lựa chọn không hợp lệ!${NC}"
            exit 1
            ;;
    esac

    # Khởi động Docker Desktop
    echo -e "\n${GREEN}✓ Cài đặt hoàn tất!${NC}"
    read -rp "Bạn có muốn khởi động Docker Desktop ngay không? [Y/n]: " START_DOCKER
    START_DOCKER="${START_DOCKER:-y}"
    if [[ "$START_DOCKER" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Đang mở Docker.app...${NC}"
        open -a Docker || true
        echo -e "${YELLOW}ℹ Lưu ý: Trong lần đầu khởi động, macOS sẽ yêu cầu cấp quyền mật khẩu quản trị (Privileged Helper).${NC}"
    fi
}

install_macos_dmg() {
    echo -e "\n${BLUE}ℹ Đang xác định link tải Docker Desktop chính thức cho kiến trúc ${ARCH}...${NC}"
    if [ "$ARCH" = "arm64" ]; then
        DMG_URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
    else
        DMG_URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
    fi

    TMP_DMG="/tmp/Docker.dmg"
    echo -e "${BLUE}ℹ Đang tải file DMG từ: ${CYAN}${DMG_URL}${NC}"
    curl -L -o "$TMP_DMG" "$DMG_URL" --progress-bar

    echo -e "\n${BLUE}ℹ Đang mount file DMG...${NC}"
    MOUNT_DIR=$(hdiutil attach "$TMP_DMG" -nobrowse -readonly | grep -o '/Volumes/.*' | head -n 1)

    if [ -d "$MOUNT_DIR/Docker.app" ]; then
        echo -e "${BLUE}ℹ Đang sao chép Docker.app vào thư mục /Applications...${NC}"
        sudo rm -rf /Applications/Docker.app
        sudo cp -R "$MOUNT_DIR/Docker.app" /Applications/
        echo -e "${GREEN}✓ Đã sao chép Docker.app vào /Applications${NC}"
    fi

    echo -e "${BLUE}ℹ Đang unmount và dọn dẹp file tạm...${NC}"
    hdiutil detach "$MOUNT_DIR" -quiet || true
    rm -f "$TMP_DMG"
}

# ==============================================================================
# CÀI ĐẶT TRÊN LINUX
# ==============================================================================
install_linux() {
    echo -e "\n${CYAN}--- CÀI ĐẶT DOCKER CHO LINUX ---${NC}"
    
    # Kiểm tra quyền root / sudo
    SUDO=""
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            echo -e "${RED}Lỗi: Bạn cần có quyền root hoặc công cụ 'sudo' để cài đặt trên Linux.${NC}"
            exit 1
        fi
    fi

    echo -e "${BLUE}ℹ Đang tải và chạy script cài đặt chính thức từ Docker (https://get.docker.com)...${NC}"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    $SUDO sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh

    # Khởi động dịch vụ Docker qua systemd (nếu có)
    if command -v systemctl >/dev/null 2>&1; then
        echo -e "\n${BLUE}ℹ Kích hoạt và khởi động Docker service...${NC}"
        $SUDO systemctl enable docker
        $SUDO systemctl start docker
    fi

    # Thêm user hiện tại vào nhóm docker (để chạy không cần gõ sudo)
    CURRENT_USER="${SUDO_USER:-$USER}"
    if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
        echo -e "\n${BLUE}ℹ Đang thêm người dùng ${BOLD}${CURRENT_USER}${NC}${BLUE} vào nhóm 'docker'...${NC}"
        $SUDO usermod -aG docker "$CURRENT_USER" || true
        echo -e "${YELLOW}ℹ Lưu ý: Để chạy lệnh 'docker' không cần 'sudo', bạn hãy đăng xuất và đăng nhập lại hoặc chạy:${NC}"
        echo -e "   👉 ${CYAN}newgrp docker${NC}"
    fi

    # Cài đặt docker-compose nếu chưa có
    if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        echo -e "\n${BLUE}ℹ Đang cài đặt Docker Compose plugin...${NC}"
        if command -v apt-get >/dev/null 2>&1; then
            $SUDO apt-get update -y && $SUDO apt-get install -y docker-compose-plugin
        elif command -v yum >/dev/null 2>&1; then
            $SUDO yum install -y docker-compose-plugin
        fi
    fi
}

# ==============================================================================
# ĐIỀU HƯỚNG THEO OS
# ==============================================================================
case "$OS" in
    Darwin)
        install_macos
        ;;
    Linux)
        install_linux
        ;;
    *)
        echo -e "${RED}Hệ điều hành không được hỗ trợ tự động: ${OS}${NC}"
        exit 1
        ;;
esac

# ==============================================================================
# KIỂM TRA KẾT QUẢ
# ==============================================================================
echo -e "\n${CYAN}-----------------------------------------------------------------${NC}"
echo -e "${GREEN}${BOLD}🎉 QUÁ TRÌNH CÀI ĐẶT HOÀN TẤT!${NC}"
echo -e "${CYAN}-----------------------------------------------------------------${NC}"

if command -v docker >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Docker Version:${NC} $(docker --version)"
else
    echo -e "${YELLOW}ℹ Nếu là Docker Desktop trên Mac, hãy mở ứng dụng để CLI được liên kết.${NC}"
fi

if docker compose version >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Docker Compose Version:${NC} $(docker compose version)"
elif command -v docker-compose >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Docker Compose Version:${NC} $(docker-compose --version)"
fi

echo -e "\n${BOLD}Lệnh kiểm tra Docker hoạt động:${NC}"
echo -e "   👉 ${CYAN}docker run --rm hello-world${NC}\n"
