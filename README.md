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

## Proteção HTTP — Tesouraria Pix (incremento 5)

Somente `tesouraria.localhost` aplica estes limites. As zonas e maps em
`nginx/conf.d/05-tesouraria-limits.conf` são declarados no contexto `http` pelo
include existente; a aplicação ocorre no server em `10-tesouraria.conf`.

| Rota normalizada (barra final opcional) | Taxa por IP | Burst |
| --- | --- | --- |
| `/api/v1/auth/login` | 5/min | 1 |
| `/api/v1/users` (cadastro) | 5/min | 1 |
| `/api/v1/auth/forgot-password` | 3/min | 1 |
| `/api/v1/auth/resend-verification` | 3/min | 1 |
| `/api/v1/auth/reset-password` | 5/min | 1 |
| `/api/v1/auth/verify-email` | 5/min | 1 |
| Todas as requisições, inclusive as acima | 10/s | 5 |

Todas usam `nodelay`: excedentes aceitos pelo burst seguem imediatamente;
os demais recebem 429, sem fila. Não é uma quota por minuto de calendário:
o saldo se recupera continuamente (12 segundos por pedido a 5/min e 20 a
3/min). Uma rajada com saldo vazio aceita até 2 pedidos nas rotas sensíveis
ou 6 no geral. Todos os métodos contam, inclusive OPTIONS; considerar isto
no dimensionamento, sem modificar CORS. Os maps usam `$uri`, sem argumentos;
chaves vazias não participam da zona específica. Páginas `/account/*` ficam
sob o limite geral. As sete diretivas `limit_req` ficam no mesmo server,
sem sobrescrita nas locations: adicionar uma diretiva numa location futura
exige repetir todos os limites aplicáveis, conforme a
[regra de herança do Nginx](https://nginx.org/en/docs/http/ngx_http_limit_req_module.html#limit_req).

Há também 10 conexões simultâneas por IP (excesso: 429). O Nginx contabiliza
requisições em processamento após ler os headers, não sockets keep-alive ociosos.
Corpos acima de 64 KiB recebem 413 apenas neste host; o global permanece 10 MiB.
Timeouts, cabeçalhos e o proxy dinâmico permanecem iguais. Sem reescrita de URI
ou método: caminho e query originais seguem para `tesouraria-api:8080`.

A identidade é `$binary_remote_addr`, proveniente da conexão TCP. Não há
`real_ip_header`; X-Forwarded-For e X-Real-IP do cliente são substituídos e
Forwarded é removido antes do upstream. Usuários atrás de NAT compartilham
taxas, bursts e conexões, podendo receber 429 coletivamente. Docker ou um proxy
intermediário também pode fazer vários clientes aparecerem como um único IP.
Reavaliar com métricas antes de produção; limites não substituem controles da API.

Neste virtual host o access log contém IP, método, status, tempos e resultado
dos limitadores, sem URL, query, headers ou corpo. O error log do host vai para
`/dev/null`, pois mensagens nativas podem incluir request line e URL do upstream.
Isso reduz diagnóstico de falhas; usar status/tempos do access log e saúde do
backend. Logs do default e da aplicação não são modificados. Não colocar
segredos em URLs. Não ativar debug logging neste host.

### Evidência local e repetição segura

Validados em container descartável com os mounts reais, UID/GID 101, rootfs
read-only, tmpfs, capabilities removidas e nenhuma porta publicada:

- `docker compose config --quiet` e `nginx -t`: sucesso.
- Seis rotas: GETs sem credenciais produziram 405, 405, 429 em cada rota;
  variação dos três headers de IP não evitou rejeição.
- Geral: 12 pedidos sequenciais rápidos produziram seis 404 e seis 429.
- Outro host: 12 respostas 404; `/healthz`: 200 mesmo após exceder limites.
- 11 conexões com corpo pendente: a 11ª recebeu 429; sockets fechados em seguida.
- Corpo de 65537 bytes: 413. Logs omitiram query e Authorization fictícios.
- GET, HEAD, OPTIONS, PUT, PATCH, DELETE e POST em rota inexistente com
  Authorization fictício chegaram ao upstream, retornando 401. Isso verifica
  encaminhamento, mas não prova a interpretação do URI/método dentro da API;
  não foram exercitadas operações autenticadas ou contas reais.
- Gateway ativo em `127.0.0.1:8088`: saúde 200 e GET login 405. Os novos
  limites foram testados somente no descartável, sem reload do ativo.

`python3 tests/tesouraria-http.py http://IP_DO_DESCARTAVEL:8080` repete os
checks de taxa com poucas requisições. Usar somente container isolado de tráfego
legítimo, conectado à `proxy_net`, sem publicar portas. Nunca apontar esse teste
para o gateway em uso: ele consome deliberadamente saldo por IP. O teste não
mede vazão sustentada, exaustão das zonas ou comportamento de usuários reais.

### Aplicação manual e rollback

Nenhum reload/deploy foi realizado neste incremento. Após revisar os arquivos,
validar novamente com o container descartável da seção de validação isolada e
com a mesma imagem do serviço. Antes do reload, preservar a configuração
anterior (o exemplo pressupõe que HEAD é a versão anterior revisada):

```sh
rollback_dir=$(mktemp -d /tmp/infra-gateway-rollback.XXXXXX)
git show HEAD:nginx/conf.d/10-tesouraria.conf > "$rollback_dir/10-tesouraria.conf"
docker compose config --quiet
docker compose exec -T gateway nginx -t && docker compose exec -T gateway nginx -s reload
curl -fsS http://127.0.0.1:8088/healthz
curl -i -H 'Host: tesouraria.localhost' http://127.0.0.1:8088/api/v1/auth/login
```

O reload é gracioso, sem recriar serviço. Em caso de regressão, na mesma sessão:

```sh
cp "$rollback_dir/10-tesouraria.conf" nginx/conf.d/10-tesouraria.conf
mv nginx/conf.d/05-tesouraria-limits.conf "$rollback_dir/05-tesouraria-limits.conf"
docker compose exec -T gateway nginx -t && docker compose exec -T gateway nginx -s reload
curl -fsS http://127.0.0.1:8088/healthz
```

Preservar o diretório de rollback até concluir a observação. Nenhum desses
procedimentos exige `down`, remoção de rede/volume ou novas portas.
