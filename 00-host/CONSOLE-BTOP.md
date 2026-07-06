# Console dashboard — btop on tty1

Replaces the login prompt on **tty1** with a persistent `btop` display on node
`sdf1`. Login shells stay on tty2–tty6 (`Ctrl+Alt+F2` … `F6`).

Unit file: [`btop-console.service`](btop-console.service).

## Install

```bash
sudo zypper in btop
sudo cp 00-host/btop-console.service /etc/systemd/system/btop-console.service
sudo systemctl daemon-reload
sudo systemctl disable --now getty@tty1.service
sudo systemctl enable --now btop-console.service
# if a getty respawns on tty1:
# sudo systemctl mask getty@tty1.service
```

## Notes

- Runs as **root** for full process + NVIDIA GPU visibility (change `User=` to drop that).
- `Restart=always` relaunches btop if you `q` out of it on tty1. Pause: `sudo systemctl stop btop-console`.
- `Environment=TERM=linux` is required for correct rendering on the raw console.

## Revert

```bash
sudo systemctl disable --now btop-console.service
sudo systemctl unmask getty@tty1.service 2>/dev/null || true
sudo systemctl enable --now getty@tty1.service
```
