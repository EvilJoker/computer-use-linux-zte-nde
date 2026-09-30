use crate::terminal::TerminalWindowContext;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
pub struct WindowInfo {
    pub window_id: u64,
    /// String representation of window_id (avoids JS number precision loss
    /// for nde KWin hash values > 2^53). For nde the value is the same
    /// string used in `kwin_uuid_for_window_id`'s synthetic uuid path
    /// (e.g. "synthetic:Chrome - title bar:1920,0"). Use this when round-tripping
    /// back via `WindowTarget.window_id_str`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_id_str: Option<String>,
    pub title: Option<String>,
    pub app_id: Option<String>,
    pub wm_class: Option<String>,
    pub pid: Option<u32>,
    pub bounds: Option<WindowBounds>,
    pub workspace: Option<i32>,
    pub focused: bool,
    pub hidden: bool,
    pub client_type: Option<String>,
    pub backend: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal: Option<TerminalWindowContext>,
}

#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
pub struct WindowBounds {
    pub x: Option<i32>,
    pub y: Option<i32>,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
pub struct WindowTarget {
    /// Numeric window_id (legacy; may have lost JS precision for nde KWin
    /// hash values > 2^53). Prefer `window_id_str` for round-trip safety.
    #[serde(default)]
    pub window_id: Option<u64>,
    /// String-form window id (preferred on nde; bypasses JS number precision).
    /// The KWin backend populates this with the same synthetic uuid
    /// string that `kwin_uuid_for_window_id` matches against.
    #[serde(default)]
    pub window_id_str: Option<String>,
    #[serde(default)]
    pub pid: Option<u32>,
    #[serde(default)]
    pub tty: Option<String>,
    #[serde(default)]
    pub terminal_pid: Option<u32>,
    #[serde(default)]
    pub terminal_command: Option<String>,
    #[serde(default)]
    pub terminal_cwd: Option<String>,
    #[serde(default)]
    pub app_id: Option<String>,
    #[serde(default)]
    pub wm_class: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
pub struct WindowFocusResult {
    pub requested_window: WindowInfo,
    pub focused_window: Option<WindowInfo>,
    pub exact_window_focused: bool,
    pub app_focused: bool,
    pub backend: String,
    pub note: String,
}

impl WindowTarget {
    pub fn has_target(&self) -> bool {
        self.window_id.is_some()
            || self.window_id_str.as_deref().is_some_and(|s| !s.trim().is_empty())
            || self.pid.is_some()
            || self.has_terminal_target()
            || self
                .app_id
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
            || self
                .wm_class
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
            || self
                .title
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
    }

    pub fn requires_exact_focus(&self) -> bool {
        self.window_id.is_some()
            || self.pid.is_some()
            || self.has_terminal_target()
            || self
                .title
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
    }

    pub(crate) fn has_terminal_target(&self) -> bool {
        self.terminal_pid.is_some()
            || self
                .tty
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
            || self
                .terminal_command
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
            || self
                .terminal_cwd
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
    }
}
