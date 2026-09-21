#!/usr/bin/env bash
# lima VM 정보를 읽어서 inventory.yaml 을 다시 만든다.
#
# lima VM 을 재시작하면 SSH 포워딩 포트가 바뀔 수 있고(user-v2 는 IP 도 바뀔 수 있음),
# 그때마다 이 스크립트를 돌리면 된다.
#
#   ./gen-inventory.sh            # inventory.yaml 갱신
#   ./gen-inventory.sh --dry-run  # 결과만 출력
set -euo pipefail

cd "$(dirname "$0")"

# VM 이름:쿠버네티스 hostname:역할
NODES=(
  "cp1:test-controlplane-1:controlplane"
  "w1:test-worker-1:worker"
  "w2:test-worker-2:worker"
)

vm_ip() {
  limactl shell "$1" -- ip -4 -o addr show eth0 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1
}

vm_port() {
  limactl list --format '{{.Name}} {{.SSHLocalPort}}' 2>/dev/null \
    | awk -v n="$1" '$1 == n {print $2}'
}

vm_status() {
  limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null \
    | awk -v n="$1" '$1 == n {print $2}'
}

cp_block=""
worker_block=""

for entry in "${NODES[@]}"; do
  IFS=: read -r vm host role <<< "$entry"

  status="$(vm_status "$vm")"
  if [[ "$status" != "Running" ]]; then
    echo "ERROR: VM '$vm' 상태가 '${status:-없음}' 입니다. 'limactl start $vm' 후 다시 실행하세요." >&2
    exit 1
  fi

  port="$(vm_port "$vm")"
  ip="$(vm_ip "$vm")"
  if [[ -z "$port" || -z "$ip" ]]; then
    echo "ERROR: VM '$vm' 의 포트/IP 를 못 읽었습니다. (port='$port' ip='$ip')" >&2
    exit 1
  fi
  echo "  $vm -> ssh 127.0.0.1:$port, node_ip $ip, hostname $host" >&2

  block="        ${vm}:
          ansible_port: ${port}
          node_ip: ${ip}
          hostname: ${host}
"
  if [[ "$role" == "controlplane" ]]; then
    cp_block+="$block"
  else
    worker_block+="$block"
  fi
done

read -r -d '' HEADER <<'EOF' || true
# ------------------------------------------------------------------
# 로컬 lima VM 테스트용 인벤토리  (gen-inventory.sh 로 생성됨 — 직접 수정 X)
#
#   limactl start --name=<cp1|w1|w2> template://ubuntu-24.04 \
#     --vm-type vz --network lima:user-v2 \
#     --cpus 2 --memory 4 --disk 20 --containerd none --mount-none -y
#
# lima:user-v2 네트워크는 VM <-> VM 통신만 되고 호스트에서 VM IP 로는
# 직접 접근이 안 된다. 그래서
#   - SSH    : 127.0.0.1 + lima 포워딩 포트 (ansible_host / ansible_port)
#   - 노드 IP : 192.168.104.x (node_ip)
# 로 분리해서 쓴다.
#
# 실행:
#   ansible-playbook -i inventories/lima_inventory/inventory.yaml \
#     playbooks/playbook-k8s-install.yaml
# ------------------------------------------------------------------
EOF

output="${HEADER}
all:
  vars:
    ansible_host: 127.0.0.1
    ansible_user: $(whoami)
    ansible_ssh_private_key_file: '~/.lima/_config/user'
    # lima VM 은 NOPASSWD sudo 라 become password 가 필요 없다
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes'
    ansible_python_interpreter: /usr/bin/python3

  children:
    k8s_group:
      children:
        controlplane_group:
        worker_group:

    controlplane_group:
      hosts:
${cp_block}
    worker_group:
      hosts:
${worker_block}"

if [[ "${1:-}" == "--dry-run" ]]; then
  echo "$output"
else
  echo "$output" > inventory.yaml
  echo "inventory.yaml 갱신 완료" >&2
fi
