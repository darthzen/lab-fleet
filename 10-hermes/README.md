# 10 — Hermes Agent (Nous Research)

    kubectl create ns hermes
    kubectl -n hermes create secret generic hermes-api-key --from-literal=key=<API_KEY>
    kubectl -n hermes create secret generic hermes-slack \
      --from-literal=SLACK_BOT_TOKEN=<xoxb-...> \
      --from-literal=SLACK_APP_TOKEN=<xapp-...> \
      --from-literal=SLACK_ALLOWED_USERS=<user-ids>
    kubectl -n hermes create secret generic hermes-webui \
      --from-literal=password="$(openssl rand -base64 24)"     # see .example file
    kubectl apply -f hermes.yaml

Self-hosted agentic AI (`nousresearch/hermes-agent`) with a Slack front-end —
API on 8642, allow-listed Slack users only, state on a Longhorn PVC.

A second container, `hermes-webui` (`nesquena/hermes-webui`), serves a browser UI
on 8787 at `hermes.ash4d.com` (Traefik + cert-manager `letsencrypt-dns`). Only
the UI is behind the ingress; the API on 8642 stays on the LoadBalancer IP. The
two containers share one pod because the UI reads the agent's state off the
shared PVC rather than over HTTP — splitting them would need an RWX volume. Two
init containers make that work: `fix-perms` chowns the PVC to uid 10000 (the UI's
user), and `copy-agent-src` stages the agent source into a shared emptyDir for
the UI to introspect.

> **Prerequisite:** the live Deployment carries `HERMES_WEBUI_PASSWORD` as a
> plaintext env value. `hermes.yaml` reads it from the `hermes-webui` Secret
> instead, since this repo is public and Fleet renders manifests into a Bundle on
> the controller. Create that Secret before enabling this path in Fleet, seeded
> with the password already in the live spec so adoption does not change the
> credential:
>
>     kubectl -n hermes get deploy hermes-agent -o jsonpath\
>       ='{.spec.template.spec.containers[1].env[?(@.name=="HERMES_WEBUI_PASSWORD")].value}'
>
> Adoption still restarts the pod once — moving the env from an inline value to a
> `secretKeyRef` is a pod template change. Rotate the password if this cluster
> ever stops being throwaway.
