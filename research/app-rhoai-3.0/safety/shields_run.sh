echo "Running regex detector"
echo "--------------------------------"


curl -s -X 'POST' https://lsd-llama-milvus-inline-service-my-first-model.apps.ocp.hkk6t.sandbox5156.opentlc.com/v1/safety/run-shield \
-H "Content-Type: application/json" \
-d '{
    "shield_id": "regex_detector",
    "messages": [
        {
        "content": "My email is test@example.com",
        "role": "user"
        }
    ]
}' | jq '.'

echo "--------------------------------"
echo "Running granite detector"
echo "--------------------------------"

curl -s -X 'POST' https://lsd-llama-milvus-inline-service-my-first-model.apps.ocp.hkk6t.sandbox5156.opentlc.com/v1/safety/run-shield \
-H "Content-Type: application/json" \
-d '{
    "shield_id": "regex-granite-guard",
    "messages": [
        {
        "content": "rm -rf /",
        "role": "system"
        }
    ]
}' | jq '.'