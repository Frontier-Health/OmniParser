FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common curl git libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install -y --no-install-recommends python3.12 python3.12-venv python3.12-dev \
    && ln -sf /usr/bin/python3.12 /usr/bin/python3 \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.12 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

WORKDIR /app

COPY pyproject.toml ./
RUN uv venv .venv --python python3.12 \
    && . .venv/bin/activate \
    && uv pip install -r pyproject.toml \
    && uv pip install huggingface-hub

COPY . .

# Download weights at build time. To skip this and mount weights at runtime
# instead, build with:  docker build --build-arg DOWNLOAD_WEIGHTS=0 .
ARG DOWNLOAD_WEIGHTS=1
RUN if [ "$DOWNLOAD_WEIGHTS" = "1" ] && [ ! -f weights/icon_detect/model.pt ]; then \
    . .venv/bin/activate && \
    for folder in icon_caption icon_detect; do \
        hf download microsoft/OmniParser-v2.0 \
            --local-dir weights --repo-type model --include "$folder/*"; \
    done && \
    mv weights/icon_caption weights/icon_caption_florence; \
    fi

ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8000

# python -m omniparserserver must run from the module's directory
WORKDIR /app/omnitool/omniparserserver

CMD ["python", "-m", "omniparserserver", \
     "--som_model_path", "/app/weights/icon_detect/model.pt", \
     "--caption_model_name", "florence2", \
     "--caption_model_path", "/app/weights/icon_caption_florence", \
     "--device", "cuda", \
     "--host", "0.0.0.0", \
     "--port", "8000"]
