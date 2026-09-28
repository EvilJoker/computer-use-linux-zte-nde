# computer-use-linux nde 适配 — 开发调试流程

> 从 0 到可以正常工作的完整流程记录，agent + 用户视角。
> 记录真实踩过的坑（不是事后编的"理想流程"）。

---

## 0. 前置条件

| 工具 | 用途 | 验证方式 |
|---|---|---|
| Docker (有 sudo NOPASSWD) | musl 静态编译 | `docker info` 不报 permission denied |
| rustup 1.98 + cargo | 编译 musl target | `rustc --version` |
| `dsh-builder:cargo-ready` 镜像 | musl build environment | `docker images \| grep dsh-builder` |
| `mmx vision describe` | VLM 看 PNG 截图 | `mmx --help` |
| xdotool / xclip / import / xwd | nde desktop tools | `which xdotool xclip import xwd scrot` |
| sudo (NOPASSWD) | 改 chrome wrapper / .desktop | `sudo -n true && echo OK` |
| `/media/vdc/github/computer-use-linux-nde/` | git 仓库（patch + 文档） | `cd ... && git status` |
| `/home/10312862@zte.intra/dsh_test/computer-use-poc/` | build dir（临时 workdir） | `ls ...` |

---

## 1. 准备上游源码

```bash
mkdir -p /home/10312862@zte.intra/dsh_test/computer-use-poc
cd /home/10312862@zte.intra/dsh_test/computer-use-poc

# upstream 源码（v0.7.1）
git clone https://github.com/agent-sh/computer-use-linux.git cul-src
cd cul-src && git checkout v0.7.1

# 或更新到 HEAD（注意：HEAD 可能已经修了部分 bug，可能 conflict）
# git checkout master && git pull
```

**为什么需要源码本地 clone**：patch 需要在源码上 `git apply`，然后 docker 编译，不能直接
修改 `/usr/local/bin/computer-use-linux` 或 DSH 自己 spawn 的 binary。

---

## 2. 准备 docker build 环境

### 2.1 镜像

```bash
# 已存在的镜像直接用；不存在就 build Dockerfile（见 docker-build-musl.sh）
docker images | grep dsh-builder
```

`dsh-builder:cargo-ready` 镜像应包含：
- ubuntu24 base
- `musl-tools` (musl gcc cross compiler)
- `rustup` with `stable-x86_64-unknown-linux-musl` target

### 2.2 编译脚本

参考 `docker-build-musl.sh`。基本流程：

```bash
docker run --rm \
    -v /home/10312862@zte.intra/dsh_test/computer-use-poc/cul-src:/src:ro \
    -v /home/10312862@zte.intra/dsh_test/computer-use-poc/build-target-musl:/out:rw \
    dsh-builder:cargo-ready \
    bash -c "cd /src && cargo build --release \
             --target x86_64-unknown-linux-musl \
             --target-dir /out/target"
```

产物：`build-target-musl/target/x86_64-unknown-linux-musl/release/computer-use-linux`

⚠️ **Docker daemon 偶发 down**：`sudo systemctl restart docker`（NOPASSWD 可用）。

---

## 3. Patch 策略

### 3.1 Patch 编号 vs commit 编号

- **Patch 编号** = 根因分类（REPORT §2 的 6 类）
- **Commit 编号** = 时间顺序（git log）

一个 commit 可能包含多个 patch（如 `0a2f247` 包含 patch 4+5），也可能一个 patch
跨多个 commit。

### 3.2 Patch 应用

```bash
cd /home/10312862@zte.intra/dsh_test/computer-use-poc/cul-src
git apply /media/vdc/github/computer-use-linux-nde/kwin.rs.patch
git apply /media/vdc/github/computer-use-linux-nde/window-id-str.patch
# ... 等等
```

或一次性：

```bash
git apply /media/vdc/github/computer-use-linux-nde/ALL-CHANGES.patch
```

⚠️ **Patch 顺序敏感**：先改 `types.rs`（加 `window_id_str` 字段），再改
`backends/{gnome,hyprland,i3,x11,kwin}.rs`（构造时填字段），最后改 `target.rs`
（解析时识别字段）。顺序错会编译失败。

### 3.3 Patch 验证

```bash
# 编译前先看每个文件 diff 是否符合预期
git diff --stat
git diff src/windowing/types.rs

# 编译看是否能过
cargo check --target x86_64-unknown-linux-musl
```

### 3.4 Rust 1.98 strict type inference 注意

闭包返回值如果不能从上下文推断，需要**显式标类型**：

```rust
// ❌ 编译错：type inference failed
let x = window.x.as_ref().and_then(json_value_as_i32).unwrap_or(0);

// ✅ OK
let x: i32 = window.x.as_ref()
    .and_then(|v| json_value_as_i32(Some(v)))
    .unwrap_or(0);
```

---

## 4. 编译 + 部署

### 4.1 编译

```bash
docker run --rm \
    -v /home/10312862@zte.intra/dsh_test/computer-use-poc/cul-src:/src:ro \
    -v /home/10312862@zte.intra/dsh_test/computer-use-poc/build-target-musl:/out:rw \
    dsh-builder:cargo-ready \
    bash -c "cd /src && cargo build --release \
             --target x86_64-unknown-linux-musl \
             --target-dir /out/target"
```

**时间**：第一次 ~10 min，后续 incremental ~30s。

### 4.2 备份原 binary

```bash
BIN=/home/10312862@zte.intra/dsh_test/computer-use-poc/build-target-musl/bin/computer-use-linux
ls -la "$BIN"
sudo cp -p "$BIN" "$BIN.bak.20260924-prepatch"
# 注意是 sudo 因为这个 binary 是 DSH 跑的，owner 可能 root
```

⚠️ **先备份再覆盖**。回滚命令见 REPORT §7。

### 4.3 替换

```bash
# build 产物
NEWBIN=/home/10312862@zte.intra/dsh_test/computer-use-poc/build-target-musl/target/x86_64-unknown-linux-musl/release/computer-use-linux

# 复制
cp "$NEWBIN" "$BIN"

# 重启 MCP server（DSH Desktop 会自动 reconnect）
sudo kill $(pgrep -f "computer-use-linux.*mcp")
sleep 2
pgrep -af computer-use-linux   # 应该看到 DSH spawn 的新进程
```

⚠️ **DSH Desktop supervisor**：DSH 用 `node lib/bin.js` spawn electron，electron 子进程
持有 MCP 连接。kill MCP server 后 DSH 自动重连。如果改的是 DSH 自身的 wrapper
（chrome.desktop / dshdesktop script）可能会引发 restart loop（详见 §6.5）。

---

## 5. 验证流程（agent 视角）

### 5.1 基础健康检查

```python
# 用 mcp__computer-use__doctor
mcp__computer-use__doctor
```

**注意**：doctor 报全绿不代表能工作，它只看接口是否存在。

### 5.2 真实可用性验证

按 REPORT §5 的测试表，每一项都跑：

```python
# 1. list_windows — 应该返回窗口列表（不是空数组）
mcp__computer-use__list_windows
# 期望: 返回 5+ 个窗口，含 window_id_str 字段

# 2. focused_window — 应该返回当前焦点
mcp__computer-use__focused_window

# 3. screenshot — 应该返回 PNG bytes
mcp__computer-use__screenshot
# 期望: source: "x11-import"，PNG > 100KB

# 4. get_app_state — 不带 scope 应该立刻拒绝
mcp__computer-use__get_app_state include_screenshot=false
# 期望: error "get_app_state requires an app or window target on nde"

# 5. get_app_state — 带 scope 走 cache
mcp__computer-use__get_app_state app_name_or_bundle_identifier="google-chrome" include_screenshot=false
# 期望: 立即返回（< 1s），a11y 已生效有 web area 节点

# 6. click (no window_id) — xdotool XTEST
mcp__computer-use__click x=500 y=500
# 期望: 立即完成

# 7. activate_window
mcp__computer-use__activate_window window_id_str="synthetic:google-chrome:0,0"
# 期望: exact_window_focused=true

# 8. type_text — nde xclip+Ctrl+V 路径
mcp__computer-use__type_text text="hello nde"
# 期望: 在文本框里出现 "hello nde"（不被 Sogou 拦截）

# 9. scroll — xdotool button 4/5
mcp__computer-use__scroll direction=down clicks=3
# 期望: 滚动

# 10. drag — xdotool mousedown/up
mcp__computer-use__drag start_x=100 start_y=100 end_x=500 end_y=500
```

### 5.3 真实业务场景验证

打开 Chrome + 导航 + 输入 + 点击：

```python
# 1. activate chrome
mcp__computer-use__activate_window window_id_str="synthetic:google-chrome:0,0"

# 2. click 地址栏
mcp__computer-use__click window_id_str="synthetic:google-chrome:0,0" x=400 y=70

# 3. type URL (走 xclip+Ctrl+V)
mcp__computer-use__type_text text="https://www.zte.com.cn"

# 4. press Enter
mcp__computer-use__press_key key="Return"

# 5. 等页面加载
time.sleep(3)

# 6. screenshot 看结果
mcp__computer-use__screenshot
# 用 mmx vision describe 看 PNG
```

⚠️ **PNG 模型看不到** — DSH 模型没有 image input，需要 `mmx vision describe --image <path>`
走 VLM 才能"看到"截图内容。这是 DSH 当前 DSH profile 的硬限制。

### 5.4 VLM 看图

```bash
mmx vision describe --image /path/to/screenshot.png \
    --prompt "[详细描述看到的窗口/UI/文字/按钮/坐标（用 1920x540 体系）]"
```

⚠️ screenshot 是 3840x1080 双屏，会被缩成 1920x540。坐标都用缩放后的体系。

---

## 6. 踩过的坑（真实记录）

### 6.1 Rust 1.98 type inference

`let x = window.x.as_ref().and_then(json_value_as_i32).unwrap_or(0)` 编译失败。
`json_value_as_i32` 接受 `Option<&Value>`，闭包自动推断失败。改成显式 closure + 标 `i32`：

```rust
let x: i32 = window.x.as_ref()
    .and_then(|v| json_value_as_i32(Some(v)))
    .unwrap_or(0);
```

### 6.2 `Ok(Err(_)) | Err(_timeout)` pattern binding

```rust
match tokio::time::timeout(...).await {
    Ok(Err(_)) | Err(_timeout) => {},  // _timeout 未声明绑定
}
```

改成 `_ => {}` 或 `Ok(Err(_)) | Err(_) => {}`。

### 6.3 `SnapshotCache` 需要 Clone

`Mutex` 不 Clone，`HashMap` 不 Clone。手动写：
```rust
#[derive(Clone)]
pub struct SnapshotCache { /* Arc 持有 */ }

impl Clone for SnapshotCache {
    fn clone(&self) -> Self { Self { inner: Arc::clone(&self.inner) } }
}
```

更简洁：`pub struct SnapshotCache(Arc<Mutex<HashMap<…>>>)`，Arc 默认 Clone。

### 6.4 `SnapshotCache` 在 crate 找不到

`src/lib.rs` 没 re-export。补：
```rust
pub use atspi_tree::SnapshotCache;
```

### 6.5 input_guard move-after-use

`run_cancellation_safe_input` 包装 input_guard，但 nde xclip paste 是 fire-and-forget，
不要 race-free 包装。直接调用 xclip+Ctrl+V 即可。

### 6.6 supervisor restart loop

DSH Desktop 的 `lib/bin.js` spawn electron，electron child 持有 MCP 连接。
改 bin.js / dshdesktop script / Chrome wrapper 时，如果改了 spawn 命令的格式或加 arg，
supervisor 检测到变化会杀 electron 重新 spawn，但新 electron 启动失败又触发 restart，
形成循环。

**规避**：
- 修改前**先备份**原文件
- 改 bin.js 时**保持** spawn 出来的 cmdline **等价**（只在内部加不影响 cmdline 的）
- 改 Chrome wrapper 时**只改 wrapper**，不改 `.desktop`（除非必要）
- 改完后**手工重启 DSH Desktop** 而不是依赖 supervisor

### 6.7 xdotool 没 `--absolute` / `--wheel`

- `--absolute` 是 ydotool 的，xdotool 没这 flag
- `--wheel` 也没，scroll wheel 是 button 4/5/6/7
- `xdotool click --repeat N 4` 模拟向下滚 N 次
- 用 `--clearmodifiers` 而不是 `--absolute`

### 6.8 JS number precision lost (u64 > 2^53)

`window_id: 11899480864350308505` 跨 MCP 边界后 JS Number 变成另一个值（被截断为 2^53）。
upstream click 用 `window_id` 做精确匹配，截断后变成 ambiguous。

**修复**：加 `window_id_str: Option<String>`，所有 backend 构造时填 `Some(uuid)` 或
`Some(window_id.to_string())`，target 解析时优先 `window_id_str` 匹配。

### 6.9 KWin uuid 大小写 mismatch

Rust 端 `synthetic_kwin_uuid` 用 `caption.trim()` 但不 lowercase，JS 端 caption 也没
lowercase 比较。同一个窗口在两种语言环境下激活时可能因为 title case 不同而 miss。

**修复**：Rust `caption.trim().to_ascii_lowercase()` + JS `c.toLowerCase()`。

### 6.10 krdc 会被 supervisor 误杀

DSH Desktop supervisor 重启 Electron 时，会杀掉所有非 X11 client 注册的窗口。krdc 是
普通 X11 客户端（不是 DSH 子进程），但因为是手动 `&` 启动，会被杀。

**解决**：每次 supervisor 重启后**手动重新启动**被影响的 X11 进程。或者写到 XDG autostart。

### 6.11 `systemctl` 不显示 sudoers

`sudo -l` 看不到 NOPASSWD ALL，但实际能用。如果脚本要检测，可用 `sudo -n true && echo OK`。

### 6.12 Chrome 主进程不带 `--force-renderer-accessibility`

Chrome fork 模型：wrapper 启动 → fork 主进程 → fork renderer。wrapper 注入 arg 只影响
子进程 argv，不影响主进程。`ps -eo pid,cmd | grep "/opt/google/chrome/chrome "` 看的是
主进程（不带 flag），看子进程要 grep renderer：

`pgrep -af "/opt/google/chrome/chrome.*--force-renderer-accessibility"` 看到的是 renderer。

如果只有主进程没 flag 但 renderer 有 flag，**a11y 是生效的**。

---

## 7. 与 DSH supervisor 的协作约定

DSH Desktop 是用户日常使用的桌面环境，supervisor 行为：

| 触发 | 后果 |
|---|---|
| `pkill electron` | 自动重启（10s 后） |
| `pkill computer-use-linux mcp` | 自动 reconnect（5s） |
| 改 bin.js | 如果 spawn cmdline 不等价 → restart loop |
| 改 Chrome wrapper | 不影响 supervisor；只影响下次 Chrome 启动 |
| 改 Chrome .desktop | 不影响 supervisor；只影响 `gio launch` |
| 改 dshdesktop script | 不影响 supervisor；只影响手动 `dshdesktop` 命令 |
| supervisor 重启时 | 所有**手动**开的 X11 进程保留，**supervisor 的子进程**被杀重启 |

**正确的工作方式**：
1. 改完源码 → 编译 → 替换 binary → `kill MCP server`（supervisor 自动 reconnect）
2. 改 Chrome wrapper / .desktop → 提示用户**重启 Chrome**（wrapper/.desktop 只影响新启动的 Chrome）
3. 改 DSH Desktop 自身 → **不要**改 bin.js / dshdesktop script，先备份 + 写 patch，
   让用户决定是否应用

---

## 8. 调试命令速查

```bash
# DSH MCP server 状态
pgrep -af computer-use-linux

# KWin 窗口列表（绕过 MCP）
dbus-send --session --print-reply --dest=org.kde.KWin /Scripting org.kde.Scripting.loadScript string:foo' string:""
# （用 kwin dbus 拿窗口列表，更直接）

# Chrome 进程 + arg
pgrep -af "/opt/google/chrome/chrome"

# AT-SPI 状态
dbus-send --session --print-reply --dest=org.a11y.Bus /org/a11y/bus org.freedesktop.DBus.Introspectable.Introspect

# 截图（不走 MCP）
import -window root /tmp/test.png

# clipboard 内容
xclip -selection clipboard -o

# xdotool 单独测试
xdotool key ctrl+l
xdotool type "hello"
xdotool click 4
xdotool mousemove 500 500
xdotool mousedown 1
xdotool mouseup 1

# 看当前焦点窗口
xdotool getactivewindow getwindowname
xdotool getactivewindow

# VLM 看图
mmx vision describe --image /path/to.png
```

---

## 9. 一次完整 patch → deploy → verify 流程

```bash
# 0. 改源码
cd /home/10312862@zte.intra/dsh_test/computer-use-poc/cul-src
# ... 编辑 src/.../*.rs ...

# 1. 本地编译验证语法（不依赖 docker，快）
cargo check --target x86_64-unknown-linux-musl

# 2. 重新 git diff 看改动
cd /home/10312862@zte.intra/dsh_test/computer-use-poc/cul-src
git diff > /media/vdc/github/computer-use-linux-nde/<新 patch 名>.patch

# 3. docker 编译（incremental 快）
docker run --rm \
    -v /home/10312862@zte.intra/dsh_test/computer-use-poc/cul-src:/src:ro \
    -v /home/10312862@zte.intra/dsh_test/computer-use-poc/build-target-musl:/out:rw \
    dsh-builder:cargo-ready \
    bash -c "cd /src && cargo build --release --target x86_64-unknown-linux-musl --target-dir /out/target"

# 4. 备份当前 binary（首次部署前已经备份过）
BIN=/home/10312862@zte.intra/dsh_test/computer-use-poc/build-target-musl/bin/computer-use-linux
NEWBIN=/home/10312862@zte.intra/dsh_test/computer-use-poc/build-target-musl/target/x86_64-unknown-linux-musl/release/computer-use-linux
cp "$NEWBIN" "$BIN"

# 5. 重启 MCP server（DSH supervisor 自动 reconnect）
sudo kill $(pgrep -f "computer-use-linux.*mcp")
sleep 3

# 6. agent 端验证
# 调 mcp__computer-use__* 工具，看返回结果

# 7. git commit（仓库目录）
cd /media/vdc/github/computer-use-linux-nde
git add -A
git commit -m "<commit message>"

# 8. 如果发现 bug，回滚
sudo cp "$BIN.bak.20260924-prepatch" "$BIN"
sudo kill $(pgrep -f "computer-use-linux.*mcp")
sleep 3
# 重新调 mcp__computer-use__doctor 看是否回到原版
```

---

## 10. 协作约定（agent ↔ 用户）

| 用户说 | agent 做 |
|---|---|
| "测试下" | 跑 REPORT §5 的全表验证 |
| "修 bug" | 改源码 → patch → 编译 → 部署 → 验证 → commit |
| "再测试下" | 跑相关业务场景 |
| "提交" | `git add -A && git commit -m "..."`（仓库在 `/media/vdc/github/computer-use-linux-nde/`） |
| "回滚" | REPORT §7 |
| "重新打开 X" | `X >/dev/null 2>&1 &` |

---

## 11. 失败模式速查

| 现象 | 排查 |
|---|---|
| `mcp__computer-use__doctor` 全绿但调用失败 | doctor 不可信，按 REPORT §5 实测 |
| `list_windows` 返回 0 个窗口 | 补丁未生效，或 `synthetic_kwin_uuid` 没 lowercase |
| `click(window_id=…)` 报 ambiguous | 用 `window_id_str` 替代 `window_id`（见 §6.8） |
| `get_app_state` 卡死 | SnapshotCache 未生效或 timeout 太长 |
| `screenshot` 报 no backend | X11 tools 没装：`which import xwd scrot` |
| `type_text` 输入乱码 | 走的是 xdotool type 而非 xclip+Ctrl+V，检查 `is_nde_x11_session()` |
| `scroll` 无反应 | xdotool click button 4/5，**不要** `--wheel` |
| DSH Desktop 进入 restart loop | 检查改的是不是 bin.js / dshdesktop script |
| `permission denied` 操作 Chrome wrapper | `sudo` 加上；或检查 owner |
| krdc 突然消失 | DSH supervisor 重启 Electron 时杀的；重新 `krdc &` |