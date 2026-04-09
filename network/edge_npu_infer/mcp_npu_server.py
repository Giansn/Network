"""
MCP server: OpenVINO NPU pipeline tools for Cursor (stdio).

Cursor loads multiple MCP servers; the model in chat can call this server's tools
and your other MCP tools (e.g. AWS Knowledge) in the same session. This process
does not embed or call other MCP servers itself.

Cursor MCP (example — merge into your mcp config):

  "edge-npu": {
    "command": "python",
    "args": ["C:\\\\Users\\\\giank\\\\Network\\\\network\\\\edge_npu_infer\\\\mcp_npu_server.py"]
  }
"""

from __future__ import annotations

import json
from pathlib import Path
from threading import Lock
import numpy as np
import openvino as ov
from mcp.server.fastmcp import FastMCP

import run_npu as rn

mcp = FastMCP("edge-npu-openvino")

_runner_lock = Lock()
_tiny_compiled: ov.CompiledModel | None = None
_ir_compiled: dict[str, ov.CompiledModel] = {}


def _get_tiny_npu() -> ov.CompiledModel:
    global _tiny_compiled
    with _runner_lock:
        if _tiny_compiled is None:
            core = ov.Core()
            model = rn.build_tiny_model()
            _tiny_compiled = rn.compile_or_die(core, model, "NPU")
            rn.assert_runs_on_npu(_tiny_compiled)
        return _tiny_compiled


@mcp.tool(
    name="openvino_list_devices",
    description="List OpenVINO runtime devices (CPU, GPU, NPU) on this machine.",
)
def openvino_list_devices() -> str:
    core = ov.Core()
    return json.dumps({"available_devices": core.available_devices})


@mcp.tool(
    name="npu_tiny_infer_ping",
    description=(
        "Run a small fixed OpenVINO graph on the Intel NPU and return "
        "EXECUTION_DEVICES, output shape, and sample stats. Use to verify NPU is active."
    ),
)
def npu_tiny_infer_ping(iterations: int = 5) -> str:
    compiled = _get_tiny_npu()
    devs = rn.resolve_execution_devices(compiled)
    inp = compiled.inputs[0]
    out = compiled.outputs[0]
    dtype = inp.element_type.to_dtype()
    x = np.random.default_rng(0).standard_normal(inp.shape, dtype=dtype)
    req = compiled.create_infer_request()
    for _ in range(max(1, iterations)):
        r = req.infer({inp: x})
    y = np.array(r[out])
    return json.dumps(
        {
            "execution_devices": devs,
            "input_shape": list(inp.shape),
            "output_shape": list(y.shape),
            "output_mean": float(y.mean()),
            "output_std": float(y.std()),
            "iterations": iterations,
        },
        indent=2,
    )


@mcp.tool(
    name="npu_infer_from_ir",
    description=(
        "Load OpenVINO IR (.xml + .bin in same folder), compile on NPU, run one random "
        "inference with correct input shape, return devices and output stats. "
        "Use for your real vision/audio models."
    ),
)
def npu_infer_from_ir(xml_path: str, seed: int = 0) -> str:
    path = Path(xml_path).expanduser()
    if not path.is_file():
        return json.dumps({"error": f"IR not found: {path}"})

    key = str(path.resolve())
    core = ov.Core()
    with _runner_lock:
        if key not in _ir_compiled:
            model = core.read_model(str(path))
            _ir_compiled[key] = rn.compile_or_die(core, model, "NPU")
        compiled = _ir_compiled[key]

    devs = rn.resolve_execution_devices(compiled)
    if not any("NPU" in d.upper() for d in devs):
        return json.dumps(
            {
                "error": "Compiled for NPU but EXECUTION_DEVICES does not list NPU",
                "execution_devices": devs,
            }
        )

    inp = compiled.inputs[0]
    dtype = inp.element_type.to_dtype()
    rng = np.random.default_rng(seed)
    x = rng.standard_normal(inp.shape, dtype=dtype)
    req = compiled.create_infer_request()
    r = req.infer({inp: x})
    out = compiled.outputs[0]
    y = np.array(r[out])
    return json.dumps(
        {
            "xml": key,
            "execution_devices": devs,
            "input_shape": list(inp.shape),
            "output_shape": list(y.shape),
            "output_mean": float(np.mean(y)),
            "output_std": float(np.std(y)),
        },
        indent=2,
    )


if __name__ == "__main__":
    mcp.run(transport="stdio")
