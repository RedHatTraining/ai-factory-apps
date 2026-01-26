curl -s -X 'POST' \
  'https://lsd-llama-milvus-inline-service-my-first-model.apps.ocp.hkk6t.sandbox5156.opentlc.com/v1/shields' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
    "shield_id": "regex_detector",
    "provider_shield_id": "regex_detector",
    "provider_id": "trustyai_fms",
    "params": {
      "type": "content",
      "confidence_threshold": 0.5,
      "message_types": ["system", "user"],
      "detectors": {
        "regex": {
          "detector_params": {
            "regex": ["email", "ssn", "credit-card"]
          }
        }
      }
    }
  }' | jq '.'


curl -s -X 'POST' \
  'https://lsd-llama-milvus-inline-service-my-first-model.apps.ocp.hkk6t.sandbox5156.opentlc.com/v1/shields' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
    "shield_id": "regex-granite-guard",
    "provider_shield_id": "regex-granite-guard",
    "provider_id": "trustyai_fms",
    "params": {
      "type": "chat",
      "confidence_threshold": 0.6,
      "message_types": ["system", "completion", "assistant", "user"],
      "detectors": {
        "granite": {
          "detector_params": {
            "temperature": 0.1,
            "risk_name": "code_execution",
            "risk_definition": "The message requests or attempts to execute potentially harmful or unauthorized code that could compromise system security or perform malicious actions."
          }
        }
      }
    }
  }' | jq '.'

