# JWT 키 회전 런북 (T-055 rolling key)

## 배경

backend (T-055) 는 JWT 헤더의 `kid` 를 보고 keyset 에서 검증용 secret 을 lookup
한다. 여러 kid 를 동시에 keyset 에 두면 같은 시점에 옛 토큰과 새 토큰이 모두
유효 → 회전 중 사용자 강제 로그아웃 없음.

코드 동작:
- 발급: `JWT_ACTIVE_KID` (envvar) 의 secret 으로 서명, JWT 헤더에 `kid` 박음.
- 검증: 토큰 헤더의 kid → `JWT_KEY_<KID>` envvar lookup. kid 없는 (legacy) 토큰은
  `JWT_SECRET` envvar 로 fallback.

## 인프라 도입 후 현재 상태

| 위치 | 항목 | 비고 |
|---|---|---|
| `k8s/sealed/backend-secret.yaml` | `JWT_SECRET`, `JWT_REFRESH_SECRET` | 운영 중 단일 키. 그대로 |
| `k8s/backend.yaml` env | `JWT_KEY_V1` ← `valueFrom secretKeyRef JWT_SECRET` | v1 으로 같은 값 노출 |
| `k8s/backend.yaml` env | `JWT_REFRESH_KEY_V1` ← `valueFrom secretKeyRef JWT_REFRESH_SECRET` | refresh 도 동일 |
| `k8s/backend.yaml` env | `JWT_ACTIVE_KID=v1`, `JWT_REFRESH_ACTIVE_KID=v1` | 평문 envvar |

backend pod 안 keyset = `{v1: <기존값>, legacy: <기존값>}` — 같은 값 두 번 등록.
새 토큰은 `kid=v1` 헤더로 발급, 옛 토큰은 'legacy' fallback. 인프라만 켜진 상태이며
실제 키는 회전되지 않았다.

## 첫 진짜 회전 절차

### Phase 1 — 새 kid (v2) SealedSecret 에 추가

맥미니 또는 클러스터 접근 가능한 머신에서:

```bash
cd album-deploy

# 새 secret 생성 (각각 ≥32바이트 엔트로피)
NEW_ACCESS=$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")
NEW_REFRESH=$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")

# backend-secret 에 두 항목 reseal --merge-into.
# stdin 으로만 값을 흘려 history/프로세스 환경에 시크릿이 남지 않게 한다.
printf '%s' "$NEW_ACCESS" | kubectl create secret generic backend-secret \
  --namespace=senior-album --dry-run=client \
  --from-file=JWT_KEY_V2=/dev/stdin -o yaml \
  | kubeseal --format yaml --merge-into k8s/sealed/backend-secret.yaml

printf '%s' "$NEW_REFRESH" | kubectl create secret generic backend-secret \
  --namespace=senior-album --dry-run=client \
  --from-file=JWT_REFRESH_KEY_V2=/dev/stdin -o yaml \
  | kubeseal --format yaml --merge-into k8s/sealed/backend-secret.yaml

unset NEW_ACCESS NEW_REFRESH

# 커밋 (ACTIVE 전환은 다음 PR 에서)
git checkout -b chore/T-055-rotate-jwt-v2-add
git add k8s/sealed/backend-secret.yaml
git commit -m "chore(secret): T-055 — JWT v2 키 reseal (활성 전환 전)"
git push -u origin chore/T-055-rotate-jwt-v2-add
```

이 PR 머지 → ArgoCD sync → backend pod 가 v2 키 인식. 발급은 여전히 v1.

> ⚠️ Phase 2 로 넘어가기 전에 **모든 backend pod 가 새 envvar 를 가진 상태로
> rollout 됐는지 확인**. SealedSecret 변경은 자동으로 pod 를 재시작시키지 않으니
> `secret-revision` annotation 을 같이 올리거나 `kubectl -n senior-album rollout
> restart deploy/backend` 수동 실행. v2 envvar 를 못 본 옛 pod 가 살아있는 상태에서
> Phase 2 를 머지하면 그 pod 는 자기가 발급한 토큰을 검증 못 한다.

### Phase 2 — 활성 kid 전환

`k8s/backend.yaml` 의 env 수정:

```yaml
- name: JWT_ACTIVE_KID
  value: "v2"          # v1 → v2
- name: JWT_REFRESH_ACTIVE_KID
  value: "v2"
```

그리고 `album.io/secret-revision` annotation 을 의미 있는 새 값 (예: `T-055-v2`)
으로 갱신 — pod template hash 가 바뀌어 ArgoCD sync 시 강제 rollout.

머지 → backend pod 가 발급용 키를 v2 로 전환. 새 토큰은 `kid=v2` 헤더, 옛 v1 토큰
은 keyset 에 v1 이 남아있으므로 그대로 검증 통과.

### Phase 3 — Grace 대기

| 토큰 종류 | 만료 | 의미 |
|---|---|---|
| access | 60분 | Phase 2 후 1시간 지나면 활성 access 토큰은 모두 v2 |
| refresh | 14일 | Phase 2 후 14일 지나면 활성 refresh 토큰도 모두 v2 |

따라서 Phase 2 머지 후 **최소 14일 대기**. 이 기간 동안 v1 / legacy 키는 keyset 에
유지되어야 옛 토큰을 들고 들어오는 사용자를 강제 로그아웃 시키지 않는다.

### Phase 4 — 옛 kid 제거

14일 경과 후:

```bash
cd album-deploy
git checkout -b chore/T-055-rotate-jwt-purge-v1

# 1) k8s/backend.yaml 의 env 에서 v1 valueFrom 매핑 두 줄 (JWT_KEY_V1,
#    JWT_REFRESH_KEY_V1) 삭제. JWT_ACTIVE_KID / JWT_REFRESH_ACTIVE_KID 는 그대로.
#    (이게 v1 keyset entry 를 끊는 첫 단계.)

# 2) SealedSecret 의 JWT_SECRET / JWT_REFRESH_SECRET 항목 제거 — 'legacy' 키 차단.
#    가장 안전한 방법: 새 secret manifest 를 처음부터 다시 만들어 reseal.
#    기존 SealedSecret 의 다른 항목들(POSTGRES_PASSWORD, MINIO_*, OPENSEARCH_* 등)을
#    모두 보존하면서 두 항목만 빼야 하므로 항목별 reseal 보다는 한 번에 재구성이
#    실수가 적다. SECRETS.md 의 회전 절차 참고.

# 3) album.io/secret-revision annotation 갱신.

git add k8s/backend.yaml k8s/sealed/backend-secret.yaml
git commit -m "chore(secret): T-055 — JWT v1/legacy 키 제거 (회전 완료)"
git push -u origin chore/T-055-rotate-jwt-purge-v1
```

머지 → backend keyset = `{v2: <new>}`. 그동안 발급된 토큰 중 만료 지난 것은 자연스럽게
무효, 14일 안에 살아있는 토큰은 모두 v2 라 검증 통과.

## 사고 시 — 즉시 회전 (grace 생략)

JWT_SECRET 유출 등으로 즉시 회전이 필요한 경우 grace 를 건너뛴다.

1. Phase 1 + Phase 2 를 한 PR 에 합쳐 머지.
2. Phase 4 도 즉시 진행 (legacy 키 즉시 제거). 이 시점에 살아있던 모든 v1/legacy
   토큰이 무효화 → **사용자 일괄 재로그인 발생**. 이게 의도된 동작.
3. Discord 알림으로 운영자에게 사고 사실 + 사용자 영향 공지 (T-041 채널).

## 보안 권장

- 정기 회전: 분기 1회 또는 보안 incident 트리거.
- 새 secret 은 `secrets.token_urlsafe(48)` (≥32바이트 base64url) 로 생성.
- 회전 전후 24시간 동안 backend 로그에서 `Token verification failed` 빈도 모니터링
  — 평소 대비 큰 spike 가 보이면 어떤 단계에서 keyset 누락이 생겼다는 신호.
- 회전 기록은 SECRETS.md 의 인벤토리 옆 `last rotated:` 메모로 관리하는 것을 권장.

## 관련 파일

- `k8s/sealed/backend-secret.yaml` — 키 SealedSecret
- `k8s/backend.yaml` — env 매핑 + ACTIVE_KID
- `src/backend/app/core/config.py` — `model_post_init` 에서 keyset 빌드
- `src/backend/app/core/security.py` — `_resolve_jwt_secret` 으로 kid → secret lookup
- `src/backend/docs/SECRETS.md` — 시크릿 인벤토리 + 그 외 회전 절차
