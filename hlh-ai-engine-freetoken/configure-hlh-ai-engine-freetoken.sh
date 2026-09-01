#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${SCRIPT_DIR}/ansible/inventories/hlh-ai-engine-freetoken.yml"
PLAYBOOK="${SCRIPT_DIR}/ansible/playbooks/hlh-ai-engine-freetoken.yml"

usage() {
	cat <<'EOF'
Usage:
	./configure-hlh-ai-engine-freetoken.sh [--offline]

This reconfigures an existing LXC 140 via Ansible (no LXC recreation).
Use this when the LXC already exists but you need to re-run configuration.

Options:
	--offline    Set HLH_OFFLINE=1 (skip model downloads, use only local files)
	-h|--help    Show this help message

EOF
}

OFFLINE_FLAG=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--offline)
			OFFLINE_FLAG="--extra-vars 'hlh_offline=true'"
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "ERROR: Unknown option: $1" >&2
			usage
			exit 1
			;;
	esac
done

command -v ansible-playbook >/dev/null 2>&1 || { echo "ERROR: ansible-playbook not found. Install Ansible first." >&2; exit 1; }
[[ -f "$PLAYBOOK" ]] || { echo "ERROR: Playbook not found: $PLAYBOOK" >&2; exit 1; }
[[ -f "$INVENTORY" ]] || { echo "ERROR: Inventory not found: $INVENTORY" >&2; exit 1; }

echo "Reconfiguring hlh-ai-engine-freetoken (LXC 140) via Ansible..."
ansible-playbook -i "$INVENTORY" $OFFLINE_FLAG "$PLAYBOOK"
