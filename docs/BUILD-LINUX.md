# 在 Linux 上构建 YunX-Desktop（Linux 移植版）

> 上游文档 [BUILD.md](BUILD.md) 描述的是 **Windows** 构建流程（PowerShell + Inno Setup + MSVC）。
> Linux 侧流程见本文，两者互不影响。

## 一、环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 发行版 | 任意 x86_64 Linux（实测 EndeavourOS / Arch） | 需要 glibc 与常见 X11 图形库 |
| JDK | **17**（`jdk17-openjdk`） | Compose Desktop 与 jlink/jpackage 需要 JDK 17 |
| Gradle | 无需安装 | 仓库内 Gradle Wrapper 会自动下载 8.13 |
| 网络 | 能访问 Maven Central / Google Maven | 首次构建拉依赖；国内可配镜像 |
| 磁盘 | ≥ 3 GB 空闲 | 依赖缓存 ~1 GB，app-image 331 MB，包体 258 MB |

```bash
# Arch
sudo pacman -S --needed jdk17-openjdk
# Debian / Ubuntu
# sudo apt install openjdk-17-jdk
```

构建 app-image 需要 `jpackage`（JDK 17 自带）与 `fakeroot`（`makepkg` 用，Arch 打包时）。

## 二、构建命令

```bash
git clone https://github.com/Cherry1Jay/yunx-desktop-linux.git
cd yunx-desktop-linux

export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
export PATH="$JAVA_HOME/bin:$PATH"

# 1) 编译并生成「自带 jlink 运行时」的 app-image
./gradlew :desktop:createDistributable

# 产物：desktop/build/compose/binaries/main/app/YunX-Desktop/
# 结构：bin/YunX-Desktop（启动器）+ lib/（jar + JCEF 原生库 + 精简 JRE）

# 2) 打 pacman 包（可选）
cd packaging
makepkg -f
sudo pacman -U yunx-desktop-1.3.3-1-x86_64.pkg.tar.zst
```

`PKGBUILD` 不重新编译 Kotlin（避免把 Gradle 网络依赖塞进 makepkg 的离线环境），
而是把第 1 步产出的 app-image 原样装进 `/opt/yunx-desktop`。若 app-image 不在默认位置：

```bash
APPIMAGE=/path/to/YunX-Desktop makepkg -f
```

## 三、开发运行

```bash
./gradlew :desktop:run
```

- **Wayland 会话下**（GNOME/KDE）应用通过 XWayland 运行；若在纯 X11 会话中从终端启动，确保
  `DISPLAY` 与 `XAUTHORITY` 已设置。
- 从 SSH / systemd 拉起时需显式带上图形环境变量：

```bash
export DISPLAY=:0
export XAUTHORITY=$(ls /run/user/$(id -u)/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
```

## 四、平台相关构建差异（相对上游）

`desktop/build.gradle.kts` 里已按平台分支，Linux 上自动走以下路径：

| 项 | Windows | Linux |
|---|---|---|
| JCEF 原生库 | `jcef-natives-windows-amd64` | `jcef-natives-linux-amd64`（**版本串必须与 `jcefmaven` 严格一致**） |
| `compileDarkMode` | 调 `cl.exe`/`g++` 编译 `darkmode.dll` | 注册为空任务（Linux 无 uxtheme 桥接） |
| `java.library.path` | `;` 分隔 | `File.pathSeparator`（`:`） |
| jpackage 目标 | `TargetFormat.Exe` | `TargetFormat.Deb` / app-image 交由 `PKGBUILD` 打包 |

## 五、产物说明与常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `createDistributable` 报 `jpackage` 不存在 | `JAVA_HOME` 指向了 JRE 而非 JDK 17；用 `java -version` 与 `echo $JAVA_HOME` 核对 |
| 运行时 `UnsatisfiedLinkError` / JCEF 初始化失败 | JCEF 原生库版本与 `jcefmaven` 不匹配；两者必须同一构建（`132.3.1` ↔ `jcef-1770317+cef-132.3.1+…`） |
| 首次启动卡顿十几秒 | 正在解包 JCEF（~325 MB）到 `~/.yunx-desktop/cache/jcef-bundle`，仅首次 |
| 无托盘图标 | GNOME 需 AppIndicator 扩展；其他桌面需支持 StatusNotifier |
| 下载时提示没有可用内核 | 首次使用会从 GitHub 拉 `gopeed-web-<ver>-linux-amd64.zip`；网络受限时先在设置里配代理/镜像 |
| `./gradlew` 没有执行权限 | `chmod +x gradlew` |

## 六、跟随上游升级

本仓库的提交结构是「上游 `tidain/YunX-Desktop` 的全部历史 + 叠加在其上的 Linux 移植提交」，
所以升级 = 把移植层重放到上游新基线上，**不需要重新移植**：

```bash
git fetch upstream
git rebase --onto upstream/main $(cat PORT-BASE)   # PORT-BASE 记录上次的上游基线 commit
echo <新上游 sha> > PORT-BASE
git add PORT-BASE && git commit -m "构建基线：跟随上游"
```

### 自动化（GitHub Actions）

`.github/workflows/upstream-sync.yml` 每天 04:00（北京时间）跑一次：

| 阶段 | 行为 |
| --- | --- |
| 检测 | 比较 `upstream/main` 与 `PORT-BASE`，无变化则直接结束 |
| 重放 | `git rebase --onto` 移植层；**冲突不静默吞**（不用 `-X ours`），开 Issue 附本地处理命令 |
| 编译 | JDK 17 编译 `:desktop:createDistributable` |
| 打包 | pacman 包 + 通用 tar.gz |
| 发布 | 打 tag `v<应用版本>-linux.<序号>`，发 Release |
| 失败 | 开 Issue 并附运行日志链接 |

也能在 Actions 页面手动触发：`force` 可强制重建当前版本，`upstream_ref` 可指定上游 tag。

> ⚠️ Actions 依赖账号 Billing 状态。若运行记录显示
> 「The job was not started because your account is locked due to a billing issue」，
> 说明账号被账单问题锁定，需先到 <https://github.com/settings/billing> 处理。

### 本地兜底（不依赖 Actions）

```bash
export GH_TOKEN=<你的 token>
./scripts/release-local.sh            # 构建 + 发布
./scripts/release-local.sh --sync     # 先 rebase 上游最新，再构建发布
./scripts/release-local.sh --build-only   # 只出包到 dist/
```

### 定时自动构建（systemd timer，Actions 不可用时的等价方案）

`~/yunx-desktop-linux` 这个符号链接指向仓库，按下面的方式挂到用户级 systemd：

```bash
mkdir -p ~/.config/yunx-release ~/.local/state
install -m 600 /dev/null ~/.config/yunx-release/token
printf '%s\n' '<你的 token>' > ~/.config/yunx-release/token   # 只存 token，不写进单元文件
```

`~/.config/systemd/user/yunx-upstream-sync.service` + `.timer`：

```ini
# .service
[Service]
Type=oneshot
WorkingDirectory=%h/yunx-desktop-linux
ExecStart=%h/yunx-desktop-linux/scripts/release-local.sh --sync
TimeoutStartSec=3h
Nice=10
Environment=JAVA_HOME=/usr/lib/jvm/java-17-openjdk
Environment=GRADLE_USER_HOME=%h/.cache/wb-yunx/gradle-home
Environment=PATH=%h/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:%h/.local/state/yunx-upstream-sync.log
StandardError=append:%h/.local/state/yunx-upstream-sync.log

# .timer
[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true            # 桌面机关了机，开机补跑
RandomizedDelaySec=15min   # 别在开机瞬间抢 CPU
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now yunx-upstream-sync.timer
systemctl --user start yunx-upstream-sync.service   # 立刻跑一次
journalctl --user -u yunx-upstream-sync -f
tail -f ~/.local/state/yunx-upstream-sync.log
```

定时运行比 CI 多几道保护，都在 `scripts/release-local.sh` 里：

| 保护 | 原因 |
| --- | --- |
| 进入 `--sync` 先 `git rebase --abort` 残留中间态 | 上一轮被打断会留下 detached HEAD，下一轮直接崩 |
| 工作区有未提交改动 → 放弃并退出 | 定时任务不能替人做决定、更不该动用户手上的编辑 |
| 不在 `main` 分支 → 拒绝 rebase | 防止在临时分支上把移植层改乱 |
| rebase 冲突 → 自动回滚到干净状态 | 不留半成品等人工 |
| 发布前先 `git push HEAD:main` | Release 的 `target_commitish` 必须已存在于远程，否则 422 |
| `dist/` 只留最近两组产物 | 每次约 460MB，根分区撑不住 |

## 七、许可

源码以 AGPL-3.0 发布，构建与分发同样受其约束（须提供对应源码、保留协议与修改声明）。
详见根目录 [LICENSE](../LICENSE) 与 [NOTICE](../NOTICE)。
