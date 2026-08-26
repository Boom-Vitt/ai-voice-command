# Text Injection: Getting Transcribed Text Into the Focused App

**Build-actionable technical brief — macOS + Windows**

Sourcing rule used throughout: every load-bearing claim carries a URL that was actually
fetched during this research, or a verbatim quote from an SDK header on this machine
(macOS 15 SDK, `/Applications/Xcode.app/.../MacOSX.sdk`). Anything not verified that way is
prefixed `UNVERIFIED:`.

*(macOS §1–§5 pending merge from parallel research; Windows and cross-cutting sections complete.)*

---

## 0. The decision rule (read this first)

Everything below is evidence for this table.

| App class | Primary approach | Why | Fallback |
|---|---|---|---|
| Native macOS text controls (NSTextField/NSTextView, TextEdit, Notes, Mail) | AX: set `kAXSelectedTextAttribute` on the focused element | Inserts at caret, no clipboard, no keystrokes, no undo spam | Clipboard paste |
| macOS Electron/Chromium (VS Code, Slack, Discord, Notion) | Clipboard paste (⌘V) | AX tree not built until `AXManualAccessibility`/`AXEnhancedUserInterface` is set, and setting it is itself broken ([electron#37465](https://github.com/electron/electron/issues/37465)) | Synthetic Unicode keystrokes, slowly |
| macOS terminals (Terminal, iTerm2, Ghostty, Warp) | Clipboard paste, but detect Secure Keyboard Entry first | Terminals opt into `EnableSecureEventInput`; taps die | Refuse + tell user |
| Windows standard controls / most apps | `SendInput` + `KEYEVENTF_UNICODE` | Microsoft explicitly blesses this for voice recognition | Clipboard + Ctrl+V |
| Windows large payloads (>~200 chars) | Clipboard + Ctrl+V | SendInput is 2 INPUT events per UTF-16 unit; latency scales | — |
| Windows elevated windows (admin CMD, Task Manager, regedit) | **Nothing works** | UIPI blocks SendInput *silently* | Detect + tell user |
| Any secure/password field (both OSes) | **Refuse** | macOS kills event taps; injecting into a password field is user-hostile | Detect + tell user |
| Games / anti-cheat | **Don't** | Injected input is flagged (`LLKHF_INJECTED`) | — |
| Figma canvas, WebGL, remote desktop | Synthetic keystrokes only | No text element exists to target | — |

**The meta-rule every shipping app converges on:** try the structured API (AX / UIA
ValuePattern), fall back to clipboard paste, fall back to synthetic keystrokes. Clipboard is
the workhorse, not the fallback of last resort — it is the only method with near-universal
coverage, and its problems (pollution, races) are *manageable*, whereas AX's problems
(unsupported, silently wrong) are not.

---

## 6. Windows: injection approaches

### 6.1 `SendInput` + `KEYEVENTF_UNICODE` — the default

Verified signature ([Learn: SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)):

```cpp
UINT SendInput(UINT cInputs, LPINPUT pInputs, int cbSize);
```

`KEYBDINPUT` ([Learn: KEYBDINPUT](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput)):

```cpp
typedef struct tagKEYBDINPUT {
  WORD wVk; WORD wScan; DWORD dwFlags; DWORD time; ULONG_PTR dwExtraInfo;
} KEYBDINPUT;
```

Microsoft **explicitly endorses this exact use case**:

> "INPUT_KEYBOARD supports nonkeyboard-input methods—such as handwriting recognition or
> voice recognition—as if it were text input by using the KEYEVENTF_UNICODE flag."

The mechanics, verbatim from the same page:

- `wVk`: "If the **dwFlags** member specifies **KEYEVENTF_UNICODE**, **wVk** must be 0."
- `wScan`: "If **dwFlags** specifies **KEYEVENTF_UNICODE**, **wScan** specifies a Unicode
  character which is to be sent to the foreground application."
- `KEYEVENTF_UNICODE` (0x0004): "the system synthesizes a **VK_PACKET** keystroke... This flag
  can only be combined with the **KEYEVENTF_KEYUP** flag."

**Delivery path, and where it breaks.** The doc spells out the chain:

> "SendInput sends a WM_KEYDOWN or WM_KEYUP message to the foreground thread's message queue
> with *wParam* equal to **VK_PACKET**. Once GetMessage or PeekMessage obtains this message,
> passing the message to **TranslateMessage** posts a **WM_CHAR** message with the Unicode
> character originally specified by **wScan**."

This is the single most important failure mode on Windows: **the character only materialises
if the target app calls `TranslateMessage`.** An app with a custom message pump that skips
`TranslateMessage`, or one that reads Raw Input (`WM_INPUT`) instead of the message queue,
receives a `VK_PACKET` keydown carrying no meaningful virtual key and drops the text.

**Surrogate pairs.** `wScan` is a `WORD` — 16 bits — so it carries exactly one UTF-16 code
unit. Emoji and other astral-plane characters require two INPUT events. The doc alludes to
this obliquely:

> "Because the touch keyboard uses the surrogate macros defined in winnls.h to send input to
> the system, a listener on the keyboard event hook must decode input originating from the
> touch keyboard."

`UNVERIFIED:` that sending the two halves as separate `SendInput` calls (rather than one
batched call) causes failures — but batching them in one call is strictly safer given the
ordering guarantee below.

**Ordering guarantee (a real advantage over `keybd_event`):**

> "The **SendInput** function inserts the events in the INPUT structures serially into the
> keyboard or mouse input stream. These events are not interspersed with other keyboard or
> mouse input events inserted either by the user... or by calls to keybd_event, mouse_event,
> or other calls to **SendInput**."

Practical consequence: **batch the whole string into one `SendInput` call.** A per-character
loop invites the user's own typing to interleave mid-word.

**State pollution:**

> "This function does not reset the keyboard's current state. Any keys that are already
> pressed when the function is called might interfere with the events that this function
> generates."

This matters enormously for a hold-a-modifier push-to-talk design: at the moment you inject,
the user may still be holding Right-Alt. Injecting `KEYEVENTF_UNICODE` while Alt is physically
down can produce menu accelerators instead of text. **Wait for the modifier's key-up before
injecting, or synthesise key-ups for the held modifiers first** (the doc's own advice is to
"check the keyboard's state with the GetAsyncKeyState function and correct as necessary").

### 6.2 `WM_CHAR` / `PostMessage` direct to the HWND

Works only for apps using the standard Win32 message loop with a real child-window text
control. Fails for: Chromium/Electron (single HWND, internal routing), Java/Swing, WPF and
WinUI (single top-level HWND, no per-control HWNDs), games, anything Direct-Composition based.
Also bypasses IME state entirely. **Not viable as a general strategy** — it's a per-app hack.

Note UIPI blocks this too (see §7.1): posting messages across integrity levels is exactly what
UIPI was built to stop.

### 6.3 UI Automation — read-only for text, whole-value-only for writes

This is the most commonly-misunderstood part of the Windows story, so it's worth being precise.

**`IUIAutomationTextPattern` has no write method.** Fetched the interface page
([Learn: IUIAutomationTextPattern](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nn-uiautomationclient-iuiautomationtextpattern));
the complete method list is:

| Method | Purpose |
|---|---|
| `get_DocumentRange` | Retrieves a text range enclosing the main text |
| `get_SupportedTextSelection` | Type of text selection supported |
| `GetSelection` | Currently selected text ranges |
| `GetVisibleRanges` | Visible text ranges |
| `RangeFromChild` | Range enclosing a child element |
| `RangeFromPoint` | Degenerate range nearest a screen point |

Every one is a getter. **TextPattern is for reading and for locating the caret — never for
writing.** Use it to answer "what is selected / where is the insertion point / what's the
bounding rect of the caret" (useful for HUD placement, §9b), then inject by another means.

**`IUIAutomationValuePattern::SetValue` writes, but replaces everything.** Verified signature
([Learn: SetValue](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationvaluepattern-setvalue)):

```cpp
HRESULT SetValue([in] BSTR val);
```

> "The CurrentIsEnabled property must be **TRUE**, and the
> IUIAutomationValuePattern::CurrentIsReadOnly property must be **FALSE**."

It takes a single BSTR for the element's entire value. There is no offset, no range, no
insert-at-caret. Using it means **read the current value, splice your text in at the caret
offset you got from TextPattern, write the whole thing back** — which destroys the caret
position, blows away the undo stack in most controls, and races against the user typing.

Decision: **UIA is a read path, not a write path.** Use it to identify the target and find the
caret; inject with SendInput or clipboard.

### 6.4 Clipboard + Ctrl+V

Standard sequence: `OpenClipboard` → `EmptyClipboard` → `SetClipboardData(CF_UNICODETEXT, h)`
→ `CloseClipboard` → `SendInput` Ctrl+V → restore.

**`OpenClipboard` fails when another process holds it.** The clipboard is a single global
resource with an owner; clipboard managers, Office, and browsers grab it constantly. The
standard mitigation is a bounded retry loop with a short sleep. `UNVERIFIED:` specific retry
counts/delays used by shipping apps — pick something like 5 attempts × 20 ms and surface a
failure rather than hanging.

**Clipboard-history pollution has a real, documented fix.** This is the single most valuable
Windows-specific finding in this brief, and most implementations miss it. From
[Learn: Clipboard Formats](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats),
verbatim:

> - **ExcludeClipboardContentFromMonitorProcessing**: Place any data on the clipboard in this
>   format to prevent all clipboard formats being included in the clipboard history or
>   synchronized to the user's other devices.
> - **CanIncludeInClipboardHistory**: Place a serialized **DWORD** value of zero on the
>   clipboard in this format to prevent all clipboard formats being included in the clipboard
>   history, or place a value of one instead to explicitly request that the clipboard item be
>   included in the clipboard history. This does not affect synchronization to the user's
>   other devices.
> - **CanUploadToCloudClipboard**: Place a serialized **DWORD** value of zero on the clipboard
>   in this format to prevent all clipboard formats being synchronized to the user's other
>   devices, or place a value of one instead...

> "As with other registered clipboard formats, you will need to use the
> **RegisterClipboardFormat** function to obtain an unsigned integer value that identifies
> each of the above 3 formats."

**Do this on every paste-injection.** Register all three formats at startup; set
`ExcludeClipboardContentFromMonitorProcessing` (plus the two DWORD-zero formats for
belt-and-braces) alongside `CF_UNICODETEXT`. It keeps dictated text out of Win+V history and
off the user's other devices. This is the same mechanism password managers use (KeePass /
KeePassXC — see [CopyQ security docs](https://copyq.readthedocs.io/en/latest/security.html)).

Note this suppresses the *system* clipboard history. Third-party managers that poll the
clipboard may still capture it; the informal `Clipboard Viewer Ignore` format is honoured by
some but not all ([CopyQ#2282](https://github.com/hluk/CopyQ/issues/2282) reports it not
working there).

### 6.5 TSF (Text Services Framework) — what Windows' own dictation uses

**This is how Win+H Voice Typing actually works**, and it's the highest-fidelity route on
Windows. Primary evidence from a terminal emulator that *doesn't* support it
([wezterm#7791, "Windows: Win+H voice typing produces no input (no TSF text store)"](https://github.com/wezterm/wezterm/issues/7791)):

> "Windows voice typing delivers recognised text via TSF — `ITextStoreACP::InsertTextAtSelection`
> on the focused window's registered text store."

And why WezTerm drops it:

> WezTerm's Windows implementation "uses IMM32 exclusively (`ImmGetContext`,
> `WM_IME_COMPOSITION`, etc.); no `ITextStoreACP` / `ITfThreadMgr` / `ITfDocumentMgr` is
> registered with the thread manager, so Windows has nowhere to deliver the recognised text
> and drops it silently."

Apps where Win+H works, per that issue: **Notepad, Microsoft Terminal, VS Code integrated
terminal.** Where it fails: **WezTerm** (and by extension any IMM32-only or custom-input app).

**Should you write a TSF TIP?** The trade-off:

- *For:* it is the officially-sanctioned text-insertion channel, it composes correctly with
  IMEs, it inserts at the caret without touching the clipboard or the keyboard state, and it
  is what Microsoft's own dictation uses.
- *Against:* a TIP is an **in-process COM server that gets loaded into every application's
  process**. That means: a crash in your code crashes the user's app; you inherit each host
  app's threading model; you must be registered system-wide and signed; debugging is
  miserable; and antivirus/EDR treats "DLL that loads into every process and sees all
  keystrokes" with suspicion. It also does not solve the elevated-window problem.
- *And critically:* the wezterm issue proves **TSF coverage is not universal either.** You'd
  be swapping one set of unsupported apps for another.

Decision: **Do not ship a TIP for v1.** SendInput+clipboard covers more apps for vastly less
risk. Revisit only if you need correct IME co-existence or streaming composition (§10).

---

## 7. Windows failure modes

### 7.1 UIPI / elevated windows — the silent killer

This is the most important Windows failure mode because **it fails without telling you**.
From [Learn: SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput), verbatim:

> "This function is subject to UIPI. Applications are permitted to inject input only into
> applications that are at an equal or lesser integrity level."

> "This function fails when it is blocked by UIPI. Note that neither GetLastError nor the
> return value will indicate the failure was caused by UIPI blocking."

Read that twice. `SendInput` returns a success-looking count and `GetLastError` is clean, yet
nothing was typed. **You cannot detect this from the SendInput result.** You must detect it
*ahead of time* by comparing integrity levels: `GetForegroundWindow` →
`GetWindowThreadProcessId` → `OpenProcess` → `GetTokenInformation(TokenIntegrityLevel)` and
compare against your own. If the target is higher, show "can't type into elevated windows"
rather than silently doing nothing.

Background, from [Learn: UAC — only elevate UIAccess applications installed in secure locations](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/security-policy-settings/user-account-control-only-elevate-uiaccess-applications-that-are-installed-in-secure-locations):

> "User Interface Privilege Isolation (UIPI) implements restrictions in the Windows subsystem
> that prevent lower-privilege applications from sending messages or installing hooks in
> higher-privilege processes. Higher-privilege applications are permitted to send messages to
> lower-privilege processes."

**Does the clipboard route escape UIPI? No.** The paste still requires synthesising Ctrl+V into
the elevated window, and that's SendInput, which UIPI blocks. Setting the clipboard succeeds;
the paste doesn't happen.

**`uiAccess=true` is the sanctioned escape hatch — and it's expensive.** Same page, verbatim
on what it grants:

> A process that's started with UIAccess rights has the following abilities:
> - Set the foreground window.
> - Drive any application window by using the SendInput function.
> - Use read input for all integrity levels by using low-level hooks, raw input, GetKeyState,
>   GetAsyncKeyState, and GetKeyboardInput.
> - Set journal hooks.
> - Use AttachThreadInput to attach a thread to a higher integrity input queue.

The requirements, verbatim:

> 1. The application must have a digital signature that can be verified by using a digital
>    certificate that is associated with the Trusted Root Certification Authorities store on
>    the local device
> 2. The application must be installed in a local folder that is writeable only by
>    administrators, such as the Program Files directory.

> "Windows enforces a PKI signature check on any interactive application that requests running
> with a UIAccess integrity level, regardless of the state of this security setting."

Allowed directories: `\Program Files\` and subdirs, `\Windows\system32\`, `\Program Files (x86)\`
and subdirs.

**Note the third bullet in the abilities list.** It answers a question that bites every
hotkey-driven app: a *non*-UIAccess process does **not** "read input for all integrity levels"
via low-level hooks. Meaning: **your `WH_KEYBOARD_LL` hotkey hook does not fire while an
elevated window has focus.** The user holds your push-to-talk key over an admin terminal and
nothing happens. UIAccess is the only fix.

Practical consequence for shipping: `uiAccess=true` means a signed binary installed to Program
Files — so **no per-user install, no `%LOCALAPPDATA%` install, no unsigned dev builds.** For a
v1, ship without it and degrade gracefully; add it later as an optional "elevated support"
installer mode.

### 7.2 Secure Desktop

UAC consent prompts, Ctrl+Alt+Del, and the logon screen run on a separate desktop. No hook, no
SendInput, no clipboard reaches it. Nothing to do but not crash.

### 7.3 Per-monitor DPI

Microsoft documents the exact trap for HUD placement, in
[Learn: GetGUIThreadInfo](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getguithreadinfo)
under "DPI Virtualization", verbatim:

> "The coordinates returned in the **rcCaret** rect of the GUITHREADINFO struct are logical
> coordinates in terms of the window associated with the caret. They are not virtualized into
> the mode of the calling thread."

So if you position a HUD at the caret using `rcCaret`, and the target window is on a
different-DPI monitor than your process assumes, **the HUD lands in the wrong place**. Declare
`DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` (via `SetProcessDpiAwarenessContext`, or the
manifest) and convert coordinates explicitly per-monitor. A non-DPI-aware process additionally
gets bitmap-stretched by the system, so the HUD renders blurry on high-DPI displays.

### 7.4 Anti-cheat and games

Games reading Raw Input see injected events, but low-level hooks tag them: `KBDLLHOOKSTRUCT.flags`
carries `LLKHF_INJECTED`, and anti-cheat filters on it. `UNVERIFIED:` the specific behaviour of
individual anti-cheat products. Treat games as out of scope; don't fight this.

### 7.5 Antivirus / EDR

A process that installs `WH_KEYBOARD_LL` **and** calls `SendInput` **and** reads the clipboard
is, behaviourally, a keylogger. `UNVERIFIED:` specific AV vendors flagging specific dictation
apps, but the behavioural signature is unambiguous and code-signing with a reputable EV
certificate is the standard mitigation. Budget for it.

### 7.6 Windows 11 vs Windows 10 — is it required?

**Researched rather than reasoned. Answer: not for text injection. Nothing in §6–§8 requires
Windows 11.** Every API cited above is Windows 2000/Vista/7-era.

Checking the specific hypotheses:

- **WASAPI process loopback** (`ActivateAudioInterfaceAsync` with
  `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK`): minimum supported client is **Windows 10
  build 20348**, not Windows 11. Not a Win11 gate.
  ([Learn: AUDIOCLIENT_ACTIVATION_TYPE](https://learn.microsoft.com/en-us/windows/win32/api/audioclientactivationparams/ne-audioclientactivationparams-audioclient_activation_type),
  [Application loopback capture sample](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/))
  — and note plain microphone capture doesn't need this at all.
- **On-device ML via Windows AI APIs / Phi Silica**: *this* is a genuine Windows 11 gate, and a
  hard one. From [Learn: Get started with Phi Silica](https://learn.microsoft.com/en-us/windows/ai/apis/phi-silica):
  "Phi Silica is optimized for efficiency and performance on Windows Copilot+ PCs (where it
  runs on the NPU) and on non-Copilot+ Windows 11 devices with a supported GPU." GPU path
  additionally requires an Insider build (26300.8553+), a specific Windows App SDK
  version, Developer Mode enabled, and RTX 30-series / RX 9060-series or newer with 6+ GB
  VRAM. It's also a Limited Access Feature requiring an unlock token, and Microsoft has
  announced Phi Silica is **being replaced by Aion Instruct** (Phi Silica removed
  ~November 2026). **Do not build a dictation product on this.**
- **What competitors actually require:** [Wispr Flow system requirements](https://docs.wisprflow.ai/articles/1036674442-supported-devices-and-system-requirements):
  "Windows 10 or Windows 11", "x64 (64-bit) required. ARM-based Windows devices (Windows on
  ARM, Snapdragon) are not supported", macOS 12+.

**Conclusion: target Windows 10 1903+ / x64. If you ever require Windows 11, it will be
because you chose WinUI 3 / an on-device model, not because of injection.** Note the Wispr
Flow data point cuts the other way on ARM — Copilot+ PCs *are* ARM, so an NPU-first strategy
and an x64-only strategy are mutually exclusive.

---

## 8. Windows: global hotkey and hold-to-talk

### 8.1 `RegisterHotKey` cannot do push-to-talk. Period.

Two independent blockers, both verifiable in
[Learn: RegisterHotKey](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey):

**(a) No modifier-only hotkeys.** `fsModifiers` accepts exactly `MOD_ALT` (0x0001),
`MOD_CONTROL` (0x0002), `MOD_SHIFT` (0x0004), `MOD_WIN` (0x0008), `MOD_NOREPEAT` (0x4000). `vk`
is "The virtual-key code of the hot key" and is mandatory. There is no way to express "the
Right-Alt key alone, held" — you must name a non-modifier key.

**(b) No key-up event.** Verbatim: "When a key is pressed, the system looks for a match against
all hot keys. Upon finding a match, the system posts the **WM_HOTKEY** message..." Press only.
There is no `WM_HOTKEY_UP`. Hold-to-talk fundamentally needs the release.

Also note the modifiers are side-agnostic: "Either ALT key must be held down." You can't bind
Right-Alt specifically.

**`RegisterHotKey` is fine for a toggle-style hotkey (Ctrl+Shift+D to start/stop). It is
unusable for the hold-a-modifier pattern.**

### 8.2 `WH_KEYBOARD_LL` — the real answer, with three landmines

From [Learn: LowLevelKeyboardProc](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc):

```c
LRESULT CALLBACK LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam);
```

`wParam` is `WM_KEYDOWN` / `WM_KEYUP` / `WM_SYSKEYDOWN` / `WM_SYSKEYUP`; `lParam` is a
`KBDLLHOOKSTRUCT*`. You get both edges, for any key including modifiers, so you can implement
"Right-Alt down → start recording; Right-Alt up → stop and inject."

Use `VK_RMENU` (Right Alt) / `VK_LMENU`, `VK_RCONTROL` / `VK_LCONTROL`, `VK_RSHIFT` /
`VK_LSHIFT` — the low-level hook reports the sided VKs directly, unlike `RegisterHotKey`.

**Landmine 1 — you must pump messages.** Verbatim:

> "This hook is called in the context of the thread that installed it. The call is made by
> sending a message to the thread that installed the hook. Therefore, the thread that
> installed the hook must have a message loop."

A hook installed on a thread without `GetMessage`/`PeekMessage` never fires. This catches
people embedding it in a worker thread or a Node/Electron addon.

**Landmine 2 — slow callbacks get you silently uninstalled.** Verbatim:

> "The hook procedure should process a message in less time than the data entry specified in
> the **LowLevelHooksTimeout** value in the following registry key: `HKEY_CURRENT_USER\Control
> Panel\Desktop`. The value is in milliseconds. If the hook procedure times out, the system
> passes the message to the next hook. However, **on Windows 7 and later, the hook is silently
> removed without being called. There is no way for the application to know whether the hook
> is removed.**"

> "**Windows 10 version 1709 and later** The maximum timeout value the system allows is 1000
> milliseconds (1 second)."

Your hotkey stops working, permanently, with no error. **Mitigation, which Microsoft states
directly:** "If the application must use low level hooks, it should run the hooks on a
dedicated thread that passes the work off to a worker thread and then immediately returns."
Do exactly that: the hook callback should do nothing but push a timestamped event onto a
lock-free queue and return. Never do audio, IPC, or allocation inside it. Additionally,
**re-install the hook periodically or on a watchdog** since you can't detect removal.

**Landmine 3 — no elevated coverage.** As established in §7.1, a non-UIAccess process cannot
"read input for all integrity levels by using low-level hooks". Your push-to-talk is dead while
an elevated window is focused.

**Also note** (from the same page): "the callback function is called before the asynchronous
state of the key is updated. Consequently, the asynchronous state of the key cannot be
determined by calling GetAsyncKeyState from within the callback function." Track modifier
state yourself from the hook's own event stream; don't query it inside the callback.

### 8.3 Raw Input — Microsoft's own recommendation

From the same Learn page, verbatim:

> "In most cases where the application needs to use low level hooks, it should monitor raw
> input instead. This is because raw input can asynchronously monitor mouse and keyboard
> messages that are targeted for other threads more effectively than low level hooks can."

`RegisterRawInputDevices` with `RIDEV_INPUTSINK` delivers `WM_INPUT` even when unfocused, has
no timeout-removal behaviour, and is not subject to the hook timeout. **Trade-off: Raw Input
cannot swallow the keystroke.** A `WH_KEYBOARD_LL` hook can return non-zero to prevent the key
reaching the focused app; Raw Input is observe-only.

**Decision:** if your push-to-talk key must not also type into the app (e.g. holding Right-Alt
would otherwise trigger AltGr/menu behaviour), you need `WH_KEYBOARD_LL` for its suppression
ability. If you pick a key whose passthrough is harmless, prefer Raw Input for robustness.
A defensible hybrid: Raw Input as the primary detector, `WH_KEYBOARD_LL` only to suppress.

---

## 9. Cross-cutting: knowing where to inject, and not stealing focus

### 9a. macOS: finding the target

Verified against the local SDK headers (`AXAttributeConstants.h`, `AXRoleConstants.h`,
`AXNotificationConstants.h` in `ApplicationServices.framework/Frameworks/HIServices.framework`):

| Constant | String value | Notes |
|---|---|---|
| `kAXFocusedUIElementAttribute` | `"AXFocusedUIElement"` | the target |
| `kAXFocusedApplicationAttribute` | `"AXFocusedApplication"` | from the system-wide element |
| `kAXValueAttribute` | `"AXValue"` | whole field contents |
| `kAXSelectedTextAttribute` | `"AXSelectedText"` | see the writability trap below |
| `kAXSelectedTextRangeAttribute` | `"AXSelectedTextRange"` | `AXValueRef` of type `kAXValueCFRange` |
| `kAXBoundsForRangeParameterizedAttribute` | `"AXBoundsForRange"` | caret rect → HUD placement |
| `kAXStringForRangeParameterizedAttribute` | `"AXStringForRange"` | read surrounding context |
| `kAXTextFieldRole` / `kAXComboBoxRole` / `kAXStaticTextRole` | `"AXTextField"` / `"AXComboBox"` / `"AXStaticText"` | role gating |
| `kAXFocusedUIElementChangedNotification` | `"AXFocusedUIElementChanged"` | observe focus |
| `kAXApplicationActivatedNotification` | `"AXApplicationActivated"` | observe app switch |
| `kAXSelectedTextChangedNotification` | `"AXSelectedTextChanged"` | detect user edits mid-dictation |

**A documentation trap worth knowing about.** The legacy HIServices header says of
`kAXSelectedTextAttribute`, verbatim:

> "The selected text of an editable text element. Value: A CFStringRef with the currently
> selected text of the element. **Writable? No.** Required for all editable text elements."

But the modern AppKit protocol declares it as a **readwrite** property
(`AppKit.framework/Headers/NSAccessibilityProtocols.h:723`):

```objc
@property (nullable, copy) NSString *accessibilitySelectedText API_AVAILABLE(macos(10.10));
```

(compare `kAXSelectedTextRangeAttribute`, which the same legacy header explicitly marks
"Writable? Yes.") So: **the legacy documentation is stale; setting `AXSelectedText` is the
supported insert-at-caret mechanism on modern AppKit**, but because it's per-app opt-in
(`isAccessibilitySelectorAllowed:` exists at line 858 of the same header, letting apps refuse
individual selectors), **you must check the result of `AXUIElementSetAttributeValue` and fall
back.** Never assume it worked.

**The two-write insert-at-caret idiom:** set `kAXSelectedTextRangeAttribute` to a zero-length
range at the desired offset, then set `kAXSelectedTextAttribute` to your string. Setting
`kAXValueAttribute` instead **replaces the entire field** and destroys the caret — only
appropriate for a genuinely empty single-line field.

**AX calls are synchronous IPC and can hang.** `AXUIElementSetMessagingTimeout` exists for
this; the header's discussion of `AXUIElementPerformAction` notes apps "may not return within
the timeout value set by the accessibility API" and that "you may be able to increase the
timeout value." Set a *short* timeout (not a long one) — for a dictation app, an AX query that
takes 500 ms should be abandoned in favour of the clipboard path, not waited on. **Never make
AX calls on the main thread without a timeout.**

### 9b. Windows: finding the target

`GetForegroundWindow` → `GetWindowThreadProcessId` → `GetGUIThreadInfo`. The key property, from
[Learn: GetGUIThreadInfo](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getguithreadinfo),
verbatim:

> "This function succeeds even if the active window is not owned by the calling process."

> "This function is useful for retrieving out-of-context information about a thread. The
> information retrieved is the same as if an application retrieved the information about
> itself."

**So you do not need `AttachThreadInput`** to learn the focused HWND and caret rect. This
matters — `AttachThreadInput` is a deadlock hazard and shares input state in ways that break
the target app.

`GUITHREADINFO` gives you `hwndFocus` (the focused control), `hwndCaret`, and `rcCaret`.

**The race is documented.** Verbatim:

> "The function may not return valid window handles in the GUITHREADINFO structure when called
> to retrieve information for the foreground thread, such as when a window is losing
> activation."

This is precisely the moment your HUD appears. **Capture the target before you show any UI**
(§9c), and treat a null `hwndFocus` as "retry shortly", not "no text field".

Caveat on `rcCaret` for HUD placement, verbatim: "For an edit control, the returned **rcCaret**
rectangle contains the caret plus information on text direction and padding. Thus, it may not
give the correct position of the cursor." The doc gives a five-step font-metrics correction
involving `GetKeyboardLayout`, `CreateFont`, and `GetCharABCWidths`. **This is almost certainly
not worth implementing** — anchor the HUD to a screen corner or the window, not the caret.

Cheaper focus tracking than a UIA event handler: `SetWinEventHook` with `EVENT_OBJECT_FOCUS` /
`EVENT_SYSTEM_FOREGROUND`. `UNVERIFIED:` relative cost, but UIA event handlers are widely
reported to be heavyweight (they marshal cross-process); WinEvent hooks with
`WINEVENT_OUTOFCONTEXT` are the lighter option.

### 9c. The focus-loss bug — the classic

**The bug:** hotkey pressed → HUD window appears → HUD takes focus → target text field loses
focus → transcript injects into nothing, or into your own HUD.

**Rule zero, and it's the one that actually matters:** capture the target *before* showing any
UI. `NSWorkspace.shared.frontmostApplication` (and the AX focused element) / `GetForegroundWindow`
+ `GetGUIThreadInfo` must be read in the hotkey handler, *before* the HUD is created or shown.
Cache the target for the whole dictation session. Everything below is about making the HUD
harmless, but even a perfect HUD can't recover a target you never recorded.

#### macOS: the `NSPanel` recipe

Verified from `AppKit.framework/Headers/NSWindow.h`, verbatim:

> `NSWindowStyleMaskNonactivatingPanel` — "Specifies that a panel that does not activate the
> owning application. Only applicable for `NSPanel` (or a subclass thereof)." (value `1 << 7`)

The full recipe, corroborated by a shipped-app writeup
([Unwait: Building a macOS overlay that never steals focus](https://unwait.ai/blog/macos-overlay-that-never-steals-focus)):

1. **`NSPanel` subclass** (not `NSWindow`) with `NSWindowStyleMaskNonactivatingPanel` in the
   style mask.
2. **Override `canBecomeKeyWindow` → `false`.** Note both `canBecomeKeyWindow` and
   `canBecomeMainWindow` are declared `@property (readonly) BOOL` in `NSWindow.h` (lines
   438–439) — they are *not* settable, you must subclass and override.
3. **`hidesOnDeactivate = false`.** This is the non-obvious one and it's the classic
   second-day bug. Per the Unwait writeup: "NSPanel's default is to hide itself whenever its
   app deactivates." Since a non-activating overlay keeps your app *permanently* inactive, the
   panel vanishes in real use while working perfectly in testing. (`hidesOnDeactivate` verified
   at `NSWindow.h:416`.)
4. **Window level** `NSStatusWindowLevel` (= `kCGStatusWindowLevel`, `NSWindow.h:198`) or
   `NSFloatingWindowLevel`.
5. **Collection behaviour**: `NSWindowCollectionBehaviorCanJoinAllSpaces` (`1 << 0`),
   `...Stationary` (`1 << 4`), and critically `...FullScreenAuxiliary` (`1 << 8`). Per Unwait,
   without `fullScreenAuxiliary` over a full-screen app "your panel simply does not appear over
   them, and there is no error to tell you why." The header confirms: "Windows with this
   collection behavior can be shown with the fullscreen window."
6. **`NSApplicationActivationPolicyAccessory`** (via `setActivationPolicy:`, `NSApplication.h:301`)
   so there's no Dock icon and no menu bar takeover. Note the header's caveat: settable to
   `Accessory` only on 10.9+.
7. `NSPanel` also offers `becomesKeyOnlyIfNeeded` (`NSPanel.h:16`) — useful if the HUD contains
   a text field the user might actually want to type into.

Unwait's acceptance test is a good one to steal: **"typing in the terminal drops zero
characters" while the overlay is displayed and interactive.**

**Electron/Tauri caveat.** If you're not writing native AppKit, `focusable: false` is not
equivalent. [electron#29644 "focusable:false BrowserWindow still makes OSX try to focus it"](https://github.com/electron/electron/issues/29644)
documents macOS trying to focus the window anyway when switching Spaces, producing a
"ping-pong" effect — confirmed across Electron 12 through 27, Intel and ARM. The root cause per
the issue: "Electron knows the window is non-focusable, but macOS does not." Related:
[electron#8649](https://github.com/electron/electron/issues/8649) (windows with `focusable:false`
still stealing focus on `loadURL`), [electron#21459](https://github.com/electron/electron/issues/21459).

For Tauri, [`tauri-nspanel`](https://github.com/ahkohd/tauri-nspanel) converts the Tao `NSWindow`
into a real `NSPanel` and lets you set `NSWindowStyleMaskNonactivatingPanel` — this is the
approach the Unwait writeup used. It is a real, maintained crate. Tauri core has an open request
for native support ([tauri#13034](https://github.com/tauri-apps/tauri/issues/13034)); see also
[tao#414](https://github.com/tauri-apps/tao/issues/414) and
[tauri discussion #9876](https://github.com/orgs/tauri-apps/discussions/9876) ("Application that
doesn't take screen's focus like the mac spotlight app").

**Recommendation: for a dictation HUD, write the panel natively even if the rest of the app is
web-based.** The focus behaviour is the product; don't inherit someone else's bugs on it.

#### Windows: the `WS_EX_NOACTIVATE` recipe

Verified from [Learn: Extended Window Styles](https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles),
verbatim:

> **WS_EX_NOACTIVATE** (0x08000000L): "A top-level window created with this style does not
> become the foreground window when the user clicks it. The system does not bring this window
> to the foreground when the user minimizes or closes the foreground window... The window does
> not appear on the taskbar by default."

> **WS_EX_TOOLWINDOW** (0x00000080L): "A tool window does not appear in the taskbar or in the
> dialog that appears when the user presses ALT+TAB."

> **WS_EX_TOPMOST** (0x00000008L): "The window should be placed above all non-topmost windows
> and should stay above them, even when the window is deactivated. To add or remove this style,
> use the **SetWindowPos** function."

> **WS_EX_LAYERED** (0x00080000L): "The window is a layered window." (Needed for
> transparency/alpha on the HUD.)

Recipe: `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED`, shown with
`ShowWindow(hwnd, SW_SHOWNOACTIVATE)` and positioned via `SetWindowPos(..., HWND_TOPMOST, ...,
SWP_NOACTIVATE)`. If the HUD has clickable controls, handle `WM_MOUSEACTIVATE` and return
`MA_NOACTIVATE` so a click doesn't activate the window.

**Note `WS_EX_TRANSPARENT` is a click-through/painting-order style, not a transparency style** —
per the doc, "The window should not be painted until siblings beneath the window... have been
painted." Use `WS_EX_LAYERED` + `SetLayeredWindowAttributes`/`UpdateLayeredWindow` for actual
alpha.

#### Why you often can't just restore focus afterwards

If focus *is* lost, calling `SetForegroundWindow` to put it back usually fails. From
[Learn: SetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow),
verbatim — a process may set the foreground window only if all of:

> - The calling process belongs to a desktop application, not a UWP app...
> - The foreground process has not disabled calls to SetForegroundWindow by a previous call to
>   the LockSetForegroundWindow function.
> - No menus are active.

**and at least one of:**

> - The foreground lock time-out has expired (see SPI_GETFOREGROUNDLOCKTIMEOUT...).
> - The calling process is the foreground process.
> - The calling process was started by the foreground process.
> - There is currently no foreground window, and thus no foreground process.
> - **The calling process received the last input event.**
> - Either the foreground process or the calling process is being debugged.

> "It is possible for a process to be denied the right to set the foreground window even if it
> meets these conditions."

> "An application cannot force a window to the foreground while the user is working with
> another window. Instead, Windows flashes the taskbar button of the window to notify the
> user."

**The exploitable clause is "The calling process received the last input event."** A hotkey-driven
dictation app *did* receive the last input event (the hotkey), so a `SetForegroundWindow` call
made promptly in the hotkey handler will typically succeed. But this is a short-lived grant —
if the user does anything else first, or too much time passes, it evaporates. **Don't architect
around restoring focus; architect around never losing it.**

---

## 10. Streaming / incremental injection

**Short answer: it's feasible, it's what the premium products sell, and it is materially harder
than batch injection. For v1, buffer and inject once on release.**

### Why streaming is hard

The fundamental problem is that streaming ASR **revises its own history**. Partial hypotheses
change as context arrives — "recognise speech" becomes "wreck a nice beach" and back. So
streaming injection isn't append-only; it's "append, then retract and rewrite." Retraction is
where everything breaks:

1. **Backspace-based correction is unsound.** To retract N characters you send N `VK_BACK` /
   `kVK_Delete` (0x33, verified in HIToolbox `Events.h:269`). But the app may have altered your
   text since you typed it — autocorrect, autocapitalisation, bracket auto-close, markdown list
   continuation — so N is wrong and you eat the user's own text. The user may also have moved
   the caret or clicked elsewhere. **There is no way to verify what you're deleting without an
   AX/UIA read-back**, and the read-back races the deletion.
2. **Undo stack destruction.** Each injected chunk becomes one or more undo steps. After a
   30-second dictation the user's Cmd+Z history is a wall of fragments and their pre-dictation
   state is unreachable. This alone is a common reason to prefer one atomic insert.
3. **Autocomplete / inline suggestions fight you.** VS Code IntelliSense, Copilot ghost text,
   Gmail Smart Compose, and iMessage autocorrect all react to injected characters. Ghost-text
   completions can capture a subsequent Tab/Enter; IntelliSense can swallow characters.
4. **IME interference.** If the user has a Japanese/Chinese/Korean IME active, injected
   characters enter the IME's composition buffer rather than the document, producing garbage.
5. **Reformatting editors.** Slack turns `>` into a blockquote and `:)` into an emoji; markdown
   editors continue lists; code editors auto-indent and auto-close brackets. Your character
   count and the document's diverge immediately.

`UNVERIFIED:` I could not find a first-hand engineering writeup from a shipping dictation app
describing exactly how they reconcile revised partials. The one blog specifically about live
dictation ([Superscribe](https://superscribe.io/blog/2026/03/20/live-dictation-into-any-input-field/))
is marketing — its only technical statement is "The app injects text at the system level, which
is why it reaches fields that paste-based tools miss," which distinguishes keystroke injection
from clipboard paste but says nothing about revision handling. Treat vendor claims about
"streaming" as UX claims, not architectural ones.

### The correct model: IME composition / marked text

Both OSes already have a mechanism designed for exactly this problem — **uncommitted,
underlined text that isn't in the document until committed.** That's what an IME shows while
you're mid-word, and revising it is free because nothing has been committed.

- **macOS**: `NSTextInputClient` — verified in
  `AppKit.framework/Headers/NSTextInputClient.h:45`:
  ```objc
  - (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange
        replacementRange:(NSRange)replacementRange;
  ```
  The header's own description: "The receiver inserts string replacing the content specified by
  replacementRange... When string is an NSString, the receiver is expected to render the marked
  text with distinguishing appearance (i.e. NSTextView renders with -markedTextAttributes)."
  Paired with `unmarkText` (line 49) and `insertText:replacementRange:` (line 37) to commit.
- **Windows**: TSF composition — the same `ITextStoreACP` machinery Win+H uses
  ([wezterm#7791](https://github.com/wezterm/wezterm/issues/7791)).

**The catch: you can only call these if you *are* the input method.** `NSTextInputClient` is a
protocol the *target app* implements; the *IME* calls it. To drive it you must be an installed
input method (macOS InputMethodKit) or a registered TSF TIP (Windows) — with all the costs in
§6.5. And per wezterm#7791, coverage still isn't universal.

This is the honest architectural conclusion: **proper streaming dictation with revision
requires becoming an input method. Everything short of that is a hack with a failure mode.**

### Recommended v1 design

- **Buffer the full utterance; inject once on hotkey release.** One atomic insert = one undo
  step, no revision problem, no backspace arithmetic, no autocomplete fight.
- Show live partial text **in your own HUD** (§9c), not in the target app. The user gets the
  psychological feedback of streaming without any of the correctness cost. This is the
  highest-value/lowest-risk trade in the whole design.
- If you later add true streaming, gate it to an allowlist of apps you've explicitly tested,
  and never enable it when an IME is active.

### A note on Apple's and Microsoft's own dictation

Windows Voice Typing goes through TSF (`ITextStoreACP::InsertTextAtSelection`) — established
above from wezterm#7791. `UNVERIFIED:` the mechanism macOS Dictation uses; Apple does not
document it, and it plausibly uses private interfaces unavailable to third parties. Do not
assume you can match its behaviour.

---

## Appendix A: verified constants and signatures

All verified against the macOS SDK on this machine or the linked Microsoft Learn pages.

**macOS — CoreGraphics** (`CGEvent.h`, `CGEventTypes.h`):
```c
CGEventRef CGEventCreateKeyboardEvent(CGEventSourceRef source, CGKeyCode virtualKey, bool keyDown);
void CGEventKeyboardSetUnicodeString(CGEventRef event, UniCharCount stringLength, const UniChar *unicodeString);
CFMachPortRef CGEventTapCreate(CGEventTapLocation tap, CGEventTapPlacement place,
                               CGEventTapOptions options, CGEventMask eventsOfInterest,
                               CGEventTapCallBack callback, void *userInfo);
```
- `CGEventTapLocation`: `kCGHIDEventTap = 0`, `kCGSessionEventTap`, `kCGAnnotatedSessionEventTap`
- `CGEventTapOptions`: `kCGEventTapOptionDefault = 0` (can modify/consume), `kCGEventTapOptionListenOnly = 1`
- Tap-disable sentinels: `kCGEventTapDisabledByTimeout = 0xFFFFFFFE`, `kCGEventTapDisabledByUserInput = 0xFFFFFFFF`
- `kCGEventFlagMaskSecondaryFn = NX_SECONDARYFNMASK = 0x00800000`

**Apple's own warning about synthetic Unicode**, verbatim from `CGEvent.h` lines 200–203 — the
most important two sentences in this appendix:

> "By default, the system translates the virtual key code in a keyboard event into a Unicode
> string based on the keyboard ID in the event source. This function allows you to manually
> override this string. Note that **application frameworks may ignore the Unicode string in a
> keyboard event and do their own translation based on the virtual keycode and perceived event
> state.**"

That is Apple stating outright that `CGEventKeyboardSetUnicodeString` is best-effort. It is the
root cause of "my app types the wrong characters in $APP" bug reports, and the reason the
clipboard path exists.

**macOS — virtual keycodes** (`HIToolbox.framework/Headers/Events.h`), relevant to
modifier-only push-to-talk and to correction:
| Constant | Value | Line |
|---|---|---|
| `kVK_ANSI_V` | 0x09 | 206 |
| `kVK_Delete` | 0x33 | 269 |
| `kVK_RightCommand` | 0x36 | 276 |
| `kVK_Command` | 0x37 | 271 |
| `kVK_Shift` | 0x38 | 272 |
| `kVK_Option` | 0x3A | 274 |
| `kVK_Control` | 0x3B | 275 |
| `kVK_RightShift` | 0x3C | 277 |
| **`kVK_RightOption`** | **0x3D (61)** | 278 |
| `kVK_RightControl` | 0x3E | 279 |
| **`kVK_Function`** | **0x3F (63)** | 280 |

**macOS — device-dependent modifier masks** (`IOKit.framework/Headers/hidsystem/IOLLEvent.h`),
required to distinguish left from right modifiers — the plain `kCGEventFlagMaskAlternate` does
*not* tell you which Option key:
| Constant | Value | Line |
|---|---|---|
| `NX_DEVICELCTLKEYMASK` | 0x00000001 | 253 |
| `NX_DEVICELSHIFTKEYMASK` | 0x00000002 | 254 |
| `NX_DEVICERSHIFTKEYMASK` | 0x00000004 | 255 |
| `NX_DEVICELCMDKEYMASK` | 0x00000008 | 256 |
| `NX_DEVICERCMDKEYMASK` | 0x00000010 | 257 |
| **`NX_DEVICELALTKEYMASK`** | **0x00000020** | 258 |
| **`NX_DEVICERALTKEYMASK`** | **0x00000040** | 259 |
| `NX_DEVICERCTLKEYMASK` | 0x00002000 | 261 |
| `NX_SECONDARYFNMASK` | 0x00800000 | 248 |

**macOS — permissions APIs**:
```c
// ApplicationServices/HIServices/AXUIElement.h:64,66
extern Boolean AXIsProcessTrustedWithOptions(CFDictionaryRef options) CF_AVAILABLE_MAC(10_9);
extern CFStringRef kAXTrustedCheckOptionPrompt CF_AVAILABLE_MAC(10_9);
```
Header note on the prompt option, verbatim: "ACFBooleanRef indicating whether the user will be
informed if the current process is untrusted... **Prompting occurs asynchronously and does not
affect the return value.**" (So: call it, get `false`, show your own onboarding UI — don't
expect the return value to change after the prompt.)

```c
// IOKit/hidsystem/IOHIDLib.h:162-177
typedef enum { kIOHIDRequestTypePostEvent, kIOHIDRequestTypeListenEvent } IOHIDRequestType;
typedef enum { kIOHIDAccessTypeGranted, kIOHIDAccessTypeDenied, kIOHIDAccessTypeUnknown } IOHIDAccessType;
```
Header, verbatim — note carefully what these actually govern:
> `kIOHIDRequestTypePostEvent`: "Request to post event through **IOHIDPostEvent API**..."
> `kIOHIDRequestTypeListenEvent`: "Request to listen to event through **IOHIDManager/IOHIDDevice
> API**..."

Both say "If you do not request access through the IOHIDRequestAccess call, the request will be
made on the process's behalf" in the corresponding call. **These describe the IOKit HID APIs,
not `CGEventTap`/`CGEventPost`** — a distinction that causes a lot of confusion about whether
Input Monitoring or Accessibility is the governing permission.

**Windows**: see the inline Learn links in §6–§9; all were fetched during this research.

---

## Appendix B: the secure-input problem (macOS) — read before shipping

`EnableSecureEventInput` is the hardest wall on macOS, and it's worth its own section because
it breaks your app in a way users will blame you for.

From Apple's [Technical Note TN2150: Using Secure Event Input Fairly](https://developer.apple.com/library/archive/technotes/tn2150/_index.html),
verbatim:

> "`EnableSecureEventInput` was implemented in Mac OS X 10.3, to provide a secure means for a
> process to protect keyboard input to a custom data entry field. This function protects
> keyboard entry so that keyboard events cannot be intercepted by a keyboard intercept
> process."

It explicitly names **event taps** as one of the three intercept techniques it defeats:

> "Installation of an event tap as defined in CoreGraphics/CGEvent.h. This method, available
> since Mac OS X 10.4, utilizes an event tap, typically between the HID system driver, and the
> Core Graphics Window Server"

(the other two being `IOHIDDeviceInterface->open` with `kIOHIDOptionsTypeSeizeDevice`, and `GetKeys`).

**It is system-wide and not scoped to the foreground app** — this is the part that surprises
people:

> "The fix for this problem is to stop passing keyboard events to **any** intercept process
> whenever **any** process has enabled secure event input, whether that process is in the
> foreground or background."

> "The system will no longer pass keyboard intercept processes keyboard events if your process
> has enabled secure input even when your process is moved to the background."

**Consequence for your app: while secure input is active anywhere on the system, your global
hotkey stops working.** Not just injection — *capture*. A push-to-talk built on `CGEventTap`
goes completely dead.

**And it gets stuck.** Espanso — a shipping text-expander with the same architecture — documents
this as a top-line troubleshooting item ([Espanso: Secure Input on macOS](https://espanso.org/docs/troubleshooting/secure-input/)):

> "Secure Input usually get 'stuck' when **an application request Secure Input while in the
> background**."

> "The most common cause for Secure Input 'locking' is having a Password Manager activate in
> the background"

Their mitigations are worth copying wholesale: **a status-bar icon that visibly changes when
secure input is detected** ("Espanso stops working and its icon becomes as shown below, it means
Secure Input was activated"), an auto-fix tool, and docs telling users to close/reopen the
password manager or browser.

Terminals opt in deliberately: [ghostty#1325](https://github.com/ghostty-org/ghostty/issues/1325)
tracks adding Secure Keyboard Entry, noting Terminal.app and Kitty enable it on window focus.
So **every time the user focuses a terminal with the setting on, your hotkey dies.**

**Build requirements this implies:**
1. Detect secure input state continuously and **show it in the UI** — never fail silently.
2. Tell the user which process is holding it if you can determine it.
3. Do not attempt to work around it. It is a security boundary, and injecting into password
   fields is exactly what it exists to prevent.
