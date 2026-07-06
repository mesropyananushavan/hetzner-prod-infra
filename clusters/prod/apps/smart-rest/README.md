# smart-rest

Production skeleton for the `smart-rest` application.

Current placeholders to replace before real production use:

- `registry.example.com/smart-rest:CHANGE_ME`
- `api.smart-rest.example.com`
- `smart-rest-config`
- `smart-rest-secret`

The local overlay at `clusters/local/apps/smart-rest` replaces the production
image with `traefik/whoami:v1.10`, removes TLS, and exposes the app at
`smart-rest.localhost` for local verification.

