#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo_dir=$(pwd)
nginx_image=nginx:stable-alpine
python_image=python:3.13-alpine
# Não ler o .env local nem resolver/criar a rede externa do Compose.
docker compose --env-file /dev/null config --quiet

docker pull "$nginx_image"
docker pull "$python_image"
# Nomes exclusivos; cleanup remove somente recursos criados por esta execução.
ci_id="infra-gateway-ci-$(date +%s)-$$"
ci_network="$ci_id-net"
ci_gateway="$ci_id-gateway"
ci_backend="$ci_id-backend"
ci_runner="$ci_id-runner"
network_created=false
created_containers=()
cleanup() {
  result=$?
  trap - EXIT
  if (( result != 0 )); then
    for container in "${created_containers[@]}"; do
      docker logs --tail 100 "$container" >&2 || true
    done
  fi
  for container in "${created_containers[@]}"; do
    docker rm -f "$container" >/dev/null || true
  done
  if "$network_created"; then docker network rm "$ci_network" >/dev/null || true; fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

restrictions=(--read-only --user 101:101 --cap-drop ALL
  --security-opt no-new-privileges:true
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777)
nginx_mounts=(--mount "type=bind,src=$repo_dir/nginx/nginx.conf,dst=/etc/nginx/nginx.conf,readonly"
  --mount "type=bind,src=$repo_dir/nginx/conf.d,dst=/etc/nginx/conf.d,readonly")

echo 'Validando sintaxe Nginx sem rede'
docker run --rm --network none "${restrictions[@]}" "${nginx_mounts[@]}" \
  --entrypoint nginx "$nginx_image" -t

docker network create --internal "$ci_network" >/dev/null
network_created=true

docker run -d --name "$ci_backend" --network "$ci_network" --network-alias tesouraria-api \
  "${restrictions[@]}" \
  --mount "type=bind,src=$repo_dir/tests/ci-backend.py,dst=/tests/backend.py,readonly" \
  "$python_image" python -B /tests/backend.py >/dev/null
created_containers+=("$ci_backend")
docker run -d --name "$ci_gateway" --network "$ci_network" --network-alias gateway \
  "${restrictions[@]}" "${nginx_mounts[@]}" \
  --entrypoint nginx "$nginx_image" -g 'daemon off;' >/dev/null
created_containers+=("$ci_gateway")
# Runner na mesma rede, sem publicar portas e sem acesso ao socket Docker.
docker create --name "$ci_runner" --network "$ci_network" "${restrictions[@]}" \
  --mount "type=bind,src=$repo_dir/tests,dst=/tests,readonly" \
  "$python_image" python -B /tests/tesouraria-http.py http://gateway:8080 --fixture >/dev/null
created_containers+=("$ci_runner")
docker start -a "$ci_runner"
test "$(docker inspect -f '{{.State.ExitCode}}' "$ci_runner")" = 0
# Os sentinelas são fictícios; nem eles devem aparecer no log do gateway.
if docker logs "$ci_gateway" 2>&1 | grep -Eq 'INC5_|token=|Bearer '; then
  echo 'Falha: dados sensíveis fictícios encontrados no log' >&2
  exit 1
fi
echo 'CI concluída: Compose, nginx -t, HTTP e logs aprovados'
