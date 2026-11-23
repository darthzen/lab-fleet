---
name: kubernetes
description: Look at, deploy to or change Rick's Kubernetes cluster (sdf1) with kubectl and helm from your machine.
---
You administer Rick's cluster, sdf1: one node, k3s. kubectl and helm are installed on your machine and logged in as you (ServiceAccount gwen in namespace buzz) with cluster-admin, which is every right there is, including every Secret. Run them with sandbox_run. Your default namespace is buzz; name the namespace with -n on every command so the output says where it came from.

Looking. Read freely. Start from what is there, never from what you expect: `kubectl get ns`, `kubectl -n <ns> get all`, `kubectl -n <ns> describe <kind>/<name>`, `kubectl -n <ns> logs <pod> --tail=100`, `kubectl -n <ns> get events --sort-by=.lastTimestamp`. Long output is cut in the middle, so narrow the command (a namespace, a name, `-o jsonpath=...`, `| tail`) before you run it wide.

Secrets. You can read every Secret. Never put a Secret's value in a reply, in memory, in the library or in a file outside the cluster. To check one, list its keys: `kubectl -n <ns> get secret <name> -o jsonpath='{.data}' | jq 'keys'`.

Who owns a thing. Most of the lab is deployed from Rick's lab-fleet git repository by Fleet. A Fleet-managed object carries the label objectset.rio.cattle.io/hash:
  kubectl -n <ns> get <kind> <name> -o jsonpath='{.metadata.labels.objectset\.rio\.cattle\.io/hash}'
If that prints anything, Fleet owns it and puts back whatever you edit, so a lasting change is Rick's to make in git. Tell him what should change and where; do not fight Fleet with repeated edits. Never run `kubectl rollout restart` on a Fleet-managed Deployment.

Changing. Before you change or delete anything you did not create yourself, tell Rick exactly what you are about to do and wait for his yes. What you created yourself in this conversation, or what Rick asked you by name to change, needs no second yes. Deleting a PersistentVolumeClaim, a namespace or a VirtualMachine destroys data that has no backup: always ask first, and say what will be lost.

Deploying something of your own. A service that should keep running belongs in the cluster, not on your machine.
1. Put it in a namespace of its own, named for what it is, unless Rick names one: `kubectl create namespace <name>`.
2. Write the manifests to a file on your machine and keep them under ~/deploy/<name>/, so you can show Rick what is running and apply it again.
3. An image from registry.ash4d.com needs the pull Secret in that namespace. Copy it from buzz:
   kubectl -n buzz get secret harbor-pull -o json | jq '{apiVersion,kind,type,data,metadata:{name:.metadata.name}}' | kubectl -n <name> apply -f -
   and set `imagePullSecrets: [{name: harbor-pull}]` in the pod spec.
4. Apply, then watch it come up before you report: `kubectl -n <name> apply -f <file>`, `kubectl -n <name> rollout status deploy/<name> --timeout=120s`, then `kubectl -n <name> get pods`. Report the status the output shows. If a pod is not Running, read `describe` and `logs` and say what they say.
5. Tell Rick the namespace, what is running in it and how to remove it (`kubectl delete namespace <name>`).

The two GPUs are shared. Your own model runs on OpenRouter, not on these GPUs; llama-server, Ollama and ComfyUI in namespace ai take turns on them, so check what is running before starting another. Do not start anything that requests nvidia.com/gpu without asking Rick.

Report what the commands printed. A command that failed, failed; say so with the error text.
