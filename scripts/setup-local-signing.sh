#!/usr/bin/env bash
# 一次性创建本地开发用的自签名代码签名证书，之后 build-app.sh 会自动使用。
# 证书只在本机登录钥匙串里，不进入仓库，不对外发布。
# 过程会改你的登录钥匙串和用户级信任设置，系统会弹出授权框，需要你本人确认。
# 可重复运行：证书已导入但没设为可信时，只补设信任。
# 用法：scripts/setup-local-signing.sh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=scripts/sign-identity.sh
source "$repo_dir/scripts/sign-identity.sh"
name="$MEOWMAC_LOCAL_IDENTITY_NAME"
keychain="$HOME/Library/Keychains/login.keychain-db"

if has_sign_identity "$name"; then
    printf '已有可用的本地开发证书：%s，无需重复创建。\n' "$name"
    exit 0
fi
[[ -f "$keychain" ]] || { printf '未找到登录钥匙串：%s\n' "$keychain" >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
    # 上次导入后没来得及设为可信：复用钥匙串里的证书，只补信任这一步。
    printf '钥匙串里已有证书“%s”，只补设信任。\n' "$name"
    security find-certificate -c "$name" -p "$keychain" > "$work_dir/cert.pem"
else
    {
        printf '[req]\ndistinguished_name = dn\nx509_extensions = ext\nprompt = no\n'
        printf '[dn]\nCN = %s\n' "$name"
        printf '[ext]\nbasicConstraints = critical,CA:false\nkeyUsage = critical,digitalSignature\nextendedKeyUsage = critical,codeSigning\n'
    } > "$work_dir/openssl.cnf"

    # 必须用系统自带的 LibreSSL：Homebrew 的 OpenSSL 3 导出的 p12 在 macOS 上无法导入。
    openssl=/usr/bin/openssl
    password="$("$openssl" rand -hex 16)"
    "$openssl" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work_dir/openssl.cnf" \
        -keyout "$work_dir/key.pem" -out "$work_dir/cert.pem" 2>/dev/null
    "$openssl" pkcs12 -export -inkey "$work_dir/key.pem" -in "$work_dir/cert.pem" \
        -out "$work_dir/identity.p12" -passout "pass:$password"
    security import "$work_dir/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
    printf '证书已导入登录钥匙串。\n'
fi

printf '接下来系统会请求授权，把它设为“代码签名”可信（仅当前用户）。\n'
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work_dir/cert.pem"

if has_sign_identity "$name"; then
    printf '完成：%s 可用于签名。\n' "$name"
    printf '首次签名时，钥匙串可能询问 codesign 能否使用私钥，选“始终允许”。\n'
    printf '下一次 scripts/build-app.sh 会自动使用它。首次换到新签名后，系统隐私授权需要重新点一次，之后重建不再重弹。\n'
else
    printf '证书已导入但仍不可用于签名，请在“钥匙串访问”里检查它的信任设置。\n' >&2
    exit 1
fi
