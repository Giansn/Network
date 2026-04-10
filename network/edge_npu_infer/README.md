# Edge NPU / CPU inference (OpenVINO)

Small, dependency-light utilities for **OpenVINO** on **Intel NPU** (where available) or **CPU/GPU**.

## Files

| File | Purpose |
|------|---------|
| `run_npu.py` | CLI: device smoke, optional IR `--xml`, timing |
| `placement.py` | Split-graph demo + `run_split_pipeline` hooks |
| `wire_tensor.py` | `pack_tensor` / `unpack_tensor` for network hops |
| `mcp_npu_server.py` | Cursor MCP tools (stdio) |
| `requirements.txt` | `openvino`, `mcp` |
| `Invoke-OpenVinoEnv.ps1` | Windows env helper |

## Install

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Commands

```bash
python run_npu.py --device CPU --iterations 20
python run_npu.py --device NPU --iterations 20   # needs NPU + drivers
python run_npu.py --device CPU --xml /path/to/model.xml
python placement.py
```

## Split pipeline + wire (example)

```python
import openvino as ov
from placement import run_split_pipeline
from wire_tensor import make_wire_pair

core = ov.Core()
send, recv = make_wire_pair()
y = run_split_pipeline(core, "CPU", "CPU", send_tensor=send, recv_tensor=recv)
```

Full setup: [../../docs/NEURAL_NETWORK_SETUP.md](../../docs/NEURAL_NETWORK_SETUP.md).
