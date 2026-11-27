# SubDump

从 **Apps Connect**（`uk.skynet.ios`）里导出你自己账号的订阅链接，方便填到 Loon / Stash / Shadowrocket 等客户端。

> 只读取本机已有数据 + 观测本机网络请求，**不修改任何业务逻辑、不伪造登录态、不绕过订阅校验**。
> 拿到的链接等同于账号凭证，请勿外传或分享，否则可能被服务方判定异常。

## 原理

Swift 方法不好按名字 hook，所以完全不走 hook 业务逻辑的路子，改成三路取证：

| 路线 | 做法 | 能拿到什么 |
|---|---|---|
| A. 沙盒文件 | 递归扫描 App 沙盒里所有 ≤40MB 的文件，从原始字节里提取 `http(s)://` | Core Data 里 `Panel.link`、缓存的面板 JSON |
| B. UserDefaults | 全量导出 `dictionaryRepresentation` | `AppsConnectDirectSubscriptions`、`AppsConnectPanelURL`、`AppsConnectPanelTOKEN` |
| C. 网络观测 | 用 `method_setImplementation` 挂 `NSURLSession` / `NSURLSessionTask` | 所有请求 URL + 订阅/面板响应的正文和 `subscription-userinfo` 头 |

零依赖：不链接 CydiaSubstrate / ElleKit / Logos，只用 objc runtime，所以 TrollStore 注入后可以直接加载，不会因为缺库崩溃。

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

注入成功后，App 启动 **3 秒**会弹出一个可滚动的结果面板，同时**候选链接已复制到剪贴板**。

面板上三个按钮：

- **全部 / 候选**：默认显示「候选链接」（已按可能性排序：`/subscribe`、`token=`、`panel`、`relay` 加分，规则集 `.mrs/.dat` 减分）；点「全部」看 UserDefaults、沙盒命中、网络请求、响应体全文
- **复制**：复制当前页内容
- **关闭**：直接关掉

结果**只存在于内存和剪贴板**，App 沙盒里不写任何文件。App 重启后重新扫。

**什么都没抓到的话**：回 App 里进「订阅管理 / 面板」点一次「刷新」，然后再点一次左上角的 🔗 悬浮球重新扫描。

## 怎么认哪条是订阅链接

- 形如 `https://xxx/api/v1/client/subscribe?token=xxxx`、`https://xxx/sub?token=xxxx`、`.../link/xxxx?clash=1`
- 在「全部」页的第 4 节「响应体」里，如果看到 `proxies:` 开头的 YAML，说明订阅内容本身已经抓到了，链接就在对应那条请求的 URL 里
- 面板接口（`relay.php` / `api/v1/app/...`）返回的 JSON 里也会带 `link` 字段

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
