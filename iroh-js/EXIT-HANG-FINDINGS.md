# iroh-js: 下游 "exit 144 / SIGTERM at teardown" 排查结论

## 修正(2026-06-28,下游 macOS 复验后)

下游用 `async_hooks` 在全量/子集 vitest 上复验,结论需要分两层,**本文档下半部分
原先把二者合并、过度归因了**,在此更正:

- **绑定层确有的问题(本文档主体,结论仍成立)**:fire-and-forget / 永不 resolve 的
  napi `async` 调用(已确认的实例:`endpoint.online()`)会留下一个 pending 的
  `napi_resolve_deferred`,ref 住 libuv loop;它对 `_getActiveHandles()` 不可见、
  且 **`close()` 取消不掉**。这是值得在 iroh-ffi 侧改进的真实缺陷。
- **但它不必然是某个下游测试套件 exit-144 的主因**:下游的 `noiroh` 子集(完全不加载
  iroh、transport 被 mock、不调用任何 `online()`)**同样 144**,且该子集 worker 里
  `napi_resolve_deferred = 0`。顶住 loop 的是**测试侧普通 Node 句柄泄漏**:大量未清
  `Timeout`、某 worker 高达 **954 个 `FILEHANDLE`**、`DNSCHANNEL`、子进程的
  `PROCESSWRAP/PIPEWRAP`、未关的 `TCPWRAP`。
- **正确结论**:该套件的 144 是"**多源句柄泄漏 → worker 退不掉 → tinypool 收尾
  SIGTERM**"的聚合问题。`online()` 至多是 iroh/relay 那几个 worker 的额外一份泄漏。
  彻底修需要**测试侧清理**(afterEach 关 server/子进程/fd、unref 或清定时器)**+**
  iroh-ffi 侧让 `online()` 不悬挂,两边都做;只改 `online()` 不解决。

下面原始分析对"napi 悬挂 async 如何隐形顶住 loop"的机制描述与复现仍然有效,只是它的
**适用范围**应理解为"绑定层的一类隐患",而非"任意下游 144 的唯一根因"。

---

## TL;DR(绑定层隐患的机制)

下游进程在「测试跑完、准备退出」阶段退不掉,被外层(tinypool / vitest / CI 的
超时)`SIGTERM` 强杀 → `128 + 15 = 144`。

根因**不是**原生线程或 libuv 句柄顶住 event loop,而是:

> **某个 napi `async` 方法的 Promise 被「发起但从不 await / 永不 resolve」,
> 留下一个 pending 的 `napi_resolve_deferred` 异步资源,它 ref 住了 libuv
> event loop,使 Node 永远无法自行 drain 退出。**

这条 ref 有两个特性,正好解释了之前排查的所有困惑:

1. **对 `process._getActiveHandles()` / `_getActiveRequests()` 完全不可见**
   (二者都返回 `[]`)——所以之前 dump 句柄查不到任何东西。
2. 只有**真正加载了原生模块、且留了一个这样的悬挂调用的 worker** 才会触发。
   纯 JS 的未 resolve Promise **不会**顶住 libuv;必须是 napi async 调用。
   这解释了「必须有 iroh worker」以及「哪些测试文件落到同一个 worker」带来的
   规模/组合敏感性(不是真的和『32 个』这个数字有关,而是和『某个会留悬挂
   async 调用的测试是否被调度进一个 iroh worker』有关)。

它**可以**通过 `async_hooks` 看到 —— 表现为一个一直存活的
`napi_resolve_deferred` 资源。这就是在真实测试套件里定位元凶的方法。

## 复现(在 Linux 上即可复现,与平台无关)

```
node test/exit-hang-repro.mjs            # 跑完整 matrix
node test/exit-hang-repro.mjs diagnose   # 用 async_hooks 显示那条隐形 ref
```

matrix 实测结果:

| 场景 | 操作 | 结果 |
|---|---|---|
| `clean-bind-close`    | bind + close                | ✅ exit 0 |
| `clean-bind-noclose`  | bind,不 close              | ✅ exit 0 |
| `hang-online`         | `ep.online()` 不 await      | ❌ HANG → SIGTERM |
| `hang-online-close`   | `ep.online()` 后 `close()`  | ❌ **仍 HANG**(close 取消不了 online) |
| `hang-accept`         | `ep.acceptNext()` 不 await  | ❌ HANG → SIGTERM |
| `ok-accept-close`     | `ep.acceptNext()` 后 close  | ✅ exit 0(close 让 acceptNext resolve) |

`diagnose` 输出:
```
still-alive async resources pinning the loop: {"PROMISE":2,"napi_resolve_deferred":1,"Timeout":1}
```

## 关键细节

- **`endpoint.online()` 最危险**:它等待 home relay,且**不被 `close()` 取消**。
  在 relay-only / 离线 / 拿不到 relay 时它**永不 resolve**,fire-and-forget
  调用会永久顶住进程,即便事后 `close()` 也没用。
- **`endpoint.acceptNext()`** 也会顶住,但 `close()` 能让它 resolve(返回
  `None`)从而释放 loop —— 所以只要每个 endpoint 都被 close,悬挂的 accept
  循环会自然收尾。
- 任何「发起但不结束」的 async 方法(`connection.closed()`、各种 `read*`/
  `accept*`/`stopped()` 等长等待)同理。

## 为什么单进程 / Linux 规模测试不崩

排查中在 Linux 上跑了:单进程各种 bind/close 组合、32 进程并发、
fork+IPC+tinypool 式 SIGTERM terminate —— **全部干净退出**。因为这些路径里
没有留下「永不 resolve 的悬挂 async 调用」。下游的 relay 相关测试里有(最可能
是 `online()` 或一个没被 close 收尾的后台 `acceptNext()`/watch 循环),macOS
上 home relay 行为又和沙箱里(无网络、relay 立即失败)不同,于是只在那边显形。

## 建议的修法(按优先级)

### A. 下游(能立即自验,优先)
1. 用 `node test/exit-hang-repro.mjs diagnose` 同款 `async_hooks` 钩子(或
   `why-is-node-running`)跑一遍全量测试,定位那个一直存活的
   `napi_resolve_deferred`,找到对应的 iroh 调用。
2. 永远不要 fire-and-forget iroh 的 async 方法。对 `online()` 这类:
   `await Promise.race([ep.online(), timeout(ms)])`,或干脆不调用。
3. 每个 `Endpoint` 在测试 teardown 里 `await ep.close()`;后台 `acceptNext()`
   循环要能在 close 后退出。

### B. 绑定层(本仓,需在 macOS 下游复验)
- 给所有「可能无限等待」的 async 方法补文档,明确:必须 await/race,且
  **`online()` 不受 `close()` 取消**。
- 可考虑让 `online()` 等方法响应 `close()`(随 endpoint 关闭而 resolve/reject),
  使悬挂调用在 shutdown 时能释放 loop。需评估 iroh-core 语义。
- 可考虑提供 `Endpoint.close()` 后把内部 endpoint 真正 drop,确保后台任务停。

## 顺带发现的另一个独立 bug(不是 144 的元凶,是 SIGABRT)

所有 `watch_*` 同步方法(`watchAddr` / `watchHomeRelay` /
`watchNetworkChange` / `Connection.watchPaths` / `watchPathEvents`)在函数体里
调用 `n0_future::task::spawn`(= `tokio::spawn`),但同步 `#[napi]` 函数运行在
JS 主线程、**不在 tokio runtime 上下文**,于是 panic:

```
thread '<unnamed>' panicked at iroh-js/src/watch.rs:50:16:
there is no reactor running, must be called from the context of a Tokio 1.x runtime
fatal runtime error: failed to initiate panic, error 5, aborting
```

→ 进程 **abort(SIGABRT / exit 134)**。任何调用这些 `watch*` 的代码都会直接崩。
修法:在这些方法里用 napi 的 runtime handle 来 spawn(`napi::tokio::spawn` /
`tokio_runtime::spawn`),或把它们改成 `async fn` 以进入 runtime 上下文。
(下游目前没报 134,说明暂未用到 watch,但这是真实缺陷。)
