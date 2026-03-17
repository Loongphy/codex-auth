# Codex Auth：一个纯本地的命令行工具，安全切换与管理多个 Codex 账号

👉 **GitHub：https://github.com/loongphy/codex-auth**

![command list](https://static.loongphy.com/2026/03/7b69a56487640d08710476787b03607c.png)

**npm（推荐，跨平台）：**

```shell
npm install -g @loongphy/codex-auth
```

**Linux / macOS / WSL2：**

```shell
curl -fsSL https://raw.githubusercontent.com/loongphy/codex-auth/main/scripts/install.sh | bash
```

**Windows（PowerShell）：**

```powershell
irm https://raw.githubusercontent.com/loongphy/codex-auth/main/scripts/install.ps1 | iex
```

## 为什么需要多账号管理？

我相信很多使用 OpenAI Codex 的朋友都遇到过同样的问题——**一个账号的额度根本不够用**。

Codex 对每个账号有着严格的速率限制：5 小时窗口期内的使用上限、每周的使用上限。当你正在高强度编码、让 Codex 帮你重构项目、跑测试、写文档的时候，额度一不留神就见底了。

怎么办？很多人的做法是：购买多个 Plus 或 Team 账号，轮流切换着用。有额度的用，没额度的歇一歇，等它重置了再切回来。

听起来很简单，但实际操作起来，**怎么切换** 就成了一个头疼的问题。

## 现有方案的问题

目前市面上已有一些工具来解决这个问题，比如 **CPA（CLIProxyAPI）** 之类的代理方案——你需要额外部署一个服务，由它来帮你做账号轮询和负载均衡。

思路是好的，但实际用起来**挺折腾的**：

- **需要额外部署。** 你得自己搭一个代理服务，找服务器、装环境、配进程守护，这本身就是一件事。
- **配置要研究。** 文档不一定全，参数不一定直观，想跑起来得花时间摸索。
- **出了问题不好修。** 报错了不知道怎么排查，翻 Issues 提问又太麻烦，折腾半天可能还是没解决。

对于只想安安静静写代码的人来说，这些额外的运维成本实在太高了。

**我只是想切个账号而已，有没有一个开箱即用的方案？**

**有的兄弟，有的。**

所以我做了 **Codex Auth**。

## Codex Auth 是什么？

**Codex Auth** 是一个纯本地的命令行工具（CLI），专门用来安全切换和管理多个 Codex 账号。

它的核心设计原则只有一条：

> **完全本地化，绝不调用任何 OpenAI 的 API。**

所有操作——查看账号、切换账号、导入认证文件——全部都是在你本地的 `~/.codex` 目录下完成的。它只读写你本机的会话文件（sessions）和认证文件（auth.json），你的凭证永远不会被发送到任何外部服务器。

这意味着什么？

**如果你的账号是正规渠道购买的，害怕被识别或封禁，那完全可以放心使用 Codex Auth。** 因为它是纯粹的本地文件操作，OpenAI 那边完全无法感知你在用这个工具。没有任何 API 调用，没有任何网络请求，零封号风险。


## 工作原理

简单来说，Codex Auth 的原理就是管理 `~/.codex/auth.json` 这个认证文件。

当你在 Codex 中登录一个账号时，Codex 会在 `~/.codex/auth.json` 中保存当前账号的认证信息（包含 JWT Token）。Codex Auth 做的事情就是：

1. **解析 JWT Token**：从 `auth.json` 中读取 `tokens.id_token`，解码 JWT 的 payload 部分，提取出你的邮箱以及订阅计划（Plus / Team / Pro 等）
2. **为每个账号独立存储**：将每个账号的认证文件以账号身份键的 `base64url(account_id)` 为文件名，保存在 `~/.codex/accounts/` 目录下
3. **切换时替换**：当你要切换到另一个账号时，把目标账号的认证文件复制回 `~/.codex/auth.json` 即可

就这么简单，没有任何黑魔法。

额度数据则来自 Codex 本身在 `~/.codex/sessions/` 目录下生成的会话日志文件（`rollout-*.jsonl`），Codex Auth 会扫描最新的日志文件，从中提取出 5 小时和每周的速率限制信息。

## 核心功能

当前 Codex Auth 主要实现了以下功能：

### 1. `codex-auth list` — 一览无余地查看所有账号

```shell
codex-auth list
```
![command list](https://static.loongphy.com/2026/03/7b69a56487640d08710476787b03607c.png)

运行后会以表格形式展示你管理的所有 Codex 账号：

- **EMAIL** — 账号邮箱（如果设了别名，会显示为 `(别名)邮箱` 的格式）
- **PLAN** — 当前订阅计划：free / plus / pro / team / business / enterprise / edu
- **5H USAGE** — 5 小时窗口期的剩余额度百分比，以及重置时间（如 `60% (14:30)` 表示剩余 60%，14:30 重置）
- **WEEKLY USAGE** — 每周额度的剩余百分比和重置时间
- **LAST ACTIVITY** — 上次使用的相对时间（如 `2m ago`、`1h ago`、`3d ago`）

当前激活的账号会用 `*` 标记并高亮显示。表格还会根据终端宽度自动调整列宽，在窄终端上也能看。

一眼就能看清哪个账号还有额度、哪个快耗尽了、上次什么时候用的，非常直观。

### 2. `codex-auth login` — 登录并添加当前账号

```shell
codex-auth login        # 默认会先执行 codex login
codex-auth login --skip # 跳过登录，直接读取本地认证文件
```

`login` 命令会把当前 `~/.codex/auth.json` 中的账号导入到 Codex Auth 的管理列表中。

默认行为是先调起 `codex login`（也就是 Codex 自己的登录流程），登录完成后再自动读取认证文件并添加。

**但你也可以完全不走这个流程。** 加上 `--skip` 参数，Codex Auth 会直接读取已有的 `auth.json` 文件。如果你已经在 Codex 里登好了账号，用这种方式最方便——不需要再登录一次。

如果你之前已经在用旧命令，也不用慌：`codex-auth add` 仍然可以作为兼容别名继续使用，但后续建议统一改成 `codex-auth login`。旧参数 `--no-login` 已经替换为 `--skip`。

这其实也是 Codex Auth 的精髓所在：它的原理就是完全读取本地的认证文件，完全不走任何 OpenAI 的 API。所以如果你的账号是正规的、害怕被封禁的话，完全可以走这种方式。

### 3. `codex-auth switch` — 灵活切换账号

这是最核心、最高频使用的功能。

![command switch](https://static.loongphy.com/2026/03/a48909f063c5ea3ed1d146b8e65ca258.png)

#### 交互式切换

```shell
codex-auth switch
```

运行后会展示一个交互式的账号选择列表，显示每个账号的邮箱、订阅计划、额度使用情况和上次活跃时间。你可以用：

- **↑/↓ 方向键**或 **j/k**（Vim 风格）上下移动
- **数字键** 直接跳转到对应编号
- **Enter** 确认选择
- **Esc** 取消退出

当前激活的账号会以绿色高亮标记 `[ACTIVE]`，选中的账号会显示 `>` 指示符。体验非常流畅。

#### 非交互式切换

```shell
codex-auth switch user@example.com   # 完整邮箱
codex-auth switch user               # 模糊匹配：邮箱片段
codex-auth switch exam               # 模糊匹配：任意子串
```

**支持模糊匹配**——你不需要输入完整的邮箱地址。只要输入邮箱的一部分（前缀、后缀、中间任意片段），工具就能自动找到匹配的账号，大小写不敏感。

如果输入的内容只匹配到一个账号，直接切换，无需确认。如果匹配到多个账号，会自动弹出交互式选择界面让你挑选。

这种非交互式模式特别适合集成到脚本或其他工具中。比如你可以在 `.bashrc` 里写个 alias：

```shell
alias cx-work="codex-auth switch work"
alias cx-personal="codex-auth switch personal"
```

一条命令就切换到对应的账号，非常高效。

#### 切换时的安全保障

每次切换账号时，Codex Auth 会：

1. **自动备份**当前的 `auth.json`（仅在内容发生变化时才备份，避免重复）
2. 将目标账号的认证文件复制到 `~/.codex/auth.json`
3. 更新注册表的 `active_account_id` 字段

备份文件保存在 `~/.codex/accounts/` 目录下，格式为 `auth.json.bak.<timestamp>`，最多保留最近 5 份。即使误操作，也能轻松恢复。

### 4. `codex-auth import` — 智能导入认证文件

如果你像我之前一样，有手动备份多个 `auth.json` 文件的习惯——比如每次登录完一个账号就把 `auth.json` 复制一份、改个名保存起来——那这个功能简直就是为你量身定做的。

#### 导入单个文件

```shell
codex-auth import /path/to/auth.json --alias personal
```

导入一份认证文件，还可以用 `--alias` 给它起个别名。别名会在 `list` 和 `switch` 命令中显示在邮箱前面，方便区分。比如设了 `personal`，列表里就会显示 `(personal)user@example.com`。

#### 批量导入整个文件夹

```shell
codex-auth import /path/to/auth-backups/
```

Codex Auth 会自动识别路径类型：
- 如果是文件 → 导入单个认证文件
- 如果是文件夹 → 扫描目录下所有 `.json` 后缀的文件（不递归子目录），逐个尝试解析并导入

无效的文件会被自动跳过，不会报错。批量导入模式下 `--alias` 参数会被忽略，因为每个账号会根据邮箱自动命名。

这个功能让你可以把之前手动备份的一堆认证文件一次性全部导入到 Codex Auth 里，省去了逐个添加的麻烦。

### 5. `codex-auth remove` — 移除不需要的账号

```shell
codex-auth remove
```

交互式多选。运行后会展示所有账号的列表，你可以：

- **↑/↓** 或 **j/k** 移动光标
- **空格键** 勾选/取消勾选要删除的账号（支持多选）
- **Enter** 确认删除
- **Esc** 取消

如果你删除了当前激活的账号，Codex Auth 会自动切换到一个额度最充裕的账号作为新的活跃账号。


## 完整命令速查

```shell
codex-auth list                          # 列出所有账号及额度
codex-auth login                         # 添加当前账号（先登录再导入）
codex-auth login --skip                  # 添加当前账号（跳过登录）
codex-auth switch                        # 交互式切换账号
codex-auth switch <email或片段>            # 非交互式切换（模糊匹配）
codex-auth import <文件路径>              # 导入单个认证文件
codex-auth import <文件路径> --alias <别名> # 导入并设置别名
codex-auth import <文件夹路径>            # 批量导入文件夹中的认证文件
codex-auth remove                        # 交互式移除账号
codex-auth --version                     # 查看版本
```

## 已知限制

### 1. 额度显示的实时性问题

最简单的场景：假如你当前没有任何正在运行的 Codex 会话，你从上一个账号切换到下一个账号的时候，你会发现新切换的账号显示的额度和上一个账号一模一样。

为什么会这样？

因为额度数据来源于 `~/.codex/sessions/` 目录下的会话日志文件（`rollout-*.jsonl`）。这些文件是 Codex 在运行过程中实时写入的。如果当前没有任何活跃的 Codex 会话，就不会有新的日志产生，Codex Auth 读取到的自然还是上一个会话留下来的数据。

**这并不影响切换功能本身**——账号实际上已经成功切换了，只是额度显示不准确而已。一旦你用新账号开始一个 Codex 会话，额度就会即时更新为正确的值。

对于正常使用来说，这个限制基本不会造成什么困扰。你总会开一个会话用一用的，对吧？

### 2. 已有会话不会自动重载

虽然 Codex Auth 解决了多账号切换的问题，但还有一个实际使用中的小痛点：**如果你已经开启了多个 Codex 会话，切换账号后，这些已有的会话并不会自动感知到账号变化。** 你需要手动退出当前的 Codex 会话，然后执行 `codex resume` 来恢复对话。

这是因为原版 Codex CLI 在启动时读取一次 `auth.json`，之后不会再监听文件变化。这属于 Codex CLI 本身的限制，而非 Codex Auth 的问题。

**解决方案：使用 codext**

如果你希望切换账号后已有会话能自动重载，可以使用我的二开 Codex：

👉 **https://github.com/Loongphy/codext**

```shell
npm install -g @loongphy/codext
```

> ⚠️ codext 为满足自我需求的二开产物，全程由 Codex 自动开发，不做生产性保证。

codext 在原版 Codex 的基础上做了多项增强：

- **自动检测 `auth.json` 变更**：当你通过 `codex-auth switch` 切换账号后，已运行的 codext 会话会自动重载新的认证信息，无需手动退出再恢复
- **独立模型配置**：可以为 Plan 和 Code 模式单独配置模型和推理等级，跟随 shift + Tab 快速切换

搭配 Codex Auth 使用，体验更加丝滑。

## 适合谁用？

- 拥有多个 Codex/ChatGPT 账号，需要频繁切换的用户
- 重视账号安全，不想把凭证交给第三方服务的用户
- 没有海外服务器，无法自建代理服务的用户
- 喜欢命令行工具，追求效率和简洁的开发者
- 需要在脚本中自动化账号切换的高级用户

## 写在最后

Codex Auth 的出发点很简单——**用最轻量、最安全的方式，解决多账号切换的痛点**。

不需要服务器，不需要搭建服务，不需要复杂配置。一行命令安装，几条命令就能管理你的所有账号。最重要的是，你的凭证始终留在本地，不经过任何第三方，不发送任何网络请求。

项目使用 Zig 语言编写，编译后是一个无依赖的 native 二进制文件，启动快、体积小。代码完全开源，MIT 协议，欢迎审计。

如果觉得有用，欢迎 Star ⭐️、提 Issue、贡献 PR：

👉 **https://github.com/loongphy/codex-auth**
