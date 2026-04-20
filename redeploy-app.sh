#!/bin/bash
# ============================================
# 앱 코드 변경 후 빠른 재배포 (인프라는 그대로)
# 사용법: ./deploy/redeploy-app.sh
# ============================================

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="senior-album"

echo "앱 재배포 시작..."

cd "$PROJECT_ROOT"

# 백엔드만, 프론트만, 또는 둘 다
BUILD_TARGET="${1:-all}"  # all, backend, frontend

if [ "$BUILD_TARGET" = "all" ] || [ "$BUILD_TARGET" = "backend" ]; then
    echo "[1] 백엔드 이미지 빌드..."
    docker build -f deploy/docker/backend/Dockerfile -t senior-album-backend:latest .
    k3d image import senior-album-backend:latest -c "$CLUSTER_NAME"
    kubectl -n senior-album rollout restart deployment backend
fi

if [ "$BUILD_TARGET" = "all" ] || [ "$BUILD_TARGET" = "frontend" ]; then
    echo "[2] 프론트엔드 이미지 빌드..."
    docker build -f deploy/docker/frontend/Dockerfile \
        --build-arg VITE_API_URL=/api \
        -t senior-album-frontend:latest .
    k3d image import senior-album-frontend:latest -c "$CLUSTER_NAME"
    kubectl -n senior-album rollout restart deployment frontend
fi

echo "재배포 완료! 팟 상태:"
kubectl -n senior-album get pods
