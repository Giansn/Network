"""
Bind inference strictly to Intel NPU (OpenVINO) and verify execution_devices.

Uses a tiny built-in ov.Model (no external ONNX) so you can prove NPU is used.
For real workloads: replace build_tiny_model() with core.read_model("model.xml").
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import openvino as ov


def build_tiny_model() -> ov.Model:
    """Minimal FP32 graph (MatMul + bias + ReLU) suitable for device smoke tests."""
    try:
        ops = ov.opset14
    except AttributeError:
        ops = ov.opset13

    inp = ops.parameter([1, 4], dtype=np.float32, name="x")
    weight_data = np.random.default_rng(0).standard_normal((4, 8), dtype=np.float32)
    bias_data = np.random.default_rng(1).standard_normal((1, 8), dtype=np.float32)
    w = ops.constant(weight_data)
    b = ops.constant(bias_data)
    mm = ops.matmul(inp, w, False, False)
    t = ops.add(mm, b)
    out = ops.relu(t)
    return ov.Model(out, [inp])


def resolve_execution_devices(compiled: ov.CompiledModel) -> list[str]:
    # CompiledModel.get_property accepts str keys in current pybind builds.
    raw = compiled.get_property("EXECUTION_DEVICES")
    if isinstance(raw, str):
        return [d.strip() for d in raw.split(",") if d.strip()]
    if isinstance(raw, (list, tuple)):
        return [str(d) for d in raw]
    return [str(raw)]


def compile_or_die(core: ov.Core, model: ov.Model, device: str) -> ov.CompiledModel:
    """Compile on an explicit device. No AUTO — failures surface as errors, not silent fallback."""
    try:
        return core.compile_model(model, device)
    except Exception as exc:  # pragma: no cover - hardware dependent
        raise RuntimeError(
            f"compile_model(..., {device!r}) failed. "
            f"Available: {core.available_devices}. "
            f"Check drivers, OpenVINO NPU plugin, and that ops are supported on NPU."
        ) from exc


def assert_runs_on_npu(compiled: ov.CompiledModel, expected_substring: str = "NPU") -> None:
    devs = resolve_execution_devices(compiled)
    joined = ",".join(devs)
    if not any(expected_substring.upper() in d.upper() for d in devs):
        raise RuntimeError(
            f"Model compiled for NPU but EXECUTION_DEVICES is {devs!r}. "
            f"Work is not on the NPU — check unsupported ops or plugin split (CPU helper)."
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="OpenVINO NPU bind + verify")
    parser.add_argument(
        "--device",
        default="NPU",
        help='Explicit OpenVINO device name (default: NPU). Use "CPU" or "GPU" to compare.',
    )
    parser.add_argument("--iterations", type=int, default=20, help="Warmup + timed inference iterations")
    parser.add_argument(
        "--xml",
        default=None,
        metavar="MODEL.XML",
        help="Path to your OpenVINO IR (.xml); same folder should contain the paired .bin weights.",
    )
    args = parser.parse_args()

    core = ov.Core()
    avail = core.available_devices
    print(f"available_devices: {avail}")

    if args.device not in avail:
        print(f"error: requested device {args.device!r} is not in {avail}", file=sys.stderr)
        return 2

    if args.xml:
        xml_path = Path(args.xml).expanduser()
        if not xml_path.is_file():
            print(
                f"error: IR not found: {xml_path}\n"
                f"      --xml must be the real path to your model.xml (not a placeholder). "
                f"Omit --xml to use the built-in tiny graph.",
                file=sys.stderr,
            )
            return 2
        bin_path = xml_path.with_suffix(".bin")
        if not bin_path.is_file():
            print(
                f"warning: expected weights next to IR but missing: {bin_path}",
                file=sys.stderr,
            )
        model = core.read_model(str(xml_path))
    else:
        model = build_tiny_model()

    compiled = compile_or_die(core, model, args.device)
    devs = resolve_execution_devices(compiled)
    print(f"EXECUTION_DEVICES after compile: {devs}")

    if args.device.upper() == "NPU":
        assert_runs_on_npu(compiled)

    ireq = compiled.create_infer_request()
    input_tensor = compiled.inputs[0]
    shape = input_tensor.shape
    dtype = input_tensor.element_type.to_dtype()
    x = np.random.default_rng(42).standard_normal(shape, dtype=dtype)

    # Warmup
    for _ in range(max(1, args.iterations // 4)):
        ireq.infer({input_tensor: x})

    t0 = time.perf_counter()
    for _ in range(args.iterations):
        ireq.infer({input_tensor: x})
    elapsed = time.perf_counter() - t0
    print(
        f"{args.iterations} sync inferences on {args.device} in {elapsed * 1000:.2f} ms "
        f"({elapsed * 1000 / args.iterations:.3f} ms / inf)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
