#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
app_path="$repo_dir/build/MeowMac.app"
version="$(sed -n 's/^[[:space:]]*public static let version = "\([0-9A-Za-z.-]*\)"$/\1/p' "$repo_dir/Sources/MeowMacCore/AppIdentity.swift")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf '版本号无效\n' >&2; exit 1; }

cd "$repo_dir"
source "$repo_dir/scripts/sign-identity.sh"
sign_identity="$(resolve_sign_identity)"
swift build -c release
binary="$(swift build -c release --show-bin-path)/MeowMac"
[[ -x "$binary" ]] || { printf '未找到 MeowMac 可执行文件\n' >&2; exit 1; }
mkdir -p "$repo_dir/build"
[[ ! -L "$app_path" ]] || { printf '产物路径是符号链接\n' >&2; exit 1; }
if [[ -e "$app_path" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
    [[ -d "$app_path" && "$existing_id" == io.github.eastcn.meowmac ]] || { printf '产物路径已有其他内容\n' >&2; exit 1; }
fi
work_dir="$(mktemp -d "$repo_dir/build/.meowmac-build.XXXXXX")"
published=0
had_previous=0
cleanup() {
    result=$?
    if (( published == 0 && had_previous == 1 )) && [[ ! -e "$app_path" && -d "$work_dir/previous.app" ]]; then
        mv "$work_dir/previous.app" "$app_path" || { printf '旧构建恢复失败：%s\n' "$work_dir" >&2; exit "$result"; }
    fi
    rm -rf -- "$work_dir"
    exit "$result"
}
trap cleanup EXIT
stage="$work_dir/MeowMac.app"
iconset="$work_dir/MeowMac.iconset"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources" "$iconset"
cp "$binary" "$stage/Contents/MacOS/MeowMac"
# 命令行入口在 AppKit 启动前分流；独立进程名让安装只等待主应用退出。
cp "$binary" "$stage/Contents/MacOS/MeowMacAgentRunner"
codesign --force --sign "$sign_identity" "$stage/Contents/MacOS/MeowMacAgentRunner"
resource_bundle="$(dirname "$binary")/MeowMac_MeowMacUI.bundle"
[[ -d "$resource_bundle" ]] || { printf '未找到渠道图标资源包\n' >&2; exit 1; }
cp -R "$resource_bundle" "$stage/Contents/Resources/"
cat > "$stage/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleDisplayName</key><string>MeowMac</string>
<key>CFBundleExecutable</key><string>MeowMac</string>
<key>CFBundleIconFile</key><string>MeowMac.icns</string>
<key>CFBundleIdentifier</key><string>io.github.eastcn.meowmac</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>MeowMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
plutil -lint "$stage/Contents/Info.plist"
"$binary" --export-icon "$iconset"
iconutil -c icns -o "$stage/Contents/Resources/MeowMac.icns" "$iconset"
codesign --force --sign "$sign_identity" "$stage"
codesign --verify --deep --strict "$stage"
if [[ -e "$app_path" ]]; then mv "$app_path" "$work_dir/previous.app"; had_previous=1; fi
mv "$stage" "$app_path"
published=1
printf '已生成：%s\n' "$app_path"
