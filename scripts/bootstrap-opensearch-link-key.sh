#!/usr/bin/env bash
# T-004e1 — backend-secret 에 OPENSEARCH_LINK_KEY 봉인 추가 (dormant)
#
# OpenSearch 의 face_embeddings 인덱스에 저장될 resident_id_hash 를 만들기 위한
# HMAC-SHA256 키. backend 만 보유하고 OpenSearch 는 모름 → vector 와 hash 만 가진
# OpenSearch dump 단독으로는 "어떤 vector 가 누구 얼굴인지" 식별 연결고리가 없음
# (spec §8 / KISA compensating control).
#
# 본 스크립트가 만드는 결과물:
#   k8s/sealed/backend-secret.yaml  — 기존 SealedSecret 에 OPENSEARCH_LINK_KEY 1 키 merge
#
# T-004e1 시점에서는 backend 코드가 아직 이 env 를 읽지 않으므로 클러스터에
# 머지된 후에도 mount 만 되고 아무도 안 쓰는 dormant 상태 (런타임 영향 0).
# T-004e2 머지 + 이미지 배포 시점에 backend 가 hash_resident_id() 헬퍼에서 활성화한다.
#
# 정책: 이 스크립트는 Mac mini 에서 직접 실행해서 평문 키가 외부 시스템 (LLM 포함) 을
# 절대 통과하지 않게 한다. 사건 #87 의 교훈.
#
# 의존: bash 4+, openssl, kubectl, kubeseal, git
#
# 재실행 (회전): 그대로 다시 실행하면 새 키 + 새 봉인본으로 갈린다. 단, 회전 시점엔
# 운영 중인 OpenSearch 인덱스의 resident_id_hash 가 모두 invalidate 되므로 backend
# 측 reindex (T-004e3 와 동일 흐름) 가 동반되어야 함.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEALED_TARGET="$REPO_ROOT/k8s/sealed/backend-secret.yaml"

# kubeseal controller 정보 — bootstrap-opensearch-security.sh 와 동일 디폴트
SEALED_CONTROLLER_NAME="${SEALED_CONTROLLER_NAME:-sealed-secrets-controller}"
SEALED_CONTROLLER_NS="${SEALED_CONTROLLER_NS:-kube-system}"

# 사전 도구 검증
for cmd in openssl kubectl kubeseal git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd 가 PATH 에 없음. Mac mini 에서 실행하는지 확인." >&2
    exit 1
  fi
done

# 봉인 대상 파일 존재 검증 (--merge-into 는 기존 파일을 갱신하므로 반드시 있어야 함)
if [[ ! -f "$SEALED_TARGET" ]]; then
  echo "ERROR: $SEALED_TARGET 가 없음. T-004c 머지 상태가 맞는지 확인." >&2
  exit 1
fi

# 이미 키가 들어 있으면 사고 방지 차원에서 중단 (회전 의도면 명시적으로 키 라인을 지우고 재실행)
if grep -q '^\s*OPENSEARCH_LINK_KEY:' "$SEALED_TARGET"; then
  echo "ERROR: $SEALED_TARGET 에 이미 OPENSEARCH_LINK_KEY 가 있음." >&2
  echo "       회전이 의도면: 해당 라인을 수동으로 제거 후 재실행." >&2
  exit 1
fi

# kubeseal controller 도달 가능성 검증
if ! kubectl -n "$SEALED_CONTROLLER_NS" get deploy "$SEALED_CONTROLLER_NAME" >/dev/null 2>&1; then
  echo "ERROR: kubeseal controller ($SEALED_CONTROLLER_NS/$SEALED_CONTROLLER_NAME) 가 보이지 않음." >&2
  echo "       kubectl get deploy -A | grep -i sealed 로 실제 이름/네임스페이스 확인 후" >&2
  echo "       SEALED_CONTROLLER_NAME / SEALED_CONTROLLER_NS env 로 override." >&2
  exit 1
fi

# 32B 랜덤 키 생성 (Mac mini 로컬에서만 평문 존재).
# tr -d '+/=' — base64 의 URL-unsafe + padding 제거.
# head -c 40 — bootstrap-opensearch-security.sh 와 동일한 길이 (≈ 240 bits, HMAC-SHA256 충분).
LINK_KEY="$(openssl rand -base64 32 | tr -d '+/=' | head -c 40)"

if [[ ${#LINK_KEY} -ne 40 ]]; then
  echo "ERROR: 키 생성 결과 길이가 예상과 다름 (${#LINK_KEY}, 기대 40)." >&2
  exit 1
fi

# 평문 Secret manifest 를 mktemp 에 만들고 (디스크 평문 1 회만), kubeseal --merge-into 로 봉인.
TMP_SECRET="$(mktemp "${TMPDIR:-/tmp}/opensearch-link-key.XXXXXX")"
trap 'rm -f "$TMP_SECRET"' EXIT

kubectl -n senior-album create secret generic backend-secret \
  --from-literal=OPENSEARCH_LINK_KEY="$LINK_KEY" \
  --dry-run=client -o yaml > "$TMP_SECRET"

# 평문 변수 즉시 제거 (process env 노출 줄이기 — best effort)
unset LINK_KEY

# --merge-into: 새 manifest 의 encryptedData 만 SEALED_TARGET 의 encryptedData 에 추가.
# 다른 키들의 봉인본은 그대로 유지된다.
kubeseal \
  --controller-namespace "$SEALED_CONTROLLER_NS" \
  --controller-name "$SEALED_CONTROLLER_NAME" \
  --format yaml \
  --merge-into "$SEALED_TARGET" \
  < "$TMP_SECRET"

# 즉시 평문 파일 삭제 (trap 도 있지만 명시적으로)
rm -f "$TMP_SECRET"

# 산출물 검증
if ! grep -q '^\s*OPENSEARCH_LINK_KEY:' "$SEALED_TARGET"; then
  echo "ERROR: $SEALED_TARGET 에 OPENSEARCH_LINK_KEY 가 추가되지 않음. kubeseal 출력 확인." >&2
  exit 1
fi

# 결과 요약 (stdout)
cat <<EOF

================================================================
✓ k8s/sealed/backend-secret.yaml 에 OPENSEARCH_LINK_KEY 봉인 추가됨

다음 스텝:
  1) git diff k8s/sealed/backend-secret.yaml
       OPENSEARCH_LINK_KEY 1 라인만 추가된 게 맞는지 확인.
  2) git add k8s/sealed/backend-secret.yaml scripts/bootstrap-opensearch-link-key.sh
  3) git commit -m "security(backend): T-004e1 — OPENSEARCH_LINK_KEY dormant SealedSecret"
  4) git push -u origin feat/T-004e1-opensearch-link-key
  5) PR 생성 (base: main).
  6) ArgoCD sync 후 검증:
       kubectl -n senior-album get secret backend-secret \\
         -o jsonpath='{.data.OPENSEARCH_LINK_KEY}' | base64 -d | wc -c
     40 이 나와야 함. 이 시점엔 backend pod 가 아직 env 로 읽지 않음 (dormant).

T-004e2 (album-backend 코드 변경) 에서 활성화되며, deployment 의
album.io/secret-revision annotation 을 함께 bump 해서 pod 가 새 env 를 픽업한다.
================================================================
EOF
