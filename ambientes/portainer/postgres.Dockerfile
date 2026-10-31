# PostgreSQL do Milebag para uma stack do Portainer, que não monta pastas da máquina: o script que cria a conta
# milebag_app e o banco (postgres/init) vai dentro da imagem e roda só na 1ª subida, com o volume vazio.
FROM postgres:16
COPY init/ /docker-entrypoint-initdb.d/
