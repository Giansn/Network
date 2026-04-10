# Agent node networks (draft)

**Status:** Generic draft — not deployment-specific. Describes how to align **logical** split-inference stages with **physical** nodes (edge, gateway, cloud) and optional **agent** surfaces (bots, HTTP handlers) that consume bounded NN outputs without requiring an LLM API.

**Operational setup (install, run, EC2 SSM, expand to IR):** [`NEURAL_NETWORK_SETUP.md`](NEURAL_NETWORK_SETUP.md) — *compare* this draft (topology / phases) with that doc (commands and artifacts).

**Code reference in this repo:** `network/edge_npu_infer/placement.py` (OpenVINO stages + transport hooks), `network/edge_npu_infer/wire_tensor.py` (tensor bytes codec).

---

## 1. Goals

- Run **non-LLM** neural graphs (OpenVINO IR) with a clear **split boundary** so only a **narrow tensor** crosses the network.
- Map **stage A / stage B** to real hosts: laptop NPU, EC2 CPU, containers on a Docker bridge, etc.
- Let an **agent node** (process that handles user I/O) consume **structured** outputs (scores, intents, bins) and reply via **templates** or rules — no requirement for external generative LLM APIs for that loop.
- Reuse existing repo pieces: **Client VPN / VPC** (`aws-node-network/`), **remote infer via SSM** (`Invoke-SsmRunEdgeInfer.ps1`), **edge smoke** (`run_npu.py`, optional MCP in `mcp_npu_server.py`).

---

## 2. Logical structure (topology enum)

| Topology | Meaning |
|----------|---------|
| `SINGLE_NPU` (or single device) | Full `ov.Model` on one OpenVINO device (`CPU`, `NPU`, …). |
| `SPLIT_EDGE_GATEWAY` | Front subgraph near the sensor or user device; **mid activation** sent over the wire; back subgraph on gateway or cloud. |

---

## 3. Setup building blocks (reference implementation)

The draft API is implemented as:

- **`SplitStage`** — one compiled subgraph with a `.run(tensor)` forward.
- **`make_stage_matmul_relu(...)`** — demo subgraph factory (replace with real `read_model` IR for production).
- **`run_split_pipeline(core, device_a, device_b, send_tensor=..., recv_tensor=...)`** — wires two stages; **transport is injected** via `send_tensor` / `recv_tensor` (defaults: in-process no-op).

Canonical excerpt (keep in sync with `placement.py` on `main`):

```python
class Topology(Enum):
    SINGLE_NPU = "single_npu"
    SPLIT_EDGE_GATEWAY = "split_edge_gateway"


@dataclass
class SplitStage:
    name: str
    compiled: ov.CompiledModel

    def run(self, tensor: np.ndarray) -> np.ndarray:
        inp = self.compiled.inputs[0]
        out = self.compiled.outputs[0]
        req = self.compiled.create_infer_request()
        res = req.infer({inp: tensor.astype(inp.element_type.to_dtype())})
        return np.array(res[out])


def run_split_pipeline(
    core: ov.Core,
    device_a: str,
    device_b: str,
    send_tensor: Callable[[np.ndarray], Any] | None = None,
    recv_tensor: Callable[[Any], np.ndarray] | None = None,
) -> np.ndarray:
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
    n = int(np.prod(mid_shape))
    bytes_fp32 = n * 4
    return f"split tensor shape={mid_shape}, ~{bytes_fp32} B/forward (FP32)"
```

**Bandwidth discipline:** call `describe_split_boundary(mid_shape)` (or equivalent) whenever you change the cut so payload size stays explicit.

---

## 4. Physical mapping (generic)

| Logical role | Typical host | OpenVINO device | Connectivity |
|--------------|--------------|-----------------|--------------|
| Stage A (front) | Edge PC / gateway | `NPU` where available | Outbound to gateway or VPC |
| Wire | — | — | TLS gRPC/HTTP, MQTT, or VPN-internal socket; serialize `mid` tensor (shape, dtype, raw bytes or compressed) |
| Stage B (back) | Cloud VM or on-prem server | `CPU` common on cloud instances | Listen on private IP or localhost behind reverse proxy |
| Agent node | Same host as B, or adjacent container on a bridge network | N/A (Python/Go/etc.) | Reads `y` or post-processed labels; drives Telegram/HTTP/WebSocket |

**Example pattern (illustrative):** VPC primary NIC `eth0` in `10.x/16` or cloud provider subnet; Docker bridge `172.18.0.0/16` or `172.19.0.0/16` for co-located services; agent process resolves stage B via `127.0.0.1` or container DNS name.

---

## 5. Plan (phased)

| Phase | Deliverable |
|-------|-------------|
| **0 — Inventory** | List real interfaces, routes, and bridge networks on target hosts; name processes that will own stage A, wire, stage B, and agent I/O. |
| **1 — Local single-device** | `Topology.SINGLE_NPU` or single `CPU` path; replace demo `make_stage_matmul_relu` with packaged IR; prove latency and correctness. |
| **2 — Collocated split** | `run_split_pipeline` with identity transport or `127.0.0.1` gRPC between two processes on one machine; validate numerical parity with single-graph baseline. |
| **3 — Networked split** | Implement `send_tensor` / `recv_tensor` over VPN or mTLS into VPC; stage A on edge (NPU), stage B on cloud (CPU); add auth, retries, and payload size limits from `describe_split_boundary`. |
| **4 — Agent integration** | Define contract from stage B output to agent (JSON schema: intents, scores, safety flags); template-based replies; optional MCP tools exposing the same inference for IDE agents. |

---

## 6. Repo cross-links

| Area | Path |
|------|------|
| Split pipeline + hooks | `network/edge_npu_infer/placement.py` |
| NPU/CPU smoke | `network/edge_npu_infer/run_npu.py` |
| MCP (stdio) tools | `network/edge_npu_infer/mcp_npu_server.py` |
| VPC + Client VPN + EC2 | `aws-node-network/` (`STEPS.md`, `template.yaml`) |
| Run edge infer on instance | `aws-node-network/scripts/Invoke-SsmRunEdgeInfer.ps1` |

---

## 7. Non-goals (this draft)

- Does not mandate a specific orchestrator (K8s, Greengrass, etc.) — only shows where hooks belong.
- Does not replace Telegram Bot API or other **messaging** transports; those remain the user-facing channel.
- Does not define training — only **deployment and placement** of compiled graphs.

---

*Last updated: draft aligned with `placement.py` split-pipeline pattern and generic agent-node mapping.*
