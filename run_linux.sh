#!/bin/bash
# 自动配置 OpenGL 环境变量以解决 WSL/VM 下的渲染问题
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330
export LIBGL_ALWAYS_INDIRECT=1

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
