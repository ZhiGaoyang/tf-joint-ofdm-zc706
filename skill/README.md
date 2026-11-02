# Skill Package

本目录收录从本项目与大模型协作过程中提炼出的 8 项可复用经验。每项都有单独的 README，写明适用场景、用法、已验证效果、来源（具体的失败或观察记录）和失效条件。这些都只是在一个项目上得到的经验，没有在其他题目或板卡上验证过，各项 README 中写明了边界。

| 目录 | 类型 | 一句话 | 与 OFDM 题目的关系 |
|---|---|---|---|
| `vivado_bd_state_check/` | 校验脚本 + 踩坑 | 用落盘的 BD/XCI 文件，而不是新会话中的 Tcl 读回字符串，判断 Block Design 配置是否改变 | 无关，任意 IP Integrator 工程可用 |
| `vivado_batch_exit/` | 踩坑 + 脚本模板 | Windows 下 Vivado 批处理的真实退出码、结果文件双重确认 | 无关 |
| `timing_triage_prompt/` | 提示词工作流 | 根据布线后最差路径的结构分类，决定继续微调还是修改结构 | 无关，案例来自本项目 |
| `board_boot_update/` | 操作流程 + 踩坑 | 保留回滚的 Zynq BOOT 更新、温度门槛和版本确认 | 适用于 Zynq 系列板卡，只在 ZC706 上验证过 |
| `format_change_regression/` | 检查清单 + 踩坑 | 改帧格式时先列出"在旧格式上标定过的常数"，再做端到端回归 | 与收发同步相关，案例来自子载波屏蔽 |
| `vivado_bram_template/` | 踩坑 + 代码模板 | 识别"块 RAM 推断失败"并改写为单读单写模板 | 无关，任意 7 系列设计可用 |
| `llm_cross_review/` | 协作流程 + 模板 | 独立只读审查 → 逐条复现 → 先红后绿 → 书面答复 → 复审 | 无关 |
| `host_test_pitfalls/` | 踩坑清单 | 变异检查与字节码缓存、假寄存器模型的命令位、Git Bash 路径改写 | 无关 |

环境：Windows 11、Vivado 2023.2、Python 3.11、ZC706。其他环境未验证。

脚本类条目可以直接运行：

```powershell
python -B skill/vivado_bd_state_check/compare_bd_state.py --reference <accepted_project> --candidate <new_project> --out report.json
```

提炼过程（从哪些失败中总结、如何验证、边界如何确定）写在设计报告的"技能包提炼"一节。
