# ============================================
# Senior Album Frontend - Multi-stage Dockerfile
# ============================================

# Stage 1: 빌드
FROM node:20-alpine AS builder

WORKDIR /build

COPY src/frontend/package.json src/frontend/package-lock.json* ./
RUN npm ci

COPY src/frontend/ .

# 빌드 시 API URL을 환경변수로 주입
ARG VITE_API_URL=/api
ENV VITE_API_URL=${VITE_API_URL}

RUN npm run build

# Stage 2: nginx로 서빙
FROM nginx:alpine

# nginx 설정
COPY deploy/docker/frontend/nginx.conf /etc/nginx/conf.d/default.conf

# 빌드 결과 복사
COPY --from=builder /build/dist /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget -q --spider http://localhost:80/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
