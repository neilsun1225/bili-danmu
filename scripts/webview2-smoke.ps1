param(
  [string]$ExePath,
  [string]$OutputDir = 'webview2-smoke-output',
  [int]$Port = 9222,
  [switch]$BackgroundOnly
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This check requires an actual Windows desktop and WebView2 runtime.' }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
[IO.Directory]::CreateDirectory($OutputDir) | Out-Null
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class SmokeNative {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; public POINT(int x, int y) { X=x; Y=y; } }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public UIntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion U; }
  public class WindowInfo {
    public long Hwnd, RootHwnd; public uint Pid, Dpi; public string Title, ClassName, Style, ExtendedStyle;
    public bool Visible, Minimized; public RECT Bounds; public POINT ClientOrigin;
  }
  public delegate bool EnumProc(IntPtr hwnd, IntPtr value);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr value);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hwnd, EnumProc callback, IntPtr value);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
  [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
  public static WindowInfo Describe(IntPtr hwnd) {
    uint pid; GetWindowThreadProcessId(hwnd, out pid);
    StringBuilder title=new StringBuilder(512), cls=new StringBuilder(256);
    GetWindowText(hwnd,title,title.Capacity); GetClassName(hwnd,cls,cls.Capacity);
    RECT bounds; GetWindowRect(hwnd,out bounds); POINT origin=new POINT(0,0); ClientToScreen(hwnd,ref origin);
    return new WindowInfo { Hwnd=hwnd.ToInt64(), RootHwnd=GetAncestor(hwnd,2).ToInt64(), Pid=pid,
      Dpi=GetDpiForWindow(hwnd), Title=title.ToString(), ClassName=cls.ToString(), Bounds=bounds, ClientOrigin=origin,
      Visible=IsWindowVisible(hwnd), Minimized=IsIconic(hwnd),
      Style="0x"+GetWindowLongPtr(hwnd,-16).ToInt64().ToString("X"),
      ExtendedStyle="0x"+GetWindowLongPtr(hwnd,-20).ToInt64().ToString("X") };
  }
  public static WindowInfo[] Windows(uint pid) {
    List<WindowInfo> windows=new List<WindowInfo>();
    EnumWindows(delegate(IntPtr hwnd,IntPtr value) { uint current; GetWindowThreadProcessId(hwnd,out current);
      if(current==pid) { windows.Add(Describe(hwnd)); EnumChildWindows(hwnd,delegate(IntPtr child,IntPtr data) { windows.Add(Describe(child)); return true; },IntPtr.Zero); }
      return true;
    },IntPtr.Zero);
    return windows.ToArray();
  }
  public static uint Click(int x,int y) {
    SetCursorPos(x,y); INPUT[] input=new INPUT[2];
    input[0].type=0; input[0].U.mi.dwFlags=0x0002;
    input[1].type=0; input[1].U.mi.dwFlags=0x0004;
    return SendInput(2,input,Marshal.SizeOf(typeof(INPUT)));
  }
}
'@
[SmokeNative]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null

function Write-Json([string]$Name, $Value) {
  ConvertTo-Json -InputObject $Value -Depth 30 | Set-Content -LiteralPath (Join-Path $OutputDir $Name) -Encoding utf8
}

function Capture-Desktop([string]$Name) {
  $left=[SmokeNative]::GetSystemMetrics(76); $top=[SmokeNative]::GetSystemMetrics(77)
  $width=[SmokeNative]::GetSystemMetrics(78); $height=[SmokeNative]::GetSystemMetrics(79)
  $bitmap=[Drawing.Bitmap]::new($width,$height)
  $graphics=[Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($left,$top,0,0,[Drawing.Size]::new($width,$height))
    $bitmap.Save((Join-Path $OutputDir $Name),[Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

# 独立进程在应用下方提供颜色已知的真实窗口，以检查跨进程命中。
if ($BackgroundOnly) {
  Add-Type -AssemblyName System.Windows.Forms
  $form = New-Object Windows.Forms.Form
  $form.Text = 'WebView2 Smoke Underlay'
  $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
  $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
  $form.Bounds = [Windows.Forms.SystemInformation]::VirtualScreen
  $form.BackColor = [Drawing.Color]::FromArgb(17, 73, 109)
  $form.ShowInTaskbar = $false
  $form.Add_Shown({ Write-Json 'background-ready.json' @{ Hwnd=$form.Handle.ToInt64(); Pid=$PID; Color=@(17,73,109) } })
  $form.Add_MouseDown({ param($sender,$event)
    @{ utc=[DateTime]::UtcNow.ToString('o'); x=$event.X; y=$event.Y } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $OutputDir 'background-clicks.jsonl') -Encoding utf8
  })
  [Windows.Forms.Application]::Run($form)
  exit 0
}

if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Run the main smoke script with pwsh (PowerShell 7).' }
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This launcher is CI-only to avoid touching an existing human application profile.' }
if (-not $ExePath) { throw '-ExePath must name the actual release executable.' }
$ExePath = (Resolve-Path -LiteralPath $ExePath).Path
$scriptDir = Split-Path -Parent $PSCommandPath
$nodeScript = Join-Path $scriptDir 'webview2-smoke.cjs'
$appProcess = $null
$nodeProcess = $null
$backgroundProcess = $null
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bili-webview2-smoke-' + [Guid]::NewGuid().ToString('N'))
$failures = [Collections.Generic.List[string]]::new()
$phases = [Collections.Generic.List[object]]::new()
$oldArguments = $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
$oldUserData = $env:WEBVIEW2_USER_DATA_FOLDER
$debugPolicy = 'HKCU:\Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments'
$debugPolicyName = [IO.Path]::GetFileName($ExePath)
$debugPolicyCreated = $false
$startTime = [DateTime]::UtcNow

function Start-Child([string]$File, [string[]]$Arguments, [string]$LogPrefix) {
  $info = [Diagnostics.ProcessStartInfo]::new()
  $info.FileName = $File
  $info.UseShellExecute = $false
  foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
  # 脚本输出保存在 JSON/文件中，保留子进程日志以诊断 CDP 故障。
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $child = [Diagnostics.Process]::Start($info)
  $stdout = $child.StandardOutput.ReadToEndAsync()
  $stderr = $child.StandardError.ReadToEndAsync()
  return @{ Process=$child; Stdout=$stdout; Stderr=$stderr; Prefix=$LogPrefix }
}

function Save-ChildLogs($Child) {
  if ($Child -and $Child.Process.HasExited) {
    $Child.Stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $OutputDir ($Child.Prefix + '.stdout.log')) -Encoding utf8
    $Child.Stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $OutputDir ($Child.Prefix + '.stderr.log')) -Encoding utf8
  }
}

function Capture-Native([string]$Phase, $Geometry, [long]$UnderlayHwnd) {
  $windows = @([SmokeNative]::Windows([uint32]$appProcess.Id))
  $senderWindow = $windows | Where-Object { $_.Title -eq 'bili-danmu 发送' -and $_.RootHwnd -eq $_.Hwnd } | Select-Object -First 1
  if (-not $senderWindow) { throw 'The actual native sender HWND was not found.' }
  $left=[SmokeNative]::GetSystemMetrics(76); $top=[SmokeNative]::GetSystemMetrics(77)
  $width=[SmokeNative]::GetSystemMetrics(78); $height=[SmokeNative]::GetSystemMetrics(79)
  if ($width -le 0 -or $height -le 0) { throw 'No usable interactive Windows desktop dimensions.' }
  $bitmap = [Drawing.Bitmap]::new($width,$height)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($left,$top,0,0,[Drawing.Size]::new($width,$height))
    $bitmap.Save((Join-Path $OutputDir ($Phase + '-desktop.png')),[Drawing.Imaging.ImageFormat]::Png)
    $scale=[double]$Geometry.devicePixelRatio
    $inputRect=$Geometry.input; $buttonRect=$Geometry.button
    if (-not $inputRect -or -not $buttonRect -or $scale -le 0) { throw 'Actual sender DOM geometry is unavailable.' }
    $origin=$senderWindow.ClientOrigin
    $frameInsets=@{left=$origin.X-$senderWindow.Bounds.Left;top=$origin.Y-$senderWindow.Bounds.Top}
    if ($frameInsets.left -ne 0 -or $frameInsets.top -ne 0) {
      $failures.Add("$Phase sender has unexpected native frame/titlebar insets")
    }
    $samples=@(
      @{name='input'; cssX=($inputRect.left+$inputRect.right)/2; cssY=($inputRect.top+$inputRect.bottom)/2; extraY=0; expectedRoot=$senderWindow.Hwnd},
      @{name='button'; cssX=($buttonRect.left+$buttonRect.right)/2; cssY=($buttonRect.top+$buttonRect.bottom)/2; extraY=0; expectedRoot=$senderWindow.Hwnd},
      @{name='below8'; cssX=($inputRect.left+$buttonRect.right)/2; cssY=[Math]::Max($inputRect.bottom,$buttonRect.bottom); extraY=8; expectedRoot=$UnderlayHwnd}
    )
    if (($buttonRect.left-$inputRect.right)*$scale -gt 1) {
      $samples+=@{name='gap'; cssX=($inputRect.right+$buttonRect.left)/2; cssY=($buttonRect.top+$buttonRect.bottom)/2; extraY=0; expectedRoot=$UnderlayHwnd}
    }
    $points=@(foreach ($sample in $samples) {
      $x=$origin.X+[int][Math]::Round($sample.cssX*$scale)
      $y=$origin.Y+[int][Math]::Round($sample.cssY*$scale)+$sample.extraY
      $hit=[SmokeNative]::Describe([SmokeNative]::WindowFromPoint([SmokeNative+POINT]::new($x,$y)))
      $inside=$x -ge $left -and $x -lt $left+$width -and $y -ge $top -and $y -lt $top+$height
      $rgb=$null
      if ($inside) { $color=$bitmap.GetPixel($x-$left,$y-$top); $rgb=@([int]$color.R,[int]$color.G,[int]$color.B) }
      $nativeHitMatches=$hit.RootHwnd -eq $sample.expectedRoot
      $underlayColorMatches=$sample.name -in @('input','button') -or ($inside -and ($rgb -join ',') -eq '17,73,109')
      if (-not $nativeHitMatches -or -not $underlayColorMatches) { $failures.Add("$Phase $($sample.name): unexpected native HWND or underlay pixels") }
      @{name=$sample.name; x=$x; y=$y; screenPointValid=$inside; pixel=$rgb; expectedRoot=$sample.expectedRoot; hit=$hit; nativeHitMatches=$nativeHitMatches; underlayColorMatches=$underlayColorMatches}
    })
    $result=@{phase=$Phase; utc=[DateTime]::UtcNow.ToString('o'); windows=$windows; senderFrameInsets=$frameInsets; desktop=@{left=$left;top=$top;width=$width;height=$height}; samples=$points}
    Write-Json ($Phase + '-native.json') $result
    $phases.Add($result)
    return $senderWindow
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

try {
  # GHA 的新账户不应包含正式版或试用版的已有配置。
  # 不读取、复制或删除已有 config.json，尤其不能访问登录 Cookie。
  foreach ($identifier in @('com.bilidanmu.app','com.neilsun1225.bilidanmu.sender-preview')) {
    if (Test-Path -LiteralPath (Join-Path $env:APPDATA ($identifier + '\config.json'))) { throw "Existing application configuration detected for $identifier; refusing an unisolated run." }
  }
  if (Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($ExePath)) -ErrorAction SilentlyContinue) { throw 'An application process already exists; refusing to share its state.' }
  if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { throw "Debug port $Port is already occupied." }
  [IO.Directory]::CreateDirectory($scratch) | Out-Null
  $dependencyPrefix=Join-Path $scratch 'dependencies'
  & npm.cmd install --prefix $dependencyPrefix --no-package-lock --ignore-scripts --no-audit --no-fund 'playwright-core@1.64.1' *> (Join-Path $OutputDir 'npm-install.log')
  if ($LASTEXITCODE -ne 0) { throw 'The pinned temporary playwright-core installation failed.' }
  Write-Json 'run-metadata.json' @{kind='actual-release-webview2';startedAt=$startTime.ToString('o');exe=$ExePath;sha256=(Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash;playwrightCore='1.64.1';port=$Port;ciOnly=$true;noRoomConnection=$true}

  $backgroundProcess=Start-Child (Get-Command pwsh.exe).Source @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-BackgroundOnly','-OutputDir',$OutputDir) 'background'
  $deadline=[DateTime]::UtcNow.AddSeconds(20)
  while (-not (Test-Path -LiteralPath (Join-Path $OutputDir 'background-ready.json'))) {
    if ($backgroundProcess.Process.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'The independent WinForms underlay did not start; an interactive desktop is required.' }
    Start-Sleep -Milliseconds 100
  }
  $underlay=Get-Content -LiteralPath (Join-Path $OutputDir 'background-ready.json') -Raw | ConvertFrom-Json
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--remote-debugging-port=$Port --remote-allow-origins=*"
  $env:WEBVIEW2_USER_DATA_FOLDER=Join-Path $scratch 'webview2-data'
  # WebView2 在当前运行器中忽略附加参数环境变量；使用 Microsoft 文档支持的应用专属策略。
  if ((Get-ItemProperty -LiteralPath $debugPolicy -Name $debugPolicyName -ErrorAction SilentlyContinue)) {
    throw 'An app-specific WebView2 debugging policy already exists; refusing to overwrite it.'
  }
  New-Item -Path $debugPolicy -Force | Out-Null
  New-ItemProperty -LiteralPath $debugPolicy -Name $debugPolicyName -Value $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -PropertyType String | Out-Null
  $debugPolicyCreated=$true
  $appInfo=[Diagnostics.ProcessStartInfo]::new()
  $appInfo.FileName=$ExePath
  $appInfo.UseShellExecute=$false
  $appInfo.Environment['WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS']=$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
  $appInfo.Environment['WEBVIEW2_USER_DATA_FOLDER']=$env:WEBVIEW2_USER_DATA_FOLDER
  $appProcess=[Diagnostics.Process]::Start($appInfo)
  $nodeProcess=Start-Child (Get-Command node.exe).Source @($nodeScript,'--output',$OutputDir,'--prefix',$dependencyPrefix,'--port',[string]$Port,'--timeout','150000') 'node'
  $deadline=[DateTime]::UtcNow.AddSeconds(100)
  while (-not (Test-Path -LiteralPath (Join-Path $OutputDir 'phase-before.json'))) {
    if ($nodeProcess.Process.HasExited -or $appProcess.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'The actual WebView2 inspection did not reach its native capture phase.' }
    Start-Sleep -Milliseconds 100
  }
  $before=Get-Content -LiteralPath (Join-Path $OutputDir 'phase-before.json') -Raw | ConvertFrom-Json
  if (-not $before.sender.ok) { throw 'The actual sender DOM could not be measured.' }
  $mainWindow=@([SmokeNative]::Windows([uint32]$appProcess.Id)) | Where-Object { $_.Title -eq 'bili-danmu' -and $_.RootHwnd -eq $_.Hwnd } | Select-Object -First 1
  if (-not $mainWindow) { throw 'The actual native settings HWND was not found.' }
  [SmokeNative]::ShowWindow([IntPtr]$mainWindow.Hwnd,0) | Out-Null
  [SmokeNative]::SetCursorPos(10,10) | Out-Null
  Start-Sleep -Milliseconds 300
  $senderWindow=Capture-Native 'before-click' $before.sender.value ([long]$underlay.Hwnd)
  $focusDeadline=[DateTime]::UtcNow.AddSeconds(15)
  while (-not (Test-Path -LiteralPath (Join-Path $OutputDir 'focus-fixture-ready.json'))) {
    if ($nodeProcess.Process.HasExited -or [DateTime]::UtcNow -gt $focusDeadline) { throw 'The input focus fixture did not become ready.' }
    Start-Sleep -Milliseconds 100
  }
  $inputRect=$before.sender.value.input; $scale=[double]$before.sender.value.devicePixelRatio
  $inputX=$senderWindow.ClientOrigin.X+[int][Math]::Round(($inputRect.left+$inputRect.right)/2*$scale)
  $inputY=$senderWindow.ClientOrigin.Y+[int][Math]::Round(($inputRect.top+$inputRect.bottom)/2*$scale)
  [SmokeNative]::SetForegroundWindow([IntPtr]$senderWindow.Hwnd) | Out-Null
  $focusSent=[SmokeNative]::Click($inputX,$inputY)
  Write-Json 'native-input-focus.json' @{method='Win32 SendInput';x=$inputX;y=$inputY;eventsSent=$focusSent;senderHwnd=$senderWindow.Hwnd}
  if ($focusSent -ne 2) { $failures.Add('Windows SendInput did not accept the input focus click.') }
  Start-Sleep -Milliseconds 350
  Capture-Native 'input-focus-350ms' $before.sender.value ([long]$underlay.Hwnd) | Out-Null
  Start-Sleep -Milliseconds 900
  Capture-Native 'input-focus-1250ms' $before.sender.value ([long]$underlay.Hwnd) | Out-Null
  'input focus captured' | Set-Content -LiteralPath (Join-Path $OutputDir 'input-focused.done') -Encoding utf8
  $focusDeadline=[DateTime]::UtcNow.AddSeconds(15)
  while (-not (Test-Path -LiteralPath (Join-Path $OutputDir 'phase-input-focus.json'))) {
    if ($nodeProcess.Process.HasExited -or [DateTime]::UtcNow -gt $focusDeadline) { throw 'The actual WebView2 input focus was not recorded.' }
    Start-Sleep -Milliseconds 100
  }
  $button=$before.sender.value.button; $scale=[double]$before.sender.value.devicePixelRatio
  $clickX=$senderWindow.ClientOrigin.X+[int][Math]::Round(($button.left+$button.right)/2*$scale)
  $clickY=$senderWindow.ClientOrigin.Y+[int][Math]::Round(($button.top+$button.bottom)/2*$scale)
  $focus=[SmokeNative]::SetForegroundWindow([IntPtr]$senderWindow.Hwnd)
  $sent=[SmokeNative]::Click($clickX,$clickY)
  Write-Json 'native-click.json' @{method='Win32 SendInput';x=$clickX;y=$clickY;eventsSent=$sent;foregroundRequestAccepted=$focus;senderHwnd=$senderWindow.Hwnd}
  if ($sent -ne 2) { $failures.Add('Windows SendInput did not accept both mouse events.') }
  Start-Sleep -Milliseconds 350
  Capture-Native 'after-click-350ms' $before.sender.value ([long]$underlay.Hwnd) | Out-Null
  Start-Sleep -Milliseconds 900
  Capture-Native 'after-click-1250ms' $before.sender.value ([long]$underlay.Hwnd) | Out-Null
  [SmokeNative]::ShowWindow([IntPtr]$mainWindow.Hwnd,4) | Out-Null
  'native capture complete' | Set-Content -LiteralPath (Join-Path $OutputDir 'native-after.done') -Encoding utf8
  if (-not $nodeProcess.Process.WaitForExit(40000)) { throw 'The CDP inspector did not finish after the native click.' }
  if ($nodeProcess.Process.ExitCode -ne 0) { $failures.Add('Actual WebView2/CDP assertions failed; inspect webview2-result.json.') }
} catch {
  $failures.Add($_.Exception.ToString())
  $_ | Out-String | Set-Content -LiteralPath (Join-Path $OutputDir 'launcher-error.log') -Encoding utf8
} finally {
  # CDP 或界面初始化失败时也记录仍存在的窗口，不得用模拟结果替代。
  if ($appProcess -and -not $appProcess.HasExited) {
    # 仅记录本次应用的进程树参数，诊断 WebView2 是否继承了调试端口；不导出环境变量或浏览器数据。
    try {
      $processes=@(Get-CimInstance Win32_Process)
      $owned=[Collections.Generic.HashSet[uint32]]::new()
      $owned.Add([uint32]$appProcess.Id) | Out-Null
      do {
        $changed=$false
        foreach ($process in $processes) {
          if ($owned.Contains([uint32]$process.ParentProcessId) -and $owned.Add([uint32]$process.ProcessId)) { $changed=$true }
        }
      } while ($changed)
      Write-Json 'app-processes.json' @($processes | Where-Object {$owned.Contains([uint32]$_.ProcessId)} | Select-Object ProcessId,ParentProcessId,Name,CommandLine)
    } catch { $failures.Add('Collecting process arguments failed: '+$_.Exception.Message) }
    Write-Json 'final-native-windows.json' @([SmokeNative]::Windows([uint32]$appProcess.Id))
    try { Capture-Desktop 'final-desktop.png' } catch { $failures.Add('Final desktop screenshot failed: ' + $_.Exception.Message) }
  }
  foreach ($child in @($nodeProcess,$backgroundProcess)) {
    if ($child -and -not $child.Process.HasExited) { & taskkill.exe /PID $child.Process.Id /T /F *> $null }
    Save-ChildLogs $child
  }
  if ($appProcess -and -not $appProcess.HasExited) { & taskkill.exe /PID $appProcess.Id /T /F *> $null }
  $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=$oldArguments
  $env:WEBVIEW2_USER_DATA_FOLDER=$oldUserData
  if ($debugPolicyCreated) { Remove-ItemProperty -LiteralPath $debugPolicy -Name $debugPolicyName -ErrorAction SilentlyContinue }
  Write-Json 'native-result.json' @{kind='actual-release-webview2';startedAt=$startTime.ToString('o');finishedAt=[DateTime]::UtcNow.ToString('o');passed=($failures.Count -eq 0);errors=$failures.ToArray();phases=$phases.ToArray();validationLimit='CI Windows desktop with real WebView2; physical game and OBS acceptance remain separate.'}
  # 浏览器数据和临时依赖不在产物目录内，绝不复制到交付包。
  if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($failures.Count -gt 0) { Write-Error ('Actual Windows WebView2 smoke failed. See ' + $OutputDir); exit 1 }
Write-Host ('Actual Windows WebView2 smoke passed. Artifacts: ' + $OutputDir)
