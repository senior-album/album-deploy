# T-042 — Loki / Grafana / Alloy

senior-album 클러스터의 로그 수집 + 쿼리 인프라.

```
backend / frontend / postgres / minio / ... (stdout)
        ↓ (kubelet 의 /var/log/pods 마운트)
   Alloy DaemonSet  ── HTTP push ──→  Loki  ── chunks/index ──→  MinIO (`loki` 버킷)
                                       ↑
                                   쿼리 (HTTP)
                                       ↑
                                   Grafana (UI, port-forward 로 접근)
```

- **Loki**: single binary mode, MinIO s3 백엔드, retention 30일
- **Alloy**: DaemonSet, senior-album 네임스페이스 pod stdout 만 스크랩
- **Grafana**: 내부 전용. 외부 노출은 후속 (인증 정책 결정 후)

## 0. 사전 준비

이 디렉토리의 매니페스트를 apply 하기 전에 **MinIO 버킷 + 사용자** 를 먼저 만들어야 합니다 (Loki 가 기동되자마자 MinIO 에 chunks 쓰려고 시도).

## 1. MinIO 셋업 (맥에서)

```bash
# 1-1. mc 설치 (없으면)
brew install minio-mc

# 1-2. MinIO S3 API port-forward (mc 는 S3 API 포트 9000 을 사용. 9001 은 web console)
kubectl -n senior-album port-forward svc/minio 9000:9000 &
PF_PID=$!

# 1-3. mc alias 등록 (admin credential)
ADMIN_AK=$(kubectl -n senior-album get secret backend-secret -o jsonpath='{.data.MINIO_ACCESS_KEY}' | base64 -d)
ADMIN_SK=$(kubectl -n senior-album get secret backend-secret -o jsonpath='{.data.MINIO_SECRET_KEY}' | base64 -d)
mc alias set saminio http://localhost:9000 "$ADMIN_AK" "$ADMIN_SK"

# 1-4. loki 버킷 생성
mc mb saminio/loki

# 1-5. loki 전용 사용자 발급 (admin key 재사용 금지)
LOKI_AK="loki-$(openssl rand -hex 6)"
LOKI_SK=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
mc admin user add saminio "$LOKI_AK" "$LOKI_SK"

# 1-6. loki 사용자에게 loki 버킷 권한만 부여
cat > /tmp/loki-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:*"],
    "Resource": ["arn:aws:s3:::loki", "arn:aws:s3:::loki/*"]
  }]
}
EOF
mc admin policy create saminio loki-rw /tmp/loki-policy.json
mc admin policy attach saminio loki-rw --user "$LOKI_AK"
rm /tmp/loki-policy.json

# 1-7. port-forward 종료
kill $PF_PID

echo "LOKI_AK=$LOKI_AK"
echo "LOKI_SK=$LOKI_SK"
# 두 값을 §2 에서 sealing 할 때 사용. 절대 LLM/Slack 에 붙여넣지 말 것.
```

## 2. SealedSecret 생성 (맥에서)

```bash
# 2-1. controller 이름 확인 (postgres-rotation 런북 §0 패턴)
kubectl get deploy -A | grep -i sealed
# 예: kube-system   sealed-secrets-controller   1/1 ...
SEALED_CONTROLLER_NAME=sealed-secrets-controller   # 위 결과로 교체
SEALED_CONTROLLER_NS=kube-system

# 2-2. loki-secret seal
kubectl -n senior-album create secret generic loki-secret \
  --from-literal=ACCESS_KEY="$LOKI_AK" \
  --from-literal=SECRET_KEY="$LOKI_SK" \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace "$SEALED_CONTROLLER_NS" \
           --controller-name "$SEALED_CONTROLLER_NAME" \
           --format yaml > k8s/sealed/loki-secret.yaml

# 2-3. grafana-secret seal (admin 비밀번호 생성)
GRAFANA_PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
kubectl -n senior-album create secret generic grafana-secret \
  --from-literal=ADMIN_PASSWORD="$GRAFANA_PW" \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace "$SEALED_CONTROLLER_NS" \
           --controller-name "$SEALED_CONTROLLER_NAME" \
           --format yaml > k8s/sealed/grafana-secret.yaml

# 2-4. 비밀번호 별도 안전한 곳에 저장 (1Password 등). 이후 unset:
echo "Grafana admin password: $GRAFANA_PW"   # 1회 출력, 저장 후 unset
unset LOKI_AK LOKI_SK GRAFANA_PW

# 2-5. git 에 SealedSecret 커밋
git add k8s/sealed/loki-secret.yaml k8s/sealed/grafana-secret.yaml
git commit -m "feat(t-042): loki + grafana SealedSecrets"
git push
```

## 3. 매니페스트 apply (맥에서)

```bash
# 3-1. SealedSecret 먼저 (controller 가 디코드해서 Secret 생성)
kubectl apply -f k8s/sealed/loki-secret.yaml
kubectl apply -f k8s/sealed/grafana-secret.yaml

# 3-2. NetworkPolicy (loki/alloy/grafana 정책 + minio 정책 갱신)
kubectl apply -f k8s/networkpolicies.yaml

# 3-3. Loki / Grafana / Alloy
kubectl apply -f k8s/loki/loki.yaml
kubectl apply -f k8s/loki/grafana.yaml
kubectl apply -f k8s/loki/alloy.yaml

# 3-4. 모두 Ready 까지 대기
kubectl -n senior-album rollout status deployment/loki --timeout=180s
kubectl -n senior-album rollout status deployment/grafana --timeout=120s
kubectl -n senior-album rollout status daemonset/alloy --timeout=120s
```

## 4. 검증 (맥에서)

### 4-1. Loki 가 살아있고 MinIO 에 쓸 수 있는지
```bash
kubectl -n senior-album logs deployment/loki --tail=50 | grep -iE "ready|error|fatal" | head -10
# "Loki started" 또는 ready 신호. AccessDenied / forbidden 보이면 §1 권한 재확인.
```

### 4-2. Alloy 가 pod 발견 + push 하는지
```bash
kubectl -n senior-album logs daemonset/alloy --tail=30 | grep -iE "discovered|push|error" | head -10
# "discovered N targets" + push 성공 로그 보여야.
```

### 4-3. Grafana 접근
```bash
kubectl -n senior-album port-forward svc/grafana 3000:3000
# 브라우저: http://localhost:3000  (admin / §2-3 의 GRAFANA_PW)
# 좌측 Explore → Loki 데이터소스 선택 → 쿼리 입력:
#   {namespace="senior-album"}
# backend / frontend / postgres 등의 stdout 이 흐르는 게 보여야 함.
```

### 4-4. 특정 pod 로그 비교
```bash
# kubectl logs 와 Loki 쿼리 결과가 일치하는지
kubectl -n senior-album logs deployment/backend --tail=20

# Grafana Explore 에서:
#   {namespace="senior-album", app="backend"}
# 같은 라인이 보여야 함 (수십 초~1분 지연 정상).
```

## 5. retention 동작 확인 (T-182 Phase 2 전제)

retention 30일은 Loki 의 `compactor` 가 적용. 즉시 검증은 어렵고, MinIO 의
`loki/` 버킷 크기가 시간 지나도 무한 증가하지 않는 것으로 간접 확인.

라벨별 다중 retention (app log 30d / api access 90d / auth 1yr 등) 은
T-182 Phase 2 에서 추가 — 본 PR 에서는 global 30일만.

## 6. 트러블슈팅

### Loki pod CrashLoopBackOff
- MinIO 권한 부족: `mc admin policy attach` 누락 또는 잘못된 정책
- 버킷 미존재: `mc mb saminio/loki` 누락
- access/secret key 오타: `kubectl -n senior-album get secret loki-secret -o jsonpath='{.data.ACCESS_KEY}' | base64 -d` 로 확인 후 §1-5 결과와 비교

### Alloy 가 pod 발견 못함
- ServiceAccount RBAC 누락: `kubectl auth can-i list pods --as=system:serviceaccount:senior-album:alloy -n senior-album` → yes 나와야
- NetworkPolicy 가 K8s API 차단: `kubectl -n senior-album logs daemonset/alloy | grep -i "kubernetes api"` 확인

### Grafana 데이터소스 연결 실패
- NetworkPolicy 가 grafana → loki 차단: `kubectl describe networkpolicy grafana` 확인
- Loki 가 안 떠있음: §4-1 부터 다시

## 7. 관련

- `roadmap/docs/log-retention-policy.md` — retention 정책 (T-182)
- `roadmap/docs/legal/06_breach_notification_procedure.md` — 유출 조사 시 Loki 쿼리 의존 (T-181)
- `roadmap/docs/slo.md` — observation roadmap (T-040/T-042/T-122)
