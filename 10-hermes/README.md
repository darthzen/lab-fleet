# 10 — Hermes Agent (Nous Research)

    kubectl create ns hermes
    kubectl -n hermes create secret generic hermes-api-key --from-literal=key=<API_KEY>
    kubectl -n hermes create secret generic hermes-slack \
      --from-literal=SLACK_BOT_TOKEN=<xoxb-...> \
      --from-literal=SLACK_APP_TOKEN=<xapp-...> \
      --from-literal=SLACK_ALLOWED_USERS=<user-ids>
    kubectl apply -f hermes.yaml

Self-hosted agentic AI (`nousresearch/hermes-agent`) with a Slack front-end —
API on 8642, allow-listed Slack users only, state on a Longhorn PVC.
