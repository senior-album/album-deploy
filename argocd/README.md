# ArgoCD Application 매니페스트

senior-album 클러스터의 ArgoCD Application CR 을 GitOps 로 관리하기 위한
디렉터리.

## 왜 별도 폴더인가

ArgoCD `senior-album` Application 의 `source.path` 가 `k8s` 라, k8s/ 하위
파일만 ArgoCD 가 추적한다. Application CR 자체를 k8s/ 안에 두면 자기 자신을
관리하는 재귀 상태가 되어 sync 마다 conflict 가 날 수 있어, 별도 `argocd/`
폴더로 분리.

## 적용 절차

매니페스트 변경 시 (드물게):

```bash
kubectl apply -f argocd/applications/senior-album.yaml
```

ArgoCD 가 자기 자신을 sync 하지 않으므로 수동 apply 가 필수. App-of-apps
패턴 도입 전까지는 이 워크플로 유지.

## 현재 등록된 Application

- `applications/senior-album.yaml` — 메인 senior-album 네임스페이스 sync.
  `directory.recurse: true` 가 켜져 있어 `k8s/sealed/` 하위 SealedSecret 도
  자동 sync 대상에 포함.
