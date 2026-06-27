# 在 macOS (Apple Silicon) 上本机构建与验证 `@cc-remote/iroh`

本文档说明如何在一台 macOS ARM (M 系列) 机器上，搭建环境、交叉编译出**除 Windows 外的全部平台** napi 二进制 (`.node`)，并在真实目标环境里验证它们能加载、跑通测试 —— 为发布 npm 做准备。

- **构建脚本**：[`build-local.sh`](./build-local.sh) —— 编出 7 个非 Windows 目标 + 静态校验。
- **验证脚本**：[`verify-local.sh`](./verify-local.sh) —— Docker 里运行时验证每个 `.node`。
- 发布矩阵已收敛到 **darwin + linux 共 7 个目标**；android / windows 已从 `napi.targets` 移除（cc-remote 的 daemon 用不到，且 windows 本机编不了）。包以 `@cc-remote/iroh` 发布。

> 本机覆盖的 7 个目标：`aarch64-apple-darwin`、`{x86_64,aarch64}-unknown-linux-{gnu,musl}`、`armv7-unknown-linux-{gnueabihf,musleabihf}`。

---

## 1. 一次性环境搭建

### 1.1 Rust 工具链

需要 Rust ≥ 1.91 (crate 的 `rust-version`)，装最新 stable 即可：

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustc --version          # 确认 ≥ 1.91
```

各 Linux target 的 std 由 `build-local.sh` 自动 `rustup target add`，无需手动。

> 加密后端是 `ring`（不是 `aws-lc-sys`），所以**不需要 cmake/protoc**，只用到 Xcode CLT 自带的 `clang`/`cc`。若没装命令行工具：`xcode-select --install`。

### 1.2 zig + cargo-zigbuild（交叉编译 Linux 用）

gnu/musl 的 Linux 目标用 zig 作为交叉链接器，在本机原生编译再 retarget（不走 Docker 仿真，快）：

```bash
brew install zig
cargo install cargo-zigbuild
zig version              # 0.16.x 可用
cargo-zigbuild --version
```

### 1.3 Node + 依赖

需要 Node ≥ 20.3。用 corepack 拉起项目锁定的 yarn 并装依赖（含 `@napi-rs/cli`）：

```bash
cd iroh-js
corepack enable
yarn install
```

### 1.4 Docker Desktop（验证用）

`verify-local.sh` 在 Linux 容器里跑测试。装好 Docker Desktop 并启动 daemon：

```bash
open -a Docker
docker info >/dev/null && echo "daemon up"
```

Docker Desktop 在 Apple Silicon 上**自带**多架构仿真：`linux/arm64` 原生跑，`linux/amd64` 走 Rosetta，`linux/arm/v7` 走 QEMU —— 无需任何额外 binfmt 配置。

> ⚠️ **不要**运行 `multiarch/qemu-user-static --reset`：它会覆盖 Docker Desktop 自带的 binfmt 处理器，导致**所有**容器（连原生 arm64 的都）报 `exec format error`。万一仿真坏了，安全的修法是重启 Docker Desktop，或 `docker run --privileged --rm tonistiigi/binfmt --install arm`。

---

## 2. 构建

```bash
cd iroh-js
./build-local.sh                  # 编 + 静态校验全部 7 个目标 (~15 min 冷编)
./build-local.sh --assemble       # 额外把 .node 分发进 npm/<platform>/ 子包
GLIBC_FLOOR=2.17 ./build-local.sh # 覆盖 gnu 的 glibc 底线 (默认 2.17)
```

产物落在 `iroh-js/iroh.<platform>.node`（已被 `.gitignore` 忽略，不入库）。脚本结尾会打印每个产物的架构与 gnu 的 glibc 底线，并对超标项报警退非零。

**各目标的构建方式不同**（见脚本注释）：

| 目标族 | 方式 | 说明 |
|---|---|---|
| darwin | `napi build`（原生） | 本机架构直接编 |
| linux musl | `napi build --cross-compile`（zig） | 静态 libc，无 glibc 底线问题 |
| linux gnu | `cargo zigbuild` 钉 glibc + 手动改名 | 见下「关键设计」 |

---

## 3. 验证

```bash
cd iroh-js
./verify-local.sh                 # Docker 里逐目标跑 node --test (~30s，镜像缓存后)
NODE_TAG=22 ./verify-local.sh     # 换 node 大版本 (默认 22)
```

- darwin 在宿主原生跑；6 个 Linux 目标各进**匹配镜像**跑测试。
- **gnu 目标特意用 `node:22-bullseye-slim`（Debian 11，glibc 2.31）做严格底线测**：能在这上面加载，就能在更新的发行版上加载。
- musl 目标用 `node:22-alpine`。
- 测试文件 `import '../index.js'`（相对路径）+ node 内建 test runner，所以容器里**无需 `yarn install`**：挂载整个 `iroh-js` 目录，loader 自动按 `platform/arch/libc` 选中对应的本地 `.node`。

任一目标失败或缺失，脚本退非零并打印失败尾部。

---

## 4. 关键设计与踩过的坑

### 4.1 gnu 目标必须钉 glibc 底线（可移植性）

zig 默认给不同目标挑的 glibc 版本不一致：x86_64/aarch64 默认约 2.30，但 **armv7-gnueabihf 默认 2.34（太新）**，在 Debian 11 / RHEL 8 等老发行版上加载即报 `GLIBC_2.34 not found`。

`build-local.sh` 统一把所有 gnu 目标钉到 **glibc 2.17**（manylinux2014 级，CentOS 7 / RHEL 8 / Debian 10+ 都能跑），办法是给 cargo-zigbuild 的 target 三元组加后缀：`armv7-unknown-linux-gnueabihf.2.17`。

### 4.2 napi 不认 glibc 后缀 → 手动改名

`napi build --target <triple>.<glibc>` 会编译成功，但其 `copyArtifact` 步骤按带后缀的路径找产物会失败。所以 gnu 目标**绕开 `napi build`**，直接：

```bash
cargo zigbuild --release --target <triple>.2.17
cp ../target/<裸三元组>/release/libnumber0_iroh.so iroh.<platform>.node
```

（cargo-zigbuild 把产物写在**不带后缀**的 `target/<裸三元组>/` 下。strip 由 `CARGO_PROFILE_RELEASE_STRIP=symbols` 在链接期完成。）

### 4.3 Android 已从发布矩阵移除

`aarch64-linux-android` / `armv7-linux-androideabi` 需要 Android NDK，且本项目消费方（Node 守护进程）用不到，已从 `package.json` 的 `napi.targets` 与 `npm/` 子包中删除。如需恢复，加回 targets 并装 NDK r23。

### 4.4 Windows / Android 已从矩阵移除

`*-pc-windows-msvc`（mac 编不了）与 `*-linux-android`（需 NDK、用不到）已从 `napi.targets` 与 `npm/` 子包删除。发布矩阵 = darwin + linux 共 7 个目标，单台 macOS arm 即可全部产出。如需恢复，加回 targets 并补对应工具链（windows 需 windows host 或 cargo-xwin；android 需 NDK r23）。

---

## 5. 目标矩阵

| 平台 (`.node` 名) | target triple | 本机方式 | 验证镜像 |
|---|---|---|---|
| darwin-arm64 | aarch64-apple-darwin | napi 原生 | 宿主原生 |
| linux-x64-gnu | x86_64-unknown-linux-gnu | zigbuild · glibc 2.17 | amd64 · bullseye |
| linux-arm64-gnu | aarch64-unknown-linux-gnu | zigbuild · glibc 2.17 | arm64 · bullseye |
| linux-arm-gnueabihf | armv7-unknown-linux-gnueabihf | zigbuild · glibc 2.17 | arm/v7 · bullseye |
| linux-x64-musl | x86_64-unknown-linux-musl | napi cross | amd64 · alpine |
| linux-arm64-musl | aarch64-unknown-linux-musl | napi cross | arm64 · alpine |
| linux-arm-musleabihf | armv7-unknown-linux-musleabihf | napi cross | arm/v7 · alpine |

---

## 6. 发版（发布到 npm）

发布是 **CI 自动**的：推一个 `v*` tag → `.github/workflows/release-cc-remote.yml` 跑**并行矩阵**——`build` 阶段每个目标一个 job 并行编（1×macos-latest 原生 darwin + 6×ubuntu-latest 经 zig 交叉编 linux，各自 upload `.node`），`publish` 阶段收齐所有 `.node` → `napi artifacts` 装配进 `npm/` → `npm publish` 主包（触发 `napi pre-publish` 先发 7 个平台子包），全部以 `@cc-remote/iroh*` 公开发布、带 provenance。墙钟约 7-10 分钟（vs 串行单 job 的 ~30 分钟）。公开仓库标准 runner 免费、无分钟上限。

> 本机用 `build-local.sh`（单机串行编全部）做开发/验证；CI 发布走上面的并行矩阵。两者构建每个目标的方式一致（darwin 原生 / musl 走 napi cross / gnu 用 cargo-zigbuild 钉 glibc 2.17）。

### 一次性前置
- npmjs.com 建好 `cc-remote` org + 一个 **automation** token（对 `@cc-remote` 有 publish 权）。
- GitHub repo → Settings → Secrets and variables → Actions 加 **Repository secret** `NPM_TOKEN` = 该 token。

### 每次发版

**关键：npm 发布的版本取自 `package.json` 的 `version`，不是 tag 名。** 所以**先 bump 版本，再打 tag**，且 tag 要指向「已含新版本」的 commit。

用 `release.sh` 一步备好（bump 全部 8 个 package.json + 同步 loader 版本串 + 校验 + 撞名检查）：

```bash
cd iroh-js
./release.sh 1.0.0          # 正式版 → CI 自动 latest dist-tag
./release.sh 1.0.1-rc.1     # 预发布 → CI 自动 next dist-tag（不污染 latest）
```

脚本**不会**自动 commit/tag/push（push tag 会触发不可逆的真发布）。它打印接下来的命令，你 review 后执行：

```bash
git add -A iroh-js && git commit -m "chore(release): 1.0.0"
# 合进 main（branch→PR→merge，或本 fork 直接提 main）—— workflow 文件需在被 tag 的 commit 上
git tag -a v1.0.0 -m "v1.0.0"
git push origin v1.0.0       # ← 触发 release-cc-remote workflow 发布
```

> 建议先发一个 `-rc.N` 预发布（走 `next` tag）验证整条链通了，再发正式版。
> tag 名要唯一——别撞已存在的 tag（如 fork 继承自上游的旧 tag）。

跟踪发布：`gh run list --workflow release-cc-remote.yml` / 在 npmjs.com 看 `@cc-remote/iroh`。
