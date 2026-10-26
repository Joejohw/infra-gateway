# infra-gateway

Gateway Nginx central para aplicações Docker na mesma EC2. Execute os comandos
neste diretório (onde está `compose.yaml`). Requer Docker Engine e Compose v2+.

## Inicialização

```sh
cp .env.example .env
docker compose config --quiet
# Reutiliza a rede existente ou cria somente se estiver ausente.
docker network inspect proxy_net >/dev/null 2>&1 || docker network create proxy_net
docker compose pull gateway
docker compose up -d gateway
docker compose ps
docker compose logs --tail=100 gateway
```

A rede é externa: seu ciclo de vida é independente do gateway. Escolha um
`COMPOSE_PROJECT_NAME` exclusivo por instalação. Não há `container_name` nem
nome fixo de contêiner; reserve `tesouraria-api` exclusivamente para a Tesouraria
na rede compartilhada. Portas de host também precisam estar disponíveis.

Por padrão, somente `127.0.0.1:8080` é publicado; não é necessário abrir portas
no Security Group para esta etapa. Em uma EC2, acesse localmente por túnel:

```sh
ssh -L 18080:127.0.0.1:8080 usuario@ec2
curl -i http://127.0.0.1:18080/healthz
```

Não há solicitação de domínio ou certificado. `nginx/https/` reserva a etapa
futura, sem ser montado ou carregado e sem porta HTTPS publicada.

## Validação isolada

O primeiro comando não precisa de daemon Docker. O segundo usa um contêiner
temporário, sem publicar portas, sem ingressar na rede de aplicações e sem
precisar da rede `proxy_net` ou de backends ativos:

Use a mesma imagem escolhida em `.env` (o exemplo abaixo usa a imagem padrão):

```sh
docker compose config --quiet
docker run --rm --network none --read-only --user 101:101 \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777 \
  --mount "type=bind,src=$(pwd)/nginx/nginx.conf,dst=/etc/nginx/nginx.conf,readonly" \
  --mount "type=bind,src=$(pwd)/nginx/conf.d,dst=/etc/nginx/conf.d,readonly" \
  --entrypoint nginx nginx:stable-alpine -t
```

Após iniciar o gateway:

```sh
curl -i http://127.0.0.1:8080/healthz
curl -i http://127.0.0.1:8080/
curl -i -H 'Host: tesouraria.localhost' 'http://127.0.0.1:8080/exemplo?teste=1'
```

Resultados esperados: `200` na saúde local; `404` para hosts sem rota; `502`
na Tesouraria enquanto o backend não estiver disponível. O healthcheck mede o
gateway, independentemente das aplicações. A resolução via DNS Docker ocorre
durante a requisição, permitindo iniciar e executar `nginx -t` sem o backend.

## Integrar uma aplicação

No Compose **da própria aplicação**, conectar apenas seu serviço HTTP à rede
externa. Este trecho é orientação; este repositório não altera outros projetos:

```yaml
services:
  api:
    # image e demais opções pertencem à aplicação
    networks:
      default: {}
      proxy_net:
        aliases:
          - tesouraria-api
    # Sem ports: para a porta 8080 do backend.

networks:
  default: {}
  proxy_net:
    external: true
    name: proxy_net
```

A API deve escutar em `0.0.0.0:8080` no contêiner. `expose` é opcional e não
publica portas. Bancos permanecem na rede privada da aplicação, sem `ports` e
sem ligação à `proxy_net`. A rede compartilhada permite comunicação entre seus
membros; conectar apenas serviços que precisam receber tráfego do gateway.
Aliases de backend devem ser exclusivos nessa rede, inclusive entre projetos.

Para Bloquinho e próximas aplicações, siga `nginx/conf.d/README.md` e defina
um host e alias próprios. Nenhuma configuração do Bloquinho foi ativada.
Depois de editar as rotas, valide antes de recarregar:

```sh
docker compose exec gateway nginx -t
docker compose exec gateway nginx -s reload
```

## Operação e permissões

Imagem oficial Nginx Alpine, master e workers com UID/GID `101:101`, porta
interna não privilegiada `8080`, capabilities removidas e sem elevação de
privilégios. O entrypoint chama o Nginx diretamente; não há geração automática
de configuração. Arquivos montados são somente leitura, o filesystem é somente
leitura e PID/temporários ficam no tmpfs limitado de `/tmp`. Mantenha os arquivos
legíveis pelo UID 101 (normalmente arquivos `0644` e diretórios `0755`).

Logs vão para stdout/stderr com rotação no Docker; o access log omite query
strings, mas caminhos e mensagens de erro ainda podem conter dados da aplicação.
Não envie segredos por URLs. Os cabeçalhos de IP e protocolo são substituídos
pelo gateway; uma futura camada de balanceamento exige revisão de proxies
confiáveis. Limite inicial de corpo: 10 MiB; timeouts do proxy: 5/30/30 segundos.

Não há Docker socket, credenciais ou volumes de outras aplicações. A tag
`stable-alpine` recebe atualizações; fixe `NGINX_IMAGE` em versão/digest revisado
para releases reproduzíveis e confirme UID, permissões e healthcheck ao atualizar.
O healthcheck sinaliza falhas; a política `unless-stopped` reinicia o processo
quando ele termina, sem reiniciar automaticamente um contêiner apenas unhealthy.

Referências: [imagem oficial](https://hub.docker.com/_/nginx) e
[proxy_pass e resolução de nomes](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_pass).
