#!/usr/bin/env bash
# 首次初始化：在装有 Flutter SDK 的开发者机器上执行（macOS 才能生成/编译 iOS 壳）。
# 生成脚手架的机器没有 Android SDK / Xcode，因此本脚本不会在那里自动运行。
set -euo pipefail

ORG="com.appforge"
PROJECT="appforge_demo"
BUNDLE_ID="com.appforge.demo"
GENERATED_ID="${ORG}.${PROJECT}"

if ! command -v flutter >/dev/null 2>&1; then
  echo "x 未检测到 Flutter SDK，请先安装: https://docs.flutter.dev/get-started/install" >&2
  exit 1
fi

# flutter create 会重写若干模板文件，先备份本仓库已定制的内容
TMP="$(mktemp -d)"
cp pubspec.yaml README.md .gitignore lib/main.dart "$TMP/"
[ -f analysis_options.yaml ] && cp analysis_options.yaml "$TMP/analysis_options.yaml"

echo "> 生成 android/ 与 ios/ 原生壳"
flutter create --org "$ORG" --project-name "$PROJECT" --platforms=android,ios .

echo "> 恢复定制文件"
cp "$TMP/pubspec.yaml" pubspec.yaml
cp "$TMP/README.md" README.md
cp "$TMP/.gitignore" .gitignore
cp "$TMP/main.dart" lib/main.dart
[ -f "$TMP/analysis_options.yaml" ] && cp "$TMP/analysis_options.yaml" analysis_options.yaml
# 模板 widget_test 与本工程的本地化配置不兼容，移除后使用 test/app_test.dart
rm -f test/widget_test.dart

echo "> 统一双端标识为 ${BUNDLE_ID}"
# Android 模板用 snake_case (com.appforge.appforge_demo)，iOS 模板可能用 camelCase
# (com.appforge.appforgeDemo)，两种形式都要替换，且 project.pbxproj 里有多处配置。
# 用 Python 而非 perl/sed -i：Windows Git Bash 无 perl，macOS BSD sed 的 -i 语法也不同。
PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
test -n "$PY" || { echo "x 需要 Python 3 来统一包名" >&2; exit 1; }
"$PY" - "$BUNDLE_ID" <<'PYEOF'
import pathlib, re, sys

bundle = sys.argv[1]

# 1) 文本替换：build.gradle / pbxproj / MainActivity.kt 的 package 声明。
#    ★ MainActivity.kt 必须一起改：Manifest 里 android:name=".MainActivity" 是按
#    namespace 解析的，若 Kotlin package 仍是模板值，编译能过但启动即
#    ClassNotFoundException（这个缺陷只会在真机/模拟器暴露，CI 编译发现不了）。
for name in [
    "android/app/build.gradle",
    "ios/Runner.xcodeproj/project.pbxproj",
    "android/app/src/main/kotlin/com/appforge/appforge_demo/MainActivity.kt",
]:
    path = pathlib.Path(name)
    if not path.exists():
        continue
    text = path.read_text(encoding="utf-8")
    updated = re.sub(r"com\.appforge\.appforge(?:Demo|_demo)", bundle, text)
    if updated != text:
        path.write_text(updated, encoding="utf-8")
        print("  已更新 " + name)

# 2) 应用显示名（模板默认写成带下划线的 project name）
manifest = pathlib.Path("android/app/src/main/AndroidManifest.xml")
if manifest.exists():
    text = manifest.read_text(encoding="utf-8")
    updated = re.sub(r'android:label="[^"]*"', 'android:label="AppForge Demo"', text, count=1)
    if updated != text:
        manifest.write_text(updated, encoding="utf-8")
        print("  已更新 " + str(manifest))

# 3) Kotlin 源码目录与 package 对齐
src = pathlib.Path("android/app/src/main/kotlin/com/appforge/appforge_demo")
dst = pathlib.Path("android/app/src/main/kotlin/com/appforge/demo")
if src.exists():
    dst.mkdir(parents=True, exist_ok=True)
    for f in src.iterdir():
        f.rename(dst / f.name)
    src.rmdir()
    print("  已整理 Kotlin 源码目录 -> " + str(dst))

# 4) 防回归自检：所有 Kotlin package 必须与 applicationId 完全一致
bad = []
for f in pathlib.Path("android/app/src").rglob("*.kt"):
    pkg = next((l.split()[1] for l in f.read_text(encoding="utf-8").splitlines()
                if l.startswith("package ")), None)
    if pkg and pkg != bundle:
        bad.append("{}: package {} != {}".format(f, pkg, bundle))
if bad:
    print("x MainActivity 包名与 applicationId 不一致，运行时会 ClassNotFoundException", file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
print("  OK Kotlin package 与 applicationId 一致：" + bundle)
PYEOF

echo "> 安装依赖并生成本地化代码"
flutter pub get
flutter gen-l10n

echo "OK 完成。接下来："
echo "  1. 按 docs/RELEASE_PATH.md 配置 Android 签名片段、iOS Signing 与权限文案"
echo "  2. 替换应用图标与启动图"
echo "  3. 提交 android/ 与 ios/ 目录，CI 才能构建"
