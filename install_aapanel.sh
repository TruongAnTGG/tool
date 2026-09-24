#!/usr/bin/env bash

# ==============================================================================
# Script Quản Lý, Cài Đặt & Gỡ Bỏ aaPanel Tự Động (Linux / VPS Server)
# Hỗ trợ: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, RockyLinux, Fedora
# Tích hợp: Cài đặt, Gỡ bỏ sạch, Quản lý dịch vụ, Lấy lại thông tin đăng nhập
# ==============================================================================

# Màu sắc hiển thị
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Tiêu đề banner
show_banner() {
    echo -e "\n${CYAN}${BOLD}=================================================================${NC}"
    echo -e "${CYAN}${BOLD}       CÔNG CỤ CÀI ĐẶT & GỠ BỎ AAPANEL TỰ ĐỘNG CHO LINUX       ${NC}"
    echo -e "${CYAN}${BOLD}=================================================================${NC}\n"
}

# 1. Phát hiện hệ điều hành và kiến trúc
detect_os() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    DISTRO="unknown"
    DISTRO_VERSION=""

    if [ "$OS" = "Linux" ]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            DISTRO="${ID:-unknown}"
            DISTRO_VERSION="${VERSION_ID:-}"
            DISTRO_NAME="${NAME:-Linux}"
        elif [ -f /etc/redhat-release ]; then
            DISTRO="centos"
            DISTRO_NAME="CentOS / RedHat"
        elif [ -f /etc/debian_version ]; then
            DISTRO="debian"
            DISTRO_NAME="Debian"
        else
            DISTRO_NAME="Linux"
        fi
    elif [ "$OS" = "Darwin" ]; then
        DISTRO_NAME="macOS"
    else
        DISTRO_NAME="$OS"
    fi
}

# 2. Kiểm tra quyền root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}✗ Lỗi: Script cần quyền root để cài đặt / gỡ bỏ các dịch vụ hệ thống.${NC}"
        echo -e "${YELLOW}ℹ Vui lòng chạy lại script bằng quyền sudo hoặc tài khoản root:${NC}"
        echo -e "   ${BOLD}sudo bash $0${NC}\n"
        exit 1
    fi
}

# 3. Cài đặt các công cụ tải cần thiết (curl, wget)
ensure_downloader() {
    if command -v curl >/dev/null 2>&1 && command -v wget >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${BLUE}ℹ Đang cài đặt công cụ tải về (curl, wget)...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y curl wget >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget >/dev/null 2>&1 || true
    fi
}

# 4. Cài đặt aaPanel
install_aapanel() {
    detect_os

    if [ "$OS" = "Darwin" ]; then
        handle_macos_environment "install"
        return
    fi

    check_root
    ensure_downloader

    echo -e "\n${CYAN}--- TIẾN HÀNH CÀI ĐẶT AAPANEL ---${NC}"
    echo -e "${BLUE}ℹ Hệ điều hành phát hiện:${NC} ${BOLD}${DISTRO_NAME} (${ARCH})${NC}"

    # Kiểm tra xem aaPanel đã cài chưa
    if [ -d "/www/server/panel" ] || [ -f "/etc/init.d/bt" ]; then
        echo -e "\n${YELLOW}⚠ Cảnh báo: aaPanel dường như đã được cài đặt trên hệ thống này!${NC}"
        echo "1) Tiếp tục cài đặt lại / Ghi đè (Reinstall)"
        echo "2) Hủy bỏ và quay lại menu"
        read -rp "Lựa chọn [1/2] (Mặc định: 2): " REINSTALL_CHOICE
        if [ "$REINSTALL_CHOICE" != "1" ]; then
            echo -e "${GREEN}Đã hủy thao tác cài đặt.${NC}"
            return
        fi
    fi

    echo -e "\n${YELLOW}ℹ Khuyến nghị từ aaPanel:${NC}"
    echo -e " - Nên cài đặt trên một máy chủ (VPS/Server) mới, sạch hệ điều hành."
    echo -e " - Tránh cài đặt nếu đã tự cài sẵn Apache/Nginx/MySQL độc lập trước đó."
    echo ""
    read -rp "Bạn có chắc chắn muốn tiến hành cài đặt ngay bây giờ? [Y/n]: " CONFIRM_INSTALL
    CONFIRM_INSTALL="${CONFIRM_INSTALL:-Y}"
    if [[ ! "$CONFIRM_INSTALL" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Đã hủy thao tác cài đặt.${NC}"
        return
    fi

    INSTALL_SCRIPT_URL=""
    case "$DISTRO" in
        ubuntu|debian)
            INSTALL_SCRIPT_URL="https://www.aapanel.com/script/install-ubuntu_6.0_en.sh"
            FALLBACK_URL="http://www.aapanel.com/script/install-ubuntu_6.0_en.sh"
            ;;
        centos|rhel|almalinux|rocky|fedora)
            INSTALL_SCRIPT_URL="https://www.aapanel.com/script/install_6.0_en.sh"
            FALLBACK_URL="http://www.aapanel.com/script/install_6.0_en.sh"
            ;;
        *)
            # Universal script cho các bản phân phối Linux khác
            INSTALL_SCRIPT_URL="https://www.aapanel.com/script/new_install_en.sh"
            FALLBACK_URL="http://www.aapanel.com/script/new_install_en.sh"
            ;;
    esac

    TMP_INSTALLER="/tmp/aapanel_install.sh"
    rm -f "$TMP_INSTALLER"

    echo -e "\n${BLUE}ℹ Đang tải bộ cài đặt chính thức từ aaPanel...${NC}"
    if ! curl -fsSL "$INSTALL_SCRIPT_URL" -o "$TMP_INSTALLER"; then
        echo -e "${YELLOW}ℹ Thử lại với đường dẫn dự phòng...${NC}"
        wget -O "$TMP_INSTALLER" "$FALLBACK_URL" || true
    fi

    if [ ! -s "$TMP_INSTALLER" ]; then
        echo -e "${RED}✗ Lỗi: Không thể tải script cài đặt aaPanel. Vui lòng kiểm tra lại kết nối mạng.${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Tải bộ cài đặt thành công. Bắt đầu quá trình thiết lập...${NC}\n"
    bash "$TMP_INSTALLER" forum

    # Dọn dẹp file tạm
    rm -f "$TMP_INSTALLER"

    echo -e "\n${GREEN}${BOLD}=================================================================${NC}"
    echo -e "${GREEN}${BOLD}                QUÁ TRÌNH CÀI ĐẶT HOÀN TẤT                      ${NC}"
    echo -e "${GREEN}${BOLD}=================================================================${NC}"
    
    # Hiển thị lại thông tin đăng nhập
    show_status_and_login

    # Nhắc mở Firewall
    suggest_firewall_setup
}

# 5. Gỡ bỏ aaPanel
uninstall_aapanel() {
    detect_os

    if [ "$OS" = "Darwin" ]; then
        handle_macos_environment "uninstall"
        return
    fi

    check_root

    echo -e "\n${RED}${BOLD}=================================================================${NC}"
    echo -e "${RED}${BOLD}                   GỠ BỎ AAPANEL KHỎI HỆ THỐNG                   ${NC}"
    echo -e "${RED}${BOLD}=================================================================${NC}\n"

    # Kiểm tra xem có aaPanel không
    if [ ! -d "/www/server/panel" ] && [ ! -f "/etc/init.d/bt" ]; then
        echo -e "${YELLOW}⚠ Không tìm thấy thư mục cài đặt aaPanel (/www/server/panel hoặc /etc/init.d/bt).${NC}"
        echo "Có thể aaPanel chưa được cài đặt hoặc đã bị gỡ bỏ trước đó."
        read -rp "Bạn vẫn muốn quét dọn các file cấu hình và dịch vụ còn sót lại? [y/N]: " FORCE_CLEAN
        if [[ ! "$FORCE_CLEAN" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    echo -e "${YELLOW}Vui lòng chọn chế độ gỡ bỏ:${NC}"
    echo -e "  ${BOLD}1)${NC} ${CYAN}Chỉ gỡ bỏ aaPanel${NC} (Giữ lại mã nguồn web, cơ sở dữ liệu và các dịch vụ Nginx/MySQL...)"
    echo -e "  ${BOLD}2)${NC} ${YELLOW}Gỡ bỏ aaPanel và toàn bộ dịch vụ máy chủ${NC} (Nginx, Apache, MySQL, PHP, Redis, Pure-FTPd...)"
    echo -e "  ${BOLD}3)${NC} ${RED}Gỡ bỏ TRIỆT ĐỂ (Xoá sạch panel, dịch vụ, toàn bộ dữ liệu web và database)${NC} ${RED}[NGUY HIỂM]${NC}"
    echo -e "  ${BOLD}4)${NC} Dùng script gỡ bỏ tự động từ Baota / aaPanel (bt-uninstall.sh)"
    echo -e "  ${BOLD}0)${NC} Hủy bỏ và quay lại menu"
    echo ""
    read -rp "Lựa chọn của bạn [0/1/2/3/4] (Mặc định: 0): " UNINSTALL_MODE
    UNINSTALL_MODE="${UNINSTALL_MODE:-0}"

    case "$UNINSTALL_MODE" in
        1)
            confirm_and_remove_panel_only
            ;;
        2)
            confirm_and_remove_panel_and_services
            ;;
        3)
            confirm_and_remove_everything
            ;;
        4)
            run_official_uninstaller
            ;;
        *)
            echo -e "${GREEN}Đã hủy thao tác gỡ bỏ.${NC}"
            return 0
            ;;
    esac
}

# Dừng tất cả dịch vụ liên quan
stop_all_services() {
    echo -e "${BLUE}ℹ Đang dừng dịch vụ aaPanel và các dịch vụ liên quan...${NC}"
    
    # 1. Dừng aaPanel
    if [ -f "/etc/init.d/bt" ]; then
        /etc/init.d/bt stop >/dev/null 2>&1 || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop bt >/dev/null 2>&1 || true
    fi

    # 2. Dừng các dịch vụ web/db stack
    SERVICES="nginx httpd apache2 mysqld mariadb pure-ftpd tomcat redis memcached mongodb pgsql"
    for s in $SERVICES; do
        if [ -f "/etc/init.d/$s" ]; then
            /etc/init.d/"$s" stop >/dev/null 2>&1 || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop "$s" >/dev/null 2>&1 || true
        fi
    done

    # Dừng các phiên bản php-fpm
    for php in /etc/init.d/php-fpm-*; do
        if [ -f "$php" ]; then
            "$php" stop >/dev/null 2>&1 || true
        fi
    done

    # Dừng Node.js PM2 nếu có trong nvm aaPanel
    if [ -d "/www/server/nvm" ] && [ -f "/www/server/nvm/nvm.sh" ]; then
        # shellcheck disable=SC1091
        source /www/server/nvm/nvm.sh >/dev/null 2>&1 || true
        command -v pm2 >/dev/null 2>&1 && pm2 stop all >/dev/null 2>&1 || true
    fi
}

# Chế độ 1: Chỉ gỡ Panel
confirm_and_remove_panel_only() {
    echo -e "\n${YELLOW}⚠ Bạn đã chọn: CHỈ GỠ BỎ AAPANEL${NC}"
    read -rp "Xác nhận gỡ bỏ giao diện quản lý aaPanel? [y/N]: " CF
    if [[ ! "$CF" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Đã hủy bỏ.${NC}"
        return
    fi

    echo -e "\n${BLUE}ℹ Đang gỡ bỏ aaPanel...${NC}"
    if [ -f "/etc/init.d/bt" ]; then
        /etc/init.d/bt stop >/dev/null 2>&1 || true
    fi

    # Gỡ service khởi động cùng hệ thống
    if command -v chkconfig >/dev/null 2>&1; then
        chkconfig --del bt >/dev/null 2>&1 || true
    fi
    if command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d -f bt remove >/dev/null 2>&1 || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable bt >/dev/null 2>&1 || true
    fi

    # Xóa file khởi chạy và thư mục panel
    rm -f /etc/init.d/bt
    rm -f /usr/bin/bt
    rm -f /lib/systemd/system/bt.service
    rm -f /etc/systemd/system/bt.service
    rm -rf /www/server/panel
    rm -rf /tmp/panel* /tmp/bt*

    echo -e "${GREEN}✓ Đã gỡ bỏ aaPanel thành công!${NC}"
    echo -e "${BLUE}ℹ Các website và cơ sở dữ liệu của bạn tại /www/ vẫn được giữ nguyên an toàn.${NC}\n"
}

# Chế độ 2: Gỡ bỏ Panel và Môi trường chạy
confirm_and_remove_panel_and_services() {
    echo -e "\n${RED}⚠ CẢNH BÁO: Thao tác này sẽ gỡ bỏ Panel và toàn bộ dịch vụ Web (Nginx/Apache), Database (MySQL/MariaDB), PHP, Redis...${NC}"
    echo -e "${YELLOW}ℹ Mã nguồn web (/www/wwwroot) và thư mục dữ liệu chưa bị xóa, nhưng các website sẽ ngưng hoạt động.${NC}"
    read -rp "Bạn có chắc chắn muốn thực hiện? [y/N]: " CF
    if [[ ! "$CF" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Đã hủy bỏ.${NC}"
        return
    fi

    stop_all_services

    # Gỡ bỏ các service tự khởi động
    SERVICES="bt nginx httpd mysqld pure-ftpd tomcat redis memcached mongodb pgsql"
    for s in $SERVICES; do
        if command -v chkconfig >/dev/null 2>&1; then
            chkconfig --del "$s" >/dev/null 2>&1 || true
        fi
        if command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d -f "$s" remove >/dev/null 2>&1 || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable "$s" >/dev/null 2>&1 || true
        fi
        rm -f "/etc/init.d/$s"
    done

    for php in /etc/init.d/php-fpm-*; do
        if [ -f "$php" ]; then
            bname=$(basename "$php")
            command -v chkconfig >/dev/null 2>&1 && chkconfig --del "$bname" >/dev/null 2>&1 || true
            command -v update-rc.d >/dev/null 2>&1 && update-rc.d -f "$bname" remove >/dev/null 2>&1 || true
            rm -f "$php"
        fi
    done

    # Dọn dẹp package rpm (CentOS/RHEL) nếu có
    if command -v rpm >/dev/null 2>&1; then
        echo -e "${BLUE}ℹ Đang dọn dẹp các gói rpm aaPanel...${NC}"
        for lib in bt-nginx bt-httpd bt-mysql bt-mariadb bt-php bt-openssl; do
            RPMS=$(rpm -qa | grep -i "${lib}" || true)
            if [ -n "$RPMS" ]; then
                for r in $RPMS; do
                    rpm -e "$r" --nodeps >/dev/null 2>&1 || true
                done
            fi
        done
    fi

    # Xóa file nvm trong profile
    sed -i '/NVM/d' /root/.bash_profile 2>/dev/null || true
    sed -i '/NVM/d' /root/.bashrc 2>/dev/null || true

    # Xoá thư mục server (chứa binary, cấu hình Nginx, PHP, MySQL)
    rm -rf /www/server
    rm -f /usr/bin/bt /etc/init.d/bt /etc/my.cnf

    echo -e "${GREEN}✓ Đã gỡ bỏ aaPanel và toàn bộ môi trường máy chủ thành công!${NC}\n"
}

# Chế độ 3: Xoá sạch toàn bộ không để lại dấu vết
confirm_and_remove_everything() {
    echo -e "\n${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    echo -e "${RED}${BOLD}  CẢNH BÁO NGUY HIỂM: HÀNH ĐỘNG NÀY SẼ XÓA TOÀN BỘ DỮ LIỆU!       ${NC}"
    echo -e "${RED}${BOLD}  - Toàn bộ website tại: /www/wwwroot                            ${NC}"
    echo -e "${RED}${BOLD}  - Toàn bộ cơ sở dữ liệu tại: /www/server/data                  ${NC}"
    echo -e "${RED}${BOLD}  - Toàn bộ backup tại: /www/backup                              ${NC}"
    echo -e "${RED}${BOLD}  - Toàn bộ log tại: /www/wwwlogs                                ${NC}"
    echo -e "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    echo ""
    read -rp "Nhập chính xác cụm từ 'XOA HET' để xác nhận: " CONFIRM_TEXT
    if [ "$CONFIRM_TEXT" != "XOA HET" ]; then
        echo -e "${GREEN}Chữ xác nhận không đúng. Đã hủy bỏ thao tác an toàn.${NC}"
        return
    fi

    # Thực hiện gỡ bỏ service
    confirm_and_remove_panel_and_services

    # Xóa sạch toàn bộ thư mục /www
    echo -e "${BLUE}ℹ Đang xóa toàn bộ dữ liệu web và database (/www)...${NC}"
    rm -rf /www

    # Xóa user www nếu có
    if id www >/dev/null 2>&1; then
        userdel -r www >/dev/null 2>&1 || true
        groupdel www >/dev/null 2>&1 || true
    fi

    echo -e "${GREEN}${BOLD}✓ Đã dọn dẹp sạch sẽ toàn bộ dữ liệu aaPanel khỏi máy chủ!${NC}\n"
}

# Chế độ 4: Dùng script chính thức từ BT/aaPanel
run_official_uninstaller() {
    echo -e "\n${BLUE}ℹ Đang tải script gỡ bỏ chính thức (http://download.bt.cn/install/bt-uninstall.sh)...${NC}"
    TMP_UNINSTALL="/tmp/bt-uninstall.sh"
    rm -f "$TMP_UNINSTALL"

    if curl -fsSL "http://download.bt.cn/install/bt-uninstall.sh" -o "$TMP_UNINSTALL" || wget -O "$TMP_UNINSTALL" "http://download.bt.cn/install/bt-uninstall.sh"; then
        echo -e "${GREEN}✓ Đã tải xong script gỡ bỏ. Đang chạy...${NC}\n"
        bash "$TMP_UNINSTALL"
        rm -f "$TMP_UNINSTALL"
    else
        echo -e "${RED}✗ Không thể tải script gỡ bỏ từ máy chủ Baota/aaPanel. Sử dụng chức năng gỡ bỏ nội bộ của script.${NC}"
        confirm_and_remove_panel_only
    fi
}

# 6. Kiểm tra trạng thái và thông tin đăng nhập
show_status_and_login() {
    detect_os
    if [ "$OS" = "Darwin" ]; then
        handle_macos_environment "status"
        return
    fi

    echo -e "\n${CYAN}--- TRẠNG THÁI & THÔNG TIN ĐĂNG NHẬP AAPANEL ---${NC}"

    if [ ! -f "/etc/init.d/bt" ] && [ ! -d "/www/server/panel" ]; then
        echo -e "${YELLOW}⚠ aaPanel chưa được cài đặt trên máy này.${NC}\n"
        return
    fi

    # Kiểm tra service
    echo -e "${BLUE}ℹ Trạng thái dịch vụ:${NC}"
    if [ -f "/etc/init.d/bt" ]; then
        /etc/init.d/bt status 2>&1 || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl status bt --no-pager 2>&1 || true
    fi

    echo ""
    echo -e "${BLUE}ℹ Thông tin tài khoản & Đường dẫn đăng nhập mặc định:${NC}"
    if [ -f "/etc/init.d/bt" ]; then
        /etc/init.d/bt default 2>&1 || true
    elif [ -f "/www/server/panel/tools.py" ]; then
        python3 /www/server/panel/tools.py username 2>&1 || true
    fi
    echo ""
}

# 7. Quản lý bật/tắt/khởi động lại service
manage_service() {
    detect_os
    if [ "$OS" = "Darwin" ]; then
        handle_macos_environment "service"
        return
    fi

    check_root
    ACTION="$1"

    if [ ! -f "/etc/init.d/bt" ]; then
        echo -e "${RED}✗ Lệnh 'bt' không tồn tại (/etc/init.d/bt). aaPanel chưa được cài đặt!${NC}"
        return 1
    fi

    case "$ACTION" in
        start)
            echo -e "${BLUE}ℹ Đang khởi động dịch vụ aaPanel...${NC}"
            /etc/init.d/bt start
            ;;
        stop)
            echo -e "${BLUE}ℹ Đang dừng dịch vụ aaPanel...${NC}"
            /etc/init.d/bt stop
            ;;
        restart)
            echo -e "${BLUE}ℹ Đang khởi động lại dịch vụ aaPanel...${NC}"
            /etc/init.d/bt restart
            ;;
        reload)
            echo -e "${BLUE}ℹ Đang tải lại cấu hình aaPanel...${NC}"
            /etc/init.d/bt reload
            ;;
        *)
            echo -e "${YELLOW}Lựa chọn thao tác dịch vụ:${NC}"
            echo "1) Khởi động (Start)"
            echo "2) Dừng lại (Stop)"
            echo "3) Khởi động lại (Restart)"
            echo "4) Tải lại cấu hình (Reload)"
            read -rp "Lựa chọn [1/2/3/4]: " SVC_CHOICE
            case "$SVC_CHOICE" in
                1) /etc/init.d/bt start ;;
                2) /etc/init.d/bt stop ;;
                3) /etc/init.d/bt restart ;;
                4) /etc/init.d/bt reload ;;
                *) echo -e "${YELLOW}Hủy bỏ.${NC}" ;;
            esac
            ;;
    esac
}

# 8. Cấu hình nhanh aaPanel qua công cụ bt CLI
quick_tools() {
    detect_os
    if [ "$OS" = "Darwin" ]; then
        handle_macos_environment "tools"
        return
    fi

    check_root
    if [ ! -f "/etc/init.d/bt" ]; then
        echo -e "${RED}✗ Không tìm thấy /etc/init.d/bt. Vui lòng cài đặt aaPanel trước.${NC}"
        return 1
    fi

    echo -e "\n${CYAN}--- CÔNG CỤ XỬ LÝ SỰ CỐ & THIẾT LẬP AAPANEL ---${NC}"
    echo "1) Đổi mật khẩu tài khoản quản trị (bt 5)"
    echo "2) Đổi tên đăng nhập tài khoản quản trị (bt 6)"
    echo "3) Đổi cổng truy cập Panel (bt 8)"
    echo "4) Xóa cache panel (bt 9)"
    echo "5) Xóa giới hạn IP đăng nhập (bt 10 / bt 13)"
    echo "6) Hủy ràng buộc tên miền truy cập panel (bt 12)"
    echo "7) Sửa lỗi Panel (bt 16 - Repair panel)"
    echo "8) Mở menu gốc toàn diện của aaPanel (bt)"
    echo "0) Quay lại menu chính"
    read -rp "Lựa chọn của bạn [0-8]: " TOOL_CHOICE

    case "$TOOL_CHOICE" in
        1)
            read -rp "Nhập mật khẩu mới muốn đặt: " NEW_PASS
            if [ -n "$NEW_PASS" ]; then
                /etc/init.d/bt 5 "$NEW_PASS"
                echo -e "${GREEN}✓ Đã đổi mật khẩu thành công!${NC}"
            fi
            ;;
        2)
            read -rp "Nhập tên đăng nhập mới: " NEW_USER
            if [ -n "$NEW_USER" ]; then
                /etc/init.d/bt 6 "$NEW_USER"
                echo -e "${GREEN}✓ Đã đổi tên đăng nhập thành công!${NC}"
            fi
            ;;
        3)
            read -rp "Nhập số cổng port mới (Ví dụ: 8888, 7800, 8889): " NEW_PORT
            if [ -n "$NEW_PORT" ]; then
                /etc/init.d/bt 8 "$NEW_PORT"
                echo -e "${GREEN}✓ Đã đổi cổng panel sang: ${NEW_PORT}${NC}"
                echo -e "${YELLOW}ℹ Lưu ý: Đừng quên mở port ${NEW_PORT} trên Firewall/Security Group của VPS!${NC}"
            fi
            ;;
        4)
            /etc/init.d/bt 9
            echo -e "${GREEN}✓ Đã dọn dẹp cache panel thành công!${NC}"
            ;;
        5)
            /etc/init.d/bt 10
            /etc/init.d/bt 13
            echo -e "${GREEN}✓ Đã gỡ bỏ mọi giới hạn IP truy cập!${NC}"
            ;;
        6)
            /etc/init.d/bt 12
            echo -e "${GREEN}✓ Đã hủy ràng buộc tên miền panel!${NC}"
            ;;
        7)
            /etc/init.d/bt 16
            ;;
        8)
            /etc/init.d/bt
            ;;
        *)
            return
            ;;
    esac
}

# 9. Hỗ trợ cấu hình tường lửa (Firewall)
suggest_firewall_setup() {
    echo -e "\n${BLUE}ℹ Kiểm tra tường lửa máy chủ để đảm bảo port truy cập được mở...${NC}"
    read -rp "Bạn có muốn mở tự động các port thông dụng (8888, 80, 443, 21, 22) trên Firewall? [Y/n]: " FW_CHOICE
    FW_CHOICE="${FW_CHOICE:-Y}"
    if [[ ! "$FW_CHOICE" =~ ^[Yy]$ ]]; then
        return
    fi

    # UFW (Ubuntu/Debian)
    if command -v ufw >/dev/null 2>&1; then
        echo -e "${BLUE}ℹ Đang cấu hình UFW...${NC}"
        ufw allow 8888/tcp >/dev/null 2>&1 || true
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw allow 20:21/tcp >/dev/null 2>&1 || true
        ufw allow 22/tcp >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
        echo -e "${GREEN}✓ Đã mở các port trên UFW.${NC}"
    fi

    # Firewalld (CentOS/RHEL/AlmaLinux/Rocky)
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            echo -e "${BLUE}ℹ Đang cấu hình Firewalld...${NC}"
            firewall-cmd --permanent --zone=public --add-port=8888/tcp >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-port=80/tcp >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-port=443/tcp >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-port=20-21/tcp >/dev/null 2>&1 || true
            firewall-cmd --permanent --zone=public --add-port=22/tcp >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            echo -e "${GREEN}✓ Đã mở các port trên Firewalld.${NC}"
        fi
    fi

    # Iptables
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport 8888 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    fi

    echo -e "${YELLOW}ℹ Lưu ý quan trọng: Nếu VPS dùng AWS, Google Cloud, Oracle Cloud, Azure, DigitalOcean...${NC}"
    echo -e "${YELLOW}  Hãy vào bảng điều khiển nhà mạng để mở inbound port 8888 (TCP) trong Security Group / Firewall rules.${NC}\n"
}

# 10. Xử lý khi chạy trên macOS
handle_macos_environment() {
    ACTION="$1"
    echo -e "\n${YELLOW}${BOLD}⚠ PHÁT HIỆN HỆ ĐIỀU HÀNH MACOS (${ARCH})${NC}"
    echo -e "${CYAN}aaPanel là bảng điều khiển web hosting chỉ hỗ trợ hệ điều hành Linux (Ubuntu, Debian, CentOS, AlmaLinux, RockyLinux).${NC}"
    echo -e "Kernel macOS không tương thích để chạy trực tiếp máy chủ aaPanel dạng native.\n"
    
    echo -e "${BOLD}Bạn có các lựa chọn sau:${NC}"
    echo -e "  ${BOLD}1)${NC} Chạy aaPanel thử nghiệm thông qua Docker container trên máy macOS này"
    echo -e "  ${BOLD}2)${NC} Xem hướng dẫn tải & chạy script này lên VPS / Server Linux từ xa qua SSH"
    echo -e "  ${BOLD}0)${NC} Thoát"
    echo ""
    read -rp "Lựa chọn của bạn [0/1/2] (Mặc định: 1): " MAC_CHOICE
    MAC_CHOICE="${MAC_CHOICE:-1}"

    case "$MAC_CHOICE" in
        1)
            run_docker_aapanel
            ;;
        2)
            show_vps_instructions
            ;;
        *)
            echo -e "${GREEN}Tạm biệt!${NC}\n"
            exit 0
            ;;
    esac
}

# Hướng dẫn gửi script lên VPS
show_vps_instructions() {
    echo -e "\n${CYAN}${BOLD}=== HƯỚNG DẪN CÀI ĐẶT TRÊN VPS / SERVER LINUX TỪ XA ===${NC}"
    echo -e "Cách 1: Chạy trực tiếp một dòng lệnh trên VPS Linux (Khuyên dùng):"
    echo -e "  ${BOLD}ssh root@<IP_VPS_CỦA_BẠN>${NC}"
    echo -e "  Sau đó copy lệnh này dán vào VPS:"
    echo -e "  ${GREEN}curl -sSO https://www.aapanel.com/script/new_install_en.sh && bash new_install_en.sh forum${NC}\n"

    echo -e "Cách 2: Gửi file script này lên VPS của bạn bằng SCP:"
    echo -e "  ${BOLD}scp install_aapanel.sh root@<IP_VPS_CỦA_BẠN>:/root/${NC}"
    echo -e "  Sau đó SSH vào VPS và chạy:"
    echo -e "  ${BOLD}ssh root@<IP_VPS_CỦA_BẠN>${NC}"
    echo -e "  ${BOLD}bash install_aapanel.sh${NC}\n"
}

# Chạy aaPanel trong Docker trên macOS / Linux
run_docker_aapanel() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}✗ Không tìm thấy Docker trên máy của bạn!${NC}"
        echo -e "${YELLOW}ℹ Bạn có thể chạy script './install_docker.sh' trong thư mục này để cài đặt Docker trước.${NC}\n"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}✗ Docker daemon chưa được khởi động! Vui lòng bật Docker Desktop trước.${NC}\n"
        return 1
    fi

    echo -e "\n${CYAN}--- QUẢN LÝ AAPANEL TRÊN DOCKER ---${NC}"
    CONTAINER_NAME="aapanel_container"

    if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
        IS_RUNNING=$(docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$" && echo "yes" || echo "no")
        echo -e "${YELLOW}ℹ Đã tìm thấy container aaPanel (${CONTAINER_NAME})! Trạng thái: ${BOLD}${IS_RUNNING}${NC}"
        echo "1) Xem thông tin đăng nhập / Log container"
        echo "2) Khởi động container (docker start)"
        echo "3) Dừng container (docker stop)"
        echo "4) Khởi động lại container (docker restart)"
        echo "5) Xóa container aaPanel (Gỡ bỏ container)"
        echo "0) Quay lại"
        read -rp "Lựa chọn [0-5]: " DOCKER_CHOICE

        case "$DOCKER_CHOICE" in
            1)
                echo -e "\n${BLUE}ℹ Lấy thông tin đăng nhập từ container...${NC}"
                docker exec -it "$CONTAINER_NAME" /etc/init.d/bt default 2>/dev/null || docker logs "$CONTAINER_NAME" | tail -n 25
                ;;
            2)
                docker start "$CONTAINER_NAME"
                echo -e "${GREEN}✓ Đã bật container.${NC}"
                ;;
            3)
                docker stop "$CONTAINER_NAME"
                echo -e "${GREEN}✓ Đã dừng container.${NC}"
                ;;
            4)
                docker restart "$CONTAINER_NAME"
                echo -e "${GREEN}✓ Đã khởi động lại container.${NC}"
                ;;
            5)
                read -rp "Bạn có chắc muốn xóa container aaPanel? [y/N]: " CONFIRM_RM
                if [[ "$CONFIRM_RM" =~ ^[Yy]$ ]]; then
                    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
                    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
                    echo -e "${GREEN}✓ Đã xóa container aaPanel thành công.${NC}"
                fi
                ;;
            *)
                return
                ;;
        esac
        return
    fi

    echo -e "${BLUE}ℹ Bạn có muốn khởi tạo container aaPanel mới qua Docker không?${NC}"
    echo -e "Các port sẽ map vào máy: ${BOLD}8888 (aaPanel), 80 (HTTP), 443 (HTTPS)${NC}"
    read -rp "Tiến hành tạo container? [Y/n]: " DOCKER_START
    DOCKER_START="${DOCKER_START:-Y}"
    if [[ ! "$DOCKER_START" =~ ^[Yy]$ ]]; then
        return
    fi

    DOCKER_IMAGE="aapanel/aapanel:latest"
    echo -e "${BLUE}ℹ Đang tải image ${DOCKER_IMAGE}...${NC}"
    
    # Chạy container hỗ trợ systemd / init
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p 8888:8888 \
        -p 80:80 \
        -p 443:443 \
        --privileged=true \
        --restart unless-stopped \
        "$DOCKER_IMAGE" || {
            echo -e "${YELLOW}Thử khởi tạo với image cộng đồng ổn định hơn...${NC}"
            docker run -d \
                --name "$CONTAINER_NAME" \
                -p 8888:8888 \
                -p 80:80 \
                -p 443:443 \
                --privileged=true \
                --restart unless-stopped \
                moerats/aapanel:latest
        }

    echo -e "\n${GREEN}✓ Đã khởi chạy container aaPanel thành công!${NC}"
    echo -e "${BLUE}ℹ Đang đợi 5 giây để panel hoàn tất khởi động...${NC}"
    sleep 5

    echo -e "\n${CYAN}Thông tin đăng nhập aaPanel trong Docker:${NC}"
    docker exec -it "$CONTAINER_NAME" /etc/init.d/bt default 2>/dev/null || docker logs "$CONTAINER_NAME" | tail -n 25
    echo -e "\n${GREEN}Truy cập: http://127.0.0.1:8888${NC}\n"
}

# 11. Hướng dẫn sử dụng dòng lệnh (CLI Help)
show_help() {
    echo -e "Cách sử dụng: ${BOLD}sudo bash $0 [lệnh]${NC}"
    echo ""
    echo "Các lệnh hỗ trợ:"
    echo -e "  ${BOLD}install${NC}       : Tiến hành cài đặt aaPanel"
    echo -e "  ${BOLD}uninstall${NC}     : Mở menu gỡ bỏ aaPanel (nhiều chế độ an toàn / triệt để)"
    echo -e "  ${BOLD}status${NC}        : Kiểm tra trạng thái và hiển thị thông tin đăng nhập (bt default)"
    echo -e "  ${BOLD}start${NC}         : Khởi động dịch vụ aaPanel"
    echo -e "  ${BOLD}stop${NC}          : Dừng dịch vụ aaPanel"
    echo -e "  ${BOLD}restart${NC}       : Khởi động lại dịch vụ aaPanel"
    echo -e "  ${BOLD}reload${NC}        : Tải lại cấu hình aaPanel"
    echo -e "  ${BOLD}tools${NC}         : Mở menu công cụ nhanh (đổi mật khẩu, port, gỡ hạn chế IP...)"
    echo -e "  ${BOLD}firewall${NC}      : Mở port tường lửa cho aaPanel (8888, 80, 443, 21, 22)"
    echo -e "  ${BOLD}docker${NC}        : Chạy/Quản lý aaPanel trong Docker container"
    echo -e "  ${BOLD}help${NC}          : Hiển thị hướng dẫn này"
    echo ""
}

# 12. Menu tương tác chính
main_menu() {
    detect_os

    while true; do
        show_banner
        echo -e "${BLUE}ℹ Hệ điều hành:${NC} ${BOLD}${DISTRO_NAME} (${ARCH})${NC}"

        # Kiểm tra nhanh trạng thái panel
        if [ "$OS" = "Linux" ]; then
            if [ -d "/www/server/panel" ] || [ -f "/etc/init.d/bt" ]; then
                echo -e "${GREEN}✓ Trạng thái: aaPanel đã cài đặt trên máy chủ${NC}"
            else
                echo -e "${YELLOW}ℹ Trạng thái: aaPanel chưa được cài đặt${NC}"
            fi
        elif [ "$OS" = "Darwin" ]; then
            echo -e "${YELLOW}ℹ Lưu ý: Bạn đang ở macOS. aaPanel native cần Linux (Ubuntu/Debian/CentOS).${NC}"
        fi

        echo -e "\n${BOLD}Vui lòng chọn một tác vụ:${NC}"
        echo -e "  ${BOLD}1)${NC} ${GREEN}Cài đặt aaPanel${NC} (Tự nhận diện Ubuntu/Debian/CentOS/Rocky/Alma)"
        echo -e "  ${BOLD}2)${NC} ${RED}Gỡ bỏ aaPanel${NC} (Lựa chọn gỡ sạch hoặc giữ dữ liệu web)"
        echo -e "  ${BOLD}3)${NC} ${CYAN}Xem thông tin đăng nhập & Trạng thái panel${NC} (bt default)"
        echo -e "  ${BOLD}4)${NC} Khởi động / Dừng / Khởi động lại dịch vụ aaPanel"
        echo -e "  ${BOLD}5)${NC} Công cụ nhanh (Đổi pass admin, đổi port, xóa cache, mở khóa IP...)"
        echo -e "  ${BOLD}6)${NC} Mở port tường lửa cho aaPanel (8888, 80, 443, 21, 22)"
        if [ "$OS" = "Darwin" ] || command -v docker >/dev/null 2>&1; then
            echo -e "  ${BOLD}7)${NC} ${MAGENTA}Chạy / Quản lý aaPanel trong Docker Container${NC}"
        fi
        echo -e "  ${BOLD}0)${NC} Thoát"
        echo ""
        read -rp "Nhập lựa chọn của bạn: " MAIN_CHOICE

        case "$MAIN_CHOICE" in
            1)
                install_aapanel
                ;;
            2)
                uninstall_aapanel
                ;;
            3)
                show_status_and_login
                ;;
            4)
                manage_service
                ;;
            5)
                quick_tools
                ;;
            6)
                suggest_firewall_setup
                ;;
            7)
                run_docker_aapanel
                ;;
            0)
                echo -e "\n${GREEN}Cảm ơn bạn đã sử dụng script. Tạm biệt!${NC}\n"
                exit 0
                ;;
            *)
                echo -e "${RED}Lựa chọn không hợp lệ! Vui lòng chọn lại.${NC}"
                ;;
        esac

        echo ""
        read -rp "Nhấn [Enter] để quay lại menu chính..." _DUMMY
    done
}

# ==============================================================================
# ĐIỀU HƯỚNG THAM SỐ ĐẦU VÀO
# ==============================================================================
case "${1:-}" in
    install)
        show_banner
        install_aapanel
        ;;
    uninstall|remove)
        show_banner
        uninstall_aapanel
        ;;
    status|info|default)
        show_banner
        show_status_and_login
        ;;
    start)
        manage_service start
        ;;
    stop)
        manage_service stop
        ;;
    restart)
        manage_service restart
        ;;
    reload)
        manage_service reload
        ;;
    tools)
        show_banner
        quick_tools
        ;;
    firewall)
        show_banner
        suggest_firewall_setup
        ;;
    docker)
        show_banner
        run_docker_aapanel
        ;;
    help|--help|-h)
        show_banner
        show_help
        ;;
    "")
        main_menu
        ;;
    *)
        echo -e "${RED}Lệnh không hợp lệ: $1${NC}\n"
        show_help
        exit 1
        ;;
esac
