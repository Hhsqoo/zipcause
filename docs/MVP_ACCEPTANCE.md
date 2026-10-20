# ZipCause MVP 验收对照

本文把项目申报范围对应到代码路径和复现命令，供初审及后续验收核对。当前目标是 MoonBit Native CLI；本项目尚未发布到 Mooncakes。

## 申报范围与证据

| 能力 | 代码与测试证据 | 验收方式 |
| --- | --- | --- |
| 比较两个 ZIP 并报告字节相同或存在差异 | `cmd/main/main.mbt`；CLI 冒烟脚本 | `moon run --target native cmd/main -- compare old.zip new.zip` |
| 报告成员新增、删除、内容变化、相对顺序变化 | `diff.mbt`；`zipcause_test.mbt` | `moon test --target native` |
| 报告 STORE / DEFLATE 方法和压缩流差异 | `diff.mbt`；MoonBit 测试；Python 生成的 DEFLATE 样例 | `python scripts/cli_smoke.py` |
| 报告时间戳、标志、内外部属性、ZIP 版本、注释和扩展字段变化 | `zip_meta.mbt`、`diff.mbt`；对应单元测试 | `moon test --target native` |
| 校验本地文件头与目录中的 CRC、大小及名称信息 | `zip_meta.mbt`；错误归档测试 | `moon test --target native` |
| 输出文本或 JSON，区分相同、不同和错误输入的退出码 | `cmd/main/main.mbt`；`scripts/cli_smoke.py` | `python scripts/cli_smoke.py` |
| 对输入和解压数据设置资源上限，拒绝未支持格式 | `zip_meta.mbt`；成员大小与条目数限制测试 | `moon test --target native` |

## 支持边界

- 支持经典单卷 ZIP、STORE 和 DEFLATE。
- 支持 ASCII 成员名，以及设置 ZIP UTF-8 标志且内容有效的 UTF-8 成员名；非 ASCII 传统编码名称会被明确拒绝。
- 单个归档最多 64 MiB、最多 10,000 个成员、单成员解压后最多 32 MiB、总解压量最多 128 MiB。
- ZIP64、加密成员、多卷归档、重复成员名和其他压缩方式不在当前范围。
- 工具只读归档，不解压到磁盘、不修改输入，也不判断源代码或构建环境是否等价。

## 验收命令

```sh
moon fmt --check
moon check --target native --deny-warn
moon build --target native
moon test --target native
python scripts/cli_smoke.py
```

CI 对上述 MoonBit 格式、检查、构建和测试步骤执行自动验证。对外提交前，应确认目标提交的 CI 通过，并核对 README 示例可以复现。

## 当前赛事阶段

本项目按参赛者当前提供的信息处于材料初审阶段。赛事官网区分了报名申报和后续开发：十月报名最多提交 3 次；开发阶段要求在公开仓库持续保留 commits、Issues、PR 与更新记录，报名/验收截止为 2026 年 10 月 31 日。报名次数与 Git commits 是不同指标。

本项目按参赛者提出的目标，继续形成 10 次以上可追溯的有效代码提交，每次对应具体功能、边界修复、测试或验收文档。此处是项目执行目标，不把提交数本身当成质量证明，也不将 Mooncakes 发布写作当前初审已完成事项。具体阶段要求以[赛事官网](https://moonbitlang.github.io/Hackathon2026/)和正式通知执行。
