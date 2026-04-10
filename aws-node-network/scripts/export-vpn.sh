#!/usr/bin/env bash
# Export Client VPN .ovpn profile (Linux/macOS). Same as export-vpn.ps1.
#
# Usage: ./export-vpn.sh eu-central-1 node-net-prod ./node-net.ovpn

set -euo pipefail

REGION="${1:?Usage: $0 <region> <stack-name> <out.ovpn>}"
STACK_NAME="${2:?}"
OUT_FILE="${3:?}"

endpoint_id="$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='ClientVpnEndpointId'].OutputValue | [0]" \
  --output text)"

if [[ -z "$endpoint_id" || "$endpoint_id" == "None" ]]; then
  echo "ClientVpnEndpointId not found in stack outputs." >&2
  exit 1
fi

aws ec2 export-client-vpn-client-configuration \
  --region "$REGION" \
  --client-vpn-endpoint-id "$endpoint_id" \
  --output text >"$OUT_FILE"

echo "Wrote $OUT_FILE — add client cert/key blocks per AWS Client VPN docs, then connect with AWS VPN Client or OpenVPN."
