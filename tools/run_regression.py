#!/usr/bin/env python3
"""Build/run actual RTL with Icarus; export measured cycles and comparisons."""
import argparse
import hashlib
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from python.ntt_ref import Parameters
from generate_vectors import make_vectors

RTL = ["rtl/mod_mul.sv", "rtl/butterfly.sv", "rtl/twiddle_gen.sv", "rtl/ntt_core.sv"]
METRIC = re.compile(r"METRIC mode=(\d+) n=(\d+) op=(\w+) cycles=(\d+) checked=(\d+)")


def run(command, logfile, timeout=300):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    logfile.parent.mkdir(parents=True, exist_ok=True)
    logfile.write_text("$ " + shlex.join(command) + "\n" + result.stdout, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {logfile}\n{result.stdout[-6000:]}")
    return result.stdout


def compile_case(vector_dir, log_n, width, q, root, mode, destination):
    command = ["iverilog", "-g2012", "-Wall", "-s", "tb_ntt",
               f"-Ptb_ntt.LOG_N={log_n}", f"-Ptb_ntt.W={width}",
               f"-Ptb_ntt.Q={width}'d{q}", f"-Ptb_ntt.PRIMITIVE_ROOT={width}'d{root}",
               f"-Ptb_ntt.USE_TFG={mode}", f'-Ptb_ntt.VECTOR_DIR="{vector_dir.as_posix()}"',
               "-o", str(destination), *RTL, "tb/tb_ntt.sv"]
    run(command, destination.with_suffix(".compile.log"))


def check_failure_detector(executable, vector_dir, n, destination):
    target = vector_dir / "forward.hex"
    original = target.read_text(encoding="ascii")
    lines = original.splitlines()
    index = min(3, n-1)
    lines[index] = f"{int(lines[index],16)^1:08x}"
    try:
        target.write_text("\n".join(lines)+"\n", encoding="ascii")
        result = subprocess.run(["vvp", str(executable)], cwd=ROOT, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        destination.write_text(result.stdout, encoding="utf-8")
        if result.returncode == 0 or f"coefficient={index} " not in result.stdout:
            raise RuntimeError("Deliberate reference corruption did not produce the expected coefficient failure")
    finally:
        target.write_text(original, encoding="ascii")
    # A truncated oracle must fail even when a simulator only prints a warning.
    short_log = destination.with_name("short_vector.log")
    try:
        target.write_text("", encoding="ascii")
        result = subprocess.run(["vvp", str(executable)], cwd=ROOT, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        short_log.write_text(result.stdout, encoding="utf-8")
        if result.returncode == 0 or "Missing, short or unknown vector" not in result.stdout:
            raise RuntimeError("Truncated reference did not fail safely")
    finally:
        target.write_text(original, encoding="ascii")
    return {"status": "passed", "corrupted_coefficient": index,
            "log": str(destination), "short_vector_log":str(short_log)}


def summarize(report, output):
    cases = report["measurements"]
    comparisons = []
    for n, seed in sorted({(m["n"],m["seed"]) for m in cases}):
        subset = [m for m in cases if m["n"]==n and m["seed"]==seed]
        for operation in sorted({m["operation"] for m in subset}):
            by_mode = {m["mode"]:m for m in subset if m["operation"]==operation}
            if "rom" in by_mode and "tfg" in by_mode:
                rom = by_mode["rom"]["cycles"]
                tfg = by_mode["tfg"]["cycles"]
                comparisons.append({"n":n,"seed":seed,"operation":operation,
                    "rom_cycles":rom,"tfg_cycles":tfg,"cycle_change_percent":100*(tfg-rom)/rom})
    report["comparisons"] = comparisons
    storage = []
    width = report["parameters"]["width"]
    for n in sorted({m["n"] for m in cases}):
        seed_words = 2*(n.bit_length()-1)
        storage.append({"n":n,"rom_table_words":n,"tfg_stage_constant_words":seed_words,
            "rom_table_bits":n*width,"tfg_stage_constant_bits":seed_words*width,
            "constant_data_reduction_percent":100*(1-seed_words/n)})
    report["logical_twiddle_storage"] = storage
    report["checked_integration_coefficients"] = sum(m["checked"] for m in cases)
    lines = ["# 实测验证报告", "", f"生成时间（UTC）：{report['generated_at']}", "",
             f"状态：{report['status']}；逐系数比较 {report['checked_integration_coefficients']:,} 次。", "",
             "Python 数学测试、32/64 位 RTL 单元测试及故障定位测试均已运行；详细日志与本文件同目录。", "",
             "## 计算周期（实际 RTL 仿真）", "",
             "周期从 core 接受 start 到 done，包含阶段切换和 twist/归一化；不含主机装载与读取。", "",
             "pointwise 行由测试平台单独计量：从逐点乘任务启动至末个流水输出，含首次发射前的等待拍，共 N+3 拍；它不经过 core 的 start/done。", "",
             "| N | 种子 | 操作 | ROM | TFG | 变化 |", "|---:|---:|---|---:|---:|---:|"]
    for c in comparisons:
        lines.append(f"| {c['n']} | {c['seed']} | {c['operation']} | {c['rom_cycles']} | {c['tfg_cycles']} | {c['cycle_change_percent']:+.3f}% |")
    lines += ["", "## 旋转因子常量数据量（理论口径）", "",
              "双向共享唯一幂 ROM 各 N/2 项，总 N 项；TFG 双向每阶段 1 个种子，共 2 log2(N) 项。", "",
              "这是常量数据位数比较，不等于综合后的 BRAM/LUT/总资源减少率。两方案共有的系数存储、twist 常量、TFG 当前因子和步长寄存器不计。", "",
              "| N | ROM 常量 bits | TFG 阶段常量 bits | 减少 |", "|---:|---:|---:|---:|"]
    for s in storage:
        lines.append(f"| {s['n']} | {s['rom_table_bits']} | {s['tfg_stage_constant_bits']} | {s['constant_data_reduction_percent']:.4f}% |")
    lines += ["", "原截图的 99.94% / +5.75% 未作为本工程实测结果。TFG 递推与蝶形计算重叠，本架构可能没有额外周期。", "",
              "尚未测量指定 FPGA 上的资源、Fmax、功耗和板级吞吐量。32 位默认模数仅演示 CKKS 所用多项式环计算；不构成完整 CKKS 实现或安全参数。", ""]
    (output/"report.md").write_text("\n".join(lines),encoding="utf-8")
    (output/"report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", nargs="+", type=int, default=[16,256,8192])
    parser.add_argument("--seeds", nargs="+", type=int, default=[20261028])
    parser.add_argument("--q", type=int, default=2013265921)
    parser.add_argument("--root", type=int, default=31)
    parser.add_argument("--width", type=int, default=32)
    parser.add_argument("--build-dir", type=Path, default=Path("build/regression"))
    args = parser.parse_args()
    if not 3 <= args.width <= 64 or args.q >= 1 << args.width:
        parser.error("Require 3 <= width <= 64 and q < 2**width")
    for n in args.sizes:
        if not 2 <= n <= (1 << 20):
            parser.error("RTL requires 2 <= n <= 2**20")
        Parameters(n=n,q=args.q,primitive_root=args.root)
    for tool in ("iverilog","vvp"):
        if not shutil.which(tool): parser.error(f"Missing {tool}; install Icarus Verilog")
    output = (ROOT/args.build_dir).resolve()
    output.mkdir(parents=True,exist_ok=True)
    report = {"status":"running","generated_at":datetime.now(timezone.utc).isoformat(),
              "parameters":{"sizes":args.sizes,"seeds":args.seeds,"q":args.q,
                            "primitive_root":args.root,"width":args.width},"measurements":[]}
    try:
        report["tools"] = {"python":sys.version.split()[0]}
        for tool in ("iverilog","vvp"):
            version = run([tool,"-V"],output/f"{tool}_version.log")
            report["tools"][tool] = version.splitlines()[0]
        source_files = sorted(p for folder in ("rtl","tb","python","tools","tests","fpga")
                              for p in (ROOT/folder).rglob("*")
                              if p.is_file() and p.suffix in (".sv",".py",".tcl",".xdc"))
        report["source_sha256"] = {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in source_files}
        report["python_tests"] = run([sys.executable,"-m","unittest","discover","-s","tests","-v"],output/"python_tests.log")
        print("PASS Python mathematical reference",flush=True)
        run(["iverilog","-g2012","-Wall","-s","tb_units","-o",str(output/"units.vvp"),*RTL[:3],"tb/tb_units.sv"],output/"units.compile.log")
        report["unit_tests"] = run(["vvp",str(output/"units.vvp")],output/"units.log")
        print(report["unit_tests"].strip(),flush=True)
        # Wide arithmetic vectors use a fixed, independent Python bigint oracle.
        run([sys.executable,"tools/generate_wide_vectors.py"],output/"wide_vectors.log")
        run(["iverilog","-g2012","-Wall","-s","tb_wide","-o",str(output/"wide.vvp"),*RTL[:2],"tb/tb_wide.sv"],output/"wide.compile.log")
        report["wide_tests"] = run(["vvp",str(output/"wide.vvp"),"+VECTORS=build/wide_vectors"],output/"wide.log")
        print(report["wide_tests"].strip(),flush=True)
        for n in args.sizes:
            for seed in args.seeds:
                params = Parameters(n=n,q=args.q,primitive_root=args.root)
                directory = output/f"n{n}_seed{seed}"
                vectors = directory/"vectors"
                make_vectors(params,seed,vectors)
                for mode in (0,1):
                    name = "tfg" if mode else "rom"
                    executable = directory/f"{name}.vvp"
                    compile_case(vectors,params.log_n,args.width,args.q,args.root,mode,executable)
                    stdout = run(["vvp",str(executable)],directory/f"{name}.log")
                    matches = METRIC.findall(stdout)
                    if len(matches)!=7 or "PASS integration" not in stdout:
                        raise RuntimeError(f"Missing completion/metrics in {directory}/{name}.log")
                    for mode_text,n_text,op,cycles,checked in matches:
                        if int(mode_text)!=mode or int(n_text)!=n or int(checked)!=n:
                            raise RuntimeError("Unexpected RTL metric parameters")
                        report["measurements"].append({"mode":name,"n":n,"seed":seed,
                            "operation":op,"cycles":int(cycles),"checked":int(checked)})
                    print(f"PASS N={n} seed={seed} {name}: {7*n:,} coefficients",flush=True)
                    if "failure_detector" not in report:
                        report["failure_detector"] = check_failure_detector(executable,vectors,n,output/"intentional_fault.log")
                        print("PASS deliberate fault correctly identified coefficient",flush=True)
        report["status"]="passed"
        summarize(report,output)
        print(f"Report: {output/'report.md'}",flush=True)
    except Exception as error:
        report["status"]="failed"; report["error"]=str(error)
        (output/"report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
        (output/"report.md").write_text("# 验证失败\n\n"+str(error)+"\n",encoding="utf-8")
        print(f"FAILED: {error}",file=sys.stderr)
        return 1
    return 0


if __name__=="__main__":
    sys.exit(main())
