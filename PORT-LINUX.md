# YunX-Desktop Linux 移植记录

- **初始移植**：2026-10-18（基于上游 v1.2.9）
- **本次升级**：2026-11-08（移植层重放到上游 v1.3.3 + 11-04 的两个热修）
- **上游**：`tidain/YunX-Desktop` v1.3.3（Windows 桌面移植版，AGPL-3.0）
- **发布仓库**：`Cherry1Jay/yunx-desktop-linux`（<https://github.com/Cherry1Jay/yunx-desktop-linux>，tag `v1.3.3-linux.1`）
- **目标机**：EndeavourOS / Arch 系，GNOME Wayland，x86_64
- **工作副本**：`/home/jay/WorkBuddy/2026-10-17-08-56-35/yunx-linux`
- **安装包**：`packaging/yunx-desktop-1.3.3-1-x86_64.pkg.tar.zst`（228 M）

## 一、为什么不是「从安卓移植」

上游 `CYQawa/YunX` 是 Android 应用（Kotlin + Jetpack Compose + Room + WebView）。桌面版已经把这些替换过一轮
（Room→`sqlite-jdbc`、SAF→AWT 文件对话框、WebView→JCEF、`SharedPreferences`→`java.util.prefs`），
224 个 Kotlin 文件里 22 个网盘解析器全部是纯 JVM 代码。真正与 Windows 绑定的只有 **约 10 个 util 文件 + 1 处下载内核平台判断**，
所以移植基座选桌面版，工作量为改写这些点，而不是把 Android 那一层再拆一遍。

另有一个 `mu-zi-lee/YunX-Docker` fork：它不是桌面移植，而是新增 `server/` 模块做成**网页版**（浏览器访问 :8080）。
其 `GopeedPlatform.kt` 已解决 Linux 内核包命名问题，本次直接沿用（见下）。

## 二、改动清单（共 12 个文件，+1 新增）

### 1. 构建层 `desktop/build.gradle.kts`

| 原状 | 移植后 |
|---|---|
| `jcef-natives-windows-amd64` 写死 | `jcef-natives-${platform}`，按 `os.name`/`os.arch` 选 `linux-amd64` |
| `compileDarkMode` 用 `cmd`/`cl` 编译 `darkmode.dll` | 非 Windows 注册为空任务（Linux 不需要 uxtheme 桥接） |
| `java.library.path` 用 `;` 拼接 | `File.pathSeparator`（Linux 为 `:`） |
| `targetFormats(TargetFormat.Exe)` | 按平台选 Exe / Deb / Dmg，并补 `linux { packageName … }` |

### 2. 平台集成层

| 能力 | Windows 原实现 | Linux 实现 |
|---|---|---|
| 托盘右键菜单 | JNA `TrackPopupMenuEx` | AWT `PopupMenu`（`TrayManager` 内按平台分派） |
| 托盘不可用 | — | `SystemTray.isSupported()=false` 时「最小化到托盘」退化为最小化到任务栏，避免窗口消失无法恢复 |
| 桌面通知 | PowerShell + WinRT toast | `notify-send`（`x-canonical-private-synchronous` 实现原地刷新 + `int:value` 进度） |
| 下载防休眠 | `SetThreadExecutionState` | `systemd-inhibit --what=idle:sleep --mode=block sleep infinity` |
| 定位文件 | `explorer.exe /select,` | `org.freedesktop.FileManager1.ShowItems`，失败回退 `xdg-open` 父目录 |
| 打开目录/文件 | `explorer.exe` / `Desktop.open` | `xdg-open` |
| 重启应用 | `cmd /c ping & start` | `sh -c 'sleep 2; exec <jpackage launcher>'` |
| 系统暗色 | 注册表 `AppsUseLightTheme` | `gsettings color-scheme=prefer-dark` → `gtk-theme` 含 dark → `GTK_THEME` |
| 系统代理 | 注册表 `Internet Settings` | 环境变量 `http(s)_proxy`/`all_proxy` → `gsettings org.gnome.system.proxy` |
| 数据库密钥绑定 | `MachineGuid`（注册表） | `/etc/machine-id` |
| 「较为严格」加密档 | DPAPI | 标记不可用（无等价实现，避免切档后解不开凭证） |

### 3. Gopeed 下载内核

新增 `GopeedPlatform.kt`（源自 YunX-Docker）：

- 内核包名 `gopeed-web-<ver>-<os>-<arch>.zip`，Linux 取 `gopeed-web-v1.9.3-linux-amd64.zip`
- 包内可执行文件 Windows 叫 `gopeed.exe`，Linux 叫 `gopeed`
- **解包后必须 `setExecutable(true)`** —— zip 不带执行位，否则 `ProcessBuilder` 直接 `EACCES`

### 4. 未移植（缺功能，不影响主流程）

- **一键导入本机浏览器 Cookie**：原实现读 `LOCALAPPDATA` + DPAPI 解密 Chromium `encrypted_value`。
  Linux 侧要做需接 libsecret + AES-256-GCM（`v10` 前缀，key 来自 gnome-keyring），本次未做 —— 目前返回「未检测到浏览器」。
- **内嵌浏览器登录**：JCEF 已可用（日志 `JCEF initialized`），Linux 原生库 325 MB 首次运行解包到
  `~/.yunx-desktop/cache/jcef-bundle`。

## 三、构建与安装

```bash
cd /home/jay/WorkBuddy/2026-10-17-08-56-35/yunx-linux

# 环境（本机已装 jdk17-openjdk；Gradle 由 wrapper 自动下载 8.13）
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
export PATH="$JAVA_HOME/bin:$PATH"
export GRADLE_USER_HOME=/home/jay/.cache/wb-yunx/gradle-home

# 1) 编译 + 生成自带运行时的 app-image
java -classpath gradle/wrapper/gradle-wrapper.jar \
  org.gradle.wrapper.GradleWrapperMain :desktop:createDistributable --console=plain

# 2) 打 pacman 包
cd packaging && makepkg -f

# 3) 安装
sudo pacman -U yunx-desktop-1.3.3-1-x86_64.pkg.tar.zst

# 4) 启动
yunx-desktop          # 或应用列表里搜「云析」
```

> 开发调试：`:desktop:run`（需要 `DISPLAY=:0` 与 `XAUTHORITY`，GNOME Wayland 下走 XWayland）。

## 四、安装内容

| 路径 | 内容 |
|---|---|
| `/opt/yunx-desktop/` | app-image（含 jlink 精简 JDK，不依赖系统 JDK） |
| `/usr/bin/yunx-desktop` | 启动脚本 |
| `/usr/share/applications/yunx-desktop.desktop` | 桌面项（`StartupWMClass=com-yunx-app-MainKt`） |
| `/usr/share/icons/hicolor/256x256/apps/yunx-desktop.png` | 图标 |

用户数据：`~/.yunx-desktop/`（`yunx.db`、`credential.key`、日志、JCEF 缓存）。

## 五、卸载 / 回滚

```bash
sudo pacman -Rns yunx-desktop
rm -rf ~/.yunx-desktop          # 连账号与任务一起清
```

## 六、移植中踩到的坑

1. **`pkill -f "<路径含 YunX-Desktop>"` 会杀掉自己** —— 命令行本身就含该字符串。用 `ps` 拿 PID 再 `kill`。
2. **xdotool 点击在缩放下要传绝对坐标**：`--window` 相对坐标在 HiDPI XWayland 上会偏移（实测 (2073,1395) 落到别处），
   改成 `mousemove 2156 1614`（窗口 96,228 + 逻辑 1030,693 × 2）才命中。
3. **Gradle 的 `TaskProvider<out Task>`**：Windows/非 Windows 两个分支注册不同类型的任务时，
   `by tasks.registering(...)` 推断不出共同类型，要显式 `TaskProvider<out Task>`。
4. **jcef 原生库版本号必须与 jcefmaven 严格一致**，否则运行期 JCEF 初始化报 API 不匹配。
5. **app-image 里 lib 目录 331 M**：绝大部分是 JCEF 原生库，打包后 zst 压缩到 258 M，属正常。

## 七、2026-11-08 升级到上游 v1.3.3

### 升级方式：移植层 rebase，而不是重新移植

本仓库的提交结构是「上游全部历史 + 叠加在其上的 3 个 Linux 移植提交」，所以升级就是把移植层重放到新基线：

```bash
git fetch upstream
git rebase --onto upstream/main $(cat PORT-BASE)
```

`.github/workflows/upstream-sync.yml` 每天自动做这件事：上游有更新 → rebase → 编译 → 发 Release；
冲突则开 Issue 等人工处理（不静默吞掉上游改动）。上游基线 commit 记在仓库根目录 `PORT-BASE`。

### 本次 rebase 的 4 处冲突与处理

| 文件 | 冲突原因 | 处理 |
| --- | --- | --- |
| `desktop/build.gradle.kts` | 上游给 jcefmaven 加了 `exclude(jogl/gluegen)` 并把原生库写死 `windows-amd64` | 保留上游的体积优化，同时保留移植层的 `jcefNativesPlatform()` 按平台选原生库 |
| `desktop/build.gradle.kts` (nativeDistributions) | 上游 `targetFormats(TargetFormat.Exe)`；移植层按宿主平台选 | 用移植层的平台判断，`modules()` 保留上游新增的 `jdk.httpserver`、`jdk.unsupported.desktop`（漏了视频预览会全挂） |
| `Main.kt` | 上游托盘右键改回 Win32 原生菜单；移植层用通用 `menuItems` | 用移植层的通用菜单（Linux 无 Win32），最小化逻辑保留上游新增的 `saveWindowPosition` |
| `DesktopActions.kt` | 上游新增「下载完成后关机」`shutdownComputer`；移植层新增 `launcherExePosix` | 两者都保留，`shutdownComputer` 补 Linux 实现（`systemctl poweroff --no-block`，回退 `shutdown -h now`） |
| `WindowsToastNotifier.kt` | 上游新增 `enabled` 开关 | 与移植层的 Linux 分支合并（见下节） |

`README.md` 冲突直接取移植版（Linux 用户看的话术与上游不同），随后手工补上版本号与新特性说明。

### 升级后暴露的两个真问题

**1. `UnsatisfiedLinkError: NativeDB._open_utf8`** —— 1.3.x 上游把 `sqlite-jdbc` 换成了自己裁剪过的
本地 jar `libs/sqlite-jdbc-3.47.1.0-win.jar`（只留 `org/sqlite/native/Windows/*`，省 11 MB）。
Linux 上加载不到 `libsqlitejdbc.so`，打开数据库即崩。修法：按平台分支依赖，Linux 走 Maven 完整包：

```kotlin
if (hostIsLinux) implementation("org.xerial:sqlite-jdbc:3.47.1.0")
else             implementation(files("libs/sqlite-jdbc-3.47.1.0-win.jar"))
```

> 这类「上游为 Windows 裁剪资源」的坑在后续每次升级都可能出现，rebase 后**必须先跑一遍启动冒烟**。

**2. 下载通知刷屏（用户反馈的核心问题）**

旧实现想用 `x-canonical-private-synchronous:<tag>` 让通知「原地刷新」，但这是 Unity / notify-osd 的私有
扩展，**GNOME Shell 与 KDE 都不认**，直接当未知 hint 丢弃 ⇒ 每 3 秒一条新通知，下载大文件时桌面被刷爆。

实测证据（GNOME 51 / notify-send 0.8.9）：

```
旧实现，连发 3 次 → id=1551, 1552, 1553   ← 每次都新建
新实现，-r 1550 替换 → id=1550            ← 原地刷新
```

修法：
- `Platform.notifyWithId()` 加 `-p/--print-id` 拿 id、`-r/--replace-id` 替换；
- 首次替换若返回的 id ≠ 传入的 id（说明服务端忽略了替换参数），立刻判定不支持并**永久降级**，
  不会退回刷屏行为；
- 新增设置 `download_notify_mode`：`done`（默认，只在全部完成时弹一条）/ `live`（实时进度）/ `off`（静默）；
- 会话未完成（暂停/失败）时用 `CloseNotification` 静默收掉进度条，不额外弹提示。

对应代码：`Platform.kt`（`notifyWithId` / `closeNotification`）、`WindowsToastNotifier.kt`（`linuxSendProgress`）、
`SettingsRepository.kt`（`downloadNotifyMode`）、`SettingsScreen.kt`（三档选择弹窗）。

### 顺带获得的上游新能力（1.2.9 → 1.3.3）

- **P2P 下载**：磁力 / BT 种子 / ed2k，含 Tracker 管理与「启动位置」选择
- **浏览器插件桥接**：嗅探 + 劫持下载 + 弹窗询问目录/线程数 + 归还浏览器下载
- **HLS 转 MP4**、资源分类与图片/视频预览、B 站专属页与清晰度选择
- **下载完成后关机**（Linux 已补实现）、存储迁移、退出稳定性修复
- 顶部轻提示替代底部 Snackbar；断点续传时弹性分片不再重叠

## 八、2026-11-08 补充：自动构建落地到本机 systemd

GitHub Actions 走不通（账号 Billing 被锁，任何 workflow 都是 3 秒失败、`steps: 0`，
注解原文 `The job was not started because your account is locked due to a billing issue.`），
改为本机 systemd user timer 每天 04:00 跑同一套 `scripts/release-local.sh --sync`。

单元在 `~/.config/systemd/user/yunx-upstream-sync.{service,timer}`，日志
`~/.local/state/yunx-upstream-sync.log`，token 单独放 `~/.config/yunx-release/token`（600）。
详细配置见 [docs/BUILD-LINUX.md](docs/BUILD-LINUX.md)。

### 这轮踩到的两个坑

**1. 定时任务被自己的「工作区脏」检查拦下**

第一次 `systemctl --user start` 直接失败：

```
ERROR: 工作区有未提交改动，放弃同步（定时任务不应改动用户手上的编辑）
```

检查本身是对的（定时任务不该替人做决定），但当时工作区脏是因为刚在改脚本，属于预期。提交后重跑正常。

**2. 创建 Release 报 422，报错信息完全误导**

```
{"message":"Validation Failed","errors":[
  {"field":"tag_name","message":"tag_name is not a valid tag"},
  {"field":"target_commitish","code":"invalid"}]}
```

看着像 tag 名字非法或 token 权限不足，实际原因是**这个 commit 还没 push**——
Release 的 `target_commitish` 指向远程不存在的 commit，GitHub 连带把 tag 也判成非法。

修法：发布前先 `git push HEAD:main`；同时把服务端的原始响应打出来（原来只有一句
「检查 GH_TOKEN 权限是否含 repo」，白跑一轮构建）。验证方式：

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: token $TOKEN" \
  https://api.github.com/repos/Cherry1Jay/yunx-desktop-linux/commits/$(git rev-parse HEAD)
# 422 = 远程没有这个 commit，就是它
```

### 定时跑起来后的保护清单

| 保护 | 场景 |
| --- | --- |
| `--sync` 前先 `rebase --abort` | 上一轮被中断留下 detached HEAD，下一轮会直接崩 |
| 工作区脏 / 不在 main → 退出 | 不替人做决定，不碰未提交的编辑 |
| rebase 冲突 → 自动回滚 | 不留半成品，日志里给出手工命令 |
| 先 push 再发 Release | 避开上面那个 422 |
| `dist/` 只留两组产物 | 每次 460MB，根分区只有 18G 可用 |

### 实测结果

一次完整流程：编译 10s（Gradle 缓存命中）→ makepkg 打包约 1 分钟 →
`git push` → 创建 Release `v1.3.3-linux.1` → 上传 `pkg.tar.zst`（228MB，HTTP 201）。
