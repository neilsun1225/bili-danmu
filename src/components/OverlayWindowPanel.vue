<script setup lang="ts">
import { invoke } from '@tauri-apps/api/core'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { onMounted, onUnmounted, ref } from 'vue'

import SettingRow from './SettingRow.vue'

import type { DashboardStatus } from '../types/ipc'

// 「弹幕窗」标签页：弹幕窗与发送框显示 / 鼠标穿透 / 始终置顶 / 宽高。
//
// 状态全部留在本组件内（与弹幕样式、弹幕过滤无耦合），父页面只管挂载。
// 设置卡片、设置行与开关的样式来自全局 styles/settings.css；
// 失败提示用独立的 .panel-error，避免与页面的 .error 样式互相影响。
const winSize = ref({ width: 480, height: 240 })
// 三个开关的初值与 Rust 侧 OverlayState 的默认值一致（创建窗口时就是这三态），
// 避免读到真实状态前先闪一下错误勾选；挂载后再用命令读一次对齐
const ov = ref({ visible: true, clickthrough: false, alwaysOnTop: true })
const senderVisible = ref(true)
const windowReady = ref(false)
const windowSaving = ref(false)
const senderSaving = ref(false)
const errMsg = ref('')
let errTimer: ReturnType<typeof setTimeout> | undefined
// 窗口被手动拖动边缘缩放时由 Rust 广播 overlay-size 同步过来
let unlistenSize: UnlistenFn | undefined
// 开关从发送框那一侧被改动时由 Rust 广播过来（两个入口必须双向同步）
let unlistenVisible: UnlistenFn | undefined
let unlistenClickthrough: UnlistenFn | undefined
let unlistenSenderVisible: UnlistenFn | undefined
let unlistenAlwaysOnTop: UnlistenFn | undefined
let unlistenReady: UnlistenFn | undefined

/** 操作失败就地提示（3s 后自动消失），不打断页面其它区域的保存提示 */
function fail(e: unknown) {
  errMsg.value = String(e)
  if (errTimer) clearTimeout(errTimer)
  errTimer = setTimeout(() => (errMsg.value = ''), 3000)
}

async function loadWindowSettings() {
  const { overlay } = await invoke<DashboardStatus>('get_dashboard_status')
  if (!overlay.ready) return
  ov.value = {
    visible: overlay.visible,
    clickthrough: overlay.clickthrough,
    alwaysOnTop: overlay.always_on_top,
  }
  senderVisible.value = overlay.sender_visible
  winSize.value = await invoke<{ width: number; height: number }>('overlay_get_size')
  windowReady.value = true
}

async function setWindowFlag(key: 'visible' | 'clickthrough' | 'alwaysOnTop', v: boolean) {
  if (windowSaving.value) return
  errMsg.value = ''
  windowSaving.value = true
  const previous = ov.value[key]
  ov.value[key] = v
  const command =
    key === 'visible'
      ? 'overlay_set_visible'
      : key === 'clickthrough'
        ? 'overlay_set_clickthrough'
        : 'overlay_set_always_on_top'
  try {
    ov.value[key] = await invoke<boolean>(command, key === 'visible' ? { visible: v } : { enabled: v })
  } catch (e) {
    await loadWindowSettings().catch(() => {
      ov.value[key] = previous
    })
    fail(e)
  } finally {
    windowSaving.value = false
  }
}

async function setSenderVisible(v: boolean) {
  if (senderSaving.value) return
  errMsg.value = ''
  senderSaving.value = true
  const previous = senderVisible.value
  senderVisible.value = v
  try {
    senderVisible.value = await invoke<boolean>('sender_set_visible', { visible: v })
  } catch (e) {
    // 原生窗口操作失败时回显实际状态；保存失败则保留本次已生效的窗口状态。
    senderVisible.value = await invoke<boolean>('sender_is_visible').catch(() => previous)
    fail(e)
  } finally {
    senderSaving.value = false
  }
}

/** 提交窗口宽高（滑块拖动结束后才调用，避免拖动中反复改窗口） */
async function commitSize() {
  try {
    await invoke('overlay_set_size', {
      width: winSize.value.width,
      height: winSize.value.height,
    })
  } catch (e) {
    fail(e)
  }
}

onMounted(async () => {
  // 先在监听：读取尺寸与手动缩放都走同一条路，不必区分先后
  unlistenSize = await listen<{ width: number; height: number }>('overlay-size', e => {
    winSize.value = e.payload
  })
  unlistenVisible = await listen<boolean>('overlay-visible', e => {
    ov.value.visible = e.payload
  })
  unlistenClickthrough = await listen<boolean>('overlay-clickthrough', e => {
    ov.value.clickthrough = e.payload
  })
  unlistenSenderVisible = await listen<boolean>('sender-visible', e => {
    senderVisible.value = e.payload
  })
  unlistenAlwaysOnTop = await listen<boolean>('overlay-always-on-top', e => {
    ov.value.alwaysOnTop = e.payload
  })
  // 先订阅再读取：无论窗口恢复发生在页面挂载前还是挂载中，都能获得最终配置。
  unlistenReady = await listen('overlay-ready', () => {
    void loadWindowSettings().catch(fail)
  })
  try {
    await loadWindowSettings()
  } catch (e) {
    fail(e)
  }
})

onUnmounted(() => {
  unlistenSize?.()
  unlistenVisible?.()
  unlistenClickthrough?.()
  unlistenSenderVisible?.()
  unlistenAlwaysOnTop?.()
  unlistenReady?.()
  if (errTimer) clearTimeout(errTimer)
})
</script>

<template>
  <div class="setting-card">
    <p v-if="errMsg" class="panel-error">{{ errMsg }}</p>

    <SettingRow label="显示弹幕窗">
      <input
        type="checkbox"
        class="switch"
        aria-label="显示弹幕窗"
        :checked="ov.visible"
        :disabled="!windowReady || windowSaving"
        @change="setWindowFlag('visible', ($event.target as HTMLInputElement).checked)" />
    </SettingRow>

    <SettingRow label="显示发送框">
      <input
        type="checkbox"
        class="switch"
        aria-label="显示发送框"
        :checked="senderVisible"
        :disabled="!windowReady || senderSaving"
        @change="setSenderVisible(($event.target as HTMLInputElement).checked)" />
    </SettingRow>

    <SettingRow label="鼠标穿透">
      <input
        type="checkbox"
        class="switch"
        aria-label="鼠标穿透"
        :checked="ov.clickthrough"
        :disabled="!windowReady || windowSaving"
        @change="setWindowFlag('clickthrough', ($event.target as HTMLInputElement).checked)" />
    </SettingRow>

    <SettingRow label="始终置顶">
      <input
        type="checkbox"
        class="switch"
        aria-label="始终置顶"
        :checked="ov.alwaysOnTop"
        :disabled="!windowReady || windowSaving"
        @change="setWindowFlag('alwaysOnTop', ($event.target as HTMLInputElement).checked)" />
    </SettingRow>

    <SettingRow label="宽度">
      <div class="size-control">
        <input
          v-model.number="winSize.width"
          type="range"
          min="240"
          max="1600"
          step="10"
          :disabled="!windowReady"
          @change="commitSize" />
        <span class="value">{{ winSize.width }}px</span>
      </div>
    </SettingRow>

    <SettingRow label="高度">
      <div class="size-control">
        <input
          v-model.number="winSize.height"
          type="range"
          min="120"
          max="900"
          step="10"
          :disabled="!windowReady"
          @change="commitSize" />
        <span class="value">{{ winSize.height }}px</span>
      </div>
    </SettingRow>

    <p class="tip">
      关闭穿透后，可在弹幕窗上按住拖动、边缘调整大小；开启穿透后鼠标点击会落到弹幕窗下方的窗口。
      本页开关、窗口位置和大小自动保存，下次启动恢复。
      关闭「显示发送框」会同时隐藏输入框和穿透按钮，重启后保持；可在此重新开启，鼠标穿透也可在此切换。
    </p>
  </div>
</template>

<style scoped>
/* 滑块与数值标签见全局 src/styles/settings.css（.size-control / .value） */

/* 只在本标签页内提示，不与页面顶部的样式/过滤保存提示混用 */
.panel-error {
  color: var(--red);
  font-size: 15px;
  padding: 6px 0 0;
}
</style>
