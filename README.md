# Network

Monorepo for local edge/NPU tooling, AWS delegated VPC + Client VPN automation, lightweight Windows usage tracking, and **Agentic ANN** integration.

| Folder | Contents |
|--------|----------|
| [aws-node-network](aws-node-network/) | CloudFormation delegated VPC, Client VPN, EC2 bootstrap, TLS helpers, `scripts/Invoke-SsmRunEdgeInfer.ps1` (run `run_npu.py` on instance via SSM) |
| [network/edge_npu_infer](network/edge_npu_infer/) | OpenVINO NPU bind, placement patterns, optional MCP server, `Invoke-OpenVinoEnv.ps1` |
| [system-usage-tracker](system-usage-tracker/) | Low-overhead CPU/RAM CSV logger, optional scheduled task, `Get-NetworkSnapshot.ps1` |
| [docs/AGENT_NODE_NETWORK_DRAFT.md](docs/AGENT_NODE_NETWORK_DRAFT.md) | **Draft:** agent node networks — split OpenVINO stages, transport hooks, phased rollout |
| [docs/NEURAL_NETWORK_SETUP.md](docs/NEURAL_NETWORK_SETUP.md) | **Full NN setup:** OpenVINO smoke/split/IR, `wire_tensor`, MCP, SSM — *compare* with agent draft |
| [docs/AGENTIC_ANN_ARCHITECTURE.md](docs/AGENTIC_ANN_ARCHITECTURE.md) | **Agentic ANN:** architecture, tool registry, split inference, DB schema, cross-repo integration |

## Agentic ANN integration

Components from this repo power the `agentic_ann` agent framework:

- **`wire_tensor.py`** → tensor serialization tools (`export_activations`, `verify_wire_codec`)
- **`placement.py`** `SPLIT_EDGE_GATEWAY` → `split_inference` tool (conv→FC split with wire boundary)
- **`mcp_npu_server.py`** `@mcp.tool` → `@tool` decorator pattern + `list_openvino_devices`

Full architecture and setup: [docs/AGENTIC_ANN_ARCHITECTURE.md](docs/AGENTIC_ANN_ARCHITECTURE.md)

**Scope:** IP networking, AWS VPC/VPN, edge inference, and agent-driven NN workflows — not abstract "agent network" simulations (e.g. dualmirakl `network_resilience.yaml` stays in that project).

Upstream: [github.com/Giansn/Network](https://github.com/Giansn/Network)
