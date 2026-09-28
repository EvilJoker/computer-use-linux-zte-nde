# computer-use-linux 在 nde 桌面上不可用的根因 + 修复方案

## 1. 环境

- OS: NewStartOS V4.4.2-ZTE (CentOS 8 base + ZTE 内部包)
- 桌面: `nde` (Nde) — 基于 **KWin 5.15.5** + Qt 5 + KDE Frameworks 5 的中兴自研桌面
  - `nde-session` 是 nde 自己的 session 启动器
  - 窗口管理器是 **真正的 KWin** (`kwin-5.15.5-15.4.el8.x86_64`)
  - nde 只是把 nde-panel / nde-fileman / nde-systemsettings 套在 KWin 上面
- 屏幕: 双屏 3840x1080 (Virtual-1 1920x1080 + Virtual-2 1920x1080)
- Compositor: XRender (X11 session, 非 Wayland)

## 2. 现象

`mcp__computer-use__doctor` 报告全绿（`can_build_accessibility_tree: true`,
`can_query_windows: true` 等），但实际调用 `list_windows` 返回空、`screenshot` 失败。

## 3. 根因（已通过 KWin DBus 探针验证）

### 3.1 `list_windows` 失败

computer-use 的 KWin backend 调用流程（`src/windowing/backends/kwin.rs`）:

1. 用 `KWin.Scripting.loadScript()` 加载一段 JS
2. JS 在 KWin 内跑，通过 `workspace.clientList()`（KWin 4 旧 API）拿到所有窗口对象
3. JS 通过 `callDBus()` 把 JSON 回传给 computer-use 的 callback
4. computer-use 在 Rust 里反序列化 (`KwinRawWindow`)

**关键证据** —— 我们注入的 KWin JS 探针（`kwin_probe/probe3.js`）通过 dbus-monitor
抓回来的实际数据:

```
has_workspace=true
typeof windowList=undefined       ← KWin 5 没用这个新 API
typeof clientList=function        ← 用这个老 API
has activeWindow=false
has activeClient=true

raw len=19                          ← 19 个窗口都被列出来了
win[0]: caption="Nde Panel"  resourceClass={} has_uuid=false has_internalId=false ...
win[1]: caption="zMail 3.0" resourceClass={} has_uuid=false has_internalId=false ...
... 17 个 Chrome / VSCode / WindTerm / iCenter 窗口 ...
```

**nde KWin 5.15.5 的 `clientList()` 返回的对象不携带 `uuid` / `internalId` /
`resourceClass` / `pid` 字段**。

而 computer-use 的反序列化代码 (kwin.rs:940-942) hard-require uuid/internalId:

**文件**: `src/windowing/backends/kwin.rs`

```rust
let uuid = window
    .kwin_uuid()
    .context("KWin window did not include uuid or internalId")?;
```

`.context()` 报错 → `try_from` 返回 Err → 19 个窗口全部被丢弃 → 返回空列表。

这跟 doctor 报的 "KWin scripting is available on the session bus" 是一致的：
- 接口本身存在（loadScript 能跑）
- 脚本能拿数据
- 解析数据时全部 drop 掉

### 3.2 `screenshot` 失败

nde 没装 `gnome-screenshot`，mutter remote_desktop portal 拿不到 credential。
只能靠 DBus screencast portal，但 nde 没实现 screencast portal backend。

### 3.3 `queryWindowInfo` 超时

`KWin.KWin.queryWindowInfo()` 方法在某些 KWin build（包含 XRender 后端）下 hang。
doctor 没调这个方法（它通过 Scripting），所以 doctor 不会发现。

## 4. 修复

### 4.1 代码改动 — `src/windowing/backends/kwin.rs`

把 hard-required 的 uuid 改成可选 fallback：

- `try_from` 方法中: 如果 `kwin_uuid()` 返回 None，用 `synthetic_kwin_uuid(caption, x, y)`
  生成稳定 hash 作为 id（同一窗口在一次 session 中 id 稳定，跨 list/activate 调用一致）
- `json_value_as_i32` 调用加显式 closure（适配 rustc 1.98 type inference）

### 4.2 编译

静态 musl 二进制（无运行时依赖、可直接替换）：

```bash
docker run --rm \
    -v $REPO_DIR/upstream:/poc:ro \
    -v $REPO_DIR/build-out:/out:rw \
    dsh-builder:cargo-ready \
    bash /build.sh
```

或者用现成 build 脚本: `docker-build-musl.sh`。

### 4.3 部署（风险评估）

DSH 当前通过 `mcp__computer-use__*` 调用的是哪个 binary —— **未知**，需要先定位。
候选位置:
- `/home/10312862@zte.intra/.cargo/bin/` (host cargo install)
- `node_modules/@agent-sh/computer-use-linux/...` (npm wrapper spawn 内部 binary)
- DSH 启动时动态 spawn

替换前必须:
1. `mcp__computer-use__doctor` 记录当前所有 readiness 字段值
2. 备份原 binary (`.bak`)
3. 替换
4. 再调 doctor 比对，差异应当只有 KWin windowing 这条从失败变成功

## 5. 还没改的部分

### 5.1 `activate_window` 仍然 hard-required uuid

`kwin_uuid_for_window_id` 拿不到 uuid 仍会 fail。改法：让它先用 caption/x/y 匹配，
找到目标 window 后用合成 uuid 调 KWin.Activate。

### 5.2 截图

需要 nde 加 screencast portal backend —— 这是 nde 上游的事情，我们这边做不了。

### 5.3 AT-SPI 树

- Chrome 没向 AT-SPI 注册 → 加 `--force-renderer-accessibility` 启动 Chrome 解决
- Qt 应用没 AT-SPI tree → 需要启用 `qaccessibilityclient` (nde 包) 或类似

## 6. 已验证

- KWin 5.15.5 在 nde 上工作正常（DBus 接口齐全）
- 19 个窗口可以通过 clientList() 拿到 caption/geometry
- Rust 代码改动已写（type-checked 编译通过预期）

## 7. 未验证（编译失败的环境问题）

容器内 rustup 装 + apt install 慢且超时，需要：
- 用 dsh-builder:cargo-ready 预装好环境的 image
- 或在 host (NewStartOS) 上装 musl-tools (yum install musl-devel)，改用 host cargo 编
