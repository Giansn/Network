#!/usr/bin/env bash
# Deploy delegated VPC + Client VPN (Linux/macOS). Same inputs as deploy.ps1.
#
# Prerequisites: AWS CLI v2; copy parameters.example.json -> my-params.json and set ACM ARNs.
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh eu-central-1 node-net-prod ./my-params.json
#
# Optional 4th arg: path to template (default: ./template.yaml next to this script).

set -euo pipefail

REGION="${1:?Usage: $0 <region> <stack-name> <parameter-json> [template.yaml]}"
STACK_NAME="${2:?}"
PARAM_FILE="${3:?}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${4:-$SCRIPT_DIR/template.yaml}"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Template not found: $TEMPLATE_FILE" >&2
  exit 1
fi
if [[ ! -f "$PARAM_FILE" ]]; then
  echo "Parameter file not found: $PARAM_FILE" >&2
  exit 1
fi

PARAM_ABS="$(cd "$(dirname "$PARAM_FILE")" && pwd)/$(basename "$PARAM_FILE")"

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides "file://${PARAM_ABS}"

aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs" \
  --output table
