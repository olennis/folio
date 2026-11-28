"""앱 경로(Vision 랜드마크 → 정렬 → Core ML) 그대로 정밀도·재현율을 기기에서 재려고 LFW 사진을 테스트 자료로 옮긴다.

    python vision_set.py ../../PhotoAlbumTests/Fixtures/lfw

- cluster_set.py와 같은 사람(씨앗 7): 10명 × 20장 + 한 장뿐인 사람 50명.
- 사진은 원본(250x250 JPEG) 그대로 복사하고, vision-set.json에 사람 번호와 dlib 5점(Vision 점 비교용)을 적는다.
- Swift 테스트(PeopleVisionAccuracyTests)가 기기에서 VisionFaceDetector로 얼굴을 찾아 끝까지 돌린다.
"""
import json
import os
import random
import shutil
import sys

import dlib

from cluster_set import LFW
from parity_test import WORK


def main(out):
    random.seed(7)
    people = sorted(d for d in os.listdir(LFW) if os.path.isdir(os.path.join(LFW, d)))
    many = [p for p in people if len(os.listdir(os.path.join(LFW, p))) >= 20]
    single = [p for p in people if len(os.listdir(os.path.join(LFW, p))) == 1]
    chosen = random.sample(many, 10)
    strangers = random.sample(single, 50)

    detector = dlib.get_frontal_face_detector()
    predictor = dlib.shape_predictor(os.path.join(WORK, "shape_predictor_5_face_landmarks.dat"))
    os.makedirs(out, exist_ok=True)
    items = []
    for label, name in enumerate(chosen + strangers):
        for f in sorted(os.listdir(os.path.join(LFW, name)))[: 20 if name in chosen else 1]:
            path = os.path.join(LFW, name, f)
            image = dlib.load_rgb_image(path)
            boxes = detector(image, 1)
            points = None
            if boxes:
                box = min(boxes, key=lambda b: abs(b.center().x - 125) + abs(b.center().y - 125))
                shape = predictor(image, box)
                points = [[shape.part(i).x, shape.part(i).y] for i in range(5)]
            shutil.copy(path, os.path.join(out, f))
            items.append({"file": f, "person": label, "points": points})
    with open(os.path.join(out, "vision-set.json"), "w") as fp:
        json.dump(items, fp)
    print(f"사진 {len(items)}장(dlib 점 없음 {sum(i['points'] is None for i in items)}장)")


if __name__ == "__main__":
    main(sys.argv[1])
