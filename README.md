# Network

Monorepo for local edge/NPU tooling, AWS delegated VPC + Client VPN automation, and lightweight Windows usage tracking.

| Folder | Contents |
|--------|----------|
| [aws-node-network](aws-node-network/) | CloudFormation delegated VPC, Client VPN, EC2 bootstrap, TLS helpers, `scripts/Invoke-SsmRunEdgeInfer.ps1` (run `run_npu.py` on instance via SSM) |
| [network/edge_npu_infer](network/edge_npu_infer/) | OpenVINO NPU bind, placement patterns, optional MCP server, `Invoke-OpenVinoEnv.ps1` |
| [system-usage-tracker](system-usage-tracker/) | Low-overhead CPU/RAM CSV logger, optional scheduled task, `Get-NetworkSnapshot.ps1` |
| [docs/AGENT_NODE_NETWORK_DRAFT.md](docs/AGENT_NODE_NETWORK_DRAFT.md) | **Draft:** agent node networks — split OpenVINO stages, transport hooks, phased rollout |
| [docs/NEURAL_NETWORK_SETUP.md](docs/NEURAL_NETWORK_SETUP.md) | **Full NN setup:** OpenVINO smoke/split/IR, `wire_tensor`, MCP, SSM — *compare* with agent draft |

**Scope:** IP networking, AWS VPC/VPN, and edge inference — not abstract “agent network” simulations (e.g. dualmirakl `network_resilience.yaml` stays in that project).

Upstream: [github.com/Giansn/Network](https://github.com/Giansn/Network)
