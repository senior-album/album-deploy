# OpenSearch Security 운영 문서 (T-004)

OpenSearch 클러스터에 Security 플러그인을 활성화하고 backend 가 TLS + basic auth
로 접속하도록 만드는 작업의 운영자 문서. 설계 배경/대안 검토는
`roadmap/docs/specs/T-004-opensearch-face-embedding-encryption.md` 참조.

---

## 작업 분할

T-004 는 운영 안전성을 위해 4 개 PR 로 분할:

| 단계 | 상태 | 산출물 | 런타임 영향 |
|---|---|---|---|
| **b** (이 PR) | 본 문서 | `opensearch-security-secret` SealedSecret 생성 + 부트스트랩 도구 | 0 — Secret 만 클러스터에 떠 있고 mount 되지 않음 |
| **c** | 다음 | `opensearch.yaml` security 활성화 + `backend-secret` 에 OPENSEARCH_* 키 추가 | 한 ArgoCD sync 로 동시 전환 — opensearch + backend 짧게 재시작 |
| **d** | 다음 | `face_embeddings` 인덱스 smoke test | 0 — 검증만 |
| **e** | 다음 | `hashed_resident_id` 마이그레이션 + 1 회 reindex | 짧은 reindex 다운타임 |

전략 선택지 비교 (전략 A demo cert vs B 자체 CA) 는 스펙 §2 / §3 + 본 PR 의
선행 논의에서 **A** 로 결정. 핵심: cluster-internal 트래픽이고 T-052
NetworkPolicy 가 별도로 MitM 벡터를 막을 예정이라 verify_certs=False 로 충분.

---

## b 단계 — 자격증명 부트스트랩 (런타임 영향 없음)

### 산출물

- `k8s/sealed/opensearch-security-secret.yaml` — 새 SealedSecret. 안에:
  - `internal_users.yml` (전체 파일 본문, admin + album_backend bcrypt 해시)
  - `admin-password` (admin 평문 — ops 비상 로그인용)
  - `backend-password` (album_backend 평문 — c 가 backend-secret 으로 옮길 때 추출)

### 부트스트랩 절차 (Mac mini 에서만 실행)

```bash
cd /Users/thekim123/workspace/senior-album/album-deploy
git checkout feat/T-004b-opensearch-security-assets
git pull

# 사전 확인 — kubeseal controller 의 정확한 위치
kubectl get deploy -A | grep -i sealed
# 기대 출력: 한 줄. 네임스페이스/이름이 디폴트 (kube-system / sealed-secrets-controller)
# 와 다르면 아래 export 로 override.

# (필요 시) export SEALED_CONTROLLER_NAME=...
# (필요 시) export SEALED_CONTROLLER_NS=...

bash scripts/bootstrap-opensearch-security.sh
```

스크립트 동작:
1. openssl 로 admin/backend 비번 2 개 생성 (Mac mini 로컬 — 외부 시스템 안 거침)
2. python3 + bcrypt 로 해시 (rounds=12, T-054 와 동일 강도)
3. `internal_users.yml` 본문 합성
4. kubectl + kubeseal 로 SealedSecret 생성 → `k8s/sealed/opensearch-security-secret.yaml`
5. 평문은 `mktemp` 임시 파일 1 회만 거치고 `trap` + 명시적 rm 로 즉시 삭제

평문 비번은 stdout 에 출력하지 **않는다**. 백업이 필요하면 클러스터에서 추출:

```bash
kubectl -n senior-album get secret opensearch-security-secret \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

### 커밋 + 머지

```bash
git diff k8s/sealed/opensearch-security-secret.yaml
# encryptedData 가 들어있는 SealedSecret 1 개만 새로 생긴다

git add k8s/sealed/opensearch-security-secret.yaml
git commit -m "security: T-004b — opensearch-security-secret bootstrap (roadmap#4)"
git push
```

머지 후 ArgoCD sync 결과:
- `senior-album` 네임스페이스에 `opensearch-security-secret` Secret 1 개가 추가됨
- 이 Secret 은 어느 Deployment 도 참조하지 않음 → opensearch / backend 양쪽 다 재시작 안 됨
- 정상 sync 검증: `kubectl -n senior-album get secret opensearch-security-secret`

---

## c 단계 — 활성화 (별도 PR, 한 sync 로 동시 전환)

c 의 핵심 원칙: **opensearch.yaml security 활성화 + backend-secret 의 OPENSEARCH_*
키 추가가 같은 PR / 같은 ArgoCD sync 안에 묶여야 한다**. 하나만 들어가면
backend ↔ opensearch 인증 미스매치로 짧은 다운타임.

c 의 작업 항목 (구현 시점에 본 문서 보강):
1. `k8s/opensearch.yaml`:
   - 이미지 bump: `opensearchproject/opensearch:2.11.0` → `2.18.0` (이상). 2.12+ 에서
     `OPENSEARCH_INITIAL_ADMIN_PASSWORD` 가 필수가 되므로 동시에 처리.
   - `DISABLE_SECURITY_PLUGIN: "true"` 제거
   - `OPENSEARCH_INITIAL_ADMIN_PASSWORD` env 를 `opensearch-security-secret.admin-password`
     에서 주입 (안전 디폴트, 실제 admin 인증은 mount 된 internal_users.yml 의 hash)
   - `opensearch-security-secret.internal_users.yml` 을 subPath 로 mount —
     `/usr/share/opensearch/config/opensearch-security/internal_users.yml`
2. `k8s/sealed/backend-secret.yaml` 에 추가 (kubeseal --merge-into):
   - `OPENSEARCH_USE_SSL=true`
   - `OPENSEARCH_VERIFY_CERTS=false`
   - `OPENSEARCH_USER=album_backend`
   - `OPENSEARCH_PASSWORD=<opensearch-security-secret.backend-password 의 평문>`

backend-password 는 c 시점에 클러스터에서 추출:

```bash
BACKEND_PW="$(kubectl -n senior-album get secret opensearch-security-secret \
  -o jsonpath='{.data.backend-password}' | base64 -d)"

kubectl -n senior-album create secret generic backend-secret \
  --from-literal=OPENSEARCH_USE_SSL=true \
  --from-literal=OPENSEARCH_VERIFY_CERTS=false \
  --from-literal=OPENSEARCH_USER=album_backend \
  --from-literal=OPENSEARCH_PASSWORD="$BACKEND_PW" \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace "$SEALED_CONTROLLER_NS" \
           --controller-name "$SEALED_CONTROLLER_NAME" \
           --format yaml --merge-into k8s/sealed/backend-secret.yaml

unset BACKEND_PW
```

---

## 회전 (admin/backend 비번 갈기)

bootstrap 스크립트를 다시 실행하면 새 비번 2 개 + 새 bcrypt 해시로 SealedSecret
이 갈린다.

```bash
bash scripts/bootstrap-opensearch-security.sh
git diff k8s/sealed/opensearch-security-secret.yaml   # encryptedData 전부 갈림
```

이후 처리:
1. **admin 비번만 갈렸으면**: opensearch pod 재시작 → 새 internal_users.yml 적용을
   위해 `securityadmin.sh` 재실행 필요 (mount 한 파일은 .opendistro_security 인덱스
   에 푸시되는 시점에만 의미. 디테일은 c 머지 후 별도 회전 런북 작성).
2. **backend 비번이 갈렸으면**: 추가로 backend-secret 의 OPENSEARCH_PASSWORD 도
   같이 갈아야 한다. 현재 backend-secret 갱신 절차는 c 머지 후 정리.

회전 런북은 c 머지 후 본 문서를 확장해서 작성. b 시점에서는 회전이 필요한
시나리오가 없다 (Secret 자체가 dormant).

---

## 응급 상황 — admin 비번 분실

```bash
kubectl -n senior-album get secret opensearch-security-secret \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

분실이 의심되면 즉시 회전 (위 절차).
