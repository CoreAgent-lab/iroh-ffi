#!/usr/bin/env bash
#
# release.sh <version> — 准备一次 @cc-remote/iroh 发布。
#
# 做什么（安全、可逆的准备工作）：
#   1. 把所有 8 个 package.json（主包 + 7 个 npm/ 子包）的 version 改成 <version>
#   2. 同步 index.js loader 里的版本校验串到 <version>（node 字符串替换，秒级，不编译）
#   3. 校验 8 个 version 与 loader 一致
#   4. 检查 v<version> tag 是否已存在（撞名会触发 force-move 麻烦）
#   5. 打印接下来的 git 命令（commit / 合 main / tag / push）
#
# 不做什么：不自动 commit / tag / push。push tag 会触发 CI 真发布到 npm（不可逆），
# 所以这一步留给你 review 后手动执行。
#
# 用法：
#   ./release.sh 1.0.0          # 正式版（CI 自动用 latest dist-tag）
#   ./release.sh 1.0.1-rc.1     # 预发布（CI 自动用 next dist-tag，不污染 latest）

set -euo pipefail

VERSION="${1:?用法: ./release.sh <version>   例: 1.0.0 或 1.0.1-rc.1}"
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
  echo "✗ 版本号格式不对: $VERSION（应形如 1.0.0 或 1.0.1-rc.1）" >&2
  exit 1
fi

JS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$JS_DIR"

OLD="$(node -p "require('./package.json').version")"
echo "==> 版本 $OLD → $VERSION"

# 1. bump 全部 8 个 package.json
node -e '
const fs=require("fs");
const v=process.argv[1];
const files=["package.json", ...fs.readdirSync("npm").map(d=>`npm/${d}/package.json`)];
for(const f of files){
  const p=JSON.parse(fs.readFileSync(f,"utf8"));
  p.version=v;
  fs.writeFileSync(f, JSON.stringify(p,null,2)+"\n");
}
console.log("  bumped", files.length, "package.json");
' "$VERSION"

# 2. 同步 loader 版本校验串（index.js 里出现的旧版本字符串 → 新版本）
if [ -f index.js ] && [ -n "$OLD" ]; then
  node -e '
const fs=require("fs");
const [oldV,newV]=process.argv.slice(1);
let s=fs.readFileSync("index.js","utf8");
const n=s.split(oldV).length-1;
s=s.split(oldV).join(newV);
fs.writeFileSync("index.js",s);
console.log("  index.js 版本串替换", n, "处");
' "$OLD" "$VERSION"
fi
# 注：即便此步漏了，CI 的 build-local.sh 也会在发布前重新生成 index.js，published 产物始终正确。

# 3. 校验一致性
echo "==> 校验"
BAD=0
for f in package.json npm/*/package.json; do
  v="$(node -p "require('./$f').version")"
  [ "$v" = "$VERSION" ] || { echo "  ✗ $f = $v"; BAD=1; }
done
grep -q "!== '$VERSION'" index.js 2>/dev/null && echo "  ok loader 版本串 = $VERSION" || echo "  ! loader 未含 $VERSION（CI 会重生成，通常无碍）"
[ "$BAD" = 0 ] && echo "  ok 8 个 package.json 版本一致 = $VERSION" || { echo "✗ 版本不一致，停。"; exit 1; }

# 4. tag 撞名检查
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "  ⚠️  tag v$VERSION 已存在！换个版本号，或确需复用得 force-move（git tag -f + push --force）。"
fi

# 5. 打印接下来的步骤
cat <<EOF

==> 准备完成。Review 后执行（push tag 会触发 CI 真发布，不可逆）：

  git add -A iroh-js
  git commit -m "chore(release): $VERSION"
  # 合进 main（branch→PR→merge，或本 fork 直接提 main）
  git tag -a v$VERSION -m "v$VERSION"
  git push origin v$VERSION          # ← 触发 release-cc-remote workflow 发布

  dist-tag 由 CI 自动判：$( echo "$VERSION" | grep -q '-' && echo 'next（预发布）' || echo 'latest（正式）' )
EOF
