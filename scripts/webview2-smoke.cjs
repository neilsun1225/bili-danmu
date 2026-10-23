// 连接真实发布版 WebView2，不模拟页面、Tauri API 或原生窗口。
// PowerShell 负责启动进程、原生截图及实际系统鼠标点击。
'use strict'

const fs = require('node:fs')
const path = require('node:path')

function option(name, fallback) {
  const index = process.argv.indexOf(`--${name}`)
  return index === -1 ? fallback : process.argv[index + 1]
}

const output = path.resolve(option('output', 'webview2-smoke-output'))
const port = Number(option('port', '9222'))
const prefix = option('prefix')
const timeout = Number(option('timeout', '120000'))
fs.mkdirSync(output, { recursive: true })
const report = { kind: 'actual-release-webview2', startedAt: new Date().toISOString(), checks: [], errors: [] }
let browser
let pages = {}

function write(name, value) {
  const target = path.join(output, name)
  fs.writeFileSync(`${target}.tmp`, JSON.stringify(value, null, 2))
  fs.renameSync(`${target}.tmp`, target)
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
async function limited(promise, label, milliseconds = 8000) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} timed out after ${milliseconds} ms`)), milliseconds)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

async function inspect(name, operation) {
  try {
    return { ok: true, value: await limited(operation(), name) }
  } catch (error) {
    return { ok: false, error: String(error.stack || error) }
  }
}

function check(name, pass, details) {
  report.checks.push({ name, pass: Boolean(pass), details })
}

// 仅调用这些只读命令，不读取登录凭据、不连接直播间。
async function nativeRead(page, command) {
  return page.evaluate(async cmd => {
    if (!window.__TAURI_INTERNALS__ || typeof window.__TAURI_INTERNALS__.invoke !== 'function') {
      throw new Error('Actual Tauri IPC is unavailable')
    }
    return window.__TAURI_INTERNALS__.invoke(cmd)
  }, command)
}

async function settings(page) {
  return page.evaluate(() => {
    const names = ['显示弹幕窗', '显示发送框', '鼠标穿透', '始终置顶']
    return names.map(name => {
      const input = [...document.querySelectorAll('input[type="checkbox"]')].find(
        el => el.getAttribute('aria-label') === name,
      )
      if (!input) return { name, present: false }
      const rect = input.getBoundingClientRect()
      return {
        name,
        present: true,
        checked: input.checked,
        disabled: input.disabled,
        visible: rect.width > 0 && rect.height > 0,
      }
    })
  })
}

async function senderGeometry(page) {
  return page.evaluate(() => {
    const rect = element => {
      if (!element) return null
      const { left, top, right, bottom, width, height } = element.getBoundingClientRect()
      const style = getComputedStyle(element)
      return { left, top, right, bottom, width, height, background: style.backgroundColor, border: style.borderColor }
    }
    return {
      devicePixelRatio: window.devicePixelRatio,
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      input: rect(document.querySelector('.send-input')),
      button: rect(document.querySelector('.ct-btn')),
      root: rect(document.querySelector('.sender-root')),
      buttonText: document.querySelector('.ct-btn')?.textContent?.trim(),
      inputDisabled: document.querySelector('.send-input')?.disabled,
      buttonTitle: document.querySelector('.ct-btn')?.title,
      inputTitle: document.querySelector('.send-input')?.title,
    }
  })
}

async function snapshot(phase) {
  const value = {
    phase,
    capturedAt: new Date().toISOString(),
    dashboard: await inspect('get_dashboard_status', () => nativeRead(pages.main, 'get_dashboard_status')),
    overlaySize: await inspect('overlay_get_size', () => nativeRead(pages.main, 'overlay_get_size')),
    clickthrough: await inspect('overlay_get_clickthrough', () => nativeRead(pages.sender, 'overlay_get_clickthrough')),
    connection: await inspect('get_connection_status', () => nativeRead(pages.main, 'get_connection_status')),
    settings: await inspect('settings DOM', () => settings(pages.main)),
    sender: await inspect('sender geometry', () => senderGeometry(pages.sender)),
  }
  for (const [name, page] of Object.entries(pages)) {
    value[`${name}Screenshot`] = await inspect(`${name} screenshot`, () =>
      page.screenshot({ path: path.join(output, `${phase}-${name}.png`), timeout: 6000 }),
    )
    // 截图保存为文件，不把二进制内容序列化到 JSON。
    if (value[`${name}Screenshot`].ok) value[`${name}Screenshot`].value = `${phase}-${name}.png`
  }
  write(`${phase}.json`, value)
  return value
}

async function attach() {
  const { chromium } = require(path.join(path.resolve(prefix), 'node_modules', 'playwright-core'))
  const endpoint = `http://127.0.0.1:${port}`
  let version
  const deadline = Date.now() + 45000
  while (Date.now() < deadline) {
    try {
      version = await (await fetch(`${endpoint}/json/version`, { signal: AbortSignal.timeout(1500) })).json()
      break
    } catch {
      await sleep(250)
    }
  }
  if (!version) throw new Error('The actual WebView2 CDP endpoint never became available')
  write('cdp-version.json', version)
  browser = await chromium.connectOverCDP(endpoint, { timeout: 15000, noDefaults: true })
  report.browserVersion = browser.version()
  report.playwrightVersion = require(
    path.join(path.resolve(prefix), 'node_modules', 'playwright-core', 'package.json'),
  ).version
  const pageDeadline = Date.now() + 30000
  const attached = new WeakSet()
  while (Date.now() < pageDeadline) {
    for (const context of browser.contexts()) {
      for (const page of context.pages()) {
        if (!attached.has(page)) {
          attached.add(page)
          page.on('pageerror', error =>
            report.errors.push({ type: 'pageerror', url: page.url(), message: String(error.stack || error) }),
          )
          page.on('console', message => {
            if (message.type() === 'error')
              report.errors.push({ type: 'console', url: page.url(), message: message.text().slice(0, 2000) })
          })
          page.setDefaultTimeout(6000)
        }
        const identity = await inspect('page identity', () =>
          page.evaluate(() => ({
            label: window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label,
            main: Boolean(document.querySelector('.layout')),
            overlay: Boolean(document.querySelector('.overlay-root')),
            sender: Boolean(document.querySelector('.sender-root')),
          })),
        )
        if (!identity.ok) continue
        const id = identity.value
        const name = ['main', 'overlay', 'sender'].find(label => id.label === label || id[label])
        if (name) pages[name] = page
      }
    }
    if (pages.main && pages.overlay && pages.sender) break
    await sleep(250)
  }
  report.pages = [...browser.contexts()].flatMap(context => context.pages().map(page => ({ url: page.url() })))
  write('cdp-pages.json', report.pages)
  if (!pages.main || !pages.overlay || !pages.sender)
    throw new Error(`Missing actual WebView2 windows: found ${Object.keys(pages).join(', ')}`)
}

async function run() {
  if (!prefix) throw new Error('--prefix must point to the temporary, pinned playwright-core installation')
  await attach()
  // 操作现有界面，保留禁用开关和真实启动问题的可观测性。
  await pages.main.getByRole('button', { name: '弹幕设置', exact: true }).click()
  await pages.main.getByRole('button', { name: '弹幕窗', exact: true }).click()
  report.initialSettings = await inspect('initial settings', () => settings(pages.main))
  const readyDeadline = Date.now() + 12000
  while (Date.now() < readyDeadline) {
    const controls = await settings(pages.main)
    if (controls.length === 4 && controls.every(control => control.present && control.visible && !control.disabled))
      break
    await sleep(250)
  }
  const before = await snapshot('phase-before')
  report.before = before
  check(
    'four settings switches are present, visible and enabled',
    before.settings.ok &&
      before.settings.value.length === 4 &&
      before.settings.value.every(control => control.present && control.visible && !control.disabled),
    before.settings,
  )
  check(
    'actual backend overlay size is readable',
    before.overlaySize.ok && before.overlaySize.value.width > 0 && before.overlaySize.value.height > 0,
    before.overlaySize,
  )
  check(
    'no live-room connection was started',
    before.connection.ok && before.connection.value.state === 'disconnected',
    before.connection,
  )
  check(
    'actual sender DOM has input and toggle button',
    before.sender.ok && before.sender.value.input?.width > 0 && before.sender.value.button?.width > 0,
    before.sender,
  )
  const geometry = before.sender.ok && before.sender.value
  check(
    'two adjacent controls fill the sender client area',
    geometry &&
      Math.abs(geometry.input.left) < 1 &&
      Math.abs(geometry.input.top) < 1 &&
      Math.abs(geometry.input.right - geometry.button.left) < 1 &&
      Math.abs(geometry.button.right - geometry.innerWidth) < 1 &&
      Math.abs(geometry.input.bottom - geometry.innerHeight) < 1 &&
      Math.abs(geometry.button.bottom - geometry.innerHeight) < 1,
    geometry,
  )

  // CI 不登录 B 站；仅解除 HTML 输入框的 disabled 以测试真实系统焦点，后端仍保持未连接。
  report.focusFixture = await pages.sender.evaluate(() => {
    const input = document.querySelector('.send-input')
    const originalDisabled = input.disabled
    input.disabled = false
    return { originalDisabled, operation: 'enable DOM input only for native focus check; no login or room connection' }
  })
  write('focus-fixture-ready.json', report.focusFixture)

  // PowerShell 读取 phase-before.json，暂时隐藏主窗口，
  // 抓取桌面和原生命中结果，再发送实际的 SendInput 点击。
  const nativeDeadline = Date.now() + 60000
  while (!fs.existsSync(path.join(output, 'input-focused.done'))) {
    if (Date.now() > nativeDeadline) throw new Error('Native input-focus phase timed out')
    await sleep(100)
  }
  report.focus = await inspect('actual input focus', () =>
    pages.sender.evaluate(() => ({
      activeClass: document.activeElement?.className,
      documentFocused: document.hasFocus(),
    })),
  )
  check(
    'actual OS click focused the sender input',
    report.focus.ok && report.focus.value.activeClass.includes('send-input'),
    report.focus,
  )
  await pages.sender.screenshot({ path: path.join(output, 'phase-input-focus-sender.png'), timeout: 6000 })
  write('phase-input-focus.json', report.focus)
  while (!fs.existsSync(path.join(output, 'native-after.done'))) {
    if (Date.now() > nativeDeadline)
      throw new Error('Native Windows companion did not complete its click/capture phase')
    await sleep(100)
  }
  const after = await snapshot('phase-after')
  report.after = after
  check(
    'SendInput click changed actual backend mouse passthrough',
    before.clickthrough.ok && after.clickthrough.ok && before.clickthrough.value !== after.clickthrough.value,
    { before: before.clickthrough, after: after.clickthrough },
  )
  const switchAfter = after.settings.ok && after.settings.value.find(control => control.name === '鼠标穿透')
  check(
    'settings switch reflects actual sender button action',
    Boolean(switchAfter) && !switchAfter.disabled && switchAfter.checked === after.clickthrough.value,
    switchAfter,
  )
  for (const phase of [before, after]) {
    for (const label of ['main', 'overlay', 'sender'])
      check(`${phase.phase} actual ${label} screenshot`, phase[`${label}Screenshot`].ok, phase[`${label}Screenshot`])
  }
}

const watchdog = setTimeout(() => {
  report.errors.push({ type: 'fatal', message: `Overall CDP smoke timeout (${timeout} ms)` })
  report.finishedAt = new Date().toISOString()
  report.passed = false
  write('webview2-result.json', report)
  process.exit(1)
}, timeout)

run()
  .catch(error => {
    report.errors.push({ type: 'fatal', message: String(error.stack || error) })
  })
  .finally(async () => {
    clearTimeout(watchdog)
    report.finishedAt = new Date().toISOString()
    report.passed =
      report.checks.length > 0 &&
      report.checks.every(item => item.pass) &&
      !report.errors.some(error => error.type === 'fatal' || error.type === 'pageerror')
    write('webview2-result.json', report)
    if (browser) await limited(browser.close(), 'CDP disconnect', 3000).catch(() => {})
    process.exitCode = report.passed ? 0 : 1
    console.log(`Actual WebView2 smoke ${report.passed ? 'passed' : 'failed'}; diagnostic artifacts: ${output}`)
  })
