# [senior-album/album-deploy] argocd-reconcile-lag-alert 에 auto-refresh 추가

> 외부 담당자 인수인계 문서. 이슈 컨텍스트 없어도 그대로 적용 가능하게 작성.

## 한 줄 요약

`argocd-reconcile-lag-alert` 워치독이 lag 알림만 보내는데, **알림과 동시에 stuck Application 에 `argocd.argoproj.io/refresh=normal` 을 자동으로 annotate** 해서 자가 회복까지 하도록 확장. 변경 파일 2개 (RBAC + 스크립트).

## 왜 필요한가

### 증상

ArgoCD application-controller 가 일부 Application 의 `reconciledAt` 을 갱신 안 함 → 워치독이 `🟠 Warn ... lag=10 min ...` / `🔴 Critical ... lag=30 min ...` 알림을 Discord 에 반복 송출. `kubectl annotate application <name> argocd.argoproj.io/refresh=normal --overwrite` 한 번 찍어주면 즉시 회복하지만, 시간이 지나면 다시 stuck.

### 원인

ArgoCD v3.x 의 **informer pipeline regression**. 업스트림에서 추적 중:

- 본 보고: [argo-cd#27192 — UI does not auto-refresh, all reconciliations timer-driven, no watch events fired (regression from 2.x → 3.x)](https://github.com/argoproj/argo-cd/issues/27192)
- 영향 범위: v3.3.5+ 전반 (v3.3.7, v3.4.1 포함). v2.13.x 까지는 정상
- Fix 상태: 2026-05-19 기준 open, 관련 fix 1개 v3.4.1 에서 revert. 회피책 없이는 해결 불가

실제 깨진 부분:
1. timer-based resync (`--app-resync` 120s default) — firing 안 함
2. Application watch event → reconcile — 동작 안 함

살아있는 경로는 `cluster cache resource event → reconcile` 뿐. namespace 내부에 자주 변하는 리소스 (CronJob 등) 가 있는 Application 은 우연히 reconcile 되지만, 정적 namespace 의 Application 은 영구 stuck.

### 회피책

현재 `canvan-helper-bot` namespace 에 별도 CronJob (`*/4 * * * *`) 을 두고 자기 Application 에 annotate 강제 — 정상 동작 확인됨. 하지만 stuck-prone Application 마다 워치독을 만드는 건 중복.

**대신 기존 `argocd-reconcile-lag-alert` 스크립트가 어차피 모든 Application 의 lag 을 확인하니, 거기에 annotate 도 같이 시키면 cluster-wide 일괄 처리**. canvan-helper-bot 의 별도 워치독은 redundant → 검증 후 제거.

## 변경 내용

### 변경 1 — Role 에 `patch` verb 추가

**파일**: senior-album/album-deploy 의 `argocd-reconcile-lag-alert` Role manifest (argocd ns 대상)

```diff
 apiVersion: rbac.authorization.k8s.io/v1
 kind: Role
 metadata:
   name: argocd-reconcile-lag-alert
   namespace: argocd
 rules:
   - apiGroups: ["argoproj.io"]
     resources: ["applications"]
-    verbs: ["get", "list"]
+    verbs: ["get", "list", "patch"]
```

resourceNames 제한 없이 모든 Application 에 대해 patch 허용. annotate 만 찍는 거라 보안 영향 최소 (operation 트리거 X, spec 변경 X).

### 변경 2 — check.sh 스크립트 수정

**파일**: senior-album/album-deploy 의 `argocd-reconcile-lag-alert` ConfigMap 의 `data.check.sh` (senior-album ns 대상)

lag 판정 분기 + 그 직후:

```diff
   if [ "${lag_min}" -ge "${CRIT_MIN}" ]; then
     severity="🔴 Critical"
-    note=" — repo-server polling 정지 의심. \`kubectl -n argocd rollout restart deploy/argocd-repo-server\` 권고."
+    note=" — informer/timer 정지 의심 ([argo-cd#27192](https://github.com/argoproj/argo-cd/issues/27192)). \`kubectl -n argocd rollout restart statefulset/argocd-application-controller\` 검토."
   elif [ "${lag_min}" -ge "${WARN_MIN}" ]; then
     severity="🟠 Warn"
     note=""
   else
     continue
   fi
+
+  # argo-cd#27192 회피 — annotate 로 informer cache event 발사해 reconcile 큐에 강제 enqueue.
+  # WARN 이상 lag 인 모든 Application 에 적용 (CRIT 도 포함, 조기 회복 시도).
+  if kubectl -n argocd annotate application "${name}" \
+       argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1; then
+    note="${note} (auto-refresh attempted)"
+  else
+    note="${note} (auto-refresh failed — RBAC?)"
+  fi
 
   content=$(printf '%s ArgoCD reconciledAt lag — **%s**\nlag=`%s min` · reconciledAt=`%s`%s' \
     "${severity}" "${name}" "${lag_min}" "${reconciled_at}" "${note}")
```

부수 변경:
- Critical 메시지의 권고가 잘못 됨 — `argocd-repo-server` 가 아니라 `argocd-application-controller` 가 informer/timer 책임. 같이 수정
- argo-cd#27192 링크 — 향후 이 알림 보는 사람 컨텍스트 제공

## 결과 동작

| lag | 이전 | 이후 |
|---|---|---|
| < 10 min | (nothing) | (nothing) |
| 10 ~ 29 min | 🟠 Warn Discord | 🟠 Warn + auto-annotate → 5분 안에 회복 |
| ≥ 30 min | 🔴 Critical Discord | 🔴 Critical + auto-annotate → 5분 안에 회복 |

WARN 단계에서도 자동 회복 시도해서 Critical 까지 안 가게 막음. Discord 알림 자체는 유지 (사람이 모니터링 가능).

## 적용 후 검증 절차

PR 머지 + ArgoCD sync 완료 후, **본 보고자 (Claude / 김영환) 가** 아래로 검증:

```bash
ssh macmini

# 1. canvan-helper-bot 의 임시 워치독 일시 suspend (방해 제거)
kubectl -n canvan-helper-bot patch cronjob canvan-helper-bot-refresh -p '{"spec":{"suspend":true}}'

# 2. canvan-helper-bot lag 발생할 때까지 ~10 분 대기
sleep 600
kubectl get application canvan-helper-bot -n argocd -o jsonpath='{.status.reconciledAt}'; echo

# 3. lag-alert CronJob 다음 실행 (*/5) 뒤 로그 확인
kubectl -n senior-album logs -l app=argocd-reconcile-lag-alert --tail=50 | grep canvan
# 기대: "canvan-helper-bot: ... Discord alert sent (🟠 Warn)" + "(auto-refresh attempted)" 문구

# 4. reconciledAt 즉시 갱신 확인
kubectl get application canvan-helper-bot -n argocd -o jsonpath='{.status.reconciledAt}'; echo
# 기대: lag-alert 실행 직후 시각으로 갱신
```

검증 통과 시:
- canvan-helper-bot-deploy 의 `k8s/refresh-cronjob.yaml` 제거 PR 작성 (대체됨)
- senior-album/album-deploy 의 본 변경이 cluster-wide 솔루션으로 정착

## 영향 분석 (cluster-wide)

- 모든 Application 에 `patch` 시도 — annotate 만 찍는 거라 spec/operation 변경 0. 부작용 없음
- 일시 suspend 된 Application (`spec.syncPolicy` 없음 / `automated` 없음) 에도 annotate 시도 → reconcile 만 되고 sync 는 안 트리거됨. 의도와 충돌 X
- annotate 실패 시 (RBAC / network) 알림 메시지에 `(auto-refresh failed — RBAC?)` 추가 → 사람이 인지 가능

## 추적 / 관련 링크

- 업스트림 버그: [argo-cd#27192](https://github.com/argoproj/argo-cd/issues/27192) (open, 2026-05-19 기준)
- 본 자동 회복 도입 결정: [elementary-teacher/canvan-helper-bot#16](https://github.com/elementary-teacher/canvan-helper-bot/issues/16)
- 진단 원본: [elementary-teacher/canvan-helper-bot#14](https://github.com/elementary-teacher/canvan-helper-bot/issues/14), [#15](https://github.com/elementary-teacher/canvan-helper-bot/issues/15)
- 현재 회피책 (제거 예정): [elementary-teacher/canvan-helper-bot-deploy#6](https://github.com/elementary-teacher/canvan-helper-bot-deploy/pull/6)

## 요청 사항

1. 위 2개 파일에 diff 그대로 적용 (파일 경로는 senior-album/album-deploy 의 구조에 맞게)
2. PR 본문에 본 문서 링크 또는 요약 인용
3. 머지 + ArgoCD sync 완료되면 본 보고자에게 알림 → 검증 진행

업스트림 fix 머지되면 본 자동 annotate 분기도 제거 가능 (별도 후속 이슈).
