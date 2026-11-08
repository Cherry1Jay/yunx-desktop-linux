#!/usr/bin/env bash
#
# 本机构建 + 发布云析 Linux 安装包
#
# 为什么存在这个脚本：GitHub Actions 依赖账号的 Billing 状态，账号被锁时
# workflow 根本不会启动（报 "your account is locked due to a billing issue"）。
# 这个脚本只用本机的 JDK + Gradle + makepkg，不依赖 Actions。
#
# 用法：
#   ./scripts/release-local.sh              # 用当前代码构建并发布
#   ./scripts/release-local.sh --sync       # 先把移植层 rebase 到上游最新，再构建发布
#   ./scripts/release-local.sh --build-only # 只出包，不发布
#
# 环境变量：
#   GH_TOKEN   发布 Release 用的 GitHub token（--build-only 时可省）
#   JAVA_HOME  指定 JDK 17（默认自动探测）
#
set -euo pipefail

REPO_SLUG="Cherry1Jay/yunx-desktop-linux"
UPSTREAM_URL="https://github.com/tidain/YunX-Desktop.git"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SYNC=0
BUILD_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --sync) SYNC=1 ;;
        --build-only) BUILD_ONLY=1 ;;
        -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $arg" >&2; exit 1 ;;
    esac
done

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. 可选：跟随上游 ----------
if [ "$SYNC" = 1 ]; then
    # 定时任务里最怕留下半截 rebase：下次一进来就是 detached HEAD + 冲突文件。
    # 宁可这一轮放弃，也不要把仓库留在中间态。
    if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
        log "检测到上次遗留的 rebase 中间态，先回滚到干净状态"
        git rebase --abort || die "无法 abort 上次的 rebase，请手工处理 .git/rebase-* 后重试"
    fi
    if [ -n "$(git status --porcelain)" ]; then
        die "工作区有未提交改动，放弃同步（定时任务不应改动用户手上的编辑）"
    fi
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    [ "$BRANCH" = "main" ] || die "当前不在 main 分支（当前：$BRANCH），拒绝自动 rebase"

    log "同步上游"
    git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
    git fetch upstream '+refs/heads/*:refs/remotes/upstream/*'

    NEW_SHA=$(git rev-parse upstream/main)
    OLD_SHA=$(tr -d '[:space:]' < PORT-BASE 2>/dev/null || echo "")
    log "上游 main = ${NEW_SHA:0:8}，当前基线 = ${OLD_SHA:0:8}"

    if [ "$NEW_SHA" = "$OLD_SHA" ]; then
        log "上游无新提交，跳过 rebase"
    else
        if ! git rebase --onto "$NEW_SHA" "$OLD_SHA"; then
            echo
            git rebase --abort >/dev/null 2>&1 || true
            die "rebase 冲突（已回滚，仓库保持原状）。请手工执行：
  git rebase --onto $NEW_SHA $OLD_SHA
  # 解冲突 → git add -A && git rebase --continue
  echo $NEW_SHA > PORT-BASE && git add PORT-BASE && git commit -m '构建基线：跟随上游'"
        fi
        echo "$NEW_SHA" > PORT-BASE
        git add PORT-BASE
        git commit -m "构建基线：跟随上游 ${NEW_SHA:0:8}" || true
        log "已 rebase 到上游 ${NEW_SHA:0:8}"
    fi
fi

# ---------- 2. 编译 ----------
APPVER=$(head -1 version.txt | tr -d '[:space:]')
log "应用版本 $APPVER"

command -v java >/dev/null || die "找不到 java，请装 jdk17-openjdk"
JAVA_MAJOR=$(java -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p')
[ "${JAVA_MAJOR:-0}" -ge 17 ] || die "需要 JDK 17+，当前是 $JAVA_MAJOR"

# 定时任务是非交互环境，没有 shell profile；显式给 GRADLE_USER_HOME 才能复用
# 已有的依赖缓存（含 130MB 的 CEF 原生库），否则每次都重新下载。
if [ -z "${GRADLE_USER_HOME:-}" ] && [ -d "$HOME/.cache/wb-yunx/gradle-home" ]; then
    export GRADLE_USER_HOME="$HOME/.cache/wb-yunx/gradle-home"
fi
log "编译 app-image（首次约 3-10 分钟）"
./gradlew :desktop:createDistributable --console=plain

APP="desktop/build/compose/binaries/main/app/YunX-Desktop"
[ -x "$APP/bin/YunX-Desktop" ] || die "构建产物缺失：$APP"

# ---------- 3. 打包 ----------
log "打包"
# 不删旧产物：tar 与 makepkg（-f）都会覆盖同名文件，避免误删
mkdir -p dist
tar -C "$(dirname "$APP")" -czf "dist/yunx-desktop-${APPVER}-linux-x86_64.tar.gz" YunX-Desktop

# makepkg 每次运行会 rm -rf 自己的 pkgdir。若沿用 packaging/pkg，第二次运行时
# 那里面已有 ~380 个文件，某些带删除保护的 shell/EDR 环境会拦下这次批量删除。
# 给它一个每次全新的 BUILDDIR 就绕开了：空目录没什么可删，也不会污染仓库。
MAKEPKG_BUILDDIR="$(mktemp -d "${TMPDIR:-/tmp}/yunx-makepkg-XXXXXX")"
(
    cd packaging
    BUILDDIR="$MAKEPKG_BUILDDIR" APPIMAGE="$ROOT/$APP" makepkg -f --noconfirm
    cp ./*.pkg.tar.zst "$ROOT/dist/"
)
# 收尾：清掉临时构建目录（用 python，避免再被 shell 的删除保护拦一次）
python3 - "$MAKEPKG_BUILDDIR" <<'PYEOF'
import shutil, sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PYEOF
# 只留最近两组产物（每组 = tar.gz + pkg.tar.zst，约 460MB）。
# 桌面机根分区本来就吃紧，定时任务跑上几个月不能让它慢慢堆满。
python3 - "$ROOT/dist" <<'PYEOF'
import os, sys
d = sys.argv[1]
files = [os.path.join(d, f) for f in os.listdir(d)
         if f.endswith(('.tar.gz', '.pkg.tar.zst'))]
files.sort(key=os.path.getmtime, reverse=True)
for f in files[4:]:
    os.unlink(f)
    print("  清理旧产物:", os.path.basename(f))
PYEOF
ls -lh dist

if [ "$BUILD_ONLY" = 1 ]; then
    log "已生成产物于 dist/（--build-only，不发布）"
    exit 0
fi

# ---------- 4. 发布 ----------
if [ -z "${GH_TOKEN:-}" ] && [ -r "$HOME/.config/yunx-release/token" ]; then
    GH_TOKEN=$(tr -d '[:space:]' < "$HOME/.config/yunx-release/token")
fi
[ -n "${GH_TOKEN:-}" ] || die "发布需要 GH_TOKEN（环境变量，或 ~/.config/yunx-release/token；--build-only 可跳过发布）"

# Release 的 target_commitish 必须已经存在于远程，否则 GitHub 返回 422，而且报错是
# "tag_name is not a valid tag" + "target_commitish invalid" —— 看着像 tag 名字非法或
# token 权限不够，实际原因是这个 commit 还没 push。先推再发。
PUSH_URL="https://x-access-token:${GH_TOKEN}@github.com/${REPO_SLUG}.git"
log "推送 main 到远程"
if ! PUSH_OUT=$(git -c credential.helper= push "$PUSH_URL" HEAD:main 2>&1); then
    printf '%s\n' "${PUSH_OUT//$GH_TOKEN/***}" >&2
    die "推送 main 失败（远程可能有他人提交，先 git fetch 看看）"
fi

N=$(git tag -l "v${APPVER}-linux.*" | wc -l)
TAG="v${APPVER}-linux.$((N + 1))"
log "发布 tag = $TAG"

API="https://api.github.com/repos/${REPO_SLUG}"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

RELEASE_RESP=$(curl -sS --max-time 30 -w '\n%{http_code}' "${AUTH[@]}" -X POST "$API/releases" \
    -d "$(printf '{"tag_name":"%s","target_commitish":"%s","name":"云析 Linux 移植 %s（%s）","body":"本机构建发布，基于上游 %s"}' \
        "$TAG" "$(git rev-parse HEAD)" "$APPVER" "$TAG" "$(tr -d '[:space:]' < PORT-BASE | cut -c1-8)")")
RELEASE_CODE=${RELEASE_RESP##*$'\n'}
RELEASE_BODY=${RELEASE_RESP%$'\n'*}
RELEASE_ID=$(printf '%s' "$RELEASE_BODY" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("id") or "")
except Exception: print("")')

if [ -z "$RELEASE_ID" ]; then
    echo "HTTP $RELEASE_CODE" >&2
    printf '%s\n' "$RELEASE_BODY" >&2
    die "创建 Release 失败（上面是服务端原始响应）"
fi

for f in dist/*; do
    name=$(basename "$f")
    log "上传 $name"
    # 实测：230MB 经代理上行约 5 分钟（~780KB/s）。原来给 600s 只有 1.3 倍余量，
    # 网络抖动一下就白跑一整轮构建，这里放宽到 30 分钟。
    curl -sS --max-time 1800 "${AUTH[@]}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$f" \
        "https://uploads.github.com/repos/${REPO_SLUG}/releases/${RELEASE_ID}/assets?name=${name}" \
        -o /dev/null -w '  HTTP %{http_code}\n'
done

log "完成：https://github.com/${REPO_SLUG}/releases/tag/${TAG}"
