#!/usr/bin/env bash

# ==============================================================================
# Script tự động tạo và cấu hình SSH Key cho GitHub trên macOS / Linux
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

echo -e "\n${CYAN}${BOLD}=== CÔNG CỤ TẠO VÀ CẤU HÌNH SSH KEY CHO GITHUB ===${NC}\n"

# 1. Lấy hoặc nhập Email
GIT_EMAIL=$(git config --get user.email 2>/dev/null || echo "")

if [ -n "$GIT_EMAIL" ]; then
    echo -e "${BLUE}ℹ Đã tìm thấy email trong git config: ${BOLD}${GIT_EMAIL}${NC}"
    read -rp "Nhấn [Enter] để dùng email này, hoặc nhập email khác: " INPUT_EMAIL
    EMAIL="${INPUT_EMAIL:-$GIT_EMAIL}"
else
    read -rp "Nhập email tài khoản GitHub của bạn: " EMAIL
fi

while [ -z "$EMAIL" ]; do
    echo -e "${RED}Email không được để trống!${NC}"
    read -rp "Nhập email tài khoản GitHub của bạn: " EMAIL
done

# 2. Chọn tên file key
SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

DEFAULT_KEY_NAME="id_ed25519_github"
if [ ! -f "$SSH_DIR/id_ed25519" ]; then
    DEFAULT_KEY_NAME="id_ed25519"
fi

echo -e "\n${BLUE}ℹ Đặt tên cho SSH key file (Lưu tại ~/.ssh/):${NC}"
read -rp "Tên file key [Mặc định: ${DEFAULT_KEY_NAME}]: " INPUT_KEY_NAME
KEY_NAME="${INPUT_KEY_NAME:-$DEFAULT_KEY_NAME}"
KEY_PATH="$SSH_DIR/$KEY_NAME"

# Kiểm tra nếu key đã tồn tại
if [ -f "$KEY_PATH" ]; then
    echo -e "\n${YELLOW}⚠ Cảnh báo: File key đã tồn tại tại: ${KEY_PATH}${NC}"
    echo "1) Dùng lại key hiện có này (không tạo mới)"
    echo "2) Ghi đè và tạo key mới (Key cũ sẽ bị xoá!)"
    echo "3) Thoát"
    read -rp "Lựa chọn của bạn [1/2/3]: " KEY_CHOICE

    case "$KEY_CHOICE" in
        1)
            echo -e "${GREEN}✓ Tiếp tục với SSH key hiện có.${NC}"
            ;;
        2)
            echo -e "${YELLOW}Đang tạo lại key mới...${NC}"
            ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY_PATH"
            ;;
        *)
            echo "Đã hủy thao tác."
            exit 0
            ;;
    esac
else
    # 3. Sinh SSH Key mới
    echo -e "\n${BLUE}ℹ Đang tạo SSH key Ed25519 mới...${NC}"
    echo -e "${CYAN}(Bạn có thể nhập mật khẩu passphrase để bảo vệ key hoặc bấm [Enter] 2 lần để bỏ qua passphrase)${NC}"
    ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY_PATH"
    echo -e "${GREEN}✓ Đã tạo SSH key thành công tại ${KEY_PATH}${NC}"
fi

# Đảm bảo phân quyền bảo mật
chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.pub"

# 4. Cấu hình ssh-agent và SSH config
echo -e "\n${BLUE}ℹ Đang khởi động ssh-agent và thêm key...${NC}"
eval "$(ssh-agent -s)" >/dev/null

SSH_CONFIG="$SSH_DIR/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# Thêm key vào ssh-agent (Hỗ trợ macOS Keychain)
if [[ "$OSTYPE" == "darwin"* ]]; then
    ssh-add --apple-use-keychain "$KEY_PATH" 2>/dev/null || ssh-add -K "$KEY_PATH" 2>/dev/null || ssh-add "$KEY_PATH"
    
    # Kiểm tra và cấu hình ~/.ssh/config cho GitHub
    if ! grep -q "IdentityFile $KEY_PATH" "$SSH_CONFIG" 2>/dev/null; then
        echo -e "\n${BLUE}ℹ Đang cấu hình ${SSH_CONFIG} cho GitHub...${NC}"
        cat <<EOL >> "$SSH_CONFIG"

# GitHub SSH configuration
Host github.com
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile $KEY_PATH
EOL
        echo -e "${GREEN}✓ Đã cập nhật ~/.ssh/config${NC}"
    fi
else
    ssh-add "$KEY_PATH" 2>/dev/null || true
    if ! grep -q "IdentityFile $KEY_PATH" "$SSH_CONFIG" 2>/dev/null; then
        cat <<EOL >> "$SSH_CONFIG"

# GitHub SSH configuration
Host github.com
  AddKeysToAgent yes
  IdentityFile $KEY_PATH
EOL
    fi
fi

# 5. Copy public key vào clipboard
PUB_KEY_CONTENT=$(cat "${KEY_PATH}.pub")

COPIED=false
if command -v pbcopy >/dev/null 2>&1; then
    pbcopy < "${KEY_PATH}.pub"
    COPIED=true
elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard < "${KEY_PATH}.pub"
    COPIED=true
elif command -v wl-copy >/dev/null 2>&1; then
    wl-copy < "${KEY_PATH}.pub"
    COPIED=true
fi

echo -e "\n${GREEN}${BOLD}=================================================================${NC}"
echo -e "${GREEN}${BOLD}✓ SSH PUBLIC KEY CỦA BẠN:${NC}"
echo -e "${GREEN}${BOLD}=================================================================${NC}"
echo -e "${CYAN}${PUB_KEY_CONTENT}${NC}"
echo -e "${GREEN}${BOLD}=================================================================${NC}"

if [ "$COPIED" = true ]; then
    echo -e "${GREEN}🎉 ĐÃ TỰ ĐỘNG COPY PUBLIC KEY VÀO CLIPBOARD! (Chỉ cần bấm Cmd + V để paste)${NC}"
else
    echo -e "${YELLOW}ℹ Hãy bôi đen và copy đoạn key phía trên.${NC}"
fi

# 6. Hướng dẫn thêm vào GitHub
echo -e "\n${BOLD}CÁC BƯỚC TIẾP THEO:${NC}"
echo -e "1. Truy cập trang thêm SSH Key của GitHub:"
echo -e "   👉 ${CYAN}https://github.com/settings/ssh/new${NC}"
echo -e "2. Điền ${BOLD}Title${NC} (ví dụ: 'MacBook - $(hostname -s 2>/dev/null || echo "My Mac")')"
echo -e "3. Dán (Paste) nội dung key vào ô ${BOLD}Key${NC}"
echo -e "4. Bấm ${BOLD}Add SSH key${NC}"

# Mở trình duyệt nếu trên macOS
read -rp "Bạn có muốn mở trang GitHub ngay bây giờ không? [y/N]: " OPEN_BROWSER
if [[ "$OPEN_BROWSER" =~ ^[Yy]$ ]]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        open "https://github.com/settings/ssh/new"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "https://github.com/settings/ssh/new"
    fi
fi

# 7. Kiểm tra kết nối
echo -e "\n-----------------------------------------------------------------"
read -rp "Sau khi đã add key lên GitHub xong, bạn có muốn test kết nối ngay không? [y/N]: " TEST_CONN
if [[ "$TEST_CONN" =~ ^[Yy]$ ]]; then
    echo -e "\n${BLUE}Đang kiểm tra kết nối tới git@github.com...${NC}"
    ssh -T git@github.com -o StrictHostKeyChecking=accept-new || true
fi

echo -e "\n${GREEN}${BOLD}Hoàn tất! Chúc bạn làm việc hiệu quả! 🚀${NC}\n"
