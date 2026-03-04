# Plan: UI/UX Improvements

## Overview
Setup 페이지의 사용성 개선 2건.

## Feature 1: Score Threshold 설명 추가

### 현재 상태
- `AdvancedOptionsSection.tsx:399-415`에 "Score Threshold" 라벨과 숫자 입력만 존재
- 값이 0~1 범위이며 Open Targets의 gene-disease association score를 의미하지만, UI에 설명이 전혀 없음
- 사용자가 이 값이 무엇인지, 어떤 기준으로 gene이 필터링되는지 알 수 없음

### 요구사항
- Score Threshold 입력 필드 옆 또는 아래에 간단한 설명 텍스트 추가
- 설명 내용: Open Targets association score (0~1)이며, 이 값 이상인 gene만 분석에 포함됨을 안내
- 너무 길지 않게 tooltip 또는 helper text 형태

### 변경 대상
- `gui/src/components/setup/AdvancedOptionsSection.tsx` (Score Threshold 섹션)

### 구현 방안
- 라벨 옆에 info 아이콘 + hover tooltip으로 상세 설명 표시
- 또는 라벨 아래에 `text-xs text-muted-foreground`로 한 줄 설명 추가

---

## Feature 2: Quick Exclude Columns 전체 선택/해제 버튼

### 현재 상태
- `FeatureSelectionAccordion.tsx:76-103`에 개별 column 버튼만 나열
- 유전자 수가 수천~수만 개이므로 개별 클릭으로 exclude하기 비현실적
- "Select All" / "Deselect All" 기능 없음

### 요구사항
- Quick exclude columns 영역 상단에 "Select All" / "Deselect All" 버튼 추가
- 전체 선택 시 모든 availableColumns를 excludeFeatures에 추가
- 전체 해제 시 availableColumns에 해당하는 항목만 excludeFeatures에서 제거

### 변경 대상
- `gui/src/components/setup/FeatureSelectionAccordion.tsx` (Quick exclude 섹션)

### 구현 방안
- 라벨 행에 "Select All" / "Deselect All" 버튼 2개 추가 (또는 토글 1개)
- 현재 상태(전체 선택됨 / 일부 선택 / 미선택)에 따라 버튼 텍스트 동적 변경 가능

---

## 우선순위
| Feature | 난이도 | 영향도 |
|---------|--------|--------|
| Score Threshold 설명 | 낮음 | 중간 (사용자 이해도 향상) |
| 전체 선택 버튼 | 낮음 | 높음 (대량 데이터 작업 효율) |

## 예상 변경 파일
1. `gui/src/components/setup/AdvancedOptionsSection.tsx`
2. `gui/src/components/setup/FeatureSelectionAccordion.tsx`
