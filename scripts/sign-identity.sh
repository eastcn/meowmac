#!/usr/bin/env bash
# 解析签名身份，供 build-app.sh 引用。用法：source scripts/sign-identity.sh; resolve_sign_identity
#
# 优先级：
#   1. 环境变量 MEOWMAC_SIGN_IDENTITY。"-" 强制 ad-hoc；其他值必须是钥匙串里的可用身份，否则报错。
#   2. 钥匙串里有本地开发证书（默认名 MeowMac Local Development）就用它，授权可跨重建保留。
#   3. 都没有就用 ad-hoc。别人克隆仓库后不需要任何证书。
# 身份名输出到标准输出，说明输出到标准错误。

MEOWMAC_LOCAL_IDENTITY_NAME="${MEOWMAC_LOCAL_IDENTITY_NAME:-MeowMac Local Development}"

has_sign_identity() {
    security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$1\""
}

resolve_sign_identity() {
    local requested="${MEOWMAC_SIGN_IDENTITY:-}"
    if [[ "$requested" == "-" ]]; then
        printf '签名：ad-hoc（MEOWMAC_SIGN_IDENTITY=-）\n' >&2
        printf -- '-\n'
    elif [[ -n "$requested" ]]; then
        has_sign_identity "$requested" || { printf '钥匙串里没有可用的签名身份：%s\n' "$requested" >&2; return 1; }
        printf '签名：%s\n' "$requested" >&2
        printf '%s\n' "$requested"
    elif has_sign_identity "$MEOWMAC_LOCAL_IDENTITY_NAME"; then
        printf '签名：%s（本地开发证书）\n' "$MEOWMAC_LOCAL_IDENTITY_NAME" >&2
        printf '%s\n' "$MEOWMAC_LOCAL_IDENTITY_NAME"
    else
        printf '签名：ad-hoc。每次重建后，系统隐私授权（如文稿）会失效重弹；运行 scripts/setup-local-signing.sh 可避免。\n' >&2
        printf -- '-\n'
    fi
}
