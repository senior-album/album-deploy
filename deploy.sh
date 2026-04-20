#!/bin/bash
# ============================================
# Senior Album 원커맨드 배포 스크립트
# 사용법: ./deploy/deploy.sh
# ============================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="senior-album"

echo "=========================================="
echo "  Senior Album 배포 시작"
echo "=========================================="

# 1. k3d 클러스터 확인/생성
if k3d cluster list | grep -q "$CLUSTER_NAME"; then
    echo "[1/6] k3d 클러스터 이미 존재 — 시작 확인 중..."
    k3d cluster start "$CLUSTER_NAME" 2>/dev/null || true
else
    echo "[1/6] k3d 클러스터 생성..."
    k3d cluster create "$CLUSTER_NAME" \
        --port "80:80@loadbalancer" \
        --port "443:443@loadbalancer" \
        --agents 0 \
        --servers 1
fi

# 2. Docker 이미지 빌드
echo "[2/6] Docker 이미지 빌드..."
cd "$PROJECT_ROOT"

docker build -f deploy/docker/backend/Dockerfile \
    -t senior-album-backend:latest .

docker build -f deploy/docker/frontend/Dockerfile \
    --build-arg VITE_API_URL=/api \
    -t senior-album-frontend:latest .

# 3. k3d에 이미지 로드
echo "[3/6] k3d에 이미지 로드..."
k3d image import senior-album-backend:latest -c "$CLUSTER_NAME"
k3d image import senior-album-frontend:latest -c "$CLUSTER_NAME"

# 4. K8s 리소스 배포
echo "[4/6] K8s 리소스 배포..."
kubectl apply -f deploy/k8s/namespace.yaml
kubectl apply -f deploy/k8s/configmap.yaml
kubectl apply -f deploy/k8s/secret.yaml

# 인프라
kubectl apply -f deploy/k8s/postgres.yaml
kubectl apply -f deploy/k8s/redis.yaml
kubectl apply -f deploy/k8s/minio.yaml
kubectl apply -f deploy/k8s/opensearch.yaml

# 5. 인프라 대기
echo "[5/6] 인프라 Ready 대기..."
kubectl -n senior-album wait --for=condition=ready pod -l app=postgres --timeout=120s
kubectl -n senior-album wait --for=condition=ready pod -l app=redis --timeout=60s

# 앱 배포
kubectl apply -f deploy/k8s/backend.yaml
kubectl apply -f deploy/k8s/frontend.yaml
kubectl apply -f deploy/k8s/ingress.yaml

# Cloudflare Tunnel (토큰이 설정되어 있으면)
if grep -q "CHANGE-ME" deploy/k8s/cloudflared.yaml; then
    echo "  ⚠ Cloudflare Tunnel 토큰 미설정 — cloudflared 건너뜀"
    echo "    deploy/k8s/cloudflared.yaml의 TUNNEL_TOKEN을 설정 후:"
    echo "    kubectl apply -f deploy/k8s/cloudflared.yaml"
else
    kubectl apply -f deploy/k8s/cloudflared.yaml
fi

# 6. 상태 확인
echo "[6/6] 배포 상태 확인..."
sleep 5
kubectl -n senior-album get pods

echo ""
echo "=========================================="
echo "  배포 완료!"
echo "  로컬 접속: http://localhost"
echo "  로그 확인: kubectl -n senior-album logs -l app=backend -f"
echo "=========================================="
