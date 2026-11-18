#!/usr/bin/env bash
# 本地开发一站式环境（Git Bash 下用 source 加载，不要直接 bash 执行）。
#
#   cd /d/workspace/WorkBuddy/appforge-demo
#   source scripts/dev-env.sh
#   flutter analyze && flutter test
#   flutter run
#
# 解决的问题：
#   1. 用户级环境变量已持久化，但已打开的终端不会自动刷新；
#   2. Git Bash 的 PATH 必须用 POSIX 形式（/d/dev/...），Windows 形式 Dart 子进程找不到；
#   3. 沙箱代理端口每次会话都可能变化，Java/Gradle 不读 HTTP_PROXY，需要动态解析；
#   4. flutter_tester 的本机 WebSocket 必须绕过代理。
#
# 只影响当前 shell，不写注册表、不修改项目文件。

if [ -z "${BASH_SOURCE[0]}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "请用法：source scripts/dev-env.sh  （不要直接执行）" >&2
  exit 1
fi

# 工具链根目录，POSIX 形式；装在别处时先 export DEV_ROOT=/e/dev 再 source
DEV_ROOT="${DEV_ROOT:-/d/dev}"
DEV_WIN="${DEV_WIN:-D:/dev}"

export JAVA_HOME="$DEV_WIN/jdk17"
export ANDROID_HOME="$DEV_WIN/android-sdk"
export ANDROID_SDK_ROOT="$DEV_WIN/android-sdk"

export PUB_CACHE="${PUB_CACHE:-C:/Users/$USERNAME/AppData/Local/Pub/Cache}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

# Dart/Flutter 在部分终端里读不到这些 Windows 目录，显式给出更稳
export LOCALAPPDATA="${LOCALAPPDATA:-C:/Users/$USERNAME/AppData/Local}"
export APPDATA="${APPDATA:-C:/Users/$USERNAME/AppData/Roaming}"

# flutter_tester 走本机 WebSocket，必须绕过代理
export NO_PROXY="localhost,127.0.0.1,::1"
export no_proxy="$NO_PROXY"

export PATH="$DEV_ROOT/flutter/bin:$DEV_ROOT/flutter/bin/cache/dart-sdk/bin:$DEV_ROOT/jdk17/bin:$DEV_ROOT/android-sdk/platform-tools:$DEV_ROOT/bin:$PATH"

# Java/Gradle 不读 HTTP_PROXY：从当前会话的代理变量动态解析 host:port。
# 端口每次会话可能不同，禁止硬编码；无代理时清掉旧值，避免连到上次会话的死端口。
_proxy_url="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
if [ -n "$_proxy_url" ]; then
  _strip=$(printf '%s' "$_proxy_url" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#^.*@##')
  _host=${_strip%%:*}
  _port=${_strip##*:}
  if [ -n "$_host" ] && [ -n "$_port" ] && [ "$_host" != "$_port" ]; then
    export JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=$_host -Dhttp.proxyPort=$_port -Dhttps.proxyHost=$_host -Dhttps.proxyPort=$_port -Dhttp.nonProxyHosts=localhost|127.0.0.1"
    echo "代理：$_host:$_port（已注入 JAVA_TOOL_OPTIONS）"
  fi
else
  unset JAVA_TOOL_OPTIONS
  echo "代理：无（直连国内镜像）"
fi
unset _proxy_url _strip _host _port

echo "Flutter: $(command -v flutter || echo '未找到，请检查 DEV_ROOT=$DEV_ROOT')"
_cwd=$(pwd -W 2>/dev/null || pwd)
echo "工程目录：$_cwd"
if printf '%s' "$_cwd" | LC_ALL=C grep -q '[^ -~]'; then
  echo "⚠ 当前路径含非 ASCII 字符，Android 构建会失败！请 cd /d/workspace/WorkBuddy/appforge-demo" >&2
fi
unset _cwd
