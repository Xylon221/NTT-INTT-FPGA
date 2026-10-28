# CKKS 多项式环 NTT/INTT FPGA 功能复刻

依据项目经历截图，从零实现可运行的 RTL、Python 参考模型和自动化验证平台。默认支持 **8192 点**变换，验证 `Z_q[x]/(x^N+1)` 上的多项式乘法，并比较在线旋转因子生成（TFG）与共享幂表 ROM。

WSL 主工程：`/home/xylon/projects/ckks-ntt-fpga`（Ubuntu-22.04）。Windows 文件管理器路径：

```text
\\wsl.localhost\Ubuntu-22.04\home\xylon\projects\ckks-ntt-fpga
```

截图没有提供原始源码、FPGA 型号与原始测试报告，因此本项目以数学定义和实际仿真为依据。它实现单模数 NTT 算术与控制，是进一步开发 CKKS RNS 加速器的功能基线。完整 CKKS 编码、密钥、加解密与重缩放不在本工程范围内。

## 直接运行

已在本机 WSL 检出 Python 3、Icarus Verilog 和 Make，无额外 Python 包依赖。

从 GitHub 获取项目，在 Linux 或 WSL 中执行：

```bash
git clone https://github.com/Xylon221/NTT-INTT-FPGA.git
cd NTT-INTT-FPGA
make test
```

本机已经创建的 WSL 工程可以直接运行：

```bash
cd /home/xylon/projects/ckks-ntt-fpga
make quick     # 16/256 点，ROM 和 TFG，两种实现
make test      # 16/256/8192 点完整回归
```

从 Windows PowerShell 也可直接执行：

```powershell
wsl -d Ubuntu-22.04 --cd /home/xylon/projects/ckks-ntt-fpga make test
```

如迁移到没有仿真工具的 Ubuntu 环境，安装 `python3 make iverilog` 后即可运行。命令失败、超时、未知值、向量缺失、任一系数不符都会返回非零退出码。

## 已实现的内容

| 部分 | 实现 |
|---|---|
| 模乘 | 三寄存级 Barrett 流水线，II=1；数据路径无运行时除法 |
| 蝶形 | Cooley–Tukey，输出 `(a+b*w, a-b*w) mod q` |
| TFG | 每级种子与乘法递推，支持有效位和停顿 |
| NTT/INTT | radix-2 DIT，单蝶形复用，自然序输入/输出 |
| 负循环变换 | 正变换乘 `psi^j`，逆变换乘 `N^-1 * psi^-j` |
| 多项式乘法 | 测试平台串联两个 RTL 正变换、RTL 逐点乘、RTL 逆变换 |
| 验证 | Python 精确整数参考、独立直接 DFT/朴素卷积、逐系数比较与错误定位 |
| 对比报告 | 仿真实际周期、逻辑因子常量位数、参数、工具版本、源码 SHA-256 |
| FPGA 入口 | Vivado Tcl 综合脚本与时钟约束，需填写真实器件料号 |

默认 `N=8192, W=32, q=2013265921, g=31`。RTL 宽度可参数化至 64 位；另提供 60 位素数的 8192 点回归，以及 Goldilocks 模数下的 64 位算术边界验证。

## 验证结果与报告

仓库中保留了本机实测快照，重新运行后最新结果位于 `build/`：

- [默认配置回归报告](reports/default/report.md)，机器可读版本为 [report.json](reports/default/report.json)。重新运行生成 `build/regression/report.md`。
- [60 位模数回归报告](reports/rns60/report.md)：`q=1152921504606830593, g=5, W=64`。重新运行生成 `build/rns60/report.md`。
- 各子目录 `rom.log` / `tfg.log` 保存全部逐项检查结果；`python_tests.log`、`units.log`、`wide.log` 保存数学和算术单元测试记录。
- `intentional_fault.log` 是主动破坏一个期望系数后的**预期失败**记录，验证错误索引能被定位；`short_vector.log` 是故意截短向量后的**预期失败**记录。它们均不表示回归失败。

已验证 8192 点四种变换定义、端到端负循环乘法，以及计算中复位、重复启动、忙时写入被忽略等控制行为。单次集成运行每种架构核对 `7*N` 个系数：6 次变换和1次逐点乘。

默认 8192 点实测核内周期：循环正变换 **266254**，负循环正变换或带归一化的逆变换 **299023**。ROM 与 TFG 周期相同，因为 TFG 更新与蝶形计算重叠。以上均不含主机装载与结果读取时间。

双向唯一幂表为 `8192*32=262144 bits`；TFG 双向阶段种子为 `2*13*32=832 bits`，常量数据量减少 **99.6826%**。该比例排除共有的系数存储和 twist 状态，并且尚未包含器件综合的映射效果。新增因子乘法器的资源代价需要通过综合评估。

截图中的 **99.94% 存储下降 / 5.75% 周期增加**保留为原项目描述。本工程没有把它们预填为本地结果。尚未完成指定 FPGA 的布局布线、板级验证与真实资源、频率、功耗测量。

## 自定义参数与随机激励

```bash
# 默认配置换随机种子
python3 tools/run_regression.py --sizes 16 256 8192 --seeds 42 20261028

# 60 位单 RNS 模数、64 位数据接口
make rns60

# 接近 2^64 的模数，验证核心常量计算和宽位宽数据路径
make wide

# 自定义一组参数；报告放独立目录
python3 tools/run_regression.py --sizes 16 8192 --width 64 \
  --q 1152921504606830593 --root 5 --build-dir build/custom
```

参数要求：`N` 为 2 的幂且 `2<=N<=2^20`，`q` 为小于 `2^W` 的素数，`2N | (q-1)`，`g^((q-1)/(2N))` 的阶为 `2N`。Python 会验证这些条件。RTL 输入须为 `[0,q)` 的标准系数；Python 接口还可把负数归约到该区间。

Python 用法：

```python
from python.ntt_ref import Parameters, ntt, negacyclic_multiply

p = Parameters(n=16)
a, b = [1, 2] + [0]*14, [3, 4] + [0]*14
spectrum = ntt(a, p, negacyclic=True)
assert ntt(spectrum, p, inverse=True, negacyclic=True) == a
assert negacyclic_multiply(a, b, p) == [3, 10, 8] + [0]*13
```

## RTL 接口和波形

`ntt_core` 空闲时通过 `wr_en/wr_addr/wr_data` 自然序写满 N 个系数；下一拍脉冲 `start`，同时给出 `inverse/negacyclic`。`done` 为单周期完成脉冲，随后使用 `rd_addr/rd_data` 自然序读取。复位低有效且同步，应覆盖至少一个上升沿。每次重新运算前都要重新加载全部输入。

生成一个小尺寸波形：

```bash
make quick
vvp build/quick/n16_seed20261028/tfg.vvp +VCD
# 波形：build/ntt.vcd；可用 GTKWave 查看
```

接口时序、位反转存储、TFG 复用与内存推断限制详见 [架构文档](docs/architecture.md)。本版本系数数组采用异步读取和双写描述，进一步做 BRAM 化及高吞吐并行结构时，需要同步改动控制调度并重新验证。

## Vivado 综合

先用与 `LOG_N` 匹配的 N 生成初始化文件，然后指定实际 FPGA 器件。`PART` 为必填；示例占位符需替换。

```bash
make vectors N=8192
make synth PART=YOUR_FPGA_PART LOG_N=13 USE_TFG=1
make synth PART=YOUR_FPGA_PART LOG_N=13 USE_TFG=0
```

默认脚本使用 32 位默认模数；宽模数综合需要同步扩展 Tcl 参数与匹配的 ROM 元数据检查。脚本生成综合后资源、时序和 checkpoint，10 ns 为初步约束。实际综合未在本次交付中执行。更多说明见 [验证与性能口径](docs/verification.md) 和 [复刻范围](docs/reproduction_scope.md)。

## 目录

```text
rtl/       模乘、蝶形、TFG、NTT/INTT 核心
tb/        算术、64位算术、完整变换与多项式乘法自检查平台
python/    精确整数参考模型
tests/     独立数学定义、卷积、8192点和64位参数测试
tools/     向量生成、完整回归、JSON/Markdown报告
fpga/      Vivado Tcl 与 XDC
docs/      架构、验证、复刻边界说明
reports/   已验证配置的报告和日志快照
build/     运行生成的 HEX、仿真程序、日志、结果报告（git 忽略）
```

项目使用 MIT 许可证。可参考 [Microsoft SEAL 的官方 NTT 接口](https://github.com/microsoft/SEAL/blob/main/native/src/seal/util/ntt.h) 理解应用语境；其内部因子布局、惰性表示与本项目的自然序标准系数接口需要显式转换。
