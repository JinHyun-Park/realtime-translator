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

## v1.1-small-auth-stable  (커밋 `55ba7fe`)  ← 현재 인프라 베이스
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

## v1.9-ux  (커밋 `1c04ace`)  ← 현재 운영 코드
**자막 UX 웨이브 (2026-07-10 ~ 07-11). "문장 단위로 빠르고 안정된 확정 + 롤링 미리보기".**

문장 리듬:
- **문장 경계 플러시**: interim에 word timestamp를 켜서, 진행 중 텍스트 안에 완성
  문장이 보이면 무음 없이도 그 지점에서 버퍼를 쪼개 즉시 확정. 논스톱 화자도
  문장당 1확정 (예전: 5문장 덩어리가 max-segment까지 감).
- **미완성 홀드 + 라이브 병합**: 문장 종결형이 아니면 무음 기준 1.8배 대기(중간
  숨에서 안 잘림); 그래도 잘리면 6초 내 다음 final을 앞줄에 병합해 화면·아카이브
  모두 한 문장으로 복구.
- **확정 순서 보장**: 모든 final이 연결당 단일 순차 큐 통과 — 플러시 final이
  다음 문장 final에 추월당해 순서가 뒤집히던 버그 수정.

표시:
- **롤링 티커** ("실시간 미리보기" 라벨): 진행 중 텍스트는 본문 흐름이 아니라
  하단 고정 스트림당 1줄에서 제자리 교체 — 확정 줄이 출렁이지 않음. 뷰어+앱.
- **interim은 항상 로컬 Qwen**: Bedrock 왕복(1.5s)이 갱신 주기(1s)보다 길어
  미리보기가 전멸하던 것 → 회색은 빠른 모델, 확정/refine은 Claude.
- **interim 기아 수정**: 취소 기반 스케줄링 → 최신-pending 워커.

품질/방어:
- **분석문 검역기**: 모델이 번역 대신 분석 프로즈를 뱉으면 차단·구출
  (대상 문자 비율 0.35 + 길이 가드; "cudgel in a club" 사건).
- **에코 게이트 v2** (앱): 오디오 교차상관 + 딜레이 락 + 500ms 룩어헤드 소급
  차단 — 스피커 재생음의 ME 중복을 장치 무관하게 억제. (AEC는 옵트인 토글로
  강등 — 시스템 볼륨 덕킹+마이크 무음 부작용; 텍스트 dedup은 기본 OFF — 방향
  역전 실패.)
- **마이크 자동 복구**: 출력 장치 변경 시 AVAudioEngine이 조용히 죽던 것 —
  구성 변경 알림 받아 자동 재시작.

라이브 노브: `/control/endpoint?interim=&flush=&hold=` (+기존 silence_ms 등).
복원: `git checkout v1.9-ux`

---

## v1.8-accuracy  (커밋 `7caa4ee`)
**번역 정확도 개선 웨이브 (2026-07-09 ~ 07-10). 서버+앱+뷰어.**

라이브 자막 품질/신뢰성:
- **interim 미리보기 기아(starvation) 수정**: 긴 문장에서 회색 미리보기가 멈추고
  final까지 4~5초 공백이 생기던 스케줄링 버그 — 새 틱이 처리 중이던 interim을
  취소하는 방식을 "최신 pending을 끝까지 처리하는 워커"로 교체. E2E 프로브로
  재현·검증.
- **interim은 항상 로컬 vLLM**: Bedrock 왕복(~1.5s)이 interim 주기(1s)보다 길어
  미리보기가 전멸하던 문제. final/refine만 선택 프로바이더(Claude) 사용.
- **fast-then-refine** (`RT_REFINE_ENABLED`, 기본 on): final 즉시 표시 후
  백그라운드에서 대화 맥락으로 재번역 → 개선되면 `refine` 프레임으로 앱/뷰어의
  해당 줄 제자리 교체. 아카이브에도 반영.
- **Bedrock temperature 버그**: 전달 누락으로 Claude가 temp 1.0으로 돌던 것 수정
  (interim 0.0 / final 0.2).
- **할루시네이션 필터 2단계화**: 유튜브 멘트는 무조건 차단, 실제 회화 문구
  ("감사합니다"/"thank you")는 오디오가 무음/잡음스러울 때만 차단 — 진짜 인사가
  증발하던 finals 드롭(22%)의 주범 제거.
- **ME/THEM 컨텍스트 공유**: 방의 마이크·시스템오디오 연결이 하나의 번역 히스토리
  공유(화자 태그 포함) + `RT_CONTEXT_WINDOW=6`(공유 12줄).

세션 종료 아카이브:
- **STT 인지 정리 패스**: 유사발음 오인식 재분류(결제/결재, 카프카/카푸카…),
  전사 전체 용어 통일, 원문·번역 동시 교정, `corrections` 감사 로그
  (before/after/사유) 저장. history.html에 교정 내역 표시.
- **요약이 교정본 사용**: 정리 패스를 요약보다 먼저 실행.

앱 (재빌드 필요 — v1.8 번들):
- **마이크 AEC**: voice processing 활성화 — 스피커 재생음이 ME로 중복 인식되던
  문제 해결 (실기기 검증 대기).
- **refine 프레임 처리**: 확정 자막 제자리 교체.
- **오디오 엔진 재시작 버튼**: coreaudiod 웨지 시 앱 종료 없이 복구.

복원: `git checkout v1.8-accuracy`

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
