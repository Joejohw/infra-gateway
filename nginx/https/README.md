# HTTPS futuro

Diretório reservado, não montado no contêiner e não incluído pelo Nginx.
Ainda não há configuração TLS, certificados, ACME ou publicação de porta 443.

Na etapa HTTPS, definir domínio e terminação TLS, criar configuração separada e
revisar portas e regras de entrada. Guardar certificados e chaves fora do Git,
montados somente para leitura; não colocar segredos neste diretório.
