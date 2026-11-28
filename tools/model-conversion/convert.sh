#!/bin/bash
# dlib 얼굴 인식 모델을 Core ML로 바꾸고 동등성 테스트까지 한 번에 돌린다.
#   ./convert.sh            # work/에 내려받고 out/FaceEmbedding.mlpackage를 만든다
#   ./convert.sh --install  # 앱(PhotoAlbum/People/)에도 복사한다
set -euo pipefail
cd "$(dirname "$0")"
PY=.venv/bin/python
mkdir -p work out

if [ ! -x "$PY" ]; then
  /opt/homebrew/bin/python3.11 -m venv .venv
  .venv/bin/pip install -q --upgrade pip
  # 번들된 libpng는 최신 macOS SDK에서 빌드되지 않아 Homebrew 것을 쓴다.
  CMAKE_PREFIX_PATH=/opt/homebrew .venv/bin/pip install -q -r requirements.txt
fi

cd work
for f in dlib_face_recognition_resnet_model_v1 shape_predictor_5_face_landmarks; do
  [ -f "$f.dat" ] || { curl -sSLO "http://dlib.net/files/$f.dat.bz2"; bunzip2 -kf "$f.dat.bz2"; }
done
if [ ! -d dlib-src ]; then
  curl -sSL https://github.com/davisking/dlib/archive/refs/tags/v19.24.6.tar.gz -o dlib-src.tar.gz
  mkdir -p dlib-src && tar xzf dlib-src.tar.gz -C dlib-src --strip-components 1
fi
cd ..

# 1) .dat -> XML (dlib C++ net_to_xml)
if [ ! -f work/dlib_face_recognition_resnet_model_v1.xml ]; then
  cmake -S xml_generator -B work/xml-build -DDLIB_SOURCE="$PWD/work/dlib-src/dlib" -DCMAKE_BUILD_TYPE=Release \
    -DDLIB_NO_GUI_SUPPORT=ON -DDLIB_USE_CUDA=OFF -DDLIB_PNG_SUPPORT=OFF -DDLIB_JPEG_SUPPORT=OFF -DDLIB_GIF_SUPPORT=OFF >/dev/null
  cmake --build work/xml-build -j8 >/dev/null
  work/xml-build/xml_generator work/dlib_face_recognition_resnet_model_v1.dat work/dlib_face_recognition_resnet_model_v1.xml
fi

# 2) XML -> Keras -> Core ML
rm -rf out/FaceEmbedding.mlpackage
$PY convert.py work/dlib_face_recognition_resnet_model_v1.xml out/FaceEmbedding.mlpackage --keras work/dlib_face.keras

# 3) 동등성 테스트(실패하면 여기서 멈춘다)
$PY parity_test.py out/FaceEmbedding.mlpackage
cp fixtures/alignment.json ../../PhotoAlbumTests/Fixtures/face-alignment.json

if [ "${1:-}" = "--install" ]; then
  rm -rf ../../PhotoAlbum/People/FaceEmbedding.mlpackage
  mkdir -p ../../PhotoAlbum/People
  cp -R out/FaceEmbedding.mlpackage ../../PhotoAlbum/People/
  echo "앱에 복사: PhotoAlbum/People/FaceEmbedding.mlpackage"
fi
