"""
Placement patterns for edge neural nets (non-LLM): single NPU vs split across networked nodes.

This module does not implement real sockets; wire `send_tensor` / `recv_tensor` to your
MQTT/HTTPS/gRPC layer the same way Greengrass components pass tensors between stages.
For a concrete bytes codec see `wire_tensor.py` (`pack_tensor` / `unpack_tensor`).

AWS-aligned workflow: optimize + package the model in the cloud, ship IR (or runtime bundle)
to devices, run inference locally with OpenVINO; multi-node = split at a narrow tensor
(embedding / pooled features) to cut bandwidth.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable

import numpy as np
import openvino as ov


class Topology(Enum):
    """Where the full compute graph executes."""

    SINGLE_NPU = "single_npu"
    """Entire ov.Model on one device (typical OpenVINO compile_model(..., 'NPU'))."""

    SPLIT_EDGE_GATEWAY = "split_edge_gateway"
    """Stage A on sensor/near-edge; narrow activation sent over network; stage B on gateway."""


@dataclass
class SplitStage:
    """One compiled subgraph."""

    name: str
    compiled: ov.CompiledModel

    def run(self, tensor: np.ndarray) -> np.ndarray:
        inp = self.compiled.inputs[0]
        out = self.compiled.outputs[0]
        req = self.compiled.create_infer_request()
        res = req.infer({inp: tensor.astype(inp.element_type.to_dtype())})
        return np.array(res[out])


def make_stage_matmul_relu(
    core: ov.Core,
    in_features: int,
    out_features: int,
    device: str,
    seed: int,
) -> SplitStage:
    """Small MatMul+ReLU subgraph for demonstration."""
    try:
        ops = ov.opset14
    except AttributeError:
        ops = ov.opset13

    rng = np.random.default_rng(seed)
    inp = ops.parameter([1, in_features], dtype=np.float32, name="x")
    w_data = rng.standard_normal((in_features, out_features), dtype=np.float32)
    w = ops.constant(w_data)
    mm = ops.matmul(inp, w, False, False)
    out = ops.relu(mm)
    model = ov.Model(out, [inp])
    compiled = core.compile_model(model, device)
    return SplitStage(name=f"matmul_relu_{device}", compiled=compiled)


def run_single_npu(core: ov.Core, device: str) -> np.ndarray:
    """Reference: one stage, one device (mirrors run_npu.py idea)."""
    stage = make_stage_matmul_relu(core, 8, 4, device, seed=0)
    x = np.random.default_rng(99).standard_normal((1, 8), dtype=np.float32)
    return stage.run(x)


def run_split_pipeline(
    core: ov.Core,
    device_a: str,
    device_b: str,
    send_tensor: Callable[[np.ndarray], Any] | None = None,
    recv_tensor: Callable[[Any], np.ndarray] | None = None,
) -> np.ndarray:
    """
    Two-stage pipeline: 8→16 on device A, then 16→4 on device B.

    Replace the default no-op transport with real network serialization.
    """
    if send_tensor is None:
        send_tensor = lambda t: t
    if recv_tensor is None:
        recv_tensor = lambda p: p

    front = make_stage_matmul_relu(core, 8, 16, device_a, seed=1)
    back = make_stage_matmul_relu(core, 16, 4, device_b, seed=2)

    x = np.random.default_rng(7).standard_normal((1, 8), dtype=np.float32)
    activ_mid = front.run(x)
    wire = send_tensor(activ_mid)
    y = back.run(recv_tensor(wire))
    return y


def describe_split_boundary(mid_shape: tuple[int, ...]) -> str:
    """Rough bandwidth hint: FP32 bytes per forward pass for the cut tensor."""
    n = int(np.prod(mid_shape))
    bytes_fp32 = n * 4
    return f"split tensor shape={mid_shape}, ~{bytes_fp32} B/forward (FP32)"


if __name__ == "__main__":
    import sys

    try:
        from wire_tensor import make_wire_pair
    except ImportError:
        make_wire_pair = None  # type: ignore[misc, assignment]

    _core = ov.Core()
    dev = "NPU" if "NPU" in _core.available_devices else "CPU"
    out_single = run_single_npu(_core, dev)
    out_split = run_split_pipeline(_core, dev, dev)
    print("single output shape:", out_single.shape, f"device={dev}")
    print("split (local identity transport) output shape:", out_split.shape)
    print(describe_split_boundary((1, 16)))
    if make_wire_pair:
        s, r = make_wire_pair()
        out_wire = run_split_pipeline(_core, dev, dev, send_tensor=s, recv_tensor=r)
        print("split (wire_tensor codec) output shape:", out_wire.shape)
        if out_wire.shape != out_split.shape:
            print("warning: shape mismatch vs identity split", file=sys.stderr)
