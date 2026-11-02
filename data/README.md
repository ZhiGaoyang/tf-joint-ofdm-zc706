# 测试数据与参考结果

| 文件 | 内容 |
|---|---|
| `final_numbers.py` | 从 `board/measurements/` 的板上原始记录复算技术文档第三部分的全部板上数据（无干扰衰减轨迹、单音干扰各档误包率与窗口吞吐、首窗正确帧数、感知耗时、无干扰长测、演示录制各段的正确帧数、反应过程与无单音窗口吞吐） |
| `analyze_sense.py` | 按预登记文件 `board/measurements/frozen_s2_v22.json` 的规则判定各假设（被 `final_numbers.py` 调用，也可单独运行：`python -I -B data/analyze_sense.py board/measurements/raw_s2s3 s2s3e`） |
| `reference_results.json` | `final_numbers.py` 的参考输出，即技术文档所用数值；重新运行后应与之完全一致 |
| `chart_data.json` | 技术文档中屏蔽帧定时偏差、单音干扰结果、逐组度量与反应过程各图所用数据 |
| `model_mask_sweep.csv` | 子载波组屏蔽浮点模型闭环扫描结果（技术文档“子载波组屏蔽：模型结果”一节的插图：QPSK/16QAM，单音 JSR −40 至 0 dB，屏蔽与不屏蔽） |

```powershell
python -I -B data/final_numbers.py > new.json   # 与 data/reference_results.json 比较
```
