# frugal-deploy

Public distribution endpoint for the **Frugal** Azure deployment template.

- Install instructions, prerequisites and runbook: **https://frugal.run**
- Source code (private): https://github.com/abhijitsghosh/frugal
- Container image (public): `ghcr.io/abhijitsghosh/frugal:latest`

The `azuredeploy.json` in this repo is auto-synced from the private source repo
on every tagged release and is what `az stack sub create --template-uri` reads.
