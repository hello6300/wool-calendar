#!/usr/bin/env bash
# Windows 用户级工具链安装脚本（Git Bash 执行，无需管理员权限）
#
# 作用：下载并解压 Flutter / Temurin JDK 17 / Android cmdline-tools / actionlint
#      到 D:/dev，核心组件全部做官方哈希校验，可重复执行（已存在且校验通过则跳过）。
# 不做：不修改系统目录、不改注册表、不改 PATH、不安装任何证书或密钥。
#      PATH 与 JAVA_HOME/ANDROID_HOME 的持久化由 PowerShell 单独完成。
#
# 用法：
#   bash scripts/setup-windows-env.sh
#   DEV_ROOT=E:/dev bash scripts/setup-windows-env.sh
#
# 下载地址与校验和来源（2026-11-05 实测核验）：
#   - Flutter: releases_windows.json 的 sha256 字段。注意 hash 字段是 Git commit，
#     不是文件校验和。官方 Google 源实测 ~220KB/s，改用 Flutter 中国镜像 ~13.9MB/s，
#     下载后 SHA-256 与官方值完全一致。
#   - JDK:     Adoptium 官方 release 的 .zip.sha256.txt + 清华 TUNA 镜像
#   - cmdline: dl.google.com repository2-3.xml 的 sha1 checksum
#   - actionlint: GitHub release（国内易断连，走镜像回退且失败不阻断主流程）
#
# 附：Gradle 首次构建（本机验证记录，按需手工执行）
#   - 官方 distributionUrl (services.gradle.org) 经沙箱代理仅 ~37KB/s；
#     改用 https://mirrors.cloud.tencent.com/gradle/gradle-8.3-all.zip (~14MB/s)，
#     下载到 ~/.gradle/wrapper/dists/gradle-8.3-all/<hash>/，解压后 touch *.zip.ok 即可。
#   - Maven 依赖在 ~/.gradle/init.gradle 里配阿里云镜像（gradle-plugin / google / public），
#     避免 Maven Central 拉 kotlin-gradle-plugin 超时；该文件是用户级配置，不进项目仓库。
#   - Java 不读 HTTP_PROXY，沙箱内需临时设置 JAVA_TOOL_OPTIONS 传 JVM 代理参数；
#     普通开发终端无需此项。
set -euo pipefail

DEV_ROOT="${DEV_ROOT:-D:/dev}"
DL="$DEV_ROOT/downloads"
mkdir -p "$DL" "$DEV_ROOT/bin"

FLUTTER_VER="3.24.5"
FLUTTER_ZIP="flutter_windows_${FLUTTER_VER}-stable.zip"
FLUTTER_URL="https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/${FLUTTER_ZIP}"
FLUTTER_SHA256="b8a7485acd3c6fb23a76b7ac09f89e8d93d62fbff7147c6f5f8c5686d949eeac"

JDK_ZIP="OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip"
JDK_URL="https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/windows/${JDK_ZIP}"
JDK_SHA256="e53a79c3c3d86865bd7e787903884331068e71321714ffd44f145785affc7cb0"

CLT_ZIP="commandlinetools-win-16111833_latest.zip"
CLT_URL="https://dl.google.com/android/repository/${CLT_ZIP}"
CLT_SHA1="57d04f2d75eb8e8fffc5000a987e5de4b5a63e9d"

AL_ZIP="actionlint_1.7.12_windows_amd64.zip"
AL_URL="https://github.com/rhysd/actionlint/releases/download/v1.7.12/${AL_ZIP}"

hash_of() {
  case "$1" in
    sha1)   sha1sum   "$2" | cut -d' ' -f1 ;;
    sha256) sha256sum "$2" | cut -d' ' -f1 ;;
  esac
}

# 核心组件：校验失败立即终止，绝不使用未经验证的 SDK
fetch() {
  local name="$1" url="$2" algo="$3" want="$4"
  local f="$DL/$name"
  if [ -f "$f" ] && [ "$(hash_of "$algo" "$f")" = "$want" ]; then
    echo "SKIP   $name (已存在，${algo} 校验通过)"
    return
  fi
  echo "FETCH  $name  <- $url"
  local t0=$SECONDS
  if [ -f "$f" ]; then
    curl -fL --retry 3 --retry-delay 2 -C - -o "$f" "$url" \
      || { rm -f "$f"; curl -fL --retry 3 -o "$f" "$url"; }
  else
    curl -fL --retry 3 -o "$f" "$url"
  fi
  local got
  got="$(hash_of "$algo" "$f")"
  if [ "$got" != "$want" ]; then
    echo "ERROR  $name 校验失败: expected=$want actual=$got" >&2
    exit 1
  fi
  echo "OK     $name (${algo} 校验通过, $(du -h "$f" | cut -f1), $((SECONDS-t0))s)"
}

echo "=== 目标目录: $DEV_ROOT ==="

fetch "$FLUTTER_ZIP" "$FLUTTER_URL" sha256 "$FLUTTER_SHA256"
fetch "$JDK_ZIP"     "$JDK_URL"     sha256 "$JDK_SHA256"
fetch "$CLT_ZIP"     "$CLT_URL"     sha1   "$CLT_SHA1"

# Flutter：zip 内顶层即 flutter/
if [ ! -f "$DEV_ROOT/flutter/bin/flutter" ]; then
  echo "UNZIP  Flutter $FLUTTER_VER"
  unzip -q -o "$DL/$FLUTTER_ZIP" -d "$DEV_ROOT"
else
  echo "SKIP   Flutter 已解压"
fi

# JDK：zip 内顶层目录名随版本变化（jdk-17.0.20.1+1 等），运行时读取，避免写死
if [ ! -f "$DEV_ROOT/jdk17/bin/java.exe" ]; then
  echo "UNZIP  Temurin JDK 17"
  rm -rf "$DEV_ROOT/_jdk_tmp"
  mkdir -p "$DEV_ROOT/_jdk_tmp"
  unzip -q -o "$DL/$JDK_ZIP" -d "$DEV_ROOT/_jdk_tmp"
  JDK_TOP="$(unzip -Z1 "$DL/$JDK_ZIP" | head -1 | cut -d/ -f1)"
  test -n "$JDK_TOP" || { echo "ERROR 无法识别 JDK zip 顶层目录" >&2; exit 1; }
  mv "$DEV_ROOT/_jdk_tmp/$JDK_TOP" "$DEV_ROOT/jdk17"
  rm -rf "$DEV_ROOT/_jdk_tmp"
else
  echo "SKIP   JDK 已解压"
fi

# Android cmdline-tools：sdkmanager 要求 cmdline-tools/latest/bin 布局
if [ ! -f "$DEV_ROOT/android-sdk/cmdline-tools/latest/bin/sdkmanager.bat" ]; then
  echo "UNZIP  Android cmdline-tools"
  mkdir -p "$DEV_ROOT/android-sdk/cmdline-tools"
  rm -rf "$DEV_ROOT/_clt_tmp"
  mkdir -p "$DEV_ROOT/_clt_tmp"
  unzip -q -o "$DL/$CLT_ZIP" -d "$DEV_ROOT/_clt_tmp"
  rm -rf "$DEV_ROOT/android-sdk/cmdline-tools/latest"
  mv "$DEV_ROOT/_clt_tmp/cmdline-tools" "$DEV_ROOT/android-sdk/cmdline-tools/latest"
  rm -rf "$DEV_ROOT/_clt_tmp"
else
  echo "SKIP   cmdline-tools 已解压"
fi

# actionlint：可选的 workflow 语义校验工具。GitHub 在国内常断连，
# 因此放在主流程最后、走镜像回退，且任何失败都不阻断 SDK 安装。
if [ ! -f "$DEV_ROOT/bin/actionlint.exe" ]; then
  echo "FETCH  actionlint (optional)"
  AL_OK=0
  for m in "https://gh-proxy.com/" "https://ghproxy.net/" "https://mirror.ghproxy.com/" ""; do
    if curl -fL -sS --retry 1 -m 30 -o "$DL/$AL_ZIP" "${m}${AL_URL}" 2>/dev/null &&
       unzip -tq "$DL/$AL_ZIP" >/dev/null 2>&1; then
      unzip -q -o "$DL/$AL_ZIP" -d "$DEV_ROOT/bin"
      AL_OK=1
      echo "OK     actionlint 已安装 (via ${m:-GitHub 直连})"
      break
    fi
  done
  if [ "$AL_OK" -eq 0 ]; then
    echo "WARN   actionlint 下载失败，跳过（不影响 Flutter / JDK / Android 工具链）"
    rm -f "$DL/$AL_ZIP"
  fi
else
  echo "SKIP   actionlint 已安装"
fi

echo
echo "=== 文件校验 ==="
"$DEV_ROOT/jdk17/bin/java.exe" -version 2>&1 | head -2
if [ -f "$DEV_ROOT/bin/actionlint.exe" ]; then
  echo "actionlint $("$DEV_ROOT/bin/actionlint.exe" -version 2>&1 | head -1)"
fi
ls -l "$DEV_ROOT/flutter/bin/flutter" "$DEV_ROOT/android-sdk/cmdline-tools/latest/bin/sdkmanager.bat"

echo
echo "=== 下载 + 解压完成 ==="
echo "下一步："
echo "  1. 用户级环境变量已由 PowerShell 配置（JAVA_HOME / ANDROID_HOME /"
echo "     PUB_HOSTED_URL / FLUTTER_STORAGE_BASE_URL + PATH），重开终端生效"
echo "  2. sdkmanager 安装 platform-tools / platforms;android-34 / build-tools;34.0.0"
echo "  3. flutter doctor、pub get、analyze、test、build appbundle 验证"
