# host_test_pitfalls：主机测试与板上脚本开发中的三个小坑

类型：踩坑清单。

## 适用场景

在 Windows 主机上为板上 Python 脚本写测试、做变异检查，并通过 Git Bash 驱动串口工具的项目。与 OFDM 题目无关。

## 1. 变异检查被 Python 字节码缓存骗过

| 现象 | 记录 |
|---|---|
| 故意把一个参数从 `.01` 改成 `.05` 做变异检查，测试仍通过；改回原文后，测试反而失败 | 2026-10-25 联合策略模块的变异检查（`progress.md`） |
| 原因：变异前后文件大小相同，修改时间又落在同一秒内，`__pycache__` 里的 `.pyc` 校验（修改时间 + 大小）没有失效，加载的是上一个版本的字节码 | 清除 `__pycache__` 并加 `-B` 后，原文 7 项全过、两个变异分别失败 1 项和 3 项 |

用法：变异检查一律用 `python -B`（或设置 `PYTHONDONTWRITEBYTECODE=1`），并在开始前删除被测目录的 `__pycache__`；每次恢复原文后都确认测试回到全部通过。

## 2. 测试用的假寄存器模型要区分"命令寄存器"

| 现象 | 记录 |
|---|---|
| 给 PS 脚本加了"读超时标志"检查后，4 个与硬件无关的测试失败 | `tests/bringup/test_lean_adapt_nc.py` |
| 原因：假寄存器模型把写入值原样读回；而硬件上 0x054 是命令寄存器，写 1 表示"清零"，读回的是状态，二者含义不同 | 假模型改为写 0x054 不回读后，全部通过 |

用法：假寄存器模型中，命令位（写 1 触发、自清零）、只读状态位、普通配置寄存器分开处理；否则测试验证的是假模型，而不是脚本。

## 3. Git Bash 会改写以 `/` 开头的参数

| 现象 | 记录 |
|---|---|
| 通过串口上传文件到板上 `/root/lean`，命令"成功"但板上没有文件 | `docs/bringup/evidence/BRINGUP-025_stage0_joint_adaptation/upload.log` |
| 原因：Git Bash（MSYS）把参数 `/root/lean/x.py` 自动改成 Windows 路径 `D:/Git/root/lean/x.py` 再传给 PowerShell 脚本 | 设置 `MSYS_NO_PATHCONV=1` 后重传成功，板上 SHA 与主机一致（`upload02.log`） |

用法：从 Git Bash 调用任何需要板上（Linux）绝对路径的工具时，前面加 `MSYS_NO_PATHCONV=1`；上传后必须在板上核对 SHA，不能只看工具退出码。

## 失效条件与边界

- 第 1 条与 Python 的 pyc 校验方式有关（默认基于修改时间）；改用基于哈希的 pyc 时不会出现。
- 第 3 条只在 Git for Windows 的 MSYS 环境中出现；PowerShell、cmd 直接调用不受影响。
- 都只在本项目中遇到过一次，属于经验记录。
