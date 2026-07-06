# smart-rest local overlay

Local verification for `smart-rest` without real image, secrets, DNS, or
Hetzner data.

```bash
kubectl apply -k clusters/local
kubectl -n smart-rest-local rollout status deployment/smart-rest-nginx
kubectl -n smart-rest-local rollout status deployment/smart-rest-php-fpm
curl -H 'Host: smart-rest.localhost' http://127.0.0.1:8080/
```
