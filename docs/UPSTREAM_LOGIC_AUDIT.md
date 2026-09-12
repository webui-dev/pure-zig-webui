# 上游实现逻辑比对审计

**最新结论（2026-09-12）：行为 parity 重新打开。** 下文 2026-09-09 的
“完整重写闭环”是当时验收结论；本次重新扫描源码发现它覆盖了 API 名称，
却没有覆盖若干上游实现语义。最新修复、剩余缺口及证据见
[本轮扫描](#2026-09-12-source-rescan)，历史记录保留供追溯。

日期：2026-08-22。
比对基准：上游 WebUI `2.5.0-beta.4`（commit `337a183cea0a9c5daee16acb77eed2d5443bbbb0`，
即 coverage ledger 钉住的版本），同时参考上游 HEAD `52f9e75` 中已合入的修复。
比对对象：`src/app.zig`、`src/browser.zig`、`src/protocol.zig`、`src/bridge.js`
对 上游 `src/webui.c`、`bridge/webui.ts`。

**修复状态：B1–B8 已于 2026-08-22 全部修复**，各条目附修复说明；
行号为审计时的位置，修复后可能偏移。

比对目标是**实现逻辑的正确性**，不要求一比一复刻。API 形态差异、
Zig 化的所有权/错误设计、以及文档中声明过的有意收紧（严格限流、显式错误替代
静默忽略）不算错误。下面只记录行为错误或与上游语义不等价、且未在文档中声明
的地方。

## 确认的逻辑错误

### B1. 页面刷新 / 后端导航会让 `Running.wait()` 直接退出整个应用

- 位置：`src/app.zig:2931`（`onClose` 中最后一个已认证客户端断开即
  `app.closed = true`）、`src/app.zig:2355`（`wait()` 轮询到 `closed` 后调用
  `stop()`）。
- 我们的行为：任何原因导致的 WebSocket 断开——包括 F5 刷新、
  `Window.navigate()`、`Window.setContent()`、`Client.show()` 触发的页面跳转——
  只要瞬间让全应用客户端数归零，`closed` 立即置位。`wait()` 以 10ms 间隔轮询，
  必定在浏览器重新连回来（typically 100ms+）之前调用 `stop()` 关掉服务器。
- 上游行为：`_webui_server_thread`（`webui.c:10920` 附近）区分两种断开：
  `CMD_CLOSE` 主动关闭（`win->is_closed = true`）立即退出；其它断开视为
  “probably the user did a refresh”，等待 `WEBUI_RELOAD_TIMEOUT`（1500ms，
  `webui.c:95`）的重连宽限期，页面刷新和后端导航因此不会终止 `webui_wait()`。
- 后果：README 宣传的运行期内容替换（`setContent`/`Client.show`）和导航广播，
  在调用方使用 `Running.wait()` 时会直接把应用带下线；用户按一次 F5 应用就退出
  （我们也没有上游 release 模式下的 F5 屏蔽）。
- 修复方向：断开后引入重连宽限期，并区分 `.close` 命令引发的断开与其它断开。
- 修复：`Running.wait()` 改为轮询客户端状态：应用曾有客户端且当前为空时，
  非 backend `close` 引发的空窗获得 1500ms 重连宽限期（`reconnect_grace`，
  对应上游 `WEBUI_RELOAD_TIMEOUT`）；`Window.close()` / `Client.close()` 置
  `close_requested` 后立即结束等待。`onClose` 不再直接判定应用关闭。

### B2. 后端发起的导航被我们自己的 bridge 拦截（装有事件处理器时）

- 位置：`src/bridge.js:135`（`CMD_NAVIGATION` 处理直接 `location.href = url`）、
  `src/bridge.js:22`（装有 `onEvent` 时 `allowNavigation` 初始为 false）、
  `src/bridge.js:81-87`（Navigation API 监听器 preventDefault 并把导航回传给
  Zig）。
- 我们的行为：窗口安装了 `Window.onEvent` 时（`__zigWebuiEvents=true`），
  Chromium 的 Navigation API 监听器会拦截**一切**导航，包括后端自己通过
  `Client.navigate` / `Window.navigate` / `Client.show` / `Window.setContent`
  下发的 `CMD_NAVIGATION`：`location.href` 赋值触发 `navigate` 事件 →
  preventDefault → 把它当成用户导航回传给 Zig。若 Zig 事件处理器按 README 的
  说明调用 `Event.client.navigate` 放行，又会触发同样的拦截——无限循环；
  若不放行，后端导航永远不生效。
- 上游行为：bridge 收到 `CMD_NAVIGATION` 不直接改 `location`，而是
  `#close(CMD_NAVIGATION, url)` 关闭 WebSocket，并在 `#wsOnClose` 里先置
  `#allowNavigation = true` 再 `location.replace(url)`（`webui.ts:632-637`），
  显式绕过自家拦截器。
- 后果：Chromium（首选浏览器）+ `onEvent` 的组合下，四个公开 API 的导航
  功能全部失效或死循环。`src/bridge.test.js` 里 mock 的 `location` 不会再触发
  `navigate` 事件，所以现有测试测不出来。
- 附注：目录监视下发的 `location.reload()` 同样会被拦截，但上游在
  AllEvents 模式下有同样的问题，属于等价行为，不单独计为错误。
- 修复方向：`CMD_NAVIGATION`（以及 close 前的跳转）先置 `allowNavigation = true`
  或设置一次性放行标记，再执行跳转。
- 修复：bridge 的 `CMD_NAVIGATION` 处理在跳转前置 `allowNavigation = true`，
  后端导航不再被自家 navigate 监听器拦截；`bridge.test.js` 增加了对应断言。

### B3. 点击 `id=""` 的元素会杀死 WebSocket 连接

- 位置：`src/bridge.js:66`（不过滤空 id 就发送 CLICK）、
  `src/protocol.zig` `decodeEventText`（空文本返回 `error.InvalidPacket`）、
  `src/app.zig:2890` 附近（解析失败即 `wsClose(.protocol_error)`）。
- 我们的行为：`closest("[id]")` 会匹配 `id=""`（属性存在即匹配），bridge 把空
  字符串作为 CLICK 载荷发出，服务器把它判为非法协议包并关闭整条连接，页面
  从此失联（bridge 无重连）。
- 上游行为：bridge 侧只在 `elem !== ''` 时才构造 CLICK 包
  （`webui.ts:388` 附近的 `#sendClick`）；C 侧对空 element 也只是照常分发事件。
- 相关：`src/app.zig:2887` 对超过 `max_event_size`（默认 8KB）的 CLICK/
  NAVIGATION 载荷同样直接断连。一个超长 `href`（如 data: URL）就能杀掉连接。
  对不可信输入断连是防御策略，但这两类载荷是我们自己的 bridge 从正常页面内容
  生成的，应在 bridge 侧过滤或在服务器侧忽略该事件，而不是断连。
- 修复方向：bridge 过滤空 id 与超长载荷；服务器对事件类载荷的解析失败降级为
  忽略 + 日志。
- 修复：bridge 侧只在 `element.id` 非空时发送 CLICK；服务器侧对空、超长或
  非法的 CLICK/NAVIGATION 载荷改为忽略 + 日志，不再关闭连接。

### B4. `use_cookies` 没有实现上游的“锁定单客户端”语义

- 位置：`src/app.zig:2468`（`setCookie` 给每个请求者都下发同一个窗口级
  cookie）、`src/app.zig:2453`（`cookieAllowed` 只在 WebSocket 升级时校验）。
- 我们的行为：cookie 是窗口级静态值，任何能访问 capability URL 的客户端都会在
  首次 HTTP 响应中自动拿到它，然后通过 WS 校验。它没有区分客户端的能力——
  实际提供的保护约等于零（Origin 校验已经挡掉跨站 WS）。HTTP 内容本身从不
  校验 cookie。
- 上游行为（`webui.c:9900-9935`、`10240-10273`、`10560-10600`）：每个客户端
  生成**唯一** cookie 并登记 client_id；单客户端模式下第一个客户端登记后
  （`cookies_single_set` 置位），后续无已知 cookie 的 HTTP 请求直接 403，
  WS 握手直接拒绝。也就是把窗口锁定给第一个浏览器。upstream 的注释明确说明
  用途是 “block unauthorized access to the window content using a URL”。
- 后果：README/ledger 把该选项描述为 “authorization cookie”，但把 URL 泄露给
  第二个客户端时它不提供上游承诺的封锁。ledger 中该行标记为已完成并不准确。
- 附注：上游在设置自定义文件处理器时会自动关闭 use_cookies（安全责任转移，
  `webui.c:971-974`）；我们没有对应逻辑，影响很小，一并记录。
- 修复方向：改为每客户端唯一 cookie + 首客户端锁定，HTTP 与 WS 双侧校验；
  或在文档中如实降级该选项的语义。
- 修复：单客户端窗口（`max_clients == 1`）在首个无 cookie 请求发放 cookie 并
  锁定（`cookie_issued`），之后无 cookie 的内容请求回 `403`，WebSocket 升级
  保持拒绝；多客户端窗口向每个客户端发放 cookie 且不阻断，与上游一致。

### B5. Windows 上 `openUrl` 用 `explorer.exe` 并要求退出码 0，必然报错

- 位置：`src/browser.zig:197`（`.windows => &.{ "explorer.exe", url }`）+
  `commandSucceeds` 要求 `exited == 0`。
- 我们的行为：`explorer.exe <url>` 委托默认浏览器后以退出码 1 结束（Windows
  的固定行为），`commandSucceeds` 返回 false，`openUrl` 返回
  `error.BrowserOpenFailed`——尽管浏览器实际已经打开。`Window.open()` 的
  OS 回退路径同样受影响：打开了页面却向调用方报失败。
- 上游行为：`_webui_open_url_native`（`webui.c:5229`）在 Windows 用
  `ShellExecuteA(NULL, "open", url, ...)`，以返回值 >32 判定成功。
- 后果：Windows 无已知浏览器时的回退路径永远报错。本机（Linux）无法实测
  Windows，结论基于 explorer.exe 的已知退出码行为，修复时应在 Windows 上验证。
- 修复方向：改用 `cmd /c start "" <url>`（注意 argv 转义）或 ShellExecuteW
  绑定，或对 explorer.exe 不检查退出码。
- 修复：Windows 分支改为通过 `ShellExecuteW`（返回值 >32 判定成功）打开
  默认处理器，与上游一致；已通过 x86_64-windows 测试模块交叉编译验证，
  运行行为待 Windows 实机确认。

### B6. 超限的 `webui.call` 载荷直接断连而不是拒绝该次调用

- 位置：`src/app.zig:2849-2851`（`payload.len > max_call_payload_size` →
  `wsClose(.message_too_big)`）。
- 我们的行为：默认 64KB 上限；一次参数过大的 `webui.call()`（例如用户在
  textarea 里粘贴大文本）会关闭整条 WebSocket，所有挂起的 promise 被 reject，
  页面失联且无重连。调用方 JS 无法预知这个上限。
- 上游行为：bridge 侧对 >65500 字节的包自动走 `CMD_MULTI` 分片
  （`webui.ts:346-386`），C 侧重组，单条消息上限 64MB（`webui.c:12`）；
  超限也不会断开连接。
- 后果（修复前）：当时的 `MULTI` 功能缺口导致大参数无法传输，并且超限调用会
  杀掉页面依赖的连接。
- 修复方向（已完成）：先以空响应 + 日志复用上游 “void response 解决 promise”
  的语义（`webui.c:11856-11866`），再实现 `MULTI`。
- 修复：超限、格式非法或超出参数限制的 `CALL_FUNC` 改为回发空响应
  （解除浏览器端 promise，与上游 void response 一致）并记录日志，不再断连。
  2026-09-03 又补齐 `CMD_MULTI`：bridge 对至少 65,500 字节的协议包分片，后端按
  已认证客户端严格校验总长、限额并重组，断开时释放未完成状态。

### B7. 运行期调用 `Window.bind()` / `onEvent()` 与消息分发存在数据竞争

- 位置：`src/app.zig:1623`（`bind` 无锁修改 `state.bindings`，可在 `start()`
  之后调用）、`src/app.zig:630` 附近（`binding()` 在 WS 消息回调里无锁遍历
  同一列表）、`onEvent` 同理（写 `event_binding`，分发路径读）。
- 我们的行为：`bind` 既没有 `started` 检查也没有加锁。服务器运行期间调用它，
  与并发的 CALL/CLICK 分发同时读写 `ArrayList`（append 可能触发重分配）——
  未定义行为。`onEvent` 的文档注释写了 “before starting”，但同样不强制。
- 上游行为：运行期 bind 是受支持的公开能力（`webui_bind` 随时可调，通过
  `CMD_ADD_ID` 推给前端），内部有互斥保护。
- 后果：要么按上游语义支持运行期绑定（加锁 + `ADD_ID`），要么显式拒绝
  （`error.AlreadyStarted`）。当前状态两者都不是，是内存安全缺陷而不只是
  功能缺口。
- 修复方向：短期在 `bind`/`onEvent` 中检查 `started` 并返回错误；长期加锁并
  实现 `ADD_ID`。
- 修复：`WindowState.running` 在 `App.start()`/`Running.stop()` 间置位，
  `Window.bind()` 与 `Window.onEvent()`（签名改为 `!void`）在运行期返回
  `error.AlreadyStarted`，消除与分发路径的数据竞争。2026-09-09 已进一步
  实现 `bind(io, ...)` / `onEvent(io, ...)`、注册表快照、`ADD_ID` 推送和
  认证前重放，不再限制为启动前安装。

### B8. Firefox 默认参数 `-purgecaches` 已被上游确认为 bug 并移除

- 位置：`src/browser.zig:283`。
- 说明：我们从钉住版本复刻了该默认参数。上游 HEAD `52f9e75`
  （“Fix Firefox purgecaches”, 2026-08-14）已把它从 Firefox 启动参数中去掉。
  跟随上游移除即可。
- 修复：已移除该默认参数，Firefox 默认不再附加任何参数，与上游 HEAD 一致。

## 次要偏差（可接受，但应知情或在文档中声明）

- **call id 回绕碰撞（2026-09-09 已修复）**：调用 ID 在 1–65535 之间循环，
  跳过仍挂起的 ID；全部占用时仅拒绝新调用，不发包、不覆盖旧 promise。
  回复、发送失败和断连释放相应挂起状态，不再照搬上游的覆盖行为。
- **keepalive（2026-09-09 已补齐）**：已认证连接每 20s 发精确文本 `ping`，
  Zig 回 `pong`，10s 未收到回复则重连。未认证心跳和其它文本仍被拒绝；
  心跳不干扰正在重组的 `MULTI`。
- **断线恢复（2026-09-09 已补齐）**：传输断开后 500ms 重试，每次重新认证，
  连接/认证期限 5s。未完成调用直接拒绝、不重放；旧连接的消息和异步
  JavaScript 结果不能串到新连接。认证拒绝、协议/策略失败和主动关闭不重试。
  提供可由用户事件回调接管的断线提示。后端 `Running.wait()` 的 1.5s
  宽限期保持不变；重连不会复活已经停止或更换 capability 的后端。
- **`/{capability}`（无尾斜线）返回 404**（`src/app.zig` `route()`）：
  `Window.url()` 生成的 URL 带斜线，正常流程不受影响；手工输入少斜线时上游会
  照常服务。可选：301 重定向。
- **eval 结果超出调用方 buffer 返回 `error.ResultTooLarge`**：上游静默截断到
  用户 buffer。我们的显式错误更好，但属于未在 README 声明的行为差异。
- **未屏蔽 F5 / 右键菜单**：上游 release 模式屏蔽两者。独立看是合理的取舍，
  但在 B1 修复之前，F5 = 应用退出。
- **`--disable-features` 合并**（`src/browser.zig` `disableFeatures`）：上游把
  `--disable-features=Translate` 和 `--disable-features=ForcedColors` 作为两个
  参数传递，Chromium 只保留最后一个——上游自身的 bug。我们合并成一个参数，
  是有意修正，记录在案以免误判为偏差。

## 比对后确认与上游语义等价（或为文档化的有意差异）的区域

- 8 字节协议头、`CALL_FUNC` 载荷格式（fn\0 lens\0 data\0…）、空响应解除
  promise、`CALL_FUNC` 响应为纯字符串无状态字节。
- JS eval 响应格式 `[error][data][0]`、`JS_QUICK` 不回包、`undefined` 序列化、
  超时/断连清理、eval id 唯一性与挂起表。
- `SEND_RAW` 载荷 `fn\0data`、CLICK/NAVIGATION 事件载荷、事件常量
  `CONNECTED:0 / DISCONNECTED:1`。
- Chromium/Firefox 启动参数：kiosk（`--chrome-frame --kiosk` / `-kiosk`）、
  headless、`--window-size/-width -height`、`--window-position`（我们用有符号
  格式，上游 `%u` 反而在负坐标时有 bug）、`--user-data-dir` / `--profile`、
  `--proxy-server`、chromium 默认参数集、`--app=` / `-new-window`。
- Safari/Firefox 不支持项返回显式错误（上游静默忽略）——ledger 已声明。
- 运行时解释的 argv、query 参数和目录 index.ts→index.js 回退语义保持。
  **2026-09-09 有意偏离上游**：解释器不可用返回 503，超时返回 504，
  输出超限或非正常退出返回 502，不再以空 200 掩盖失败，也不向浏览器泄露
  失败进程的部分 stdout 或诊断。成功输出仍为 200 text/plain，静态资源不受影响。
- cookie 解析、Origin 校验（我们更严：上游 `Access-Control-Allow-Origin: *`
  且不校验 WS Origin）、回环默认监听、TLS 显式配置。
- 目录监视重载广播、favicon 注入与服务、`webui_show_client` 的单客户端导航
  语义、托管 profile 路径规则与删除边界。

## 修复记录

B1–B8 已全部修复（2026-08-22）：`zig build test` 通过（含扩展后的
`bridge.test.js` 与新增的 cookie 锁定、运行期 bind 拒绝测试），五个门禁
目标交叉编译通过，x86_64-windows 测试模块编译通过。次要偏差中的 call id
碰撞及运行时失败响应已在 2026-09-09 修正；其余未处理项仍保留。

2026-09-09 验证：运行时定向测试 10/10 通过，bridge 测试 3/3 通过；
`zig build test` 的 Zig 测试 25 通过、8 项受平台限制跳过，`zig build` 通过。
Chromium 经真实 Zig 后端完成 65,536 次调用后仍正确收到原始延迟回复；
实际 HTTP 验证成功 200、解释器缺失 503、异常退出/超限 502 和 30 秒超时
504，失败正文为空且静态资源仍可访问。本轮未重新执行跨平台发布门禁。

随后补齐连接恢复：4 项真实 WebSocket 心跳场景通过，bridge 回归 11/11
通过；`zig build test` 的 Zig 测试 29 通过、8 项平台限制跳过，
`zig build` 通过。Chromium 实测自动 ping/pong、断线拒绝未完成调用、
无需刷新重连、提示条显示/移除、认证拒绝的终止错误、刷新恢复和后端
主动关闭；验证程序最终退出码为 0。未重跑跨平台发布门禁。

## 完整重写核查：核心边界加固

2026-09-09 复查发现并修复以下并非“API 缺失”、但会影响完整实现的错误：

| 问题 | 修复 |
|---|---|
| HTTP 升级按窗口 A 检查 Origin/cookie，CHECK_TOKEN 却可选择 B | 升级时保留已授权窗口身份，协议认证只能匹配该窗口；连接结束必定释放登记。 |
| 解释器检查原始后缀，静态路径再次解码，`secret.%6as` 泄露源码 | 资源路径统一解码/校验一次；Linsang 接收已规范化路径，不再二次解码。 |
| 解释器跟随目录或脚本符号链接 | 逐组件 no-follow 检查并限定普通文件；不把拒绝执行的脚本降级为静态源码响应。 |
| 默认串行处理器阻塞同一连接的 eval 回复 | 单个有界 FIFO worker 执行串行快照，网络接收线程持续处理回复；关闭时取消并清空队列。 |
| 未认证和失联客户端永不释放名额 | 服务端认证绝对期限 5s，已认证空闲期限 25s；容量暂满用可重试的 1013 关闭，不伪装成认证拒绝。 |
| eval 超时未覆盖发送锁和网络写入 | 整个操作使用同一个绝对期限；返回调用方缓冲区前取消并等待失败方清理。 |
| 多窗口共享 Chromium profile，替换先启动后杀旧进程 | 每窗口独立 profile 叶目录；替换先终止并回收旧进程，删除只触及拥有的路径。 |
| 外部跨站页面与 Strict cookie 授权组合无法连接 | 创建、启动及内容替换时明确拒绝该组合，不静默放宽授权。 |

依赖前置修复见 [Linsang PR #3](https://github.com/jinzhongjia/Linsang/pull/3)：
升级请求在 `on_ws_open` 回调期间有效，支持绝对 WebSocket 期限及规范化静态路径。
完整依赖测试还暴露了 TLS 向只读 Reader 密文写入的问题，现使用连接自有
有界明文缓冲，并拒绝不完整 CBC 块。真实原生门禁暴露的默认线程池问题也已
修正：需要竞争/并发执行的网络任务使用 `concurrent`，不依赖 `async` 不内联。
Linux 依赖测试 107/107 通过。

## 原生平台实现核查

三个平台均使用系统 ABI，不编译 WebUI C 或 Objective-C/C++ 包装代码。
单独的 ABI/所有权审查修正了跨窗口关闭派发、GTK 已显示窗口居中、Windows
样式位保留和宿主透明路径，以及 WebKit 关闭通知不能实现提前否决的问题。
JavaScript 关闭请求由 document-start 原生消息桥接处理；否决时页面和连接保持
可用。macOS、Linux 与 Windows 均已完成真实双窗口 smoke；最终 CI 全部通过。

补充修复：复现了超时 eval 的迟到回复在 16 位 ID 回绕后错误完成新请求
（期望 `new` 却得到 `old`）。现在每个执行过 eval 的客户端用 8 KiB 有界
位图隔离仍可能收到迟到回复的 ID；收到旧回复或断连才释放，耗尽明确报错。
对应真实 WebSocket 回归覆盖错误归属、ID 恢复及完全耗尽后的恢复。

最终验收：[CI 34342120131](https://github.com/webui-dev/pure-zig-webui/actions/runs/34342120131)
所有平台任务与五目标交叉构建通过。Linux 核心测试 54/54、桥接测试 15/15；
协议 fuzz 实际执行 101,191 次无失败。Windows 已校验真实页面渲染、初始标题和
OS 关闭路径；本机 macOS 屏幕捕获受限，但其原生窗口与 JavaScript/控制门禁通过。
覆盖账本已关闭实现和验收缺口，实验性/非生产就绪声明仍保留。

## 2026-09-12 Source Rescan

### 基准与方法

重新获取上游源码，HEAD 仍为
[`52f9e75b92faf9a23fd150b3c60051c4ec85fc69`](https://github.com/webui-dev/webui/tree/52f9e75b92faf9a23fd150b3c60051c4ec85fc69)，
并与账本基准 `337a183cea0a9c5daee16acb77eed2d5443bbbb0` 做源码差异比较。
读取 `include/webui.h`、`src/webui.c`、`bridge/webui.ts`、Cocoa/WebView2
适配器，再分别对照本仓库 `app.zig`、`bridge.js`、`browser.zig` 和原生模块。
未编译或链接上游 C。以下上游行号均指上述 HEAD；本仓库以符号名定位。

### 本轮已实现并复现验证

1. **认证中的显式调用等待。** 上游 `bridge/webui.ts:609–619,919–924`
   在 WebSocket OPEN、token 尚未接受时等待绑定列表；这是基准之后新增的
   实现。原桥接直接拒绝。现在 `awaitingAuthentication` 将调用绑定到当前
   socket，成功后才发送；最多 65,535 个等待者，共用既有 5s 认证期限。
   拒绝、超时、断开、pagehide 都取消，不把调用移到替换连接。
   `CONNECTED` 回调重入关闭也不会漏发旧调用。
2. **嵌套点击及后端顺序。** 上游 `bridge/webui.ts:337–345` 给匹配元素
   分别安装点击监听器，因此 DOM 冒泡会经过所有匹配祖先。旧实现只查
   `closest("[id]")`，内层未绑定 ID 会遮住外层绑定。现在沿祖先逐个分发，
   跳过空 ID；运行期绑定仍有效。上游 `webui.c:10456–10489` 先调用 general
   observer 再调用 named binding；`WindowState.invokeEvent` 已改为相同顺序，
   保留同一任务内的注册快照以及 serial/concurrent 调度。
3. **物理目录 index 路由。** 上游 `webui.c:11278–11314,11396–11450`
   按 HTML、HTM、TS、JS 顺序选入口并 302。旧实现只在静态路径补 `index.html`，
   runtime 路径先找 TS/JS；`/docs` 和 HTM-only 目录失败，HTML/TS 并存时会
   错选脚本。新增 `directoryIndex`，先逐组件 no-follow 打开目录，再检查
   普通可读文件；`onRequest` 先重定向，`runtimeScript` 仅处理显式脚本。
   Location 使用原始编码路径并保留 query，避免 `%`、空格、`#`、`?`
   文件名被重新解释。解释器关闭时 TS/JS index 仍可静态服务。
   此项不宣称实现 custom handler 的虚拟 index 或任意配置入口文件。

前置失败证据：新桥接回归分别得到 `WebUI is not connected` 和空点击列表；
后端顺序回归期望 `GB` 却得到 `BG`；目录集成回归未得到预期的 302。
修复后这些场景全部通过。

### 尚未实现或不等价的能力

下表为源码确认的缺口，不宣称已经对每个缺口运行平台复现。
优先级表示建议实现顺序，不是安全严重性。

| 优先级 | 缺口 | 上游具体实现 | 本仓库边界 |
|---|---|---|---|
| P1 | HTML、磁盘资源、自定义覆盖/回退不能组合 | `webui.c:11249–11266,11343–11401` 先 custom，未处理再访问页面/磁盘；`6059–6063` 的 NULL 表示回退 | `Content` 是互斥 union；`onRequest` 的 `.html` 非根路径 404、`.custom` 总是结束请求。更换资源目录还会更换内容并导航。 |
| P1 | 运行期创建、独立销毁窗口 | `webui.c:1270–1333,1583–1670` 允许其它窗口运行时创建/销毁并处理回调内延迟回收 | `App.createWindow` 在 started 时拒绝；`Window.close` 只发协议，`Running.stop`/`App.deinit` 是全局级别。需要稳定句柄和任务/Client/PendingReply 生命周期设计，不能直接 free。 |
| P1 | Firefox 托管 app profile | `webui.c:7249–7321` 创建 profile，写 prefs/userChrome.css 隐藏浏览器 chrome，并设置 high-contrast preference | `browser.managedProfileDirectory` 不支持 Firefox；只转发 caller profile 和 `-new-window`。已声明的显式 high-contrast 错误不是该能力的实现。 |
| P1 | 原生 frameless 的实际拖动与边缘缩放 | GTK `webui.c:12640–12658,14530–14612`；Win32 `14091–14098` 的 resizable 样式；`win32_wv2.cpp:488` draggable regions；`wkwebview.m:217–220` background movement | 本地无 GTK drag/resize 信号或协议实现、WebView2 draggable 配置、Cocoa background movement；Windows frameless style 丢掉 resizable。不是 Wayland absolute-position 限制所能解释。 |
| P2 | 任意本地入口文件、custom index 探测 | `webui.c:10180–10198,11283–11285` 的 `user_index_file`；`5999–6055` 虚拟入口探测 | `.directory` 只能从标准 index 打开，`.custom` 不自动探测；物理目录标准 index 已在本轮修复。 |
| P2 | callback 元信息 | `include/webui.h:205–214`、`webui.c:10447–10454,12913–12923` 带 event_type、element、cookies | `Call` 无公开 name/origin；零参数显式调用与 DOM click 对 named handler 不可区分。`Call`/`Event` 没有 connection cookie 快照。 |
| P2 | 原生标题跟随页面 | GTK `webui.c:14278–14291`；Cocoa `wkwebview.m:114–125`；WebView2 `win32_wv2.cpp:75–89,164–166` | 三个适配器只设 options.title/显式 setTitle，无页面标题通知。需定义显式标题覆盖策略。 |
| P2 | GTK 引擎级导航拦截 | `webui.c:14294–14352` 的 decide-policy 可在无 live bridge 时拦截并区分 backend navigation | 本地 Linux 适配器无 decide-policy 信号；仅靠 bridge 的 Navigation API/链接点击不能完整替代。 |
| P2 | 平台浏览器发现范围 | `webui.c:8430–8480` 区分注册的 Chrome/Chromium；`7872–7877,8319–8322` 使用 macOS 应用解析 | 本地 Windows Chromium 只找 `chromium.exe`；macOS 只查固定 bundle 目录。[INFERENCE] 注册在其它位置的应用可被上游解析而被本地漏掉。显式 executable 只是绕过。 |
| P3 | 默认 favicon | `webui.c:11317–11346` 依次找用户/磁盘/default SVG | 本地只有配置或内容提供的图标；无上游默认图标回退。 |

### 生命周期源码风险，尚未运行复现

- **旧 close intent 影响另一窗口的刷新。** `App.closeRequested` 对所有
  window 的 `close_requested` 做 OR；标记只在启动时复位。
  `Running.wait` 在任意窗口曾请求 close 后都会跳过最后断连的重连宽限期。
  [INFERENCE] 关闭 A 后 B 再刷新可能触发全局停止。上游按窗口处理并在
  重新连接时清 `is_closed`（`webui.c:11956–11960`）。
- **初次无客户端 wait 的完成条件。** `Running.wait` 在 `ever_connected`
  为 false 时始终 continue，也不检查 stopped。上游首连等待有期限
  （`webui.c:11858–11949`）。不应给刻意无头的服务强加期限，但应补齐
  显式停止条件，并把启动等待与服务寿命区分。

### 不应误报为缺口

- 上游 `CALL_FUNC` 实际仅调用 named handler（`webui.c:12923–12963`），
  不会调用所谓 all-events handler。不能仅凭头文件“all events”描述，
  给 `onEvent` 凭空添加 callback 事件。
- C ABI、旧 Zig、自签证书、CivetWeb 和无约束全局数组仍属明确排除项。
  capability 路由、argv 启动、有界任务、严格错误和 stale-client ID 是有意设计。
- 自定义 HTTP handler 的 Request/Response 是借用，返回前可通过 `std.Io`
  await 延迟工作；没有类似 `PendingReply` 的返回后持有型 HTTP reply。
  账本已将该所有权差异写明，不能把 borrowed Response 说成原样替代
  上游 `webui_return_http`。
- F5、右键菜单、release DevTools 的开关是 UI policy 差异；
  不影响协议能力，不在本轮悄悄改变。

### 本轮验证

- `zig build test --summary all`：4/4 步成功，Zig 50/56 通过，六项既有
  Linux-only 平台门禁跳过；Node bridge **18/18**。Deno/Node/Bun 实际执行。
- `zig build --summary all`：13/13 步成功。
- `zig build test-native -Dnative=true --summary all`：macOS WKWebView 实际
  双窗口 smoke 成功，覆盖 bridge、geometry、controls、dispatch、close veto、
  history、多窗口关闭；不是新的 drag/title 缺口验收。
- 真实 Chromium + 临时 Zig 服务：延迟 token ACK，确认 OPEN 未认证时调用
  等待后成功；真实 DOM 嵌套点击依次得到 general→named、inner→outer；
  root HTML 胜过并存 TS；`/docs?name=zig%20ui` 跳到
  `/docs/index.htm?name=zig%20ui`，相对 CSS 被加载且计算颜色正确。
  后端收到结束调用，打印 `SMOKE_PASS` 并以 0 退出。
- 浏览器截图工具超时，因此不声称像素/截图验收；上述结论来自实际页面、
  DOM、网络调用、计算样式和服务退出结果。未重跑 Linux/Windows 原生运行、
  五目标交叉构建或 fuzz；历史门禁不作为本轮新验收。
