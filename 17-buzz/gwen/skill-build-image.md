---
name: build-image
description: Build a container image on your machine with podman and push it to Rick's registry (Harbor, registry.ash4d.com).
---
You build images with podman on your machine and push them to Rick's Harbor registry. podman is logged in as your own robot account, which can push and pull in the project ash4d-lab and nowhere else. Run everything with sandbox_run.

Where it goes. registry.ash4d.com/ash4d-lab/<name>:<tag>. The project is shared with every image the lab runs, including your own service (ash4d-lab/gwen), and your account can overwrite any tag in it. So:
- Before you choose a name, check that it is free, or already yours: `podman search --list-tags registry.ash4d.com/ash4d-lab/<name>` (an error saying the repository is unknown means the name is free).
- Never push over a tag that already exists. Choose a new tag. Use version numbers (0.1.0, 0.1.1), never `latest`.
- Never push to ash4d-lab/gwen or to any name you did not create, unless Rick asks for exactly that.

The base image. Start FROM a SUSE BCI image: registry.suse.com/bci/bci-base, bci-micro, bci-minimal, or a language image such as registry.suse.com/bci/python:3.13, bci/nodejs:22, bci/golang. Find one with `podman search registry.suse.com/bci/`. A maintained image from the software's own vendor is also acceptable when you run their software unchanged. Run as a numeric non-root user (`USER 1000:1000`) so the cluster can verify it.

Building.
1. Keep each image's source in its own directory under ~/images/<name>/ with its Dockerfile, so it can be built again.
2. Build: `cd ~/images/<name> && podman build -t registry.ash4d.com/ash4d-lab/<name>:<tag> .`  A build can pass the time limit of one call. For anything beyond a small image, start it detached and check on it:
   systemd-run --user --unit=build-<name> --working-directory=$HOME/images/<name> podman build -t registry.ash4d.com/ash4d-lab/<name>:<tag> .
   journalctl --user -u build-<name> --no-pager | tail -30
3. Test the image before you push it: `podman run --rm registry.ash4d.com/ash4d-lab/<name>:<tag> <a command that proves it works>`.
4. Push: `podman push registry.ash4d.com/ash4d-lab/<name>:<tag>`.
5. Prove the push by reading the tag back from the registry, not from your local copy:
   skopeo inspect docker://registry.ash4d.com/ash4d-lab/<name>:<tag> --format '{{.Digest}}'
   If skopeo is missing, `sudo zypper --non-interactive install skopeo`. Give Rick the full image name and that digest.

Running it in the cluster is a separate job: load the kubernetes skill. The project is private, so a pod needs the pull Secret harbor-pull in its namespace.

Housekeeping. Your disk is 20 GB. `podman image prune -f` after a build removes the layers nothing uses; `podman system df` shows what images take.

If a push is refused with "unauthorized", your login is gone or the name is outside ash4d-lab. Check with `podman login --get-login registry.ash4d.com`; it should print robot$ash4d-lab+gwen. If it does not, tell Rick; you cannot log in again yourself.
