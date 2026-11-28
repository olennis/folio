"""동등성 테스트: 같은 정렬 얼굴에서 dlib 원본과 Core ML 모델의 임베딩을 비교한다.

    python parity_test.py out/FaceEmbedding.mlpackage

- 얼굴: dlib 소스의 examples/faces 사진에서 dlib HOG 검출기 + 5점 랜드마크로 찾는다.
- 정렬: dlib.get_face_chip(size=150, padding=0.25). 두 모델 모두 이 같은 칩을 받는다.
- 기준: 얼굴마다 두 임베딩의 유클리드 거리가 1e-3 이하.
- 덤으로 Swift FaceAligner 테스트에 쓸 정렬 기준값(fixtures/alignment.json)도 만든다.
"""

import argparse
import glob
import json
import math
import os
import sys

import coremltools as ct
import dlib
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
TOLERANCE = 1e-3


def faces(limit_images=None):
    detector = dlib.get_frontal_face_detector()
    predictor = dlib.shape_predictor(os.path.join(WORK, "shape_predictor_5_face_landmarks.dat"))
    paths = sorted(glob.glob(os.path.join(WORK, "dlib-src", "examples", "faces", "*.jpg")))
    for path in paths[:limit_images]:
        image = dlib.load_rgb_image(path)
        for box in detector(image, 1):
            shape = predictor(image, box)
            yield path, image, shape


def chip_transform(points, size=150, padding=0.25):
    """dlib get_face_chip_details + extract_image_chip이 쓰는 칩 -> 원본 변환(2x3)을 그대로 계산한다.

    Swift FaceAligner가 같은 식을 쓴다. dlib과 같은지 여기서 먼저 확인한다.
    """
    template = np.array([
        (0.8595674595992, 0.2134981538014),
        (0.6460604764104, 0.2289674387677),
        (0.1205750620789, 0.2137274526848),
        (0.3340850613712, 0.2290642403242),
        (0.4901123135679, 0.6277975316475),
    ])
    src = (padding + template) / (2 * padding + 1) * size
    dst = np.asarray(points, dtype=np.float64)
    # find_similarity_transform(src -> dst): Umeyama 방식 최소제곱.
    mean_s, mean_d = src.mean(0), dst.mean(0)
    s, d = src - mean_s, dst - mean_d
    sigma_s = (s ** 2).sum() / len(s)
    cov = d.T @ s / len(s)
    u, sv, vt = np.linalg.svd(cov)
    sign = np.eye(2)
    if np.linalg.det(cov) < 0 or (np.linalg.det(cov) == 0 and np.linalg.det(u) * np.linalg.det(vt) < 0):
        sign[1, 1] = -1 if np.linalg.det(cov) < 0 else 1
    r = u @ sign @ vt
    c = np.trace(np.diag(sv) @ sign) / sigma_s
    m = c * r
    t = mean_d - m @ mean_s
    # chip_details: 각도와 배율만 뽑고, 칩 가운데를 옮긴 점을 중심으로 한 사각형을 만든다.
    p = m @ np.array([1.0, 0.0])
    angle = math.atan2(p[1], p[0])
    scale = float(np.hypot(*p))
    center = m @ np.array([size / 2.0, size / 2.0]) + t
    width = size * scale
    # extract_image_chip: 칩의 (0,0), (size-1,0), (0,size-1)을 회전한 사각형 모서리에 맞춘다.
    # centered_drect는 폭에서 1을 빼고 잡는다(drectangle.width()가 right-left+1이라서).
    half = (width - 1) / 2
    left, top = center[0] - half, center[1] - half
    right, bottom = center[0] + half, center[1] + half
    def rot(pt):
        dx, dy = pt[0] - center[0], pt[1] - center[1]
        ca, sa = math.cos(angle), math.sin(angle)
        return np.array([center[0] + ca * dx - sa * dy, center[1] + sa * dx + ca * dy])
    tl, tr, bl = rot((left, top)), rot((right, top)), rot((left, bottom))
    n = size - 1
    a = np.array([(tr - tl) / n, (bl - tl) / n]).T  # 2x2
    return np.hstack([a, tl.reshape(2, 1)]), angle, scale, center, width


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    args = parser.parse_args()

    recognizer = dlib.face_recognition_model_v1(os.path.join(WORK, "dlib_face_recognition_resnet_model_v1.dat"))
    models = {
        "cpu": ct.models.MLModel(args.model, compute_units=ct.ComputeUnit.CPU_ONLY),
        "all": ct.models.MLModel(args.model, compute_units=ct.ComputeUnit.ALL),
    }

    rows, fixtures = [], []
    for path, image, shape in faces():
        chip = dlib.get_face_chip(image, shape, size=150, padding=0.25)
        reference = np.array(recognizer.compute_face_descriptor(chip))
        result = {"face": f"{os.path.basename(path)}#{len(rows)}"}
        for name, model in models.items():
            out = model.predict({"image": Image.fromarray(chip)})["embedding"].reshape(-1)
            result[name] = float(np.linalg.norm(out - reference))
        rows.append(result)

        points = [(shape.part(i).x, shape.part(i).y) for i in range(5)]
        details = dlib.get_face_chip_details(shape, size=150, padding=0.25)
        transform, angle, scale, center, width = chip_transform(points)
        fixtures.append({
            "image": os.path.basename(path),
            "points": points,
            "dlib": {
                "angle": details.angle,
                "center": [details.rect.center().x, details.rect.center().y],
                "width": details.rect.width(),
            },
            "transform": transform.tolist(),
        })
        # 우리 식이 dlib과 같은 사각형·각도를 내는지.
        assert abs(angle - details.angle) < 1e-6, (angle, details.angle)
        assert abs(width - details.rect.width()) < 1e-4, (width, details.rect.width())

    print(f"{'얼굴':<28} {'CPU 거리':>12} {'ALL 거리':>12}")
    for row in rows:
        print(f"{row['face']:<28} {row['cpu']:>12.2e} {row['all']:>12.2e}")
    worst = {k: max(r[k] for r in rows) for k in ("cpu", "all")}
    print(f"얼굴 {len(rows)}개. 최대 거리 CPU {worst['cpu']:.2e}, ALL {worst['all']:.2e} (기준 {TOLERANCE:.0e})")

    os.makedirs(os.path.join(HERE, "fixtures"), exist_ok=True)
    with open(os.path.join(HERE, "fixtures", "alignment.json"), "w") as f:
        json.dump(fixtures, f, indent=1)

    ok = len(rows) >= 10 and worst["cpu"] <= TOLERANCE
    print("통과" if ok else "실패")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
