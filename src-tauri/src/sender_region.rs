//! 发送窗只保留输入框和穿透按钮的原生区域，透明间距不能截获游戏鼠标。

use serde::Deserialize;

#[derive(Clone, Copy, Deserialize)]
pub(crate) struct HitRect {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,
}

impl HitRect {
    fn physical(&self, scale: f64) -> Result<[i32; 4], String> {
        let coords = [self.left, self.top, self.right, self.bottom];
        // GDI 区域使用 27 位有符号坐标；先检查再转整数，拒绝空矩形和非法缩放。
        if !scale.is_finite() || scale <= 0.0
            || coords.iter().any(|v| !v.is_finite() || *v < 0.0 || *v * scale >= 67_108_864.0)
            || self.right <= self.left || self.bottom <= self.top
        {
            return Err("发送框点击区域无效".into());
        }
        Ok([
            (self.left * scale).floor() as i32,
            (self.top * scale).floor() as i32,
            (self.right * scale).ceil() as i32,
            (self.bottom * scale).ceil() as i32,
        ])
    }
}

/// setup 主线程中调用：测量前不允许透明矩形拦截点击。
pub(crate) fn initialize(window: &tauri::WebviewWindow) -> Result<(), String> {
    #[cfg(windows)]
    return win::set_region(window.hwnd().map_err(|e| e.to_string())?.0 as _, &[]);
    #[cfg(not(windows))]
    { let _ = window; Ok(()) }
}

/// CSS 像素乘页面 devicePixelRatio（包含浏览器缩放），不能再乘一次窗口 DPI。
pub(crate) fn update(
    window: &tauri::WebviewWindow,
    rects: &[HitRect; 2],
    scale: f64,
) -> Result<(), String> {
    let rects = rects.iter().map(|r| r.physical(scale)).collect::<Result<Vec<_>, _>>()?;
    #[cfg(windows)]
    return win::set_region(window.hwnd().map_err(|e| e.to_string())?.0 as _, &rects);
    #[cfg(not(windows))]
    { let _ = (window, rects); Ok(()) }
}

#[cfg(windows)]
mod win {
    use windows_sys::Win32::Foundation::{HWND, POINT, RECT};
    use windows_sys::Win32::Graphics::Gdi::{
        ClientToScreen, CombineRgn, CreateRectRgn, DeleteObject, SetWindowRgn, HRGN, RGN_OR,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::GetWindowRect;

    /// 返回的 HRGN 尚未移交，调用者负责交给系统或释放。
    pub(super) fn region(rects: &[[i32; 4]]) -> Result<HRGN, String> {
        unsafe {
            let combined = CreateRectRgn(0, 0, 0, 0);
            if combined.is_null() { return Err("创建发送框区域失败".into()); }
            for &[left, top, right, bottom] in rects {
                let part = CreateRectRgn(left, top, right, bottom);
                if part.is_null() {
                    DeleteObject(combined);
                    return Err("创建发送框控件区域失败".into());
                }
                let result = CombineRgn(combined, combined, part, RGN_OR);
                DeleteObject(part);
                if result == 0 {
                    DeleteObject(combined);
                    return Err("合并发送框区域失败".into());
                }
            }
            Ok(combined)
        }
    }

    pub(super) fn set_region(hwnd: HWND, rects: &[[i32; 4]]) -> Result<(), String> {
        unsafe {
            let mut origin = POINT { x: 0, y: 0 };
            let mut outer = RECT { left: 0, top: 0, right: 0, bottom: 0 };
            if ClientToScreen(hwnd, &mut origin) == 0 || GetWindowRect(hwnd, &mut outer) == 0 {
                return Err(format!("读取发送框原点失败: {}", std::io::Error::last_os_error()));
            }
            // SetWindowRgn 的原点是整个窗口，DOM 的原点是 client 区域。
            let (dx, dy) = (origin.x - outer.left, origin.y - outer.top);
            let rects: Vec<_> = rects.iter().map(|r| [r[0] + dx, r[1] + dy, r[2] + dx, r[3] + dy]).collect();
            let combined = region(&rects)?;
            if SetWindowRgn(hwnd, combined, 1) == 0 {
                // 只有成功时所有权才转交给 Windows。
                DeleteObject(combined);
                return Err(format!("设置发送框区域失败: {}", std::io::Error::last_os_error()));
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 控件区域按页面缩放换算且只向边界取整() {
        let rect = HitRect { left: 0.0, top: 0.0, right: 150.0, bottom: 30.0 };
        assert_eq!(rect.physical(1.0).unwrap(), [0, 0, 150, 30]);
        assert_eq!(rect.physical(1.25).unwrap(), [0, 0, 188, 38]);
        assert_eq!(rect.physical(1.5).unwrap(), [0, 0, 225, 45]);
        assert_eq!(rect.physical(2.0).unwrap(), [0, 0, 300, 60]);
        assert!(rect.physical(0.0).is_err());
        assert!(rect.physical(f64::NAN).is_err());
        assert!(HitRect { right: 0.0, ..rect }.physical(1.0).is_err());
        assert!(HitRect { left: -1.0, ..rect }.physical(1.0).is_err());
        assert!(HitRect { bottom: f64::INFINITY, ..rect }.physical(1.0).is_err());
    }

    #[cfg(windows)]
    #[test]
    fn 原生联合区域只包含输入框和按钮并排除间隙与下方空白() {
        use windows_sys::Win32::Graphics::Gdi::{DeleteObject, PtInRegion};
        for scale in [1.0, 1.25, 1.5, 2.0] {
            let rects = [
                HitRect { left: 0.0, top: 0.0, right: 150.0, bottom: 30.0 }.physical(scale).unwrap(),
                HitRect { left: 155.0, top: 0.0, right: 210.0, bottom: 30.0 }.physical(scale).unwrap(),
            ];
            let region = win::region(&rects).unwrap();
            unsafe {
                for (x, y, expected) in [(50.0, 15.0, true), (180.0, 15.0, true), (152.0, 15.0, false), (50.0, 40.0, false)] {
                    assert_eq!(PtInRegion(region, (x * scale) as i32, (y * scale) as i32) != 0, expected);
                }
                DeleteObject(region);
            }
        }
    }

    #[cfg(windows)]
    #[test]
    fn Windows窗口接受空初始区域并读回两个控件区域() {
        use windows_sys::Win32::Graphics::Gdi::{CreateRectRgn, DeleteObject, GetWindowRgn, PtInRegion};
        use windows_sys::Win32::UI::WindowsAndMessaging::{CreateWindowExW, DestroyWindow, WS_POPUP};
        unsafe {
            let class: Vec<u16> = "STATIC\0".encode_utf16().collect();
            let hwnd = CreateWindowExW(0, class.as_ptr(), class.as_ptr(), WS_POPUP, 100, 100, 210, 60,
                std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null());
            assert!(!hwnd.is_null());
            win::set_region(hwnd, &[]).unwrap();
            let actual = CreateRectRgn(0, 0, 0, 0);
            assert_eq!(GetWindowRgn(hwnd, actual), 1); // NULLREGION
            win::set_region(hwnd, &[[0, 0, 150, 30], [155, 0, 210, 30]]).unwrap();
            assert_eq!(GetWindowRgn(hwnd, actual), 3); // COMPLEXREGION
            assert_ne!(PtInRegion(actual, 50, 15), 0);
            assert_ne!(PtInRegion(actual, 180, 15), 0);
            assert_eq!(PtInRegion(actual, 152, 15), 0);
            assert_eq!(PtInRegion(actual, 50, 40), 0);
            DeleteObject(actual);
            DestroyWindow(hwnd);
        }
    }
}
