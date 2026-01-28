#!/bin/bash
# 自动配置 OpenGL 环境变量以解决 WSL/VM 下的渲染问题

# 尝试不同的软件渲染器 (softpipe 有时比 llvmpipe 更稳定)
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=softpipe 

# 强制使用 X11 后端 (Flutter 默认可能会尝试 Wayland)
export GDK_BACKEND=x11
export EGL_PLATFORM=x11

# 禁用硬件加速合成
export FLUTTER_DRM_DEVICE=/dev/null

# 调试输出
echo "Launching esp32_ota_tool with software rendering (softpipe)..."

# 获取脚本所在目录
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
APP_NAME="esp32_ota_tool"

# 检查当前目录下是否有程序，如果没有则尝试在 build 目录找
if [ -f "$DIR/$APP_NAME" ]; then
    "$DIR/$APP_NAME"
elif [ -f "$DIR/build/linux/x64/release/bundle/$APP_NAME" ]; then
    "$DIR/build/linux/x64/release/bundle/$APP_NAME"
else
    echo "Error: Could not find $APP_NAME executable."
    echo "Usage: Place this script next to the executable or in the project root."
    exit 1
fi
