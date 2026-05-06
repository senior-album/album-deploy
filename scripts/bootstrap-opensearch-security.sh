#!/usr/bin/env bash
# T-004b — opensearch-security-secret bootstrap
#
# OpenSearch Security 플러그인용 자격증명 SealedSecret 을 한 번에 생성한다.
# 이 스크립트가 만드는 결과물:
#   k8s/sealed/opensearch-security-secret.yaml  (SealedSecret, dormant)
#
# Secret 내용:
#   - internal_users.yml : admin + album_backend bcrypt 해시 포함 전체 파일
#   - admin-password     : admin 평문 (ops 비상용)
#   - backend-password   : album_backend 평문 (T-004c 가 backend-secret 으로 옮길 때 추출)
#
# 본 SealedSecret 은 b' 시점에서는 mount 되는 곳이 없어 클러스터에 Secret 만 존재하고
# 누구도 읽지 않는 상태로 머문다 (런타임 영향 0). T-004c 에서 opensearch 컨테이너가
# subPath 로 마운트하면서 활성화된다.
#
# 정책: 이 스크립트는 Mac mini 에서 직접 실행해서 평문 비번이 외부 시스템 (LLM 포함) 을
# 절대 통과하지 않게 한다. 사건 #87 의 교훈.
#
# 의존: bash 4+, openssl, python3 (bcrypt 모듈), kubectl, kubeseal, git
#
# 재실행 (회전): 그대로 다시 실행하면 새 비번 + 새 해시로 SealedSecret 이 갈린다.
# 주의: 회전 시점의 처리는 OPENSEARCH_SECURITY.md 의 "회전" 섹션 참조.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEALED_OUT="$REPO_ROOT/k8s/sealed/opensearch-security-secret.yaml"

# kubeseal controller 정보 — postgres-password-rotation.md §0 와 동일 디폴트
SEALED_CONTROLLER_NAME="${SEALED_CONTROLLER_NAME:-sealed-secrets-controller}"
SEALED_CONTROLLER_NS="${SEALED_CONTROLLER_NS:-kube-system}"

# 사전 도구 검증
for cmd in openssl python3 kubectl kubeseal git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd 가 PATH 에 없음. Mac mini 에서 실행하는지 확인." >&2
    exit 1
  fi
done

# bcrypt 모듈 확인
if ! python3 -c "import bcrypt" 2>/dev/null; then
  echo "ERROR: python3 의 bcrypt 모듈 없음. pip3 install bcrypt 또는" >&2
  echo "       brew install python3 후 pip3 install bcrypt." >&2
  exit 1
fi

# kubeseal controller 도달 가능성 검증
if ! kubectl -n "$SEALED_CONTROLLER_NS" get deploy "$SEALED_CONTROLLER_NAME" >/dev/null 2>&1; then
  echo "ERROR: kubeseal controller ($SEALED_CONTROLLER_NS/$SEALED_CONTROLLER_NAME) 가 보이지 않음." >&2
  echo "       kubectl get deploy -A | grep -i sealed 로 실제 이름/네임스페이스 확인 후" >&2
  echo "       SEALED_CONTROLLER_NAME / SEALED_CONTROLLER_NS env 로 override." >&2
  exit 1
fi

# 비번 생성 (Mac mini 로컬에서만 평문 존재)
# tr -d '+/=' — base64 의 URL-unsafe 문자 제거. opensearch http_auth 는 URL-safe 만 안전.
gen_pw() {
  openssl rand -base64 32 | tr -d '+/=' | head -c 40
}

ADMIN_PW="$(gen_pw)"
BACKEND_PW="$(gen_pw)"

# bcrypt 해싱 — rounds=12 (T-054 와 동일 강도)
hash_pw() {
  python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt(rounds=12)).decode())
" "$1"
}

ADMIN_HASH="$(hash_pw "$ADMIN_PW")"
BACKEND_HASH="$(hash_pw "$BACKEND_PW")"

# internal_users.yml 본체
# - admin: backend_role "admin" → 디폴트 roles_mapping.all_access 매핑으로 전체 권한
# - album_backend: backend_role "admin" → 디폴트 roles_mapping.all_access 로 전체 권한
#   (least-privilege 는 spec §9 (b)/(c) 후속작업으로 분리. 현 시점 backend 는 cluster
#    내부에서만 도달 가능하고 비번이 SealedSecret 에 갇혀 있어 marginal)
INTERNAL_USERS_YAML="$(cat <<EOF
---
_meta:
  type: "internalusers"
  config_version: 2

admin:
  hash: "${ADMIN_HASH}"
  reserved: true
  hidden: false
  backend_roles:
    - "admin"
  attributes: {}
  description: "Album OpenSearch admin (T-004)"

album_backend:
  hash: "${BACKEND_HASH}"
  reserved: false
  hidden: false
  backend_roles:
    - "admin"
  attributes: {}
  description: "Album backend service account (T-004)"
EOF
)"

# stringData Secret 생성 → kubeseal 로 봉인
# --from-file 은 파일을 만들어야 하므로 process substitution 으로 우회 (디스크에 평문 안 남김)
TMP_SECRET="$(mktemp "${TMPDIR:-/tmp}/opensearch-sec-secret.XXXXXX")"
trap 'rm -f "$TMP_SECRET"' EXIT

# kubectl create secret 의 stringData 모드로 평문 Secret 생성 (디스크 평문은 mktemp 파일 1 회뿐)
kubectl -n senior-album create secret generic opensearch-security-secret \
  --from-literal=admin-password="$ADMIN_PW" \
  --from-literal=backend-password="$BACKEND_PW" \
  --from-literal=internal_users.yml="$INTERNAL_USERS_YAML" \
  --dry-run=client -o yaml > "$TMP_SECRET"

# kubeseal — 새 파일 생성 (--merge-into 아님)
kubeseal \
  --controller-namespace "$SEALED_CONTROLLER_NS" \
  --controller-name "$SEALED_CONTROLLER_NAME" \
  --format yaml \
  < "$TMP_SECRET" \
  > "$SEALED_OUT"

# 즉시 평문 파일 삭제 (trap 도 있지만 명시적으로)
rm -f "$TMP_SECRET"

# 산출물 검증
if [[ ! -s "$SEALED_OUT" ]]; then
  echo "ERROR: $SEALED_OUT 가 비어 있음. kubeseal 출력 실패." >&2
  exit 1
fi
if ! grep -q "kind: SealedSecret" "$SEALED_OUT"; then
  echo "ERROR: $SEALED_OUT 가 SealedSecret 형식이 아님." >&2
  exit 1
fi

# 결과 요약 (stdout)
cat <<EOF

================================================================
✓ k8s/sealed/opensearch-security-secret.yaml 생성됨

다음 스텝:
  1) git diff k8s/sealed/opensearch-security-secret.yaml   # SealedSecret 1 개만 추가됐는지 확인
  2) git add k8s/sealed/opensearch-security-secret.yaml
  3) git commit -m "security: T-004b — opensearch-security-secret bootstrap"
  4) git push
  5) ArgoCD sync 후:
       kubectl -n senior-album get secret opensearch-security-secret
     이 새 Secret 1 개가 namespace 에 떠야 함 (mount 되는 곳 없음 — dormant).

T-004c 에서:
  - kubectl -n senior-album get secret opensearch-security-secret \\
      -o jsonpath='{.data.backend-password}' | base64 -d
    값을 OPENSEARCH_PASSWORD 로 backend-secret 에 kubeseal --merge-into.
================================================================
EOF
