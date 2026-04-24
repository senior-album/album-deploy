# k3d CNI 교체 런북: flannel → Calico (T-053)

## 목적

현재 맥미니 k3d 클러스터는 기본 CNI 인 flannel 을 쓴다. flannel 은 NetworkPolicy
리소스를 수락하기만 하고 실제로 패킷 필터링을 하지 않는다 (fail-open).
`k8s/networkpolicies.yaml` (T-052) 이 main 에 들어가 있지만 enforce 되지 않는
상태다.

이 런북은 **클러스터를 재생성하면서 CNI 를 Calico 로 교체**해서 NetworkPolicy 가
실제로 작동하게 만드는 절차다.

## 사전 준비

- **예상 소요 시간**: 데이터 복원 포함 60–90분 (PVC 크기/네트워크 속도에 따라)
- **서비스 중단 시간**: 클러스터 delete 부터 앱 재apply + 데이터 복원까지 약 30–60분
- **정지 공지**: Cloudflare tunnel 기반이라 DNS 는 그대로 유지됨 — 사용자에겐 "점검 중" 페이지 대신 단순 5xx 가 보일 수 있음
- **전제**: 사용자가 맥미니에 로컬 로그인 or ssh 접근 가능, `kubectl`, `k3d`, `cloudflared` 설치됨

## ⚠️ 되돌릴 수 없는 스텝

`k3d cluster delete senior-album` 이 실행되는 순간 모든 PVC 데이터(postgres/minio/opensearch/uptime-kuma) 가 사라진다. **그 이전에 아래 백업 섹션이 전부 완료**되어 있어야 한다.

---

## Phase 0 — 백업 (delete 전 필수)

### 0-1. SealedSecrets 개인키 백업 ⚠️

**가장 중요한 스텝.** 이걸 놓치면 `k8s/sealed/` 에 있는 모든 SealedSecret 이 영구적으로 복호화 불가능해진다.

```bash
# 현재 활성 키 확인 (이상적으로 1 개)
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key

# 백업
mkdir -p ~/senior-album-migration-backup
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > ~/senior-album-migration-backup/sealed-secrets-master-key.yaml

# 내용 확인 — type 이 kubernetes.io/tls 인 Secret 이 최소 1 개
grep -c 'type: kubernetes.io/tls' \
  ~/senior-album-migration-backup/sealed-secrets-master-key.yaml
# 출력이 "1" 이상이어야 함
```

### 0-2. PostgreSQL 덤프 (수동 1회)

스케줄된 CronJob 을 기다리지 말고 지금 덤프를 찍는다.

```bash
# 방법 A: 스케줄 CronJob 에서 즉시 Job 파생
kubectl create job --from=cronjob/postgres-backup \
  postgres-backup-premigration -n senior-album

kubectl wait --for=condition=complete -n senior-album \
  job/postgres-backup-premigration --timeout=900s

# 로그로 성공 확인
kubectl logs -n senior-album job/postgres-backup-premigration | tail -20
# "[backup] done ..." 문자열이 나와야 함
```

R2 버킷에 `postgres/senior_album_<TS>.dump` 가 올라갔는지 Cloudflare 대시보드에서도 확인.

**백업 CronJob 이 아직 정상 동작하지 않는다면** (backup-secret 미설정 등) 로컬에서 직접:

```bash
kubectl exec -n senior-album deploy/postgres -- \
  pg_dump --no-owner --no-privileges -Fc -U postgres senior_album \
  > ~/senior-album-migration-backup/senior_album.dump
ls -lh ~/senior-album-migration-backup/senior_album.dump
# 수백 KB ~ 수 MB 정도. 0 byte 면 실패.
```

### 0-3. MinIO 덤프 (수동 1회)

```bash
kubectl create job --from=cronjob/minio-backup \
  minio-backup-premigration -n senior-album

kubectl wait --for=condition=complete -n senior-album \
  job/minio-backup-premigration --timeout=3600s

kubectl logs -n senior-album job/minio-backup-premigration | tail
# "[backup] done ..." 확인
```

CronJob 이 아직 없다면 `mc` 로컬 실행으로 R2 에 mirror — DEPLOY_GUIDE 의 MinIO 접근 방법 참고.

### 0-4. OpenSearch 인덱스 — 재색인 계획

얼굴 임베딩 인덱스(`face_embeddings` 등)는 백엔드에서 postgres 의 원본 사진에서 재생성 가능해야 한다. 백엔드에 재색인 엔드포인트가 있는지 확인:

```bash
# 예시 — 백엔드에 관리자용 재색인 엔드포인트가 있는 경우
kubectl exec -n senior-album deploy/backend -- \
  curl -s http://localhost:8000/admin/reindex/status || true
```

**없다면** 이 런북 실행 전에 백엔드에 간단한 재색인 스크립트를 먼저 준비해야 한다. 없는 채로 진행하면 얼굴 검색 기능이 클러스터 재생성 후 빈 상태가 된다.

### 0-5. uptime-kuma 설정 백업 (optional)

uptime-kuma 모니터 정의는 재입력이 크지 않아 백업 생략 가능. 꼭 보존하고 싶으면:

```bash
kubectl cp senior-album/$(kubectl get pod -n senior-album -l app=uptime-kuma -o jsonpath='{.items[0].metadata.name}'):/app/data/kuma.db \
  ~/senior-album-migration-backup/uptime-kuma.db
```

### 0-6. 로컬 전용 매니페스트 확인

`.gitignore` 로 git 에 없는 파일들 — 로컬 사본이 있어야 재apply 가능.

```bash
ls -la k8s/secret.yaml k8s/cloudflared.yaml k8s/configmap.yaml
# 셋 다 존재해야 함. 없으면 DEPLOY_GUIDE 의 "시크릿 수정" 단계 재수행.
```

### 0-7. 현재 상태 스냅샷

```bash
kubectl get all -n senior-album > \
  ~/senior-album-migration-backup/pre-swap-state.txt
kubectl get networkpolicy -n senior-album >> \
  ~/senior-album-migration-backup/pre-swap-state.txt
kubectl get secret -n senior-album >> \
  ~/senior-album-migration-backup/pre-swap-state.txt
```

---

## Phase 1 — 클러스터 재생성

### 1-1. 현재 클러스터 삭제

```bash
k3d cluster delete senior-album
```

PVC 전부 소멸. 복원 불가 지점.

### 1-2. flannel 끈 채로 재생성

```bash
k3d cluster create senior-album \
  --port "80:80@loadbalancer" \
  --port "443:443@loadbalancer" \
  --agents 0 \
  --servers 1 \
  --k3s-arg '--flannel-backend=none@server:*' \
  --k3s-arg '--disable-network-policy@server:*' \
  --k3s-arg '--cluster-cidr=10.42.0.0/16@server:*' \
  --k3s-arg '--service-cidr=10.43.0.0/16@server:*'
```

주요 포인트:
- `--flannel-backend=none`: k3s 가 flannel 설치하지 않음
- `--disable-network-policy`: k3s 기본 정책 컨트롤러도 제거 (Calico 것 사용)
- `--cluster-cidr=10.42.0.0/16`: k3s 기본 pod CIDR 유지 (Calico 설정도 여기 맞춤)

이 직후 노드가 `NotReady` 상태일 것 — CNI 가 없어서 정상. Calico 설치하면 Ready 로 바뀜.

```bash
kubectl get nodes
# STATUS: NotReady  ← 정상
```

### 1-3. Calico 설치

```bash
# Manifest 방식 (operator 아님 — 단일 노드 k3d 에선 이게 단순함)
# 버전은 실행 시점의 최신 stable 확인: https://github.com/projectcalico/calico/releases
CALICO_VERSION=v3.28.2

kubectl apply -f \
  https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml
```

pod CIDR 확인 — Calico 기본값이 `192.168.0.0/16` 이라 k3s 기본 `10.42.0.0/16` 과 다르면 수정 필요. 최신 calico.yaml 은 환경변수 `CALICO_IPV4POOL_CIDR` 주석 처리돼 있어 대체로 노드에서 자동 감지. 문제 시:

```bash
kubectl -n kube-system set env daemonset/calico-node \
  CALICO_IPV4POOL_CIDR=10.42.0.0/16
kubectl -n kube-system rollout restart daemonset/calico-node
```

Calico 준비 대기:

```bash
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl wait --for=condition=ready -n kube-system pod -l k8s-app=calico-node --timeout=300s

kubectl get nodes
# STATUS: Ready  ← 여기 도달해야 다음 단계
```

### 1-4. SealedSecrets controller 설치 + 키 복원

```bash
# 1) controller 설치 (네임스페이스 & Deployment 생성)
SEALED_VERSION=v0.27.2  # 또는 기존 클러스터가 쓰던 버전에 맞출 것
kubectl apply -f \
  https://github.com/bitnami-labs/sealed-secrets/releases/download/${SEALED_VERSION}/controller.yaml

# 2) 자동 생성된 새 키 삭제 (복원할 old 키로 대체)
kubectl delete secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key

# 3) 백업한 키 복원
kubectl apply -f \
  ~/senior-album-migration-backup/sealed-secrets-master-key.yaml

# 4) controller 재시작 해서 복원한 키 로드
kubectl -n sealed-secrets rollout restart deployment/sealed-secrets-controller
kubectl -n sealed-secrets rollout status deployment/sealed-secrets-controller --timeout=120s

# 5) 검증 — 기존 SealedSecret 한 개 apply 해서 복호화 되는지 테스트
kubectl apply -f k8s/sealed/backend-secret.yaml
kubectl get secret -n senior-album backend-secret
# "Opaque" Secret 이 정상 생성되면 키 복원 성공.
# 안 되면 SealedSecret 상태 확인:
#   kubectl get sealedsecret -n senior-album -o wide
```

**5) 단계에서 실패하면 즉시 중단.** 뭔가 잘못된 것. 키 백업 파일 다시 확인 or ops 상담.

---

## Phase 2 — 워크로드 재apply

### 2-1. 네임스페이스 + 인프라

```bash
cd /path/to/album-deploy

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/sealed/          # 모든 SealedSecret
kubectl apply -f k8s/configmap.yaml   # 로컬 전용
kubectl apply -f k8s/secret.yaml      # 로컬 전용 (SealedSecrets 이전 레거시 있으면)

kubectl apply -f k8s/postgres.yaml
kubectl apply -f k8s/redis.yaml
kubectl apply -f k8s/minio.yaml       # minio + minio-init Job
kubectl apply -f k8s/opensearch.yaml

kubectl -n senior-album wait --for=condition=ready pod -l app=postgres --timeout=180s
kubectl -n senior-album wait --for=condition=ready pod -l app=redis --timeout=60s
kubectl -n senior-album wait --for=condition=ready pod -l app=minio --timeout=120s
kubectl -n senior-album wait --for=condition=ready pod -l app=opensearch --timeout=300s
```

### 2-2. 앱

```bash
kubectl apply -f k8s/backend.yaml
kubectl apply -f k8s/frontend.yaml
kubectl apply -f k8s/ingress.yaml
kubectl apply -f k8s/cloudflared.yaml  # 로컬 전용 (T-002 에서 SealedSecret 이관 안 함)
kubectl apply -f k8s/uptime-kuma.yaml
kubectl apply -f k8s/minio-backup.yaml
kubectl apply -f k8s/postgres-backup.yaml
```

### 2-3. NetworkPolicy apply ⚠️

**이 시점까지 위 파드들이 전부 Running 인지 먼저 확인.** 정책 apply 후에도 기존 세션은 유지되지만 신규 연결이 차단될 수 있어, 파드가 Ready 이후 apply 해야 순서 꼬임 없음.

```bash
kubectl get pod -n senior-album
# 모두 Running + Ready 인지 확인

kubectl apply -f k8s/networkpolicies.yaml

kubectl get networkpolicy -n senior-album
# 13 개 정책 확인
```

---

## Phase 3 — 데이터 복원

### 3-1. PostgreSQL 복원

```bash
# R2 에서 최신 덤프 다운로드 (mc 로컬 or Cloudflare 대시보드)
# 덤프 파일: postgres/senior_album_<TS>.dump

# 복원
kubectl cp ~/path/to/senior_album_<TS>.dump \
  senior-album/$(kubectl get pod -n senior-album -l app=postgres -o jsonpath='{.items[0].metadata.name}'):/tmp/restore.dump

kubectl exec -n senior-album deploy/postgres -- \
  pg_restore --no-owner --no-privileges -d senior_album \
    -U postgres --clean --if-exists /tmp/restore.dump

# 검증
kubectl exec -n senior-album deploy/postgres -- \
  psql -U postgres -d senior_album -c \
  "SELECT COUNT(*) FROM residents; SELECT COUNT(*) FROM photos;"
# 복원 전 데이터와 일치하는지 비교
```

### 3-2. MinIO 복원

```bash
# mc alias 설정 (로컬 머신에서)
mc alias set r2 <R2_ENDPOINT> <R2_ACCESS_KEY> <R2_SECRET_KEY>
mc alias set local http://localhost:9000 <MINIO_ACCESS_KEY> <MINIO_SECRET_KEY>
# MinIO 에 로컬 접근하려면:
kubectl port-forward -n senior-album svc/minio 9000:9000 &

# 미러 (R2 → local MinIO)
mc mirror r2/senior-album-photos-backup/ local/senior-album-photos/

# 검증
mc ls local/senior-album-photos/ | wc -l
```

### 3-3. OpenSearch 재색인

백엔드 재색인 엔드포인트 호출:

```bash
kubectl exec -n senior-album deploy/backend -- \
  curl -X POST -s http://localhost:8000/admin/reindex/faces
```

백엔드에 이런 엔드포인트가 없다면 Phase 0-4 에서 미리 준비했어야 함 — 없는 채로 여기까지 왔다면 얼굴 검색 기능이 일시 비활성화된 상태로 진행.

### 3-4. uptime-kuma 설정

- 백업한 `kuma.db` 가 있으면 uptime-kuma pod 에 복사 후 재시작
- 없으면 관리자 UI 에서 모니터 재입력

---

## Phase 4 — 검증

### 4-1. 전체 헬스체크

```bash
kubectl get pod -n senior-album
# 모두 Running / Ready

kubectl get networkpolicy -n senior-album
# 13 개

kubectl -n senior-album logs -l app=cloudflared | tail -20
# "Connection registered" 여러 개 보여야 정상
```

### 4-2. NetworkPolicy enforce 검증 (핵심)

정책이 "진짜로" 작동하는지 양성/음성 테스트.

**양성 (통과해야 하는 것):**
```bash
# backend → postgres:5432 (정상 경로)
kubectl exec -n senior-album deploy/backend -- \
  nc -zv postgres 5432
# "succeeded" 나와야 함

# frontend → backend:8000 (정상 경로)
kubectl exec -n senior-album deploy/frontend -- \
  wget -q -O- --timeout=5 http://backend:8000/health
# 정상 응답
```

**음성 (차단돼야 하는 것):**
```bash
# frontend → postgres:5432 (차단돼야 함)
kubectl exec -n senior-album deploy/frontend -- \
  timeout 5 nc -zv postgres 5432
# "timed out" 또는 즉시 실패. "succeeded" 나오면 CNI enforce 안 되는 상태.

# cloudflared → opensearch:9200 (차단돼야 함)
kubectl exec -n senior-album deploy/cloudflared -- \
  timeout 5 nc -zv opensearch 9200
# 위와 동일하게 실패해야 함
```

양성만 통과 + 음성만 차단 = 성공.

### 4-3. 외부 접속 검증

브라우저에서 `https://<your-domain>` 접속, 로그인, 사진 업로드/조회 정상 동작 확인.

### 4-4. 백업 CronJob 재검증

```bash
# postgres 백업 트리거
kubectl create job --from=cronjob/postgres-backup postgres-backup-post-swap -n senior-album
kubectl wait --for=condition=complete -n senior-album job/postgres-backup-post-swap --timeout=600s
kubectl logs -n senior-album job/postgres-backup-post-swap | tail
# 정책상 외부 443 egress 열려 있어 R2 업로드 성공해야 함
```

실패하면 `networkpolicies.yaml` 의 `postgres-backup` 정책 검토.

---

## Phase 5 — 정리

- `~/senior-album-migration-backup/` 유지 (2주 이상 보관 권장)
- `sealed-secrets-master-key.yaml` 은 안전한 곳에 추가 백업 (1Password, hardware vault)
- 이 런북 실행 기록 (phase 별 완료 시각, 이슈 발생 항목) 을 roadmap#<T-053 issue> 에 코멘트로 남기기

---

## 롤백 시나리오

Phase 1 중 Calico 설치가 실패하면 같은 방식으로 flannel 로 되돌릴 수 있음:

```bash
k3d cluster delete senior-album
k3d cluster create senior-album \
  --port "80:80@loadbalancer" --port "443:443@loadbalancer" \
  --agents 0 --servers 1
# flannel 기본값으로 원상복귀. 이후 Phase 1-4, Phase 2, Phase 3 동일하게 재수행.
```

NetworkPolicy 파일은 main 에 그대로 있지만 enforce 되지 않는 원상 상태로 돌아감.

---

## 참고 자료

- Calico + k3d: https://docs.tigera.io/calico/latest/getting-started/kubernetes/k3s/quickstart
- SealedSecrets backup/restore: https://github.com/bitnami-labs/sealed-secrets#how-can-i-do-a-backup-of-my-sealedsecrets
- k3s flannel 비활성화: https://docs.k3s.io/installation/network-options
