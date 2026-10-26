# Aplicações HTTP

Somente arquivos `*.conf` deste diretório são carregados. Use um arquivo por
aplicação, com `server_name` e alias de backend exclusivos na `proxy_net`.
O exemplo da Tesouraria preserva caminho e query string, sem prefixo adicional.

Bloquinho está reservado para uma próxima etapa: adicionar um arquivo
`20-bloquinho.conf` somente quando host, alias e porta interna forem definidos.
Outras aplicações seguem o mesmo padrão; não há rota curinga para backends.
Não use `container_name`; nomes de contêiner devem ser gerados pelo Compose.
