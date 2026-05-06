# ArgoCD Notifications → Discord (T-129)

ArgoCD 가 senior-album Application 의 sync / health 이벤트를 Discord webhook
으로 푸시하는 설정. T-040 (Uptime Kuma) + T-041 (Discord 웹훅 알림) 의
follow-up — Kuma 의 HTTP up/down 만으론 sync 결과·revision drift 를 검증할
수 없어 분리.

## 왜 별도 폴더인가

senior-album Application 의 destination 은 `namespace: senior-album` 이라,
`argocd` 네임스페이스에 있어야 하는 `argocd-notifications-cm` /
`argocd-notifications-secret` 은 GitOps 자동 sync 의 범위 밖. 따라서 이 두
매니페스트는 ArgoCD 가 안 잡고, **사람이 수동으로 `kubectl apply`** 한다.
Application annotation 변경 (구독 trigger 추가/삭제) 은 senior-album
Application CR 자체를 다시 apply 해야 반영된다.

## 매니페스트 구성

| 파일 | 역할 | 적용 |
|------|------|------|
| `argocd-notifications-cm.yaml` | trigger / template / service.webhook.discord | `kubectl apply` |
| `argocd-notifications-secret.yaml.example` | webhook URL 의 평문 예시 (실제 클러스터엔 sealed 변형) | 미적용 (가이드용) |
| `argocd-notifications-secret.sealed.yaml` | 사용자가 kubeseal 로 만든 SealedSecret (gitignore 안 됨, 봉인 안전) | `kubectl apply` |

## 활성화된 trigger

| Trigger | 발사 조건 | Template | 색상 / 톤 |
|---------|-----------|----------|-----------|
| `on-sync-running` | sync operation 시작 | 🔄 정보 | (간단 회색) |
| `on-deployed` | sync 성공 + Healthy + revision 새로움 | ✅ 성공 | 초록 |
| `on-sync-failed` | sync operation Error / Failed | ❌ 실패 + error message | 빨강 |
| `on-health-degraded` | health = Degraded | ⚠️ 경고 | 주황 |
| `on-out-of-sync` | OutOfSync 인데 active sync 가 없음 (selfHeal 실패 추정) | 🟡 stuck | 노랑 |

Application 별 구독은 `argocd/applications/senior-album.yaml` 의
`metadata.annotations` 에서 on/off.

## 첫 적용 절차

```bash
# 1. 평문 secret 사본 만들고 webhook URL 채우기
cp argocd/notifications/argocd-notifications-secret.yaml.example \
   /tmp/argocd-notifications-secret.yaml
$EDITOR /tmp/argocd-notifications-secret.yaml
# → discord-webhook-url 에 실제 URL 입력

# 2. SealedSecret 으로 봉인
kubeseal --controller-namespace=kube-system \
         --controller-name=sealed-secrets-controller \
         --format yaml \
         < /tmp/argocd-notifications-secret.yaml \
         > argocd/notifications/argocd-notifications-secret.sealed.yaml

# 3. apply (argocd 네임스페이스, senior-album Application 의 destination 밖)
kubectl apply -f argocd/notifications/argocd-notifications-cm.yaml
kubectl apply -f argocd/notifications/argocd-notifications-secret.sealed.yaml

# 4. controller 가 새 cm/secret 을 재로드
kubectl -n argocd rollout restart deploy/argocd-notifications-controller

# 5. Application annotation 반영 (이미 main 에 있으면 ArgoCD 가 spec 만
#    추적해서 annotations 자동 sync 안 될 수 있음 — 직접 apply 권장)
kubectl apply -f argocd/applications/senior-album.yaml
```

## 동작 검증

수동 sync 트리거로 `on-sync-running` + `on-deployed` 가 둘 다 들어오는지 확인:

```bash
kubectl -n argocd patch application senior-album \
  --type=merge \
  -p '{"operation":{"sync":{}}}'
```

Discord 채널에서 ~10 초 안에 🔄, ~30 초~수 분 안에 ✅ 가 보이면 정상.

실패 케이스 검증 (가짜 manifest 로 일시적 실패 유도):

```bash
# k8s/backend.yaml 의 image: tag 를 일부러 존재하지 않는 sha 로 바꿔 push
# → autosync 가 잡으면 ❌ Sync 실패 + ⚠️ Degraded 가 차례로 떠야 함.
# 검증 후 즉시 main 으로 revert.
```

## 알림 음소거 / 트리거 끄기

특정 trigger 끄기: `argocd/applications/senior-album.yaml` 에서 해당
`subscribe.on-XXX.discord` annotation 줄을 삭제 후 apply.

전체 끄기: `argocd-notifications-secret` 의 `discord-webhook-url` 을 빈
문자열로 변경 → controller 가 service 유효성 실패로 발사 자체를 skip.

## 트러블슈팅

### 알림이 안 옴

```bash
# 1. controller 로그 확인
kubectl -n argocd logs deploy/argocd-notifications-controller -f

# 2. 특정 trigger 가 평가됐는지 (디버깅용 임시 step)
kubectl -n argocd logs deploy/argocd-notifications-controller \
  | grep -i "senior-album"

# 3. webhook URL 이 secret 에 잘 들어갔는지
kubectl -n argocd get secret argocd-notifications-secret -o yaml \
  | grep discord-webhook-url
# stringData / data 어느 쪽이든 base64 디코드 시 https://discord... 로 시작
```

### Discord 가 400 으로 거절

template body 가 valid JSON 인지 검증. `operationState.message` 에 따옴표/
개행이 들어와도 `printf ... | toJson` 패턴으로 escape 되지만, template 수정
시 같은 패턴 유지 필요. 직접 `"content": "...{{.field}}..."` 식으로 풀어쓰면
escape 사고 가능성 있음.

### "OutOfSync 5분" 알림 타이밍이 어긋남

`on-out-of-sync` trigger 는 시간 기반 임계 대신 `oncePer:
app.status.sync.revision` 으로 dedup. 결과적으로 한 revision 당 1 회 알림 →
selfHeal+autosync 가 정상이면 다음 reconciliation 에서 sync.status 가
Synced 로 바뀌어 알림 자체가 안 가고, stuck 일 때만 "이 revision 의 첫 1 회"
알림이 간다. autosync interval (3 분) + notifications poll (1 분) 합쳐
사실상 4~5 분 지연 ≒ KANBAN 의 "5 분" 의도.

엄밀한 시간 임계가 필요하면 `when:` 절에 `time.Now().Sub(time.Parse(...))`
패턴 추가 고려 — 단 expression 엔진 버전 의존성 있어 controller 업그레이드
시 회귀 위험.
