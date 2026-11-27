# dlib 얼굴 인식 모델 → Core ML 변환

인물 앨범에 쓰는 얼굴 임베딩 모델(`PhotoAlbum/People/FaceEmbedding.mlpackage`)을 만드는 절차다.
원본은 dlib의 `dlib_face_recognition_resnet_model_v1`(퍼블릭 도메인, 128차원 임베딩)이다.

## 한 번에 돌리기

```bash
brew install cmake python@3.11 libpng jpeg-turbo
./convert.sh --install
```

`convert.sh`는 아래 단계를 차례로 돌린다. 내려받은 파일과 가상환경은 `work/`, `.venv/`에 두고 커밋하지 않는다.

## 단계

1. **내려받기**:
   - 변환할 모델: `dlib_face_recognition_resnet_model_v1.dat.bz2`
   - 동등성 테스트에 쓰는 5점 랜드마크 모델: `shape_predictor_5_face_landmarks.dat.bz2`
   - dlib 소스(v19.24.6): XML 변환 도구를 빌드하고, 테스트 얼굴 사진(`examples/faces`)을 쓴다.
2. **.dat → XML** (`xml_generator/`):
   - ksachdeva/dlib-to-tf-keras-converter와 같은 방식이다.
   - dlib 예제(`dnn_face_recognition_ex.cpp`)와 같은 네트워크 정의로 `.dat`를 읽고, `net_to_xml`로 층과 가중치를 XML로 쓴다.
3. **XML → Keras → Core ML** (`convert.py`):
   - XML을 입력 쪽부터 읽으며 같은 층을 Keras로 쌓고 가중치를 옮긴다.
   - 그다음 coremltools로 ML Program(.mlpackage)을 만든다.
   - **입력** `image`: 150×150 RGB 이미지(ImageType).
     - 정규화 `(픽셀 − 평균) / 256`을 scale/bias로 넣었다.
     - 평균은 dlib 입력층 값이다: R 122.782, G 117.001, B 104.298.
   - **출력** `embedding`: 128차원 Float32 벡터.
   - **정밀도**: 1e-3 기준을 지키려고 FLOAT32로 둔다(FP16로 줄이지 않는다).
4. **동등성 테스트** (`parity_test.py`):
   - dlib HOG 검출기와 5점 랜드마크로 얼굴을 찾고, `dlib.get_face_chip(size=150, padding=0.25)`로 정렬한 같은 칩을 dlib 원본과 Core ML에 넣는다.
   - 얼굴마다 두 임베딩의 유클리드 거리가 **1e-3 이하**여야 하고, 얼굴은 10개 이상이어야 한다.
   - 정렬 식이 dlib의 `get_face_chip_details`와 같은 사각형·각도를 내는지도 확인한다.
   - Swift `FaceAligner` 테스트용 기준값을 `PhotoAlbumTests/Fixtures/face-alignment.json`으로 내보낸다.

## 결과 (2026-11-27, M1 Mac)

| 항목 | 값 |
|---|---|
| 테스트 얼굴 | 68개 (dlib `examples/faces` 사진 11장) |
| dlib 대비 최대 거리 (CPU) | 2.27e-05 |
| dlib 대비 최대 거리 (ALL: CPU+GPU+ANE) | 2.28e-05 |
| 기준 | 1e-03 → **통과** |
| 모델 크기 | 21 MB |

## dlib과 맞춘 곳

- **텐서 배치**: dlib은 NCHW, Keras는 NHWC다. 합성곱 가중치는 `(out, in, h, w)`를 `(h, w, in, out)`으로 돌린다.
- **패딩**: 보폭 2인 합성곱과 풀링은 dlib에서 패딩이 0이다. XML의 `padding_*` 값을 그대로 쓴다.
- **`add_prev`의 크기 차이**: dlib은 두 입력의 크기가 다르면 큰 쪽에 맞추고 빈 곳을 0으로 채운다(왼쪽 위 기준).
  - 축소 블록에서 4×4와 3×3, 2×2와 1×1이 만난다. Keras에서도 오른쪽 아래와 뒤쪽 채널을 0으로 채운 뒤 더한다.
- **`affine_con`**: 학습이 끝난 배치 정규화다. `x * gamma + beta`로 옮긴다.
- **채널 순서**: RGB다. dlib `input_rgb_image`가 R, G, B 순서로 텐서를 채운다.

## 얼굴 정렬 (Swift FaceAligner가 따라야 할 식)

dlib `get_face_chip_details` + `extract_image_chip`과 같다.

1. **기준점**: 5점 템플릿을 `(padding + p) / (2·padding + 1) · 150`으로 칩 좌표에 놓는다.
   - 템플릿은 `interpolation.h`에 있다.
   - 랜드마크 순서는 dlib 5점 모델과 같다: 0 한쪽 눈 바깥, 1 같은 눈 안쪽, 2 다른 눈 바깥, 3 같은 눈 안쪽, 4 코 밑.
2. **변환 구하기**: 칩 기준점 → 이미지 랜드마크의 유사 변환을 최소제곱(Umeyama)으로 구한다.
3. **사각형 만들기**: 변환에서 각도와 배율만 꺼낸다.
   - 칩 가운데 `(75, 75)`를 옮긴 점을 중심으로, 폭 `150·배율`인 사각형을 만든다.
   - dlib `centered_drect`는 폭에서 1을 빼고 잡는다. 실제 모서리는 중심 ± (폭−1)/2다.
4. **픽셀 매핑**: 칩의 `(0,0)`, `(149,0)`, `(0,149)`를 회전한 사각형 모서리에 맞춰 이중선형 보간한다.
   - dlib은 소수점을 버리고 정수로 쓴다.
   - 이 식으로 만든 칩은 dlib 칩과 반올림 차이(평균 0.5/255) 안에서 같다.
5. **큰 얼굴**: 배율이 2보다 크면 dlib은 이미지 피라미드(5탭 필터)로 먼저 줄인 뒤 뽑는다.
   - Swift에서는 원본을 2의 거듭제곱 비율로 먼저 면적 평균해 줄여서 근사한다.
   - 이 근사로 dlib 칩과의 임베딩 거리는 0.04~0.06이다. 같은 사람 기준인 0.6의 10% 안팎이다.
   - 피라미드를 쓰지 않는 크기의 얼굴(테스트 68개 중 66개)은 거리가 0.002 이하다.

## 묶기 정확도 측정 세트 (`cluster_set.py`)

LFW(funneled)에서 사진이 20장 이상인 사람 10명 × 20장과 한 장뿐인 사람 50명을 골라,
위 정렬 + 변환한 Core ML 모델로 임베딩을 만들어 `PhotoAlbumTests/Fixtures/cluster-set.json`으로 쓴다.
Swift `PeopleClusterAccuracyTests`가 `ChineseWhispersClusterer`로 묶어 쌍 단위 정밀도·재현율을 잰다.

| 임계값 | 정밀도 | 재현율 |
|---|---|---|
| 0.50 | 1.000 | 0.980 |
| 0.55 | 0.989 | 0.990 |
| 0.60 | 0.749 | 1.000 |

dlib 원본 `chinese_whispers_clustering`으로 다른 표본 5개를 재면 0.6에서 정밀도 평균 0.80(최저 0.64),
0.5에서 0.998(최저 0.989)이다. 0.6은 두 얼굴을 비교하는 기준이라, 이웃을 따라 번호가 번지는
Chinese Whispers에서는 닮은 두 사람이 한 사람으로 이어지는 일이 생긴다.
