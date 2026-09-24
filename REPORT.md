# computer-use-linux nde 适配 — 完整根因 + 修复报告

## 1. 环境基线

```
OS:        NewStartOS V4.4.2-ZTE (CentOS 8 base + ZTE 内部包)
桌面:       nde / Nde — KDE Frameworks 5 + KWin 5.15.5 + nde 自研 shell
窗口管理:   真正的 KWin (kwin-5.15.5-15.4.el8)
屏幕:       3840x1080 双屏 (Virtual-1 + Virtual-2)
Compositor: XRender (X11 session)
输入栈:     Sogou/FCITX IME + xdotool
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

## 2. 根因（共 6 类）

| # | 现象 | 根因 |
|---|---|---|
| 1 | `list_windows` 返回空 | nde KWin 5.15.5 的 `clientList()` 返回的对象不暴露 `uuid`/`internalId`/`resourceClass`/`pid`，upstream Rust 反序列化 hard-required 这些字段 |
| 2 | `get_app_state` 整树扫描卡死几十秒 | nde 上 AT-SPI bus 有 never-responding peers，rust AccessibilityConnection 等不到回包 |
| 3 | `screenshot` 失败 | 没装 GNOME Shell，没装 gnome-screenshot，XDG portal 在 nde 上不可用 |
| 4 | `click` 带 `window_id` 失败 | 走 `activate_window` 路径，需要 KWin uuid（见 #1） |
| 5 | `type_text` 输入乱码 | Sogou IME 拦截 xdotool type，把 ASCII 当拼音预选上屏 |
| 6 | `scroll`/`drag` 失败 | upstream 最后 fallback 到 `run_ydotool_*`，nde 没装 ydotool，100% 失败 |

`doctor` 报全绿但实际失败 — 它只看接口是否存在，不看运行时响应。

## 3. 修复（共 6 个 patch）

### 3.1 KWin window list — `synthetic_kwin_uuid` fallback

```rust
let uuid = window.kwin_uuid().unwrap_or_else(|| {
    let caption = clean_string(window.caption.as_deref())
        .unwrap_or_else(|| "<unknown>".to_string());
    let x: i32 = window.x.as_ref().and_then(|v| json_value_as_i32(Some(v))).unwrap_or(0);
    let y: i32 = window.y.as_ref().and_then(|v| json_value_as_i32(Some(v))).unwrap_or(0);
    synthetic_kwin_uuid(&caption, x, y)
});
```

合成稳定 id：`synthetic:<caption>:<x>,<y>`。同一窗口同 session 内 id 不变。
（Rust 1.98 strict type inference 需要显式 closure 加 `: i32`。）

### 3.2 KWin activate — caption+x+y 匹配

`activate_window` 改用同样的合成 uuid 路径；activate JS 脚本里检测 `synthetic:` 前缀，命中时改为 caption+x+y 匹配：
- JS 端 caption=null 也 fallback 到 `<unknown>` 跟 Rust 对齐（标题为 null 的窗口如 DSH Desktop 自身能匹配）

### 3.3 `get_app_state` 强制 scope

```rust
if !accessibility_target_requested {
    return error "get_app_state requires an app or window target on nde. ..."
}
```

调用方传 `app_name_or_bundle_identifier` 或 `window_target` 才扫描 a11y 树。否则立即返回说明性错误。

### 3.4 Screenshot — X11 root fallback

在 GNOME Shell / portal / gnome-screenshot 都失败后：
1. `import -window root -display :0 file.png` （ImageMagick）
2. `xwd -root -display :0 -silent -out file.xwd` + `convert file.xwd file.png`
3. `scrot file.png`

nde 自带 ImageMagick，第一条路径稳定工作。

### 3.5 type_text — nde X11 xclip+Ctrl+V

```rust
fn is_nde_x11_session() -> bool {
    !is_wayland_session() && env_contains("XDG_CURRENT_DESKTOP", "nde")
}
```

当是 nde X11 时：
1. `xclip -selection clipboard -in` 把 text 写入 CLIPBOARD
2. `xdotool key --clearmodifiers ctrl+v` 触发 paste
3. 后台 task 恢复原 clipboard 内容

Ctrl+V 是 Qt/Chromium 接受的标准 paste shortcut，Sogou IME 不拦截。

### 3.6 scroll / drag — xdotool 优先于 ydotool

xdotool 没 `--absolute` flag（那是 ydotool 的），也没 `--wheel` flag（scroll wheel 是 button 4/5/6/7）：
- 新加 `xdotool_mousemove_args`: 用 `--clearmodifiers` 而非 `--absolute`
- 新加 `xdotool_wheel_click_args`: `click --repeat N 4|5|6|7`
- drag 路径：mousemove + mousedown 1 + mousemove + mouseup 1
- 原 `absolute_mousemove_args` 保留给 ydotool fallback

`should_prefer_xdotool_pointer()` 走 xdotool 路径，失败 fallback 到 ydotool。

## 4. 验证结果（DSH 当前跑的 patched binary）

| 功能 | 状态 | 说明 |
|---|---|---|
| `doctor` | ✅ | readiness 全绿，字段含义需要结合实测判断（doctor 仍然乐观） |
| `list_windows` | ✅ | 返回 18 个真实窗口（含 google-chrome / code / electron / iCenter / nde 套件） |
| `focused_window` | ✅ | 准确返回当前焦点窗口 |
| `get_app_state` (no scope) | ✅ | 立即返回说明性错误，不挂 |
| `get_app_state` (scope=google-chrome) | ✅ | tree_scoped=true，0 节点（Chrome 未启用 a11y） |
| `screenshot` | ✅ | 走 `x11-import` 路径，PNG 输出正常 |
| `click` (无 window_id) | ✅ | xdotool XTEST |
| `click` (带 window_id) | ✅ | activate_window → xdotool click |
| `type_text` | ✅ | 走 nde xclip+Ctrl+V 路径 |
| `press_key` | ✅ | xdotool XTEST |
| `scroll` | ✅ | "Action sent through xdotool (X11 XTEST wheel)" |
| `drag` | ✅ | "Action sent through xdotool (X11 XTEST)" |
| `activate_window` | ✅ | kwin backend, exact_window_focused=true |
| `list_apps` | ✅ | 进程列表 + 1 个 accessible_apps (electron) |
| `perform_action` / `set_value` | ⚠️ | 需要 AT-SPI 树有元素，Chrome 不注册需手动加 `--force-renderer-accessibility` |
| `setup_accessibility` | n/a | nde 上 AT-SPI 已启用，无需 setup |
| `setup_window_targeting` | n/a | GNOME-specific，nde 不适用 |

## 5. 仍未解决（限制）

1. **Chrome 不向 AT-SPI 注册 a11y 树** — 需要在启动 Chrome 时加 `--force-renderer-accessibility` flag。这需要用户重启 Chrome。
2. **Qt 应用不向 AT-SPI 注册** — nde 自带的 Qt 应用需要装 `qaccessibilityclient`。
3. **Mutter remote desktop portal 拿不到 credential** — nde 没实现 mutter 接口。截图靠 X11 root 工具链 fallback。
4. **`mutter_screencast` portal 失败** — 同上。

## 6. 回滚

```bash
sudo kill $(pgrep -f "computer-use-linux.*mcp")
sudo mv /home/10312862@zte.intra/dsh_test/computer-use-poc/build-target-musl/bin/computer-use-linux.bak.20260924-prepatch \
        /home/10312862@zte.intra/dsh_test/computer-use-poc/build-target-musl/bin/computer-use-linux
# dsh-mcp-client 自动 reconnect 回到原版
```

## 7. 仓库结构

```
/media/vdc/github/computer-use-linux-nde/
├── README.md                     # 用法
├── REPORT.md                     # 本文件
├── docker-build-musl.sh          # 编译脚本
├── ALL-CHANGES.patch             # 合并 patch (描述性)
├── kwin.rs.patch                 # patch 1: list_windows synthetic uuid
├── server.rs.patch               # patch 2: get_app_state scope guard
├── screenshot.rs.patch            # patch 3: X11 root screenshot fallback
├── kwin-activate.patch           # patch 4: activate caption+coords match
├── nde-x11-clipboard.patch        # patch 5: type_text xclip+Ctrl+V
└── scroll-drag-xdotool-v2.patch  # patch 6: scroll/drag xdotool
```
