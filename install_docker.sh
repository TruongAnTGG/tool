#!/usr/bin/env bash

# ==============================================================================
# Script tự động cài đặt & cấu hình Docker cho macOS & Linux
# Tự nhận diện hệ điều hành, kiến trúc CPU (Apple Silicon / Intel / ARM / x86_64)
# Tự động khắc phục lỗi phân quyền Docker socket (Permission Denied)
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
echo -e "${CYAN}${BOLD}           SCRIPT CÀI ĐẶT & CẤU HÌNH DOCKER (macOS & LINUX)      ${NC}"
echo -e "${CYAN}${BOLD}=================================================================${NC}\n"

# 1. Phát hiện hệ điều hành và kiến trúc chip
OS="$(uname -s)"
ARCH="$(uname -m)"

echo -e "${BLUE}ℹ Hệ điều hành phát hiện:${NC} ${BOLD}${OS}${NC}"
echo -e "${BLUE}ℹ Kiến trúc phần cứng:${NC} ${BOLD}${ARCH}${NC}"

# Hàm sửa lỗi phân quyền Docker trên Linux
fix_linux_permissions() {
    echo -e "\n${BLUE}ℹ Đang kiểm tra và sửa quyền truy cập Docker socket...${NC}"
    CURRENT_USER="${SUDO_USER:-$USER}"
    
    # 1. Thêm user vào group docker
    if command -v sudo >/dev/null 2>&1; then
        sudo usermod -aG docker "$CURRENT_USER" 2>/dev/null || true
        # 2. Cấp quyền đọc/ghi tạm thời cho socket để có hiệu lực ngay trong phiên hiện tại
        if [ -e /var/run/docker.sock ]; then
            sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
            sudo chown root:docker /var/run/docker.sock 2>/dev/null || true
        fi
        # 3. Đảm bảo docker daemon đang chạy
        if command -v systemctl >/dev/null 2>&1; then
            sudo systemctl enable docker 2>/dev/null || true
            sudo systemctl start docker 2>/dev/null || true
        fi
    elif [ "$EUID" -eq 0 ]; then
        usermod -aG docker "$CURRENT_USER" 2>/dev/null || true
        [ -e /var/run/docker.sock ] && chmod 666 /var/run/docker.sock 2>/dev/null || true
    fi

    echo -e "${GREEN}✓ Đã cấp quyền truy cập Docker socket thành công!${NC}"
}

# 2. Kiểm tra Docker hiện tại
if command -v docker >/dev/null 2>&1; then
    DOCKER_VER=$(docker --version 2>/dev/null || echo "Unknown")
    echo -e "\n${YELLOW}⚠ Đã tìm thấy Docker trên hệ thống:${NC} ${BOLD}${DOCKER_VER}${NC}"
    
    # Kiểm tra xem daemon có kết nối được không
    if docker info >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Docker daemon đang hoạt động bình thường!${NC}"
        echo "1) Thoát (Giữ nguyên hiện tại)"
        echo "2) Cài đặt lại / Cập nhật Docker mới"
        read -rp "Lựa chọn [1/2] (Mặc định: 1): " CHOICE
        if [ "$CHOICE" != "2" ]; then
            echo -e "${GREEN}Hoàn tất. Thoát script.${NC}\n"
            exit 0
        fi
    else
        echo -e "${RED}✗ Lệnh 'docker info' thất bại! Có thể do daemon chưa bật hoặc thiếu quyền truy cập socket.${NC}"
        if [ "$OS" = "Linux" ]; then
            echo "1) Tự động sửa quyền Docker (Thêm vào group docker & cấp quyền socket) [Khuyên dùng]"
            echo "2) Cài đặt lại Docker từ đầu"
            echo "3) Thoát"
            read -rp "Lựa chọn [1/2/3] (Mặc định: 1): " REPAIR_CHOICE
            REPAIR_CHOICE="${REPAIR_CHOICE:-1}"
            
            if [ "$REPAIR_CHOICE" = "1" ]; then
                fix_linux_permissions
                if docker info >/dev/null 2>&1; then
                    echo -e "\n${GREEN}${BOLD}🎉 Tuyệt vời! Docker đã hoạt động bình thường mà không cần sudo!${NC}\n"
                    exit 0
                else
                    echo -e "\n${YELLOW}ℹ Hãy chạy 'newgrp docker' hoặc đăng nhập lại để cập nhật nhóm user.${NC}"
                    exit 0
                fi
            elif [ "$REPAIR_CHOICE" = "3" ]; then
                exit 0
            fi
        else
            echo "1) Khởi động Docker Desktop trên macOS"
            echo "2) Cài đặt lại Docker"
            echo "3) Thoát"
            read -rp "Lựa chọn [1/2/3] (Mặc định: 1): " MAC_ERR_CHOICE
            MAC_ERR_CHOICE="${MAC_ERR_CHOICE:-1}"
            if [ "$MAC_ERR_CHOICE" = "1" ]; then
                open -a Docker || true
                exit 0
            elif [ "$MAC_ERR_CHOICE" = "3" ]; then
                exit 0
            fi
        fi
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

    # Tự động phát hiện và xử lý lỗi Proxmox VE Enterprise Repo (401 Unauthorized)
    if [ -d /etc/pve ] || command -v pveversion >/dev/null 2>&1 || grep -rq "enterprise.proxmox.com" /etc/apt/ 2>/dev/null; then
        if grep -rq "^[[:space:]]*deb[[:space:]]\+https\?:\/\/enterprise\.proxmox\.com" /etc/apt/ 2>/dev/null || grep -rq "enterprise\.proxmox\.com" /etc/apt/sources.list.d/*.sources 2>/dev/null; then
            echo -e "\n${YELLOW}⚠ Phát hiện Proxmox VE đang dùng kho Enterprise (cần license trả phí)!${NC}"
            echo -e "${YELLOW}ℹ Điều này sẽ gây lỗi '401 Unauthorized' khi apt-get update.${NC}"
            echo -e "${BLUE}ℹ Đang tự động vô hiệu hoá kho Enterprise và thêm kho No-Subscription miễn phí...${NC}"
            
            # Vô hiệu hoá repo enterprise trong .list
            $SUDO sed -i 's/^[[:space:]]*deb[[:space:]]\+\(https\?:\/\/enterprise\.proxmox\.com\)/# deb \1/g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
            
            # Vô hiệu hoá trong file .sources nếu có
            for src in /etc/apt/sources.list.d/*.sources; do
                if [ -f "$src" ] && grep -q "enterprise.proxmox.com" "$src" 2>/dev/null; then
                    $SUDO sed -i 's/Enabled:[[:space:]]*yes/Enabled: no/g' "$src" 2>/dev/null || true
                fi
            done

            # Lấy codename của Debian (bookworm, bullseye, trixie,...)
            CODENAME=""
            if [ -f /etc/os-release ]; then
                CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
            fi
            [ -z "$CODENAME" ] && CODENAME="bookworm"

            # Thêm pve no-subscription nếu chưa có
            if ! grep -rq "pve-no-subscription" /etc/apt/ 2>/dev/null; then
                echo "deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription" | $SUDO tee /etc/apt/sources.list.d/pve-no-subscription.list >/dev/null
                echo -e "${GREEN}✓ Đã cấu hình kho Proxmox No-Subscription (${CODENAME})${NC}"
            fi

            # Xử lý kho ceph no-subscription nếu có cài ceph
            if grep -rq "ceph" /etc/apt/sources.list.d/ 2>/dev/null; then
                CEPH_VER="squid"
                if grep -rq "ceph-reef" /etc/apt/ 2>/dev/null; then
                    CEPH_VER="reef"
                elif grep -rq "ceph-quincy" /etc/apt/ 2>/dev/null; then
                    CEPH_VER="quincy"
                fi
                if ! grep -rq "ceph-.*no-subscription" /etc/apt/ 2>/dev/null; then
                    echo "deb http://download.proxmox.com/debian/ceph-${CEPH_VER} ${CODENAME} no-subscription" | $SUDO tee /etc/apt/sources.list.d/ceph-no-subscription.list >/dev/null
                    echo -e "${GREEN}✓ Đã cấu hình kho Ceph (${CEPH_VER}) No-Subscription${NC}"
                fi
            fi

            echo -e "${BLUE}ℹ Đang làm mới danh mục gói phần mềm (apt-get update)...${NC}"
            $SUDO apt-get update -qq || true
            echo -e "${GREEN}✓ Đã khắc phục xong kho lưu trữ Proxmox!${NC}\n"
        fi
    fi

    echo -e "${BLUE}ℹ Đang tải và chạy script cài đặt chính thức từ Docker (https://get.docker.com)...${NC}"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    $SUDO sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh

    # Khởi động dịch vụ Docker qua systemd
    if command -v systemctl >/dev/null 2>&1; then
        echo -e "\n${BLUE}ℹ Kích hoạt và khởi động Docker service...${NC}"
        $SUDO systemctl enable docker
        $SUDO systemctl start docker
    fi

    # Cấp quyền cho user & socket
    fix_linux_permissions

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
echo -e "${GREEN}${BOLD}🎉 QUÁ TRÌNH CÀI ĐẶT & CẤU HÌNH HOÀN TẤT!${NC}"
echo -e "${CYAN}-----------------------------------------------------------------${NC}"

if command -v docker >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Docker Version:${NC} $(docker --version)"
fi

if docker compose version >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Docker Compose Version:${NC} $(docker compose version)"
elif command -v docker-compose >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Docker Compose Version:${NC} $(docker-compose --version)"
fi

echo -e "\n${BOLD}Lệnh kiểm tra Docker hoạt động:${NC}"
echo -e "   👉 ${CYAN}docker run --rm hello-world${NC}\n"
