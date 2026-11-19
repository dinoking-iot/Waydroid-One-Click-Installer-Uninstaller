
Waydroid One-Click Installer / Uninstaller

Optimized for BigLinux & Multi-Distro Support | Tối ưu cho BigLinux & Đa nền tảng
An all-in-one, zero-prompt automation script to install, optimize, and cleanly uninstall Waydroid on Linux. Runs as your normal user, never adds autostart entries, and keeps your system clean.
Công cụ tự động hóa không cần tương tác giúp cài đặt, tối ưu hóa hiệu năng và gỡ bỏ sạch sẽ Waydroid trên Linux. Chạy dưới quyền người dùng thông thường, không tự khởi động cùng hệ thống và giữ hệ thống luôn sạch sẽ.

🌟 Features / Tính năng nổi bật

• Smart One-Click Toggle / Cơ chế Một chạm thông minh:

Automatically detects whether Waydroid is installed. If missing, it performs a full automated setup. If already installed, it switches to uninstall mode and reverts all system changes.
Tự động nhận diện trạng thái cài đặt. Nếu chưa có Waydroid, script sẽ tự động cài đặt hoàn chỉnh. Nếu đã có, script chuyển sang chế độ gỡ bỏ và hoàn tác toàn bộ thay đổi trên hệ thống.

• Glitch-Free Gaming with Cage Compositor / Hiển thị mượt mà với Cage Compositor:
Solves KWin partial-repaint freezes and garbled graphics on KDE Plasma by launching Waydroid and all Android app shortcuts inside a nested cage Wayland compositor.
Giải quyết triệt để lỗi đứng hình, vỡ hình của KWin trên KDE Plasma bằng cách chạy Waydroid và toàn bộ lối tắt ứng dụng Android bên trong compositor lồng cage.

• Double-Click APK Handler & Auto-Repair / Cài APK bằng nhấp đúp & Tự động sửa lỗi:
Associates .apk files with a smart installer that automatically repairs damaged ZIP headers, auto-signs unsigned APKs with a local debug key, disables Google Play Protect warnings, and enables mouse-to-touch (fake_touch) per app.
Liên kết tệp .apk với trình cài đặt thông minh có khả năng tự phục hồi cấu trúc ZIP lỗi, tự ký APK thiếu chứng chỉ bằng khóa debug cục bộ, tắt cảnh báo Play Protect và tự kích hoạt giả lập cảm ứng cho từng ứng dụng.

• Google Play & ARM Translation Ready / Tích hợp Google Play & Lớp dịch ARM:
Installs official GAPPS images directly (with waydroid_script fallback) and automatically selects libndk (AMD) or libhoudini (Intel) based on your CPU.
Cài đặt trực tiếp ảnh hệ thống tích hợp sẵn GAPPS (có phương án dự phòng qua waydroid_script) và tự động chọn libndk (AMD) hoặc libhoudini (Intel) phù hợp với CPU.

• Local Offline Store & Crash Recovery / Kho lưu trữ cục bộ & Tự phục hồi:
Caches downloaded images and archives in a local store folder verified by SHA256 checksums for fast offline reinstalls. Tracks completed steps so interrupted runs resume seamlessly.
Lưu trữ ảnh hệ thống và gói tải về trong thư mục store kèm mã kiểm tra SHA256 để cài lại ngoại tuyến siêu tốc. Ghi nhớ các bước đã hoàn thành để tự động tiếp tục nếu quá trình cài bị gián đoạn.

• Kernel & Network Auto-Fixes / Tự động khắc phục lỗi Kernel & Mạng:
Detects XanMod kernels and safely appends psi=1 to GRUB if memory pressure info is disabled (preventing lmkd boot loops), resolves dnsmasq port 53 conflicts via a reversible systemd drop-in, and waits for GPU/RAM to become idle before booting Android.
Nhận diện kernel XanMod và tự động thêm psi=1 vào GRUB nếu thiếu (ngăn lỗi khởi động lặp lmkd), xử lý xung đột cổng 53 của dnsmasq bằng systemd drop-in có thể hoàn tác, đồng thời chờ GPU/RAM rảnh trước khi khởi động Android.

💻 Supported Systems / Hệ điều hành hỗ trợ

• Package Managers / Trình quản lý gói: pacman (BigLinux, Manjaro, Arch Linux), apt (Ubuntu, Debian, Linux Mint, Zorin OS, Deepin), dnf (Fedora).
• Architectures / Kiến trúc: x86_64 / amd64, aarch64 (Wayland session required / yêu cầu phiên Wayland).

🚀 Usage / Hướng dẫn sử dụng

1. Download waydroid-installer.sh / Tải tệp waydroid-installer.sh về máy.
2. Make it executable (chmod +x waydroid-installer.sh or via file Properties) / Cấp quyền thực thi cho tệp.
3. Double-click the file (or run it in terminal) to install or uninstall / Nhấp đúp vào tệp (hoặc chạy trong terminal) để cài đặt hoặc gỡ bỏ.
   
Optional CLI Flags / Tùy chọn dòng lệnh bổ sung:

• --check: Run compatibility preflight checks without making changes / Kiểm tra độ tương thích hệ thống mà không thay đổi gì.

• --diag: Generate a full diagnostic log for troubleshooting / Xuất báo cáo chẩn đoán chi tiết để gỡ lỗi.

• --update-helpers: Update the cage launcher and APK handler scripts / Cập nhật nhanh script khởi chạy cage và trình cài APK.

• --fake-touch <package.name>: Enable touch emulation for a specific app / Bật giả lập cảm ứng cho một ứng dụng cụ thể.

• --fresh: Clear saved progress from an incomplete run and start over / Xóa tiến trình lưu tạm của lần cài dở trước đó để chạy lại từ đầu.

Download here https://github.com/dinoking-iot/Waydroid-One-Click-Installer-Uninstaller/releases/tag/Waydroid
