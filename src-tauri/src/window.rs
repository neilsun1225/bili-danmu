//! Overlay / Sender 窗口辅助：取窗口句柄、吸附布局、位置落盘
//!
//! 窗口的创建与事件绑定在 `lib.rs` 的 setup 里，这里只放被多处复用的操作。

use crate::config;
use crate::state::OverlayState;
use tauri::{AppHandle, Emitter, Manager};

/// 获取 Overlay 窗口实例（不存在返回 None）
pub(crate) fn overlay_window(app: &AppHandle) -> Option<tauri::WebviewWindow> {
    app.get_webview_window("overlay")
}

/// 获取 Sender 窗口实例（不存在返回 None）
pub(crate) fn sender_window(app: &AppHandle) -> Option<tauri::WebviewWindow> {
    app.get_webview_window("sender")
}

/// 读取窗口当前矩形 → 更新内存态；尺寸变化时广播给主界面「弹幕窗」标签的宽高滑块
///
/// 统一换算成**逻辑像素**再存：窗口 API（outer_position / inner_size）返回物理像素，
/// 高 DPI 下差一个 scale_factor 的倍数；而恢复窗口用的 position/inner_size(构建器)
/// 与设置页的 px 都是逻辑像素，不换算就会出现「存的比恢复的大」。
pub(crate) fn capture_overlay_bounds(app: &AppHandle) {
    let Some(win) = overlay_window(app) else { return };
    if win.is_minimized().unwrap_or(false) {
        return;
    }
    let Ok(pos) = win.outer_position() else { return };
    let Ok(size) = win.inner_size() else { return };
    let scale = win.scale_factor().unwrap_or(1.0);
    let pos = pos.to_logical::<f64>(scale);
    let size = size.to_logical::<f64>(scale);
    let b = config::WindowBounds {
        x: pos.x,
        y: pos.y,
        w: size.width,
        h: size.height,
    };
    if !b.is_valid() {
        return;
    }
    let st = app.state::<OverlayState>();
    let size_changed = {
        let mut bounds = st.bounds.lock().unwrap();
        let changed = bounds.map(|p| (p.w, p.h) != (b.w, b.h)).unwrap_or(true);
        *bounds = Some(b);
        changed
    };
    // 只在尺寸变化时广播：拖动窗口（只改位置）会每帧触发窗口事件，全发会把 IPC 刷满。
    // 取整后发出，与 overlay_get_size 同一口径（滑块的取值是整数）。
    if size_changed {
        let _ = app.emit(
            "overlay-size",
            serde_json::json!({ "width": size.width.round(), "height": size.height.round() }),
        );
    }
}

/// 内存态位置与已保存不同则写盘（去重）
pub(crate) fn flush_overlay_bounds(app: &AppHandle) {
    let st = app.state::<OverlayState>();
    let _ = persist_overlay_bounds(&st, |bounds| config::save_overlay_bounds(app, bounds));
}

fn persist_overlay_bounds(
    st: &OverlayState,
    save: impl FnOnce(&config::WindowBounds) -> Result<(), String>,
) -> Result<(), String> {
    // 持锁到写盘结束：退出前的最终保存不能被较早的周期快照反向覆盖。
    let current = st.bounds.lock().unwrap();
    let Some(bounds) = *current else { return Ok(()) };
    let mut saved = st.saved_bounds.lock().unwrap();
    if *saved != Some(bounds) {
        save(&bounds)?;
        *saved = Some(bounds);
    }
    Ok(())
}

/// 发送框始终吸附：左端与弹幕区面板背景左边缘齐平，宽度取面板宽度的 50%（上限 260px），高度随字号
pub(crate) fn sync_sender_docked(app: &AppHandle) {
    let (Some(ov), Some(sender)) = (overlay_window(app), sender_window(app)) else {
        return;
    };
    let Ok(pos) = ov.outer_position() else { return };
    let Ok(size) = ov.outer_size() else { return };
    let scale = ov.scale_factor().unwrap_or(1.0);
    let (indent, w, h) = sender_layout_metrics(app, scale, size.width);
    let x = pos.x + indent as i32;
    let y = pos.y + size.height as i32;
    let _ = sender.set_position(tauri::Position::Physical(tauri::PhysicalPosition::new(x, y)));
    let _ = sender.set_size(tauri::Size::Physical(tauri::PhysicalSize::new(w, h)));
}

/// 弹幕窗容器 padding（px）：对应 OverlayApp.vue 的 .overlay-root padding
const OVERLAY_PADDING: f64 = 6.0;
/// 正文列起点（em）：role-slot 4.8em + 0.7em 间距，对应 OverlayApp.vue 的 --role-indent
const ROLE_INDENT_EM: f64 = 5.5;
/// 面板背景相对正文列再左让的宽度（em）：对应 OverlayApp.vue 的 --panel-inset
const PANEL_INSET_EM: f64 = 0.35;
/// 发送框宽度占面板宽度的比例
const SENDER_WIDTH_RATIO: f64 = 0.5;
/// 发送框宽度上限（逻辑 px）：面板很宽时不再跟着变宽，避免过长挡住游戏操作区。
/// 按逻辑 px 定义、使用时乘 scale 换算成物理 px，高 DPI 下显示宽度与 100% 缩放一致
const SENDER_MAX_WIDTH: f64 = 260.0;

/// 发送框相对弹幕窗的左缩进 / 宽度 / 高度（物理 px），随弹幕字号缩放。
/// 缩进 = 容器 padding + 面板左边缘（--panel-inset = --role-indent − 0.35em），
/// 落在面板背景左边缘那条线上；宽度 = 面板宽度（弹幕窗宽 − 左缩进 − 右侧 padding）的 50%，
/// 且不超过 SENDER_MAX_WIDTH（逻辑 px）。
///
/// 高度只容纳输入行：0.9em 字号 ×（1.2 行高 + 上下各 0.3em padding）+ 2px 边框。
/// 错误改为输入框边框和悬停提示，不再预留下方透明区域。
/// 宽度是硬约束（不能被太多游戏画面），输入区靠 SenderApp.vue 里的字号 0.9em + 紧内边距
/// 才放得下约 8 个中文字；想再宽只能调 SENDER_WIDTH_RATIO / SENDER_MAX_WIDTH。
fn sender_layout_metrics(app: &AppHandle, scale: f64, overlay_width: u32) -> (u32, u32, u32) {
    let font_size = app.state::<OverlayState>().style.lock().unwrap().font_size;
    // 面板宽度用未取整的浮点算：缩进先取整会把那半个像素的误差带进宽度
    let left = (OVERLAY_PADDING + (ROLE_INDENT_EM - PANEL_INSET_EM) * font_size) * scale;
    let panel_width = overlay_width as f64 - left - OVERLAY_PADDING * scale;
    let indent = left.round() as u32;
    let w = ((panel_width * SENDER_WIDTH_RATIO)
        .min(SENDER_MAX_WIDTH * scale)
        .round() as u32)
        .max(1);
    let h = ((font_size * 0.9 * 1.8 + 2.0) * scale).ceil() as u32;
    (indent, w, h)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 位置保存失败后不标记已保存并在下次成功重试() {
        let st = OverlayState::default();
        let bounds = config::WindowBounds { x: 321.0, y: 234.0, w: 680.0, h: 310.0 };
        *st.bounds.lock().unwrap() = Some(bounds);
        assert!(persist_overlay_bounds(&st, |_| Err("模拟磁盘暂时不可写".into())).is_err());
        assert_eq!(*st.saved_bounds.lock().unwrap(), None);
        persist_overlay_bounds(&st, |b| {
            assert_eq!(*b, bounds);
            Ok(())
        }).unwrap();
        assert_eq!(*st.saved_bounds.lock().unwrap(), Some(bounds));
        persist_overlay_bounds(&st, |_| panic!("位置不变时不应重复写盘")).unwrap();
    }

    #[test]
    fn 最后一次拖动的坐标覆盖上一周期已保存位置() {
        let st = OverlayState::default();
        let old = config::WindowBounds { x: 80.0, y: 80.0, w: 700.0, h: 400.0 };
        let last = config::WindowBounds { x: 321.0, y: 234.0, ..old };
        *st.saved_bounds.lock().unwrap() = Some(old);
        *st.bounds.lock().unwrap() = Some(last);
        persist_overlay_bounds(&st, |b| {
            assert_eq!(*b, last);
            Ok(())
        }).unwrap();
        assert_eq!(*st.saved_bounds.lock().unwrap(), Some(last));
    }
}
