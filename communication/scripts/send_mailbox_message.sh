#!/usr/bin/env bash
set -euo pipefail

# 引数:
#   $*: エラーメッセージ本文
# 戻り値:
#   なし。標準エラー出力後に終了コード 1 で終了する。
# 処理概要:
#   呼び出し側で継続不能な入力不備や実行環境不備を一元的に終了させる。
die() {
    echo "[send-mailbox-message] Error: $*" >&2
    exit 1
}

# 引数:
#   なし
# 戻り値:
#   なし。使用方法を標準エラー出力し、終了コード 1 で終了する。
# 処理概要:
#   不正なコマンドライン引数が渡されたときに usage を表示する。
usage() {
    cat >&2 <<'EOF'
Usage: send_mailbox_message.sh --member <member> --to <name> --type <request|response|question|error> --message <body> [--session-name <session>] [--repo-root <path>]
EOF
    exit 1
}

# 引数:
#   $1: 検証対象の値
#   $2: エラーメッセージに使うラベル
# 戻り値:
#   なし。不正値なら die() で終了する。
# 処理概要:
#   空文字とパストラバーサルにつながる名前を拒否する。
validate_name() {
    local value="$1"
    local label="$2"

    if [[ -z "$value" ]]; then
        die "$label is required"
    fi

    if [[ "$value" == *".."* ]] || [[ "$value" == *"/"* ]]; then
        die "Invalid $label: $value"
    fi
}

# 引数:
#   $1: 探索開始ディレクトリ
# 戻り値:
#   stdout に repo root を出力する。見つからなければ die() で終了する。
# 処理概要:
#   1. 現在位置から親ディレクトリへ順に遡る。
#   2. `.agents` または `.git` を含む最初のディレクトリを返す。
resolve_default_repo_root() {
    local current_dir="$1"

    while [ "$current_dir" != "/" ]; do
        if [ -d "${current_dir}/.agents" ] || [ -d "${current_dir}/.git" ]; then
            printf '%s\n' "$current_dir"
            return 0
        fi
        current_dir="$(dirname "$current_dir")"
    done

    die "Failed to detect the repository root. Pass --repo-root explicitly."
}

# 引数:
#   コマンドライン引数一式
# 戻り値:
#   stdout に生成した Mailbox ファイルのパスを出力する。
# 処理概要:
#   1. 必須引数を検証する。
#   2. tmux セッション名と repo root を解決する。
#   3. outbox に frontmatter 付き Markdown メッセージを書き込む。
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root=""

member=""
to=""
message_type=""
message=""
session_name=""

while [ $# -gt 0 ]; do
    case "$1" in
        --member)
            [ $# -ge 2 ] || usage
            member="$2"
            shift 2
            ;;
        --to)
            [ $# -ge 2 ] || usage
            to="$2"
            shift 2
            ;;
        --type)
            [ $# -ge 2 ] || usage
            message_type="$2"
            shift 2
            ;;
        --message)
            [ $# -ge 2 ] || usage
            message="$2"
            shift 2
            ;;
        --session-name)
            [ $# -ge 2 ] || usage
            session_name="$2"
            shift 2
            ;;
        --repo-root)
            [ $# -ge 2 ] || usage
            repo_root="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

validate_name "$member" "member"
validate_name "$to" "destination"

case "$message_type" in
    request|response|question|error)
        ;;
    *)
        die "Invalid message type: $message_type"
        ;;
esac

[ -n "$message" ] || die "message is required"

if [ -z "$session_name" ]; then
    if ! session_name="$(tmux display-message -p '#{session_name}' 2>/dev/null)"; then
        die "Failed to read the tmux session name. Run inside tmux or pass --session-name explicitly."
    fi
fi

[ -n "$session_name" ] || die "session name is required"
validate_name "$session_name" "session name"

if [ -z "$repo_root" ]; then
    repo_root="$(resolve_default_repo_root "$script_dir")"
fi

repo_root="$(cd "$repo_root" && pwd)"
outbox_dir="${repo_root}/.ai-team/${session_name}/mailbox/${member}/outbox"
mkdir -p "$outbox_dir"

epoch="$(date -u +%s)"

while :; do
    file_stamp="$(date -u -d "@${epoch}" +%Y%m%dT%H%M%S)"
    iso_stamp="$(date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ)"
    output_path="${outbox_dir}/${file_stamp}.md"

    if [ ! -e "$output_path" ]; then
        break
    fi

    epoch="$((epoch + 1))"
done

{
    printf '%s\n' '---'
    printf 'from: %s\n' "$member"
    printf 'to: %s\n' "$to"
    printf 'type: %s\n' "$message_type"
    printf 'timestamp: %s\n' "$iso_stamp"
    printf '%s\n' '---'
    printf '\n'
    printf '%s\n' "$message"
} > "$output_path"

printf '%s\n' "$output_path"
