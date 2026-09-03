# 上游实现逻辑比对审计

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
  `error.AlreadyStarted`，消除与分发路径的数据竞争。运行期绑定 + `ADD_ID`
  仍是独立的功能缺口。

### B8. Firefox 默认参数 `-purgecaches` 已被上游确认为 bug 并移除

- 位置：`src/browser.zig:283`。
- 说明：我们从钉住版本复刻了该默认参数。上游 HEAD `52f9e75`
  （“Fix Firefox purgecaches”, 2026-08-14）已把它从 Firefox 启动参数中去掉。
  跟随上游移除即可。
- 修复：已移除该默认参数，Firefox 默认不再附加任何参数，与上游 HEAD 一致。

## 次要偏差（可接受，但应知情或在文档中声明）

- **call id 回绕碰撞**（`src/bridge.js:187`）：id 在 65536 次调用后回绕，如果
  旧调用仍未完成，`pending.set` 会覆盖旧 promise，使其永不 settle。上游用递减
  的 16 位 id，同类问题。低概率，可在回绕时跳过仍挂起的 id。
- **无 keepalive ping**：上游 bridge 每 20s 发 'ping' 文本帧并开启 civetweb
  ping-pong。回环场景无影响；`public` + TLS 场景中间设备（反向代理/NAT）会
  掐空闲连接。注意我们的 `onMessage` 会对文本帧直接断连
  （`src/app.zig:2788`），实现 ping 时需要同时改服务器侧。
- **无断线重连与断线提示**：上游 `#wsStayAlive` 每 500ms 重连并显示警告条；
  我们断线后页面静默失联。已在功能缺口清单中，此处仅指出它会放大 B1/B3/B6
  的后果。
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
- 运行时解释（Deno/Node/Bun）：missing runtime/失败回空 200、404 语义、
  text/plain、query 作为第二个 argv、目录 index.ts→index.js 回退。
- cookie 解析、Origin 校验（我们更严：上游 `Access-Control-Allow-Origin: *`
  且不校验 WS Origin）、回环默认监听、TLS 显式配置。
- 目录监视重载广播、favicon 注入与服务、`webui_show_client` 的单客户端导航
  语义、托管 profile 路径规则与删除边界。

## 修复记录

B1–B8 已全部修复（2026-08-22）：`zig build test` 通过（含扩展后的
`bridge.test.js` 与新增的 cookie 锁定、运行期 bind 拒绝测试），五个门禁
目标交叉编译通过，x86_64-windows 测试模块编译通过。次要偏差清单保持
未处理，留待后续决策。
