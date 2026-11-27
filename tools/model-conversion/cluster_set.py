"""클러스터 정밀도·재현율 측정용 얼굴 세트를 만든다(LFW funneled).

    python cluster_set.py ../../PhotoAlbumTests/Fixtures/cluster-set.json

- 사진이 20장 이상인 사람 10명 × 20장 + 한 장뿐인 사람 50명(섞여 들어오는 낯선 얼굴).
- 얼굴: dlib HOG + 5점 → get_face_chip(150, 0.25) → 변환한 Core ML 모델 임베딩.
- Swift 테스트(PeopleClusterAccuracyTests)가 이 임베딩을 ChineseWhispersClusterer로 묶어 잰다.
"""
import json
import os
import random
import sys

import coremltools as ct
import dlib
import numpy as np
from PIL import Image

from parity_test import WORK

LFW = os.path.expanduser("~/scikit_learn_data/lfw_home/lfw_funneled")


def main(out):
    random.seed(7)
    people = sorted(d for d in os.listdir(LFW) if os.path.isdir(os.path.join(LFW, d)))
    many = [p for p in people if len(os.listdir(os.path.join(LFW, p))) >= 20]
    single = [p for p in people if len(os.listdir(os.path.join(LFW, p))) == 1]
    chosen = random.sample(many, 10)
    strangers = random.sample(single, 50)

    detector = dlib.get_frontal_face_detector()
    predictor = dlib.shape_predictor(os.path.join(WORK, "shape_predictor_5_face_landmarks.dat"))
    model = ct.models.MLModel("out/FaceEmbedding.mlpackage", compute_units=ct.ComputeUnit.CPU_ONLY)

    faces, missed = [], 0
    for label, name in enumerate(chosen + strangers):
        files = sorted(os.listdir(os.path.join(LFW, name)))[: 20 if name in chosen else 1]
        for f in files:
            image = dlib.load_rgb_image(os.path.join(LFW, name, f))
            boxes = detector(image, 1)
            if not boxes:
                missed += 1
                continue
            # LFW는 가운데 얼굴이 그 사람이다.
            box = min(boxes, key=lambda b: abs(b.center().x - 125) + abs(b.center().y - 125))
            chip = dlib.get_face_chip(image, predictor(image, box), size=150, padding=0.25)
            vector = model.predict({"image": Image.fromarray(chip)})["embedding"].reshape(-1)
            faces.append({"person": label, "name": name, "embedding": [round(float(x), 6) for x in vector]})
    with open(out, "w") as fp:
        json.dump(faces, fp)
    print(f"얼굴 {len(faces)}개(사람 {len(chosen)}명 + 낯선 얼굴 {len(strangers)}명), 못 찾은 사진 {missed}장")


if __name__ == "__main__":
    main(sys.argv[1])
