# 버전 / 배포 이력 (Versions & Deploy)

언제든 특정 시점으로 되돌려 배포할 수 있도록 주요 버전을 git 태그로 박제하고
각 버전의 상태·복원법·인프라를 기록한다. **태그는 커밋을 지우지 않는 한 영구
보존**되며, `git checkout <태그>`로 그 시점 코드를 정확히 가져올 수 있다.

---

## 빠른 복원 (어느 버전이든)

```bash
cd ~/workspace/experiments/realtime-translator
git checkout <태그명>          # 그 시점 코드로 이동 (detached HEAD)
# 배포:  deploy/launch.sh 로 인스턴스 띄우고 CloudFront 오리진을 그 인스턴스로
# 돌아오기: git checkout broadcast-webpage  (또는 main)
```

태그 목록 보기: `git tag -l -n1`

---

## v1.0-broadcast-bigbox  (커밋 `6adb2f0`)
**"큰 인스턴스 + 인증 없음" — 며칠 전 완성·시연한 버전.**

- **인스턴스**: g6e.12xlarge (L40S 4장, ~$15/hr). vLLM=GPU0, whisper 6워커=GPU1,2,3.
- **인증**: ❌ 없음 (CloudFront 엔드포인트 공개, 토큰 검증 없음). URL만 알면 접속.
- **기능**: broadcast(1캡처→N뷰어), 자동저장(로컬 .md), 듀얼스트림, 자가복원 터널.
- **AMI**: DLAMI(PyTorch 2.7) + 풀 부트스트랩 (모델 다운로드 ~20분).
- **언제 쓰나**: 20명+ 동시 발화 부하가 필요하거나, 인증 없이 빠르게 열어 시연할 때.
- **주의**: 공개 노출 — 데모 끝나면 즉시 teardown. 워크스페이스 공개노출 룰 유의.

복원·배포:
```bash
git checkout v1.0-broadcast-bigbox
INSTANCE_TYPE=g6e.12xlarge FORCE_DLAMI=1 deploy/launch.sh   # 인증 토큰 파일 없으면 공개로 뜸
```

---

## v1.1-small-auth-stable  (커밋 `55ba7fe`)  ← 현재 운영
**"작은 인스턴스 + 비번 + 안정화" — 2~3명용 상용 준비 베이스.**

- **인스턴스**: g6e.2xlarge (L40S 1장, ~$3/hr). vLLM+whisper 3워커 GPU0 공유(util 0.78).
- **인증**: ✅ 공유 토큰. `deploy/.relay-token`(gitignore)에 비번 저장, `?token=`로 검증.
  비번 모르면 4401 거부. 앱엔 비번칸, 뷰어는 prompt 1회.
- **안정화**: `/metrics`에 finals_dropped·e2e_p95·vllm_up 등 계측 + vLLM 헬스 watchdog
  (60s 다운 시 자동 재시작).
- **버전 핀**: vLLM 0.22.1 + starlette 1.2.1 + fastapi 0.136.3 (최신은 HTTP 500 버그).
- **golden AMI**: `ami-00a71da973e364ff0` (rt-translator-golden-20260615-0433) —
  모델·버전·드라이버 박제. launch.sh가 자동 사용 → 수십 초 기동.
- **언제 쓰나**: 평상시 운영(소규모), 대시보드 개발의 베이스.

복원·배포:
```bash
git checkout v1.1-small-auth-stable
# deploy/.relay-token 에 비번이 있어야 인증 활성화 (없으면 openssl rand -hex 12 로 생성)
deploy/launch.sh        # golden AMI 자동 사용(빠른 부팅)
```

---

## working-dual-stream-5ff0d95  (커밋 `5ff0d95`)
초기 듀얼스트림 동작 검증본(롤백 안전점). broadcast/인증 이전.

---

## 현재 라이브 인프라 (수시 변동 — 참고용)
- 운영 인스턴스: **g6e.2xlarge `i-0dfc07b6e3112410e`** (도쿄 1c, v1.1)
- CloudFront: `E3LZ8CS76QYR5X` → `dv7fu8km0bcfp.cloudfront.net`
  - `/` 캡처(wss), `/viewsock` 뷰어(wss), `/view` 뷰어 페이지(https)
- golden AMI: `ami-00a71da973e364ff0`
- 접속 비번: `deploy/.relay-token` (git 제외)
- teardown: `deploy/cloudfront-teardown.sh` + `deploy/teardown.sh terminate`

## 새 버전 박제하는 법 (다음에 또)
```bash
git tag -a vX.Y-설명 <커밋> -m "상태 요약"   # 시점 박제
# 인프라가 정상이면 golden AMI 재생성:
aws ec2 create-image --region ap-northeast-1 --instance-id <iid> \
  --name "rt-translator-golden-$(date +%Y%m%d-%H%M)" --no-reboot
# 이 파일(VERSIONS.md)에 항목 1개 추가
```
