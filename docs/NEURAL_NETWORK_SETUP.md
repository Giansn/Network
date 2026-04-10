# Neural network setup (OpenVINO edge + split placement)

This document is the **operational** companion to [`AGENT_NODE_NETWORK_DRAFT.md`](AGENT_NODE_NETWORK_DRAFT.md). That draft focuses on **agent-node topology** and phased rollout; **this** file covers **install, run, compare, and expand** into production IR models and networked tensor cuts.

---

## 1. What is in this repo (vs draft)

| Piece | Role |
|--------|------|
| [`network/edge_npu_infer/run_npu.py`](../network/edge_npu_infer/run_npu.py) | Smoke test: list devices, compile on **NPU/CPU/GPU**, optional `--xml` IR, timed inference, assert `EXECUTION_DEVICES`. |
| [`network/edge_npu_infer/placement.py`](../network/edge_npu_infer/placement.py) | **Split graph** demo: `SplitStage`, `run_split_pipeline`, `send_tensor` / `recv_tensor` hooks, `describe_split_boundary`. |
| [`network/edge_npu_infer/wire_tensor.py`](../network/edge_npu_infer/wire_tensor.py) | **Reference** `pack_tensor` / `unpack_tensor` for MQTT/gRPC/HTTP bodies (`allow_pickle=False`). |
| [`network/edge_npu_infer/mcp_npu_server.py`](../network/edge_npu_infer/mcp_npu_server.py) | Cursor MCP (stdio): list devices, tiny NPU ping, IR infer. |
| [`aws-node-network/scripts/Invoke-SsmRunEdgeInfer.ps1`](../aws-node-network/scripts/Invoke-SsmRunEdgeInfer.ps1) | Run `run_npu.py` on EC2 via SSM (CPU default; GPU only on GPU instances). |
| [`aws-node-network/`](../aws-node-network/) | VPC, Client VPN, bootstrap — path from edge laptop into cloud subnets. |

**Compare:** Use the **draft** when you design *where* stages run and *how* agents consume outputs. Use **this** guide when you *execute* OpenVINO locally, on EC2, or behind VPN.

---

## 2. Prerequisites

### 2.1 Python

- Python **3.10+** recommended (matches OpenVINO wheels).

### 2.2 OpenVINO

- Install from Intel docs; this repo pins **`openvino>=2024.5.0`** in [`requirements.txt`](../network/edge_npu_infer/requirements.txt).
- **Intel NPU (Meteor Lake / Arrow Lake / …):** Windows driver + OpenVINO NPU plugin; use `Invoke-OpenVinoEnv.ps1` on dev machines if needed.
- **EC2:** Typical instances have **CPU** only; use `--device CPU`. **GPU** requires GPU AMI + drivers. **NPU** is not EC2-standard.

### 2.3 Optional: MCP (Cursor)

- `pip install -r network/edge_npu_infer/requirements.txt` (includes `mcp`).
- Register server in Cursor MCP config (see header in `mcp_npu_server.py`).

---

## 3. Quick start (local)

```bash
cd network/edge_npu_infer
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# List devices, tiny built-in graph, bind to NPU (or CPU if no NPU)
python run_npu.py --device NPU --iterations 20
python run_npu.py --device CPU --iterations 20

# Your IR (model.xml + model.bin next to it)
python run_npu.py --device CPU --xml /path/to/model.xml --iterations 10
```

**Placement / split (same venv):**

```bash
python placement.py   # prints single vs split shapes + split boundary hint
```

---

## 4. Expand: from demo MatMul to real models

1. **Export** your trained model to **OpenVINO IR** (`model.xml` + `model.bin`) via OpenVINO Model Converter / POT / your framework plugin.
2. **Prove device** with `run_npu.py --xml model.xml --device NPU` (or CPU on server).
3. **Choose split point** using `placement.py` patterns: replace `make_stage_matmul_relu` with two `core.read_model` subgraphs (or one model split with `ov.Model` surgery / intermediate outputs — advanced).
4. **Measure** payload size: `describe_split_boundary(mid_shape)` or `wire_tensor.tensor_nbytes(arr)`.
5. **Wire** `send_tensor` / `recv_tensor` in `run_split_pipeline` to your transport; start from `wire_tensor.pack_tensor` / `unpack_tensor` over gRPC bytes or HTTP POST body.

---

## 5. Remote smoke (EC2 + SSM)

From Windows (AWS tools + permissions):

```powershell
.\aws-node-network\scripts\Invoke-SsmRunEdgeInfer.ps1 -Region eu-central-1 -InstanceId i-xxxxxxxx -Device CPU -Wait
```

The script pulls `run_npu.py` from **this** GitHub repo (`Giansn/Network` `main` by default). After you push changes, new hosts pick them up on the next run.

---

## 6. Security & ops notes

- **Tensor payloads:** Treat as **opaque binary**; authenticate TLS (or VPN) on the wire. Do not `allow_pickle=True` on untrusted bytes.
- **IR files:** Version-control **graphs** carefully; weights can be large — often distributed via S3/artifact store, not git.
- **NPU vs CPU fallback:** If NPU rejects ops, OpenVINO may silently involve CPU helpers — always log `EXECUTION_DEVICES` in production.

---

## 7. Optional: bounded NN in Sygnif (downstream)

The main Sygnif repo may ship a **small MLP** or training scripts for sentiment-style scores (e.g. `finance_agent/sentiment_mlp.py`, `scripts/train_sentiment_mlp.py`). That is **application-specific**; this Network monorepo stays **generic OpenVINO + networking**. Link Sygnif only at integration time (HTTP sidecar, Docker `finance-agent`, etc.).

---

## 8. Checklist (production-leaning)

- [ ] `run_npu.py` succeeds on target device with **your** IR.
- [ ] Split boundary shape + `tensor_nbytes` fit SLA / LTE / VPN budget.
- [ ] `send_tensor` / `recv_tensor` implemented with auth + timeouts + retries.
- [ ] Logging: device name, latency p50/p95, shape, version of IR.
- [ ] Rollback: single-node path (`Topology.SINGLE_NPU` equivalent) documented.

---

*Maintainers: keep `Invoke-SsmRunEdgeInfer.ps1` `$RepoPath` / `$GitHubRef` aligned with branches that contain `network/edge_npu_infer/run_npu.py`.*
