'''
python -m omniparserserver --som_model_path ../../weights/icon_detect/model.pt --caption_model_name florence2 --caption_model_path ../../weights/icon_caption_florence --device cuda --BOX_TRESHOLD 0.05
'''

import sys
import os
import time
import base64
import logging
from typing import Optional

import argparse
import boto3
import uvicorn
from fastapi import FastAPI, File, HTTPException, UploadFile
from pydantic import BaseModel

root_dir = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.append(root_dir)
from util.omniparser import Omniparser

logger = logging.getLogger("omniparserserver")


def parse_arguments():
    parser = argparse.ArgumentParser(description='Omniparser API')
    parser.add_argument('--som_model_path', type=str, default='../../weights/icon_detect/model.pt', help='Path to the som model')
    parser.add_argument('--caption_model_name', type=str, default='florence2', help='Name of the caption model')
    parser.add_argument('--caption_model_path', type=str, default='../../weights/icon_caption_florence', help='Path to the caption model')
    parser.add_argument('--device', type=str, default='cpu', help='Device to run the model')
    parser.add_argument('--BOX_TRESHOLD', type=float, default=0.05, help='Threshold for box detection')
    parser.add_argument('--host', type=str, default='0.0.0.0', help='Host for the API')
    parser.add_argument('--port', type=int, default=8000, help='Port for the API')
    args = parser.parse_args()
    return args


args = parse_arguments()
config = vars(args)

app = FastAPI(title="OmniParser API")
omniparser = Omniparser(config)

_s3_client = None


def get_s3_client():
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client("s3")
    return _s3_client


def _download_from_s3(s3_uri: str) -> bytes:
    """Download an object from S3 given an s3://bucket/key URI."""
    if not s3_uri.startswith("s3://"):
        raise ValueError(f"Invalid S3 URI: {s3_uri}")
    path = s3_uri[len("s3://"):]
    bucket, _, key = path.partition("/")
    if not bucket or not key:
        raise ValueError(f"Invalid S3 URI: {s3_uri}")
    resp = get_s3_client().get_object(Bucket=bucket, Key=key)
    return resp["Body"].read()


def _image_bytes_to_base64(image_bytes: bytes) -> str:
    return base64.b64encode(image_bytes).decode("utf-8")


def _run_parse(image_base64: str) -> dict:
    start = time.time()
    som_image_base64, parsed_content_list = omniparser.parse(image_base64)
    latency = time.time() - start
    logger.info("parse completed in %.3fs", latency)
    return {
        "som_image_base64": som_image_base64,
        "parsed_content_list": parsed_content_list,
        "latency": latency,
    }


# ---------------------------------------------------------------------------
# JSON body endpoint (backward-compatible, also adds s3_path support)
# ---------------------------------------------------------------------------

class ParseRequest(BaseModel):
    base64_image: Optional[str] = None
    s3_path: Optional[str] = None


@app.post("/parse/")
async def parse(parse_request: ParseRequest):
    if parse_request.base64_image and parse_request.s3_path:
        raise HTTPException(status_code=400, detail="Provide exactly one of base64_image or s3_path, not both.")

    if parse_request.base64_image:
        image_b64 = parse_request.base64_image
    elif parse_request.s3_path:
        try:
            image_bytes = _download_from_s3(parse_request.s3_path)
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"Failed to download from S3: {e}")
        image_b64 = _image_bytes_to_base64(image_bytes)
    else:
        raise HTTPException(status_code=400, detail="Provide either base64_image or s3_path.")

    return _run_parse(image_b64)


# ---------------------------------------------------------------------------
# Multipart file upload endpoint
# ---------------------------------------------------------------------------

@app.post("/parse/upload/")
async def parse_upload(image_file: UploadFile = File(...)):
    image_bytes = await image_file.read()
    if not image_bytes:
        raise HTTPException(status_code=400, detail="Uploaded file is empty.")
    image_b64 = _image_bytes_to_base64(image_bytes)
    return _run_parse(image_b64)


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.get("/probe/")
async def probe():
    return {"message": "Omniparser API ready"}


if __name__ == "__main__":
    uvicorn.run("omniparserserver:app", host=args.host, port=args.port, reload=True)