# Agentic ANN — architecture setup

**Status:** Integrated. Describes the agent-driven artificial neural network framework built in [`ann-text-project/agentic_ann/`](https://github.com/Giansn) that reuses components from this Network monorepo.

**Companion docs:** [`AGENT_NODE_NETWORK_DRAFT.md`](AGENT_NODE_NETWORK_DRAFT.md) (topology / phases), [`NEURAL_NETWORK_SETUP.md`](NEURAL_NETWORK_SETUP.md) (OpenVINO install / run / expand).

---

## 1. Overview

Agentic ANN is a **tool-calling agent loop** that autonomously trains, evaluates, profiles, and deploys neural networks. It combines patterns from five indexed repositories:

| Source | What was taken |
|--------|---------------|
| **Giansn/Network** (`wire_tensor.py`, `placement.py`, `mcp_npu_server.py`) | Tensor serialization codec, split-inference topology, MCP tool pattern |
| **google-ai-edge/gallery** (`AgentTools.kt`, `MobileActionsTools.kt`) | `@Tool` / `ToolSet` decorator pattern → Python `@tool` registry |
| **pytorch/kineto** (`torch.profiler`) | Kineto-backed performance tracing with schedule/trace handlers |
| **harshit433/ANN-from-scratch** (`Polynomial3`) | Raw `nn.Parameter` + Xavier init MLP (`ScratchNet`) |
| **PyTorch Blitz tutorial** (DB-seeded layer specs) | LeNet-style CNN (`BlitzNet`) with conv/pool/FC layers |

---

## 2. Architecture diagram

```
┌──────────────────────────────────────────────────┐
│                    Agent Loop                     │
│  (ReAct: observe → think → act → observe)        │
│                                                   │
│  ┌───────────────────────────────────────────────┐│
│  │            Tool Registry (14 tools)           ││
│  │  @tool decorator (Gallery ToolSet pattern)    ││
│  └──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──────┘│
└─────┼──┼──┼──┼──┼──┼──┼──┼──┼──┼──┼──┼──┼───────┘
      │  │  │  │  │  │  │  │  │  │  │  │  │
      ▼  ▼  ▼  ▼  ▼  ▼  ▼  ▼  ▼  ▼  ▼  ▼  ▼

 ┌─────────────┐ ┌──────────────────────────────────┐
 │ Core Tools  │ │ Network Tools (from this repo)    │
 │             │ │                                    │
 │ create_model│ │ export_activations (wire_tensor)   │
 │ train       │ │ verify_wire_codec  (roundtrip)     │
 │ evaluate    │ │ split_bandwidth    (boundary est.) │
 │ profile_run │ │ split_inference    (placement.py)  │
 │ save_run    │ │ list_openvino_devices (MCP pattern)│
 │ db_status   │ └──────────────────────────────────┘
 │ list_layers │
 │ list_steps  │
 │ inspect     │
 └──────┬──────┘
        │
   ┌────┴─────┐  ┌──────────┐  ┌─────────┐  ┌──────────┐
   │  Models  │  │ Trainer  │  │Profiler  │  │ DB Store │
   │ BlitzNet │  │ fit()    │  │torch.    │  │ PG /     │
   │ Scratch  │  │ eval()   │  │profiler  │  │ SQLite   │
   │  Net     │  │          │  │(Kineto)  │  │          │
   └──────────┘  └──────────┘  └──────────┘  └──────────┘
```

---

## 3. What came from this repo (Network)

### 3.1 `wire_tensor.py` — tensor serialization

Copied verbatim from `network/edge_npu_infer/wire_tensor.py`. Provides:

- `pack_tensor(arr)` → bytes (NumPy `.npy` format, `allow_pickle=False`)
- `unpack_tensor(data)` → ndarray
- `tensor_nbytes(arr)` → raw element byte count for bandwidth planning

Used by three agent tools: `export_activations`, `verify_wire_codec`, `split_inference`.

### 3.2 Split inference (`placement.py` topology)

The `SPLIT_EDGE_GATEWAY` pattern from `placement.py` is adapted as the `split_inference` agent tool:

- **Stage A** (conv layers): runs on the "edge" side
- **Wire boundary**: mid activation serialized through `wire_tensor` codec
- **Stage B** (FC layers): runs on the "gateway" side
- **Verification**: output compared to full-model forward pass (must match exactly)

Proven result: `BlitzNet` split at conv→FC boundary, mid shape `[1, 400]` = **1,728 bytes** on wire, outputs match.

### 3.3 MCP tool pattern (`mcp_npu_server.py`)

The `@mcp.tool` decorator pattern for exposing inference as Cursor MCP tools maps directly to the `@tool` decorator in `agentic_ann/tools/registry.py`. The `list_openvino_devices` tool follows the same structure as `openvino_list_devices` from the MCP server.

---

## 4. Database schema (PostgreSQL + SQLite)

Runs are persisted in `ann_dev` (PostgreSQL) or `db/data/local.db` (SQLite):

| Table | Content |
|-------|---------|
| `tutorial_ref` | Canonical tutorials (e.g. PyTorch Blitz NN) |
| `model_def` | Model class definitions tied to tutorials |
| `layer_spec` | Per-layer config (matches `nn.Conv2d` / `nn.Linear` args) |
| `training_step` | Six-step training procedure from the tutorial |
| `loss_recipe` | Loss functions with usage notes |
| `optimizer_recipe` | Optimizer patterns (manual SGD vs `torch.optim`) |
| `tutorial_concept` | Recap terms (`Tensor`, `Module`, `Parameter`, etc.) |
| `runs` | Experiment runs with `tutorial_id`, `model_id`, `lr`, `loss_name`, `optimizer_name` |

---

## 5. Running the agent

```bash
cd ann-text-project
source .venv/bin/activate

# Train + evaluate + save
PG_DBNAME=ann_dev python -m agentic_ann "train blitz_net and save" --epochs 5

# Split inference with wire verification
PG_DBNAME=ann_dev python -m agentic_ann "train blitz_net then split inference and verify wire codec"

# Profile with Kineto traces
PG_DBNAME=ann_dev python -m agentic_ann "profile blitz_net" --epochs 2

# ScratchNet (raw parameters, no nn.Linear)
PG_DBNAME=ann_dev python -m agentic_ann "train scratch_net" --model scratch_net --epochs 10
```

---

## 6. File layout (ann-text-project/agentic_ann/)

```
agentic_ann/
├── __init__.py              # Package metadata
├── __main__.py              # CLI entry point
├── agent.py                 # ReAct agent loop + memory
├── config.py                # Env-var defaults
├── tools/
│   ├── base.py              # AgentTool ABC
│   ├── registry.py          # @tool decorator + ToolRegistry
│   ├── builtin_tools.py     # 9 core tools
│   ├── network_tools.py     # 5 tools from Network repo
│   └── wire_tensor.py       # Copied from Network/network/edge_npu_infer/
├── models/
│   ├── architectures.py     # BlitzNet, ScratchNet
│   └── trainer.py           # Training loop with profiler hook
├── db/
│   └── store.py             # PostgreSQL / SQLite persistence
└── profiling/
    └── profiler.py          # torch.profiler / Kineto wrapper
```

---

## 7. Cross-repo references

| This repo (Network) | Agentic ANN (ann-text-project) |
|---------------------|-------------------------------|
| `network/edge_npu_infer/wire_tensor.py` | `agentic_ann/tools/wire_tensor.py` (copy) |
| `network/edge_npu_infer/placement.py` `SPLIT_EDGE_GATEWAY` | `agentic_ann/tools/network_tools.py` `split_inference` |
| `network/edge_npu_infer/mcp_npu_server.py` `@mcp.tool` | `agentic_ann/tools/registry.py` `@tool` |
| `docs/AGENT_NODE_NETWORK_DRAFT.md` phase 4 (agent integration) | Agent loop consumes structured NN outputs |
| `docs/NEURAL_NETWORK_SETUP.md` expand section | Future: export `BlitzNet` to OpenVINO IR, run via `run_npu.py` |

---

## 8. Next steps

- [ ] Export trained `BlitzNet` / `ScratchNet` to **OpenVINO IR** (`.xml` + `.bin`) and run through `run_npu.py`
- [ ] Replace PyTorch split simulation with real `placement.py` OpenVINO `SplitStage` subgraphs
- [ ] Wire `send_tensor` / `recv_tensor` over gRPC/MQTT for true networked split inference
- [ ] Connect agent output to downstream consumers (phase 4 of agent node network draft)
- [ ] Add LLM-based planner (replace rule-based `Agent.plan()`) for natural-language goal parsing

---

*Last updated: aligned with `agentic_ann` v0.1.0, 14 tools, BlitzNet + ScratchNet models, PostgreSQL persistence.*
