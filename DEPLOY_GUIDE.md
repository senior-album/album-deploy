# Senior Album 맥미니 배포 가이드

맥미니에 k3d(k3s in Docker)로 클러스터를 만들고, Cloudflare Tunnel로 외부 접속을 연결하는 가이드입니다.

## 전체 구조

```
[시설 기기 (브라우저)]
        │
        ▼  HTTPS
[Cloudflare Tunnel]  ←─  your-domain.com
        │
        ▼
[k3d 클러스터 (맥미니)]
  ├── frontend (nginx :80)  ← /
  ├── backend  (uvicorn :8000) ← /api
  ├── postgres :5432
  ├── redis    :6379
  ├── minio    :9000
  └── opensearch :9200
```

## 1단계: 맥미니 사전 준비

### Docker Desktop 설치

```bash
# Homebrew로 설치
brew install --cask docker

# Docker Desktop 실행 후 설정에서:
# - Resources → Memory: 최소 6GB 이상 권장
# - Resources → CPUs: 4 이상 권장
```

### k3d 설치

```bash
brew install k3d
```

### kubectl 설치

```bash
brew install kubectl
```

### cloudflared 설치

```bash
brew install cloudflare/cloudflare/cloudflared
```

## 2단계: k3d 클러스터 생성

```bash
# 클러스터 생성 (트래픽 포트 매핑 포함)
k3d cluster create senior-album \
  --port "80:80@loadbalancer" \
  --port "443:443@loadbalancer" \
  --agents 0 \
  --servers 1

# 확인
kubectl cluster-info
kubectl get nodes
```

## 3단계: Docker 이미지 빌드

프로젝트 루트 디렉토리에서 실행:

```bash
cd /path/to/senior-album

# 백엔드 이미지 빌드
docker build -f deploy/docker/backend/Dockerfile -t senior-album-backend:latest .

# 프론트엔드 이미지 빌드 (API URL은 nginx가 프록시하므로 /api)
docker build -f deploy/docker/frontend/Dockerfile \
  --build-arg VITE_API_URL=/api \
  -t senior-album-frontend:latest .

# k3d 클러스터에 이미지 로드 (레지스트리 없이 로컬 이미지 사용)
k3d image import senior-album-backend:latest -c senior-album
k3d image import senior-album-frontend:latest -c senior-album
```

## 4단계: 시크릿 수정

배포 전 `deploy/k8s/secret.yaml`을 편집합니다:

```bash
# JWT 시크릿 생성 (랜덤)
openssl rand -base64 48
# → 출력된 값을 secret.yaml의 JWT_SECRET에 넣기

# 카카오 OAuth 키가 있으면 KAKAO_CLIENT_ID, KAKAO_CLIENT_SECRET도 넣기
```

## 5단계: ConfigMap 수정

`deploy/k8s/configmap.yaml`에서 `your-domain.com`을 실제 도메인으로 변경:

```yaml
ALLOWED_ORIGINS: '["https://album.example.com"]'
FRONTEND_URL: "https://album.example.com"
API_BASE_URL: "https://album.example.com/api"
KAKAO_REDIRECT_URI: "https://album.example.com/auth/kakao/callback"
```

## 6단계: K8s 리소스 배포

순서대로 실행합니다:

```bash
# 네임스페이스
kubectl apply -f deploy/k8s/namespace.yaml

# 설정
kubectl apply -f deploy/k8s/configmap.yaml
kubectl apply -f deploy/k8s/secret.yaml

# 인프라 (DB → Redis → MinIO → OpenSearch)
kubectl apply -f deploy/k8s/postgres.yaml
kubectl apply -f deploy/k8s/redis.yaml
kubectl apply -f deploy/k8s/minio.yaml
kubectl apply -f deploy/k8s/opensearch.yaml

# 인프라가 뜰 때까지 대기
kubectl -n senior-album wait --for=condition=ready pod -l app=postgres --timeout=120s
kubectl -n senior-album wait --for=condition=ready pod -l app=redis --timeout=60s
kubectl -n senior-album wait --for=condition=ready pod -l app=minio --timeout=60s

# 앱 배포
kubectl apply -f deploy/k8s/backend.yaml
kubectl apply -f deploy/k8s/frontend.yaml

# Ingress
kubectl apply -f deploy/k8s/ingress.yaml

# 상태 확인
kubectl -n senior-album get pods
kubectl -n senior-album get svc
```

전부 Running이 되면 `http://localhost`에서 로컬로 접속 가능합니다.

## 7단계: Cloudflare Tunnel 설정

### 7-1. Cloudflare 계정 + 도메인 준비

무료 도메인이 없으면 Cloudflare에서 저렴한 도메인을 하나 구매하거나, 기존 도메인의 네임서버를 Cloudflare로 옮깁니다.

### 7-2. Tunnel 생성

```bash
# Cloudflare 로그인
cloudflared tunnel login
# → 브라우저가 열림, 도메인 선택 후 인증

# 터널 생성
cloudflared tunnel create senior-album
# → 출력: Created tunnel senior-album with id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# 토큰 확인 (이 토큰을 k8s secret에 넣음)
cloudflared tunnel token senior-album
# → 출력: eyJhIjoi... (긴 토큰 문자열)
```

### 7-3. DNS 라우팅 설정

```bash
# 도메인을 터널에 연결
cloudflared tunnel route dns senior-album album.your-domain.com
```

### 7-4. Cloudflare Dashboard에서 터널 설정

[Cloudflare Zero Trust 대시보드](https://one.dash.cloudflare.com/) → Networks → Tunnels → senior-album → Configure:

**Public Hostname 추가:**

| Hostname | Service |
|----------|---------|
| `album.your-domain.com` | `http://frontend.senior-album.svc.cluster.local:80` |

### 7-5. k8s에 cloudflared 배포

```bash
# secret.yaml의 TUNNEL_TOKEN을 7-2에서 얻은 토큰으로 변경 후:
kubectl apply -f deploy/k8s/cloudflared.yaml

# 확인
kubectl -n senior-album logs -l app=cloudflared
# → "Connection registered" 메시지가 나오면 성공
```

이제 `https://album.your-domain.com`으로 외부에서 접속 가능합니다.

## 유용한 명령어

### 로그 확인

```bash
# 백엔드 로그
kubectl -n senior-album logs -l app=backend -f

# 프론트엔드 로그
kubectl -n senior-album logs -l app=frontend -f

# 전체 팟 상태
kubectl -n senior-album get pods -w
```

### 코드 업데이트 후 재배포

```bash
# 이미지 재빌드
docker build -f deploy/docker/backend/Dockerfile -t senior-album-backend:latest .
k3d image import senior-album-backend:latest -c senior-album

# 팟 재시작 (이미지 갱신)
kubectl -n senior-album rollout restart deployment backend
```

### DB 직접 접속

```bash
kubectl -n senior-album exec -it deploy/postgres -- psql -U postgres -d senior_album
```

### MinIO 콘솔 접속

```bash
# 포트포워딩
kubectl -n senior-album port-forward svc/minio 9001:9001
# → http://localhost:9001 (minioadmin / minioadmin)
```

### 클러스터 중지/시작

```bash
# 중지 (맥미니 절전 등)
k3d cluster stop senior-album

# 재시작
k3d cluster start senior-album
```

### 전체 삭제 (초기화)

```bash
k3d cluster delete senior-album
```

## 문제 해결

### 이미지 Pull 에러 (ErrImageNeverPull)

```bash
# 이미지가 k3d에 로드되었는지 확인
docker exec k3d-senior-album-server-0 crictl images | grep senior-album

# 없으면 다시 import
k3d image import senior-album-backend:latest -c senior-album
```

### 백엔드 CrashLoopBackOff

```bash
# 로그 확인
kubectl -n senior-album logs deploy/backend --previous

# 보통 DB 연결 실패 → postgres가 먼저 Ready인지 확인
kubectl -n senior-album get pods
```

### OpenSearch OOM (메모리 부족)

```bash
# opensearch.yaml에서 OPENSEARCH_JAVA_OPTS 줄이기
# -Xms128m -Xmx128m 으로 변경

# 또는 맥미니 RAM이 8GB면 OpenSearch 빼고 운영 (얼굴 검색만 비활성화)
kubectl -n senior-album delete -f deploy/k8s/opensearch.yaml
```

### Cloudflare Tunnel 연결 안 됨

```bash
# cloudflared 로그 확인
kubectl -n senior-album logs -l app=cloudflared

# 토큰이 맞는지 확인
cloudflared tunnel info senior-album
```

## 맥미니 스펙별 권장 설정

| 스펙 | OpenSearch | 백엔드 workers | 비고 |
|------|-----------|---------------|------|
| 8GB RAM | 끄기 | 1 | 얼굴 검색 비활성화, 나머지 정상 |
| 16GB RAM | 켜기 (256MB) | 2 | 전체 기능 가능 |
| 32GB+ | 켜기 (512MB) | 4 | 여유롭게 운영 |
