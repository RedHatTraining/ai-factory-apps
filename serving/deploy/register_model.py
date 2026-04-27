# /// script
# requires-python = ">=3.12"
# dependencies = ["model-registry"]
# ///

import subprocess
import time

from model_registry import ModelRegistry

REGISTRY_NS   = "rhoai-model-registries"
REGISTRY_NAME = "serving-deploy-registry"
MODEL_IMAGE   = "oci://quay.io/redhattraining/oci-models/qwen3_0.6b"
MODEL_NAME    = "Qwen3-0.6b"
MR_PORT       = 8080
LOCAL_MR_PORT = 9246

pf = subprocess.Popen(
    ["oc", "port-forward", f"svc/{REGISTRY_NAME}",
     f"{LOCAL_MR_PORT}:{MR_PORT}", "-n", REGISTRY_NS],
    stdout=subprocess.DEVNULL,
)
time.sleep(3)

try:
    registry = ModelRegistry("http://localhost", LOCAL_MR_PORT, author="student", is_secure=False)
    if registry.get_registered_model(MODEL_NAME) is not None:
        print(f"[INFO] {MODEL_NAME} already registered, skipping.")
    else:
        registry.register_model(
            MODEL_NAME,
            MODEL_IMAGE,
            version="v1",
            model_format_name="OCI",
            model_format_version="1",
            metadata={"task": "text-generation", "license": "apache-2.0"},
        )
        print(f"[OK] {MODEL_NAME} registered.")
finally:
    pf.terminate()
    pf.wait()
