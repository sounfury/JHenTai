"""Run LaMa on real DirectML hardware; session creation alone is not a probe.

Use an isolated environment with onnxruntime-directml and numpy installed.
"""
import argparse
import json
import time

import numpy as np
import onnxruntime as ort

parser = argparse.ArgumentParser()
parser.add_argument("model")
parser.add_argument("--size", type=int, default=512)
parser.add_argument("--width", type=int)
parser.add_argument("--compare", help="Original model to compare on CPU")
parser.add_argument("--profile", action="store_true")
parser.add_argument("--mode", choices=["default", "basic", "disabled", "static", "no-metacommands", "cpu"], default="basic")
args = parser.parse_args()
options = ort.SessionOptions()
options.enable_mem_pattern = False
options.intra_op_num_threads = 2
options.inter_op_num_threads = 1
options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
options.enable_cpu_mem_arena = False
options.enable_profiling = args.profile
options.profile_file_prefix = ".dart_tool/lama-profile"
if args.mode == "static":
    options.add_free_dimension_override_by_name("batch", 1)
    options.add_free_dimension_override_by_name("height", args.size)
    options.add_free_dimension_override_by_name("width", args.width or args.size)
if args.mode == "basic":
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
elif args.mode == "disabled":
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
providers = ["CPUExecutionProvider"] if args.mode == "cpu" else [
    ("DmlExecutionProvider", {"device_id": "0", **({"disable_metacommands": "True"} if args.mode == "no-metacommands" else {})}),
    "CPUExecutionProvider",
]
print(json.dumps({"runtime": ort.__version__, "mode": args.mode, "size": args.size}), flush=True)
session = ort.InferenceSession(args.model, sess_options=options, providers=providers)
session.disable_fallback()
if args.mode != "cpu":
    assert "DmlExecutionProvider" in session.get_providers(), "DirectML was not loaded"
print(session.get_providers(), flush=True)
rng = np.random.default_rng(42)
rgb = rng.random((1, 3, args.size, args.width or args.size), dtype=np.float32)
mask = np.zeros((1, 1, args.size, args.width or args.size), dtype=np.float32)
mask[:, :, args.size // 3:args.size // 2, args.size // 3:args.size // 2] = 1
for run in range(2):
    start = time.perf_counter()
    output = session.run(None, {"image": rgb, "mask": mask})[0]
    assert output.shape == rgb.shape and np.isfinite(output).all()
    print(json.dumps({"run": run, "seconds": time.perf_counter() - start, "min": float(output.min()), "max": float(output.max())}), flush=True)
if args.profile:
    from collections import Counter
    with open(session.end_profiling()) as f:
        events = json.load(f)
    print(Counter(e["args"]["provider"] for e in events if e.get("args", {}).get("provider")), flush=True)
options.enable_profiling = False
if args.compare:
    cpu = ort.InferenceSession(args.compare, sess_options=options, providers=["CPUExecutionProvider"])
    reference = cpu.run(None, {"image": rgb, "mask": mask})[0]
    delta = np.abs(reference - output)
    print(json.dumps({"max_error": float(delta.max()), "mean_error": float(delta.mean())}), flush=True)
    np.testing.assert_allclose(output, reference, atol=2e-4, rtol=2e-4)
