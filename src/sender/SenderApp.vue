<script setup lang="ts">
import { invoke } from '@tauri-apps/api/core'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue'

import type { OverlayStyle, RoomStatusEvent, SenderHitRect } from '../types/ipc'

const danmakuText = ref('')
const sending = ref(false)
const sendError = ref('')
const loggedIn = ref(false)
const connected = ref(false)
// 鼠标穿透是否开启：开关按钮在发送框右端，发送框是独立窗口，穿透开启后仍可点
const clickthrough = ref(false)
// 弹幕字号（与弹幕窗统一，界面元素按 em 相对缩放）
const fontSize = ref(17)
const inputElement = ref<HTMLInputElement | null>(null)
const buttonElement = ref<HTMLButtonElement | null>(null)

let unlistenRoom: UnlistenFn | undefined
let unlistenStyle: UnlistenFn | undefined
// 穿透从主界面那一侧被改动时由 Rust 广播过来（两个入口必须双向同步）
let unlistenClickthrough: UnlistenFn | undefined
let pollTimer: ReturnType<typeof setInterval> | undefined
let unlistenScale: UnlistenFn | undefined
let regionObserver: ResizeObserver | undefined
let regionFrame = 0
let lastRegion = ''

const canSend = computed(() => loggedIn.value && connected.value)

/** 只把两个可见控件的边界交给原生窗口，透明间距和余量不能挡住游戏点击。 */
function syncHitRegion() {
  regionFrame = 0
  if (!inputElement.value || !buttonElement.value) return
  const rects: SenderHitRect[] = [inputElement.value, buttonElement.value].map(el => {
    const { left, top, right, bottom } = el.getBoundingClientRect()
    return { left, top, right, bottom }
  })
  if (rects.some(r => r.right <= r.left || r.bottom <= r.top)) return
  const scale = window.devicePixelRatio
  const signature = JSON.stringify({ rects, scale })
  if (lastRegion === signature) return
  lastRegion = signature
  void invoke('sender_set_hit_regions', { rects, scale }).catch(e => {
    if (lastRegion === signature) lastRegion = ''
    console.error('更新发送框点击区域失败', e)
  })
}

function scheduleHitRegion() {
  if (!regionFrame) regionFrame = requestAnimationFrame(syncHitRegion)
}

async function sendDanmaku() {
  const text = danmakuText.value.trim()
  if (!text || sending.value || !canSend.value) return
  sendError.value = ''
  sending.value = true
  try {
    await invoke('send_danmaku', { msg: text })
    danmakuText.value = ''
  } catch (e) {
    sendError.value = String(e)
  } finally {
    sending.value = false
  }
}

/** 切换鼠标穿透（发送框隐藏后可在主窗口「弹幕窗」设置中切换） */
async function toggleClickthrough() {
  try {
    clickthrough.value = await invoke<boolean>('overlay_set_clickthrough', { enabled: !clickthrough.value })
  } catch (e) {
    sendError.value = String(e)
  }
}

async function poll() {
  try {
    const info = await invoke<{ loggedIn: boolean }>('get_login_info')
    loggedIn.value = info.loggedIn
  } catch {
    /* ignore */
  }
  try {
    const st = await invoke<RoomStatusEvent>('get_connection_status')
    connected.value = st.state === 'connected'
  } catch {
    /* ignore */
  }
  try {
    clickthrough.value = await invoke<boolean>('overlay_get_clickthrough')
  } catch {
    /* ignore */
  }
}

onMounted(async () => {
  regionObserver = new ResizeObserver(scheduleHitRegion)
  if (inputElement.value) regionObserver.observe(inputElement.value)
  if (buttonElement.value) regionObserver.observe(buttonElement.value)
  window.addEventListener('resize', scheduleHitRegion)
  // 空原生区域可能暂停绘制，首次测量不能等 requestAnimationFrame。
  syncHitRegion()
  unlistenScale = await getCurrentWindow().onScaleChanged(scheduleHitRegion)
  scheduleHitRegion()
  unlistenRoom = await listen<RoomStatusEvent>('room-status', e => {
    connected.value = e.payload.state === 'connected'
  })
  unlistenStyle = await listen<OverlayStyle>('overlay-style', e => {
    fontSize.value = e.payload.font_size
  })
  unlistenClickthrough = await listen<boolean>('overlay-clickthrough', e => {
    clickthrough.value = e.payload
  })
  try {
    const s = await invoke<OverlayStyle>('overlay_get_style')
    fontSize.value = s.font_size
    await nextTick()
    syncHitRegion()
  } catch {
    /* ignore */
  }
  await poll()
  pollTimer = setInterval(poll, 2000)
})

onUnmounted(() => {
  regionObserver?.disconnect()
  window.removeEventListener('resize', scheduleHitRegion)
  if (regionFrame) cancelAnimationFrame(regionFrame)
  unlistenScale?.()
  if (pollTimer) clearInterval(pollTimer)
  unlistenRoom?.()
  unlistenStyle?.()
  unlistenClickthrough?.()
})
</script>

<template>
  <div class="sender-root" :style="{ fontSize: fontSize + 'px' }" @contextmenu.prevent>
    <div class="input-row">
      <input
        ref="inputElement"
        v-model="danmakuText"
        class="send-input"
        :class="{ 'has-error': sendError }"
        type="text"
        aria-label="发送弹幕"
        :aria-invalid="Boolean(sendError)"
        :title="sendError || '输入弹幕后按回车发送'"
        :placeholder="sendError || '输入弹幕回车发送'"
        maxlength="100"
        :disabled="!canSend"
        @input="sendError = ''"
        @keyup.enter="sendDanmaku" />
      <button
        ref="buttonElement"
        type="button"
        class="ct-btn"
        :class="{ on: clickthrough }"
        :title="sendError || (clickthrough ? '鼠标穿透：开（点击关闭）' : '鼠标穿透：关（点击开启）')"
        @click="toggleClickthrough">
        穿透
      </button>
    </div>
  </div>
</template>

<style scoped>
.sender-root {
  display: flex;
  height: 100%;
  box-sizing: border-box;
  overflow: hidden;
}

.input-row {
  display: flex;
  width: 100%;
  height: 100%;
  /* stretch 而非 center：两个子元素天然等高（字号/padding 一致），stretch 再上一层保险 */
  align-items: stretch;
  gap: 0.25em;
}

/* 输入区字号比弹幕小一档（0.9em）：发送框宽度受「不能挡太多游戏画面」约束
   （面板宽度的 50%、上限 260px），字号 1em 时 210px 的框只放得下 6 个中文字，
   连 placeholder 都会截尾。要再宽只能改 window.rs 的 SENDER_WIDTH_RATIO。 */
.send-input {
  flex: 1 1 auto;
  min-width: 0;
  appearance: none;
  -webkit-appearance: none;
  background: rgba(0, 0, 0, 0.55);
  border: 1px solid rgba(255, 255, 255, 0.35);
  border-radius: 0.4em;
  color: #fff;
  padding: 0.3em;
  font-size: 0.9em;
  line-height: 1.2;
  outline: none;
  user-select: text;
}

.send-input::placeholder {
  color: rgba(255, 255, 255, 0.5);
}

.send-input:focus {
  border-color: rgba(120, 180, 255, 0.95);
  border-radius: 0.4em;
}

.send-input.has-error {
  border-color: #ff7b72;
}

/* 穿透开关：发送框是独立窗口，穿透开启后本按钮仍可点击；主窗口也保留穿透开关。
   字号 / 上下 padding 与 .send-input 保持一致：em 是相对自身字号的，字号小一档
   行高框与 padding 会跟着缩，按钮就比输入框矮（0.8em 时矮 3.5px，看着不齐）。 */
.ct-btn {
  flex: 0 0 auto;
  appearance: none;
  -webkit-appearance: none;
  cursor: pointer;
  white-space: nowrap;
  font-size: 0.9em;
  line-height: 1.2;
  font-family: inherit;
  color: rgba(255, 255, 255, 0.85);
  background: rgba(0, 0, 0, 0.55);
  border: 1px solid rgba(255, 255, 255, 0.35);
  border-radius: 0.4em;
  padding: 0.3em 0.45em;
  transition:
    background 0.12s ease,
    color 0.12s ease,
    border-color 0.12s ease;
}

.ct-btn:hover {
  border-color: rgba(255, 255, 255, 0.6);
}

.ct-btn.on {
  color: #fff;
  background: rgba(120, 180, 255, 0.55);
  border-color: rgba(120, 180, 255, 0.95);
}
</style>
