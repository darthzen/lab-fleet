# GPU Thermal Guard (sdf1)

Protects the V100 from running hot when its external fan is off.

## Why it exists

The V100 (`Tesla PG500-216`, GPU 1) is passively cooled — `nvidia-smi` reports
`fan.speed` as `N/A`. Its entire cooling system is an external fan on DLI outlet
6. That fan **does not self-start when its outlet is restored**, it runs at a
reduced speed (set 2026-08-02 to cut noise), and there is no remote way to
confirm it is spinning. Outlet state answers only whether the relay closed.

So the failure mode is silent: power event, fan stays off, nobody notices, and
the next inference or training run cooks the card.

## Why it reads nvidia-smi and not Kubernetes

`ai/ollama` is pinned to the V100 by UUID with **empty `resources: {}`**, so it
bypasses the device plugin entirely. `kubectl describe node` reports
`nvidia.com/gpu allocated: 0` while the card is fully in use. Any guard keyed on
scheduler state would see an idle GPU.

## The ladder

Thresholds come from the card's own reported limits: core max operating 83 °C,
slowdown 88 °C, shutdown 91 °C; HBM2 memory max 85 °C. Either sensor trips it.

| Stage | Core / Mem | Action |
|---|---|---|
| `NOTIFY` | 70 / 70 | alert only |
| `CAP` | 75 / 75 | power limit 250 W → 150 W, no cluster interaction |
| `STOP` | 80 / 80 | pause Fleet bundles, scale V100 workloads to 0 |
| `FLOOR` | 85 / 83 | power limit → 100 W, page, stop escalating |
| recover | < 50 both | restore workloads and the 250 W limit |

Escalation **walks every rung**. A jump straight from `NORMAL` to `FLOOR` still
performs `CAP` and `STOP` on the way past — a card with no airflow can cross
25 °C between two 15 s polls, and flooring the power limit while leaving the
workloads running would be the worst of both.

Escalation is one-way while hot; the guard holds the highest stage reached
rather than stepping back down as temperature wobbles, so it cannot flap between
78 and 82.

**Recovery at 50 °C is deliberate.** Idle with the fan running is 38 °C. A
passive V100 with the fan *off* is not expected to settle that low, so the guard
effectively latches in the fan-off case and self-restores only after a transient
load spike. That is reasoning from the card being passive — nobody has run it
with the fan off to measure where it actually settles.

## What it will not do

**It never shuts the node down, at any stage.** `shutdown -h now` on sdf1 hangs
on Longhorn iSCSI teardown — measured at 21 minutes with no sign of completing,
and it ended in an AC cut. An automated shutdown here is a delayed unclean cut.
`FLOOR` pages and stops.

## Targets

| Workload | Why |
|---|---|
| `ai/ollama` | UUID-pinned to the V100, `KEEP_ALIVE=-1` |
| `ai/comfyui` | `nvidia.com/gpu: 1`, scheduler may place it on the V100 |
| `ai/unsloth-studio` | `runtimeClass: nvidia`, training — sustained max load |

`emby/emby` is deliberately excluded: it is pinned to the GTX 1070
(`GPU-5641c03a-…`) and cannot heat the V100.

Fleet bundles paused alongside: `lab-ai-04-ollama`, `lab-ai-07-comfyui`,
`lab-ai-21-unsloth-studio`. Pause-then-scale going off, scale-then-unpause
coming back — the same ordering `sdf1-toggle` uses, and the same
`lab.ash4d.com/prior-replicas` annotation, so the two tools do not fight and
`sdf1-toggle on ai` can also restore what the guard stopped.

## Rancher is not on the critical path

sdf1 runs independently of Rancher — a managed cluster keeps working whether the
management cluster is up or not. Only Fleet state changes and the Rancher admin
UI need khyron.

The guard is built to that fact:

- Every API call carries `--request-timeout` (`KUBE_TIMEOUT`, default 5s), so an
  unreachable Rancher costs seconds rather than blocking the sdf1-side
  scale-down, which is the action that actually cools the card.
- **The pause is best-effort; the scale is not.** A failed pause sets
  `pause_pending` and the guard keeps scaling workloads down regardless.
- While `pause_pending` is set and a stage is held, the guard retries the pause
  on every poll. Nothing reverts the scale-down while Rancher is away, but the
  moment it returns Fleet would restore the workloads onto a possibly hot card.
- On recovery, a failed *unpause* leaves the bundles paused and says so. That is
  the safe direction: paused means Fleet leaves the restored replicas alone.

## Install

    install -m0755 gpu-guard.sh    /opt/gpu-guard/gpu-guard.sh
    install -m0644 gpu-guard.conf  /etc/gpu-guard/gpu-guard.conf   # dir 0700
    install -m0644 gpu-guard.service /etc/systemd/system/
    systemctl daemon-reload && systemctl enable --now gpu-guard

Alerting needs a Slack incoming-webhook URL, one line, at
`/etc/gpu-guard/slack-webhook` mode 0600. The canonical copy lives at
`~/Developer/keys/slack/webhook`. **Absent webhook degrades to journal-only —
the guard still acts.** A thermal guard that refused to run because it could not
reach Slack would be worse than a quiet one.

## Commands

    gpu-guard.sh status          temps, held stage, thresholds, alert path
    gpu-guard.sh simulate 81     what 81 °C would do, touching nothing
    gpu-guard.sh clear           restore workloads + power limit now
    gpu-guard.sh test-alert      prove the Slack path
    journalctl -u gpu-guard -f

`simulate` exists so a warning branch can be exercised by reading its output
rather than by invoking the command that mutates state. Running
`sdf1-power.sh off gpu-fan` "to see what it printed" cut real rack power to the
fan on 2026-08-02.

## State

`/var/lib/gpu-guard/state`, not `/run`, on purpose. Paused bundles live on
khyron and survive an sdf1 reboot, and the scaled-down deployments survive with
them. A guard that forgot it had tripped would leave them off silently forever.
