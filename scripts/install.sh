#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
source_app="$repo_dir/build/MeowMac.app"
target_app="$HOME/Applications/MeowMac.app"
[[ -d "$source_app" && ! -L "$source_app" ]] || { printf '请先运行 scripts/build-app.sh\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" == io.github.eastcn.meowmac ]] || { printf 'bundle id 不符\n' >&2; exit 1; }
codesign --verify --deep --strict "$source_app"
if pgrep -x MeowMac >/dev/null; then
    printf '正在让 MeowMac 正常退出…\n'
    osascript -e 'tell application id "io.github.eastcn.meowmac" to quit'
    for ((attempt = 0; attempt < 10; attempt++)); do
        if ! pgrep -x MeowMac >/dev/null; then break; fi
        sleep 1
    done
    if pgrep -x MeowMac >/dev/null; then
        printf 'MeowMac 未正常退出，本次安装已取消。\n' >&2
        exit 1
    fi
fi
apps_dir="$HOME/Applications"
[[ ! -L "$apps_dir" && ! -L "$target_app" ]] || { printf '安装路径是符号链接\n' >&2; exit 1; }
mkdir -p "$apps_dir"
if [[ -e "$target_app" ]]; then
    [[ -d "$target_app" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist" 2>/dev/null)" == io.github.eastcn.meowmac ]] || { printf '目标路径已有其他内容\n' >&2; exit 1; }
fi
work_dir="$(mktemp -d "$apps_dir/.meowmac-install.XXXXXX")"
old_moved=0
new_moved=0
committed=0
cleanup() {
    result=$?
    if (( committed == 0 )); then
        if (( new_moved == 1 )); then rm -rf -- "$target_app"; fi
        if (( old_moved == 1 )); then
            mv "$work_dir/previous.app" "$target_app" || { printf '旧应用恢复失败：%s\n' "$work_dir" >&2; exit "$result"; }
        fi
    fi
    rm -rf -- "$work_dir"
    exit "$result"
}
trap cleanup EXIT
ditto "$source_app" "$work_dir/MeowMac.app"
codesign --verify --deep --strict "$work_dir/MeowMac.app"
if [[ -e "$target_app" ]]; then mv "$target_app" "$work_dir/previous.app"; old_moved=1; fi
mv "$work_dir/MeowMac.app" "$target_app"; new_moved=1
open -a "$target_app"
committed=1
printf '已安装并启动：%s\n' "$target_app"
