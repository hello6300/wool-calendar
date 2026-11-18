#!/usr/bin/env bash
# 连接网易 MuMu 模拟器并启动 Flutter 调试（带热重载）。
#
#   bash scripts/run-mumu.sh --check   # 只探测/连接，打印设备信息，不启动 App
#   bash scripts/run-mumu.sh           # 连接并 flutter run（r 热重载 / R 热重启 / q 退出）
#
# 只使用本机 Android SDK 的 adb。不要改用 MuMu 安装目录里的 adb_server.exe / adb.exe：
# 版本不同会另起一个 server 抢 5037，导致 flutter run 看不到设备。
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=dev-env.sh
source scripts/dev-env.sh

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

ADB="$(command -v adb)"
if [ -z "$ADB" ]; then
  echo "x 未找到 adb，请检查 scripts/dev-env.sh 的 DEV_ROOT" >&2
  exit 1
fi

echo "> 启动本机 adb server"
"$ADB" start-server >/dev/null 2>&1 || true

# 新版 MuMu 同时监听 5555 / 7555 / 16384，三者指向同一台设备。
# 同一个模拟器会在 adb devices 里出现多个别名，因此必须显式 -d 指定其一。
DEVICE=""
for p in 16384 7555 5555; do
  "$ADB" connect "127.0.0.1:$p" >/dev/null 2>&1 || true
  state=$("$ADB" -s "127.0.0.1:$p" get-state 2>/dev/null | tr -d '\r' || true)
  if [ "$state" = "device" ]; then
    DEVICE="127.0.0.1:$p"
    break
  fi
done

if [ -z "$DEVICE" ]; then
  echo "x 未连上 MuMu。请确认：① 模拟器已完全启动 ② 实际 adb 端口未被改过" >&2
  "$ADB" devices -l
  exit 1
fi

ver=$("$ADB" -s "$DEVICE" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
sdk=$("$ADB" -s "$DEVICE" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
abi=$("$ADB" -s "$DEVICE" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
echo "> 已连接: $DEVICE  | Android $ver (API $sdk) | $abi"

if [ "$CHECK" = 1 ]; then
  echo "> 检查模式，未启动应用。手动安装已构建的 APK："
  echo "  adb -s $DEVICE install -r build/app/outputs/flutter-apk/app-debug.apk"
  echo "  adb -s $DEVICE shell am start -n com.appforge.demo/.MainActivity"
  exit 0
fi

echo "> 启动 flutter run（r 热重载 / R 热重启 / q 退出）"
exec flutter run -d "$DEVICE" --device-timeout 60
