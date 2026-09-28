# 如何验证 Chrome a11y 已生效（待你重启 Chrome 后跑）

## 前置条件
已确认 wrapper 已改：
- /opt/google/chrome/google-chrome 注入 `--force-renderer-accessibility`
- 备份: google-chrome.bak.20260924-1747
- 验证: 用 `google-chrome-stable --headless=new` 启动后 `/opt/google/chrome/chrome --force-renderer-accessibility ...` 出现在 cmdline

## 重启 Chrome（一次性动作）
```bash
# 退出 Chrome 所有窗口（保存好 tab 工作）
# 然后 shell 里:
pkill -f "/opt/google/chrome/chrome "
# 等 2 秒让 DSH reconnect
```

DSH Desktop 的 chrome-devtools MCP 会自动 reconnect 到新 chrome。

## 验证步骤
用任何 DSH agent tool call:
```
mcp__computer-use__get_app_state app_name_or_bundle_identifier="google-chrome" include_screenshot=false
```

### 预期结果（a11y 已生效）
- `accessibility_tree_raw_count` > 0（之前是 0）
- `accessibility_tree` 数组里包含 `role: "web area"` / `role: "button"` 等节点
- Chrome 各 tab 的 DOM 元素都注册到 AT-SPI

### 失败的预期（a11y 没生效）
- `accessibility_tree_raw_count: 0`
- `accessibility_tree: []`
- 说明 chrome wrapper 没生效，需要检查：
  1. `cat /opt/google/chrome/google-chrome | grep force-renderer` 应该有
  2. 重启后 `ps -eo pid,cmd | grep "/opt/google/chrome/chrome "` 看主进程 cmdline 有 `--force-renderer-accessibility`

## 回滚
```bash
sudo cp /opt/google/chrome/google-chrome.bak.20260924-1747 \
        /opt/google/chrome/google-chrome
sudo cp /usr/share/applications/google-chrome.desktop.bak.20260924-1747 \
        /usr/share/applications/google-chrome.desktop
```

## 备注
- `setup_accessibility` 在 nde 上是 no-op（AT-SPI 已启用）
- `setup_window_targeting` 仅适用 GNOME（nde 是 KWin），不要调
