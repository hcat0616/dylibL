# SubDump

从 **Apps Connect**（`uk.skynet.ios`）里导出你自己账号的订阅链接，方便填到 Loon / Stash / Shadowrocket 等客户端。

> 只读取本机已有数据 + 观测本机网络请求，**不修改任何业务逻辑、不伪造登录态、不绕过订阅校验**。
> 拿到的链接等同于账号凭证，请勿外传或分享，否则可能被服务方判定异常。

## 原理

Swift 方法不好按名字 hook，所以完全不走 hook 业务逻辑的路子，改成四路取证：

| 路线 | 做法 | 能拿到什么 |
|---|---|---|
| A. 沙盒 + AppGroup | 递归扫描 `NSHomeDirectory()` **和 entitlements 里的 App Group 容器**（NE 要读配置，config.yaml 通常在这），把 yaml 里的 `proxies:` / `proxy-providers:` 段落直接摘出来 | **明文 config.yaml**、`proxy-providers` 里的订阅 url |
| B. 响应分类 | 抓 `NSURLSession` 的响应体，按**内容**判断类型（Clash YAML / base64 节点列表 / JSON 面板数据），不靠 URL 关键词猜 | 订阅内容、`link` 字段、`subscription-userinfo` 流量头 |
| C. NE 配置 | hook `-[NETunnelProviderProtocol setProviderConfiguration:]` | App 可能把整份配置塞给 NE，这条路能直接拿到 |
| D. UserDefaults | 全量导出 `dictionaryRepresentation` | `AppsConnectDirectSubscriptions`、`AppsConnectPanelURL` |

零依赖：不链接 CydiaSubstrate / ElleKit / Logos，只用 objc runtime + dlsym，TrollStore 注入后可以直接加载，不会因为缺库崩溃。

## 构建（GitHub Actions，免费）

仓库是 public 的话 macOS runner 免费不限量。

1. 在 GitHub 新建一个 public 仓库（**不要**勾选自动生成 README，避免冲突）
2. 本目录已 `git init` 并提交过一次，接着：

```bash
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git branch -M main
git push -u origin main
```

3. 打开仓库的 **Actions** → `build-dylib` 会自动跑（约 1 分钟）
4. 跑完在页面底部 **Artifacts** 下载 `SubDump-dylib.zip`，里面有 `SubDump.dylib`

> 不要提交 IPA 或脱壳出来的二进制，`.gitignore` 已经挡掉了（体积大 + 版权问题）。

## 安装（TrollStore / 巨魔）

1. 把 `SubDump.dylib` 传到 iPhone（AirDrop / 微信文件传输 / 存到「文件」App 都行）
2. 打开 **TrollFools**
3. 选 `Apps Connect` → 右上角 `+` → 选 `SubDump.dylib` → 确认注入
4. 启动 Apps Connect

## 使用

注入成功后，App 启动 **3 秒**会弹出结果面板，同时把最有把握的链接复制到剪贴板。

默认页是「关键线索」，分成 5 段，按可信度排：

| 段 | 内容 | 怎么用 |
|---|---|---|
| 【1】NE 配置转储 | `providerConfiguration` 里的键值，可能含整份 yaml | 找 `url` / `config` 开头的键 |
| 【2】订阅类响应 | 按**内容**判定：Clash YAML、base64 节点列表、带 `subscription-userinfo` 头 | 这里的 URL 就是订阅地址 |
| 【3】本地 yaml 配置 | 扫到的 `config.yaml` / `config_archive.yaml` 的 `proxies:` / `proxy-providers:` 段落 | 有 `proxy-providers: url:` 直接就是订阅链接；否则可把这段导入 Loon |
| 【4】面板类 JSON | 从响应体里挖出的 `link` / `url` / `token` / `plan` / `expired` / `residue` 等字段 | `link` 一般就是订阅地址 |
| 【5】候选链接 | 过滤掉规则集、测速、文档后的 URL，按分数排序，最多 40 条 | 兜底 |

面板顶部按钮：**全部 / 线索** 切换页面，**节点** 复制 `proxies:` 段整段（没有内联节点时退回复制 `proxy-providers:` 段），**复制** 复制当前页，**关闭** 退出。

【3】里每个 yaml 会给：文件路径、大小、`proxies` 节点数、`proxy-providers` 里的订阅 `url`、前 40 个节点名、`proxies` 前 12 行。节点显示不全不要紧，点 **节点** 直接拿整段。

结果**只存在于内存和剪贴板**，App 沙盒里不写任何文件。

**第 2、3 段是空的**：说明配置还没落地。进 App 里连一次 VPN（或点一次「刷新订阅」），再按左上角 🔗 重新扫描。

## 怎么认哪条是订阅链接

优先级从高到低：

1. 【3】里 `proxy-providers:` 下面的 `url:` —— 这就是标准的订阅地址
2. 【2】里 `[Clash YAML]` 那一条的 URL —— 服务器直接返回 yaml 的订阅
3. 【2】里带 `subscription-userinfo` 头的那条 —— 机场标准订阅接口
4. 【4】里 `link` / `url` 字段的值
5. 形如 `https://xxx/api/v1/client/subscribe?token=xxxx`、`https://xxx/sub?token=xxxx`、`.../link/xxxx?clash=1`

如果【3】只有内联的 `proxies:` 而没有 `proxy-providers`，说明这个服务**不下发订阅链接**，配置是 App 本地拼的。那就把 `proxies:` 段落整个复制出来，存成 `.yaml` 文件，Loon 支持直接导入 Clash 配置（节点会进去，但不会自动更新）。

## 拿到链接之后

Loon：`配置 → 订阅 → 添加`，粘贴链接即可。注意这类链接通常绑定账号 + 流量统计，用自己的就行，别分享。

## 先试一个 30 秒的土办法

在写 tweak 之前，其实可以先自己翻一下（有 Filza 的话）：

```
/var/mobile/Containers/Data/Application/<Apps Connect 的 UUID>/Library/Preferences/uk.skynet.ios.plist
/var/mobile/Containers/Data/Application/<Apps Connect 的 UUID>/Library/Application Support/*.sqlite
```

- 第一个用 Filza 自带的 plist 预览打开，找 `AppsConnectDirectSubscriptions`
- 第二个是 Core Data 库，用 DB 查看器打开找 `ZPANEL` 表，`ZLINK` 列就是订阅链接

TrollStore 装的 App 数据目录可以用 Filza 的「App 管理器」直接进。如果这样就能拿到，就不用装 dylib 了。

## 目录结构

```
Sources/SubDump.m          # 全部逻辑（单文件，无第三方依赖）
Makefile                   # 直接调 xcode clang，不用 Theos
.github/workflows/build.yml# CI：macOS runner 编译 + 上传 artifact
```

## 免责

仅用于导出**你自己付费账号**的配置数据，方便换客户端。请勿用于破解、共享、二次分发。
