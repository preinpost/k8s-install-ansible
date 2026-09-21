# lima VM 설치 테스트

로컬 lima VM 3대(cp1 / w1 / w2)에 실제로 클러스터를 올려보는 테스트 환경.

## VM 생성

```bash
# SSH 포워딩 포트 시작값 (VM 마다 +1).
# 고정하지 않으면 기동할 때마다 랜덤 포트가 잡혀서 인벤토리가 틀어진다.
startport=60021

i=0
for n in cp1 w1 w2; do
  limactl start --name=$n template://ubuntu-24.04 \
    --vm-type vz --network lima:user-v2 \
    --cpus 2 --memory 4 --disk 20 \
    --containerd none --mount-none \
    --ssh-port $((startport + i)) -y
  i=$((i + 1))
done
# cp1=60021, w1=60022, w2=60023
```

이미 만든 VM 에 나중에 적용하려면 (재생성 불필요):

```bash
startport=60021
i=0
for n in cp1 w1 w2; do
  limactl stop $n
  limactl edit $n --ssh-port $((startport + i)) --start
  i=$((i + 1))
done
```

## 인벤토리 갱신

`--ssh-port` 로 포트를 고정했으면 인벤토리를 다시 만들 일이 없다.
포트를 고정하지 않았거나 구성이 바뀔 때는:

```bash
./inventories/lima_inventory/gen-inventory.sh
```

현재 값:

| VM  | SSH             | node_ip       | k8s hostname        |
| --- | --------------- | ------------- | ------------------- |
| cp1 | 127.0.0.1:58106 | 192.168.104.1 | test-controlplane-1 |
| w1  | 127.0.0.1:58117 | 192.168.104.3 | test-worker-1       |
| w2  | 127.0.0.1:58128 | 192.168.104.4 | test-worker-2       |

user-v2 IP 는 인스턴스 이름 기준이라 VM 을 지우고 다시 만들어도 유지된다.
(실측: 재생성 전후 모두 cp1=.1 / w1=.3 / w2=.4, 바뀐 건 SSH 포트뿐)

`lima:user-v2` 는 VM↔VM 통신만 되고 호스트에서 `192.168.104.x` 로는 직접 못 간다.
그래서 SSH 는 `127.0.0.1:<포워딩 포트>`, 클러스터 내부 주소(advertiseAddress / node-ip /
certSANs / `/etc/hosts`)는 `node_ip` 로 분리해서 쓴다.

## 실행

`ansible/` 디렉터리에서:

```bash
# 연결 확인
ansible -i inventories/lima_inventory/inventory.yaml k8s_group -m ping

# 전체 설치 (cp1 init + Calico + worker 2대 join)
ansible-playbook -i inventories/lima_inventory/inventory.yaml \
  playbooks/playbook-k8s-install.yaml

# 컨트롤플레인만 먼저
ansible-playbook -i inventories/lima_inventory/inventory.yaml \
  playbooks/playbook-k8s-install.yaml --limit cp1

# 처음부터 다시 (전 노드 reset)
ansible-playbook -i inventories/lima_inventory/inventory.yaml \
  playbooks/playbook-k8s-reset.yaml
```

## 확인

```bash
limactl shell cp1 -- kubectl get nodes -o wide
limactl shell cp1 -- kubectl get pods -A
```

## 참고

- 설치 버전은 `group_vars/k8s_group.yaml` 에서 조정 (운영 인벤토리와 같은 값 유지).
- lima VM 은 NOPASSWD sudo 라 `ansible_become_password` 가 없다.
- 완전히 갈아엎고 싶으면 `limactl delete -f cp1 w1 w2` 후 위 생성 명령 재실행.
