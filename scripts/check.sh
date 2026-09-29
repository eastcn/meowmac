#!/usr/bin/env bash
# MeowMac 的统一检查：受保护文件、依赖、编译和全部离线自测。任一项失败返回非零。
# 用法：scripts/check.sh
set -euo pipefail

cd "$(dirname "$0")/.."
failed=0

# 1. 受保护文件必须和 plan-baseline 标签一致（含未提交的改动）。
protected=(AGENTS.md CLAUDE.md docs/DECISIONS.md)
if git rev-parse -q --verify refs/tags/plan-baseline >/dev/null; then
    if ! git diff --quiet plan-baseline -- "${protected[@]}"; then
        printf '受保护文件与 plan-baseline 不一致，只有用户能改：\n' >&2
        git diff --stat plan-baseline -- "${protected[@]}" >&2
        failed=1
    fi
else
    printf '缺少 git 标签 plan-baseline，无法校验受保护文件\n' >&2
    failed=1
fi

# 2. 只允许依赖本地的 TunCanary。
if [[ ! -f Package.swift ]]; then
    printf '缺少 Package.swift，先完成 v0.1 执行清单第 1 条\n' >&2
    exit 1
fi
package_lines="$(grep -E '\.package\(' Package.swift || true)"
package_count="$(printf '%s\n' "$package_lines" | grep -c '\.package(' || true)"
if [[ "$package_count" != "1" ]] || ! grep -q 'path: "../tuncanary"' <<<"$package_lines"; then
    printf '依赖只能是 .package(path: "../tuncanary")，当前为：\n%s\n' "$package_lines" >&2
    failed=1
fi

# 3. 编译和离线自测。
swift build
scripts/test.sh

if (( failed != 0 )); then
    printf 'check 失败\n' >&2
    exit 1
fi
printf 'check 通过\n'
