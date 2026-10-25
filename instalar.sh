
#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================================
# INSTALADOR AUTOMATICO DO SITE
# Ubuntu 22.04 / 24.04
# Nginx + Python + PHP + SSL Let's Encrypt
# ==========================================================

ZIP_URL="https://www.dropbox.com/scl/fi/6b7b0iyky4bffle14xo49/script_completo.zip?rlkey=2t3a3c9z41xz2138ru1pjipjy&st=a1melg5s&dl=1"

TMP_DIR="/tmp/instalador-site"
ZIP_FILE="$TMP_DIR/site.zip"
EXTRACT_DIR="$TMP_DIR/extracao"
PUBLISH_DIR="$TMP_DIR/publicacao"

INSTALL_DIR="/var/www/painel"
NGINX_SITE="/etc/nginx/sites-available/painel"
NGINX_LINK="/etc/nginx/sites-enabled/painel"

DOMAIN=""
PHP_VERSION=""
PHP_SOCKET=""
BACKUP_DIR=""
NGINX_BACKUP=""

# ----------------------------------------------------------
# CORES
# ----------------------------------------------------------

VERDE='\033[0;32m'
AMARELO='\033[1;33m'
VERMELHO='\033[0;31m'
AZUL='\033[0;34m'
RESET='\033[0m'

info() {
    echo -e "${AZUL}[INFO]${RESET} $*"
}

sucesso() {
    echo -e "${VERDE}[OK]${RESET} $*"
}

aviso() {
    echo -e "${AMARELO}[AVISO]${RESET} $*"
}

erro() {
    echo -e "${VERMELHO}[ERRO]${RESET} $*" >&2
}

pausar() {
    read -r -p "Pressione ENTER para continuar..."
}

# ----------------------------------------------------------
# TRATAMENTO DE ERROS
# ----------------------------------------------------------

trap 'codigo=$?; erro "O instalador parou na linha $LINENO (codigo $codigo)."; erro "Execute novamente o script para tentar continuar."; exit "$codigo"' ERR

# ----------------------------------------------------------
# CABECALHO
# ----------------------------------------------------------

clear 2>/dev/null || true

echo "=========================================================="
echo "          INSTALADOR AUTOMATICO DO SITE"
echo "=========================================================="
echo
echo "Instalacao:"
echo "  Site:       $INSTALL_DIR"
echo "  Arquivo ZIP: $ZIP_FILE"
echo "  Nginx:      $NGINX_SITE"
echo
echo "O instalador pode ser executado novamente."
echo

# ----------------------------------------------------------
# 1. VERIFICAR ROOT E SISTEMA
# ----------------------------------------------------------

echo "[1/8] Verificando o sistema..."

if [[ "${EUID}" -ne 0 ]]; then
    erro "Execute como root:"
    echo "sudo bash instalar.sh"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    erro "Nao foi possivel identificar o sistema operacional."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    erro "Este instalador foi preparado para Ubuntu 22.04 ou 24.04."
    erro "Sistema detectado: ${PRETTY_NAME:-desconhecido}"
    exit 1
fi

if [[ "${VERSION_ID:-}" != "22.04" && "${VERSION_ID:-}" != "24.04" ]]; then
    erro "Versao nao suportada: ${VERSION_ID:-desconhecida}"
    exit 1
fi

sucesso "Sistema identificado: ${PRETTY_NAME}"

# ----------------------------------------------------------
# 2. PREPARAR PASTAS E INSTALAR DEPENDENCIAS
# ----------------------------------------------------------

echo
echo "[2/8] Preparando pastas e dependencias..."

mkdir -p "$TMP_DIR"
mkdir -p /var/backups/instalador-site

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    unzip \
    zip \
    nginx \
    python3 \
    python3-pip \
    python3-venv \
    php-fpm \
    php-cli \
    php-common \
    php-mysql \
    php-curl \
    php-gd \
    php-mbstring \
    php-xml \
    php-zip \
    php-intl \
    php-bcmath \
    certbot \
    python3-certbot-nginx

sucesso "Dependencias instaladas."

# ----------------------------------------------------------
# 3. REUTILIZAR OU BAIXAR O ZIP
# ----------------------------------------------------------

echo
echo "[3/8] Verificando o arquivo ZIP..."

REUTILIZAR_ZIP=0

if [[ -s "$ZIP_FILE" ]] && unzip -tq "$ZIP_FILE" >/dev/null 2>&1; then
    echo
    sucesso "Foi encontrado um ZIP valido:"
    echo "$ZIP_FILE"
    echo
    echo "Escolha uma opcao:"
    echo "  1) Reutilizar o ZIP existente"
    echo "  2) Baixar novamente"
    echo "  3) Cancelar a instalacao"
    echo

    while true; do
        read -r -p "Opcao [1/2/3]: " OPCAO

        case "$OPCAO" in
            1)
                REUTILIZAR_ZIP=1
                info "O arquivo existente sera reutilizado."
                break
                ;;
            2)
                REUTILIZAR_ZIP=0
                info "Um novo download sera realizado."
                break
                ;;
            3)
                echo "Instalacao cancelada. Nenhum ZIP foi removido."
                exit 0
                ;;
            *)
                aviso "Opcao invalida. Digite 1, 2 ou 3."
                ;;
        esac
    done
else
    aviso "Nenhum ZIP valido encontrado."
    info "Sera necessario baixar o arquivo."
fi

if [[ "$REUTILIZAR_ZIP" -eq 0 ]]; then
    ARQUIVO_NOVO="${ZIP_FILE}.download"

    rm -f "$ARQUIVO_NOVO"

    info "Baixando o site..."

    curl \
        --fail \
        --location \
        --show-error \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 30 \
        --output "$ARQUIVO_NOVO" \
        "$ZIP_URL"

    if [[ ! -s "$ARQUIVO_NOVO" ]]; then
        rm -f "$ARQUIVO_NOVO"
        erro "O download terminou sem gerar um arquivo valido."
        exit 1
    fi

    if ! unzip -tq "$ARQUIVO_NOVO" >/dev/null 2>&1; then
        rm -f "$ARQUIVO_NOVO"
        erro "O arquivo recebido nao e um ZIP valido."
        erro "O ZIP anterior, se existente, foi preservado."
        exit 1
    fi

    # O ZIP anterior so e substituido depois da validacao.
    mv -f "$ARQUIVO_NOVO" "$ZIP_FILE"

    sucesso "Download concluido e ZIP validado."
else
    sucesso "Usando o ZIP que ja estava baixado."
fi

# ----------------------------------------------------------
# 4. EXTRAIR E LOCALIZAR O SITE
# ----------------------------------------------------------

echo
echo "[4/8] Extraindo e verificando os arquivos..."

rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

unzip -oq "$ZIP_FILE" -d "$EXTRACT_DIR"

# Procura dominio.txt em qualquer subpasta.
mapfile -d '' ARQUIVOS_DOMINIO < <(
    find "$EXTRACT_DIR" -type f -iname "dominio.txt" -print0
)

if [[ "${#ARQUIVOS_DOMINIO[@]}" -eq 0 ]]; then
    erro "O ZIP nao contem um arquivo dominio.txt."
    erro "Confira o conteudo do ZIP e execute novamente."
    exit 1
fi

if [[ "${#ARQUIVOS_DOMINIO[@]}" -gt 1 ]]; then
    erro "Foram encontrados varios arquivos dominio.txt."
    erro "Deixe apenas um dominio.txt dentro do ZIP."
    printf 'Encontrado: %s\n' "${ARQUIVOS_DOMINIO[@]}"
    exit 1
fi

PASTA_SITE="$(dirname "${ARQUIVOS_DOMINIO[0]}")"

if [[ ! -f "$PASTA_SITE/index.php" &&
      ! -f "$PASTA_SITE/index.html" &&
      ! -f "$PASTA_SITE/index.htm" ]]; then
    erro "A pasta que contem dominio.txt nao possui index.php, index.html ou index.htm."
    erro "Pasta identificada: $PASTA_SITE"
    erro "Verifique a estrutura do arquivo ZIP."
    exit 1
fi

sucesso "Pasta principal do site localizada:"
echo "$PASTA_SITE"

# ----------------------------------------------------------
# 5. SOLICITAR E VALIDAR O DOMINIO
# ----------------------------------------------------------

echo
echo "[5/8] Configuracao do dominio..."
echo
echo "Digite o dominio que vai acessar o painel."
echo "Exemplo: painel.exemplo.com"
echo "Use somente letras e pontos, sem https:// ou barras."
echo

while true; do
    read -r -p "Dominio do painel: " DOMAIN

    DOMAIN="${DOMAIN,,}"

    if [[ -z "$DOMAIN" ]]; then
        aviso "O dominio nao pode ficar vazio."
        continue
    fi

    if [[ ! "$DOMAIN" =~ ^[a-z]+(\.[a-z]+)+$ ]]; then
        aviso "Dominio invalido. Use somente letras e pontos."
        continue
    fi

    break
done

sucesso "Dominio escolhido: $DOMAIN"

# ----------------------------------------------------------
# 6. PUBLICAR SITE E CONFIGURAR NGINX/PHP
# ----------------------------------------------------------

echo
echo "[6/8] Publicando o site e configurando Nginx/PHP..."

# Detectar a versao instalada do PHP-FPM.
PHP_VERSION="$(
    php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null
)"

if [[ -z "$PHP_VERSION" ]]; then
    erro "Nao foi possivel detectar a versao do PHP."
    exit 1
fi

PHP_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"

if [[ ! -S "$PHP_SOCKET" ]]; then
    aviso "O socket PHP-FPM ainda nao existe. Tentando iniciar o servico..."
    systemctl enable "php${PHP_VERSION}-fpm"
    systemctl restart "php${PHP_VERSION}-fpm"
fi

if [[ ! -S "$PHP_SOCKET" ]]; then
    erro "Socket PHP-FPM nao encontrado: $PHP_SOCKET"
    exit 1
fi

# Garantir que a configuracao principal do Nginx exista.
if [[ ! -f /etc/nginx/nginx.conf ]]; then
    aviso "nginx.conf nao encontrado. Criando configuracao principal."

    mkdir -p /etc/nginx/conf.d
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    mkdir -p /etc/nginx/snippets

    cat > /etc/nginx/nginx.conf <<'NGINX_MAIN'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINX_MAIN
fi

# Se o snippet PHP padrao nao existir, cria uma versao compativel.
if [[ ! -f /etc/nginx/snippets/fastcgi-php.conf ]]; then
    cat > /etc/nginx/snippets/fastcgi-php.conf <<'FASTCGI_PHP'
fastcgi_split_path_info ^(.+\.php)(/.+)$;
try_files $fastcgi_script_name =404;
set $path_info $fastcgi_path_info;
fastcgi_param PATH_INFO $path_info;
fastcgi_index index.php;
include fastcgi.conf;
FASTCGI_PHP
fi

# Fazer backup do site anterior, caso exista.
if [[ -d "$INSTALL_DIR" ]]; then
    BACKUP_DIR="/var/backups/instalador-site/painel-$(date +%Y%m%d-%H%M%S)"
    info "Fazendo backup do site existente em:"
    echo "$BACKUP_DIR"
    cp -a "$INSTALL_DIR" "$BACKUP_DIR"
fi

# Preparar nova publicacao sem modificar o ZIP original.
rm -rf "$PUBLISH_DIR"
mkdir -p "$PUBLISH_DIR"

cp -a "$PASTA_SITE"/. "$PUBLISH_DIR"/

# Criar pasta temporaria e garantir permissao de leitura.
chown -R www-data:www-data "$PUBLISH_DIR"
find "$PUBLISH_DIR" -type d -exec chmod 755 {} \;
find "$PUBLISH_DIR" -type f -exec chmod 644 {} \;

# Guardar a configuracao anterior do site Nginx, se existir.
if [[ -f "$NGINX_SITE" ]]; then
    NGINX_BACKUP="/var/backups/instalador-site/painel-nginx-$(date +%Y%m%d-%H%M%S).conf"
    cp -a "$NGINX_SITE" "$NGINX_BACKUP"
fi

# Desativar o site padrao para evitar conflito.
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
fi

# Preparar publicacao do novo site.
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
fi

mv "$PUBLISH_DIR" "$INSTALL_DIR"
chown -R www-data:www-data "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
find "$INSTALL_DIR" -type f -exec chmod 644 {} \;

# Configuracao do host virtual.
cat > "$NGINX_SITE" <<NGINX_SITE_CONF
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN;

    root $INSTALL_DIR;
    index index.php index.html index.htm;

    charset utf-8;
    server_tokens off;

    access_log /var/log/nginx/painel-access.log;
    error_log /var/log/nginx/painel-error.log;

    client_max_body_size 32M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINX_SITE_CONF

ln -sfn "$NGINX_SITE" "$NGINX_LINK"

# Ativar servicos e testar a configuracao.
systemctl enable nginx
systemctl enable "php${PHP_VERSION}-fpm"

systemctl restart "php${PHP_VERSION}-fpm"

if ! nginx -t; then
    erro "A configuracao do Nginx esta invalida."

    if [[ -n "$NGINX_BACKUP" && -f "$NGINX_BACKUP" ]]; then
        cp -a "$NGINX_BACKUP" "$NGINX_SITE"
        nginx -t && systemctl reload nginx || true
    fi

    erro "O ZIP e o backup do site foram preservados."
    exit 1
fi

systemctl restart nginx

sucesso "Site publicado e Nginx/PHP configurados."

# ----------------------------------------------------------
# 7. CONFIGURAR SSL LET'S ENCRYPT
# ----------------------------------------------------------

echo
echo "[7/8] Verificando o dominio para configurar SSL..."

IP_PUBLICO=""

IP_PUBLICO="$(curl -4 -fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)"

if [[ -n "$IP_PUBLICO" ]]; then
    info "IP publico detectado: $IP_PUBLICO"
else
    aviso "Nao foi possivel detectar o IP publico automaticamente."
fi

IP_DOMINIO="$(
    getent ahostsv4 "$DOMAIN" 2>/dev/null |
    awk '{print $1}' |
    sort -u |
    head -n 1 || true
)"

if [[ -z "$IP_DOMINIO" ]]; then
    aviso "O dominio $DOMAIN ainda nao resolveu para um endereco IPv4."
    aviso "O site foi configurado, mas o SSL sera ignorado nesta execucao."
    aviso "Aponte o registro DNS A para o IP publico da VPS."
elif [[ -n "$IP_PUBLICO" && "$IP_DOMINIO" != "$IP_PUBLICO" ]]; then
    aviso "O dominio resolve para $IP_DOMINIO, mas a VPS tem IP $IP_PUBLICO."
    aviso "Confira o DNS antes de solicitar o certificado."
else
    echo
    echo "O dominio foi localizado no DNS."
    echo "Para emitir o SSL, a porta 80 e a porta 443 precisam estar acessiveis."
    echo

    read -r -p "E-mail para o Let's Encrypt (ENTER para pular o SSL): " EMAIL_SSL

    if [[ -n "$EMAIL_SSL" ]]; then
        if [[ ! "$EMAIL_SSL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
            aviso "Formato de e-mail invalido. O SSL sera ignorado."
        else
            info "Solicitando certificado SSL..."

            if certbot --nginx \
                --non-interactive \
                --agree-tos \
                --redirect \
                --email "$EMAIL_SSL" \
                -d "$DOMAIN"; then

                sucesso "Certificado SSL configurado."
                systemctl enable certbot.timer 2>/dev/null || true
                systemctl start certbot.timer 2>/dev/null || true

                if certbot renew --dry-run; then
                    sucesso "Teste de renovacao do SSL concluido."
                else
                    aviso "O teste de renovacao falhou. Confira a configuracao do Certbot."
                fi
            else
                aviso "O Certbot nao conseguiu emitir o certificado."
                aviso "Confira DNS, portas 80/443, firewall e tente novamente:"
                echo "certbot --nginx -d $DOMAIN"
            fi
        fi
    else
        aviso "SSL ignorado por escolha do usuario."
    fi
fi

# ----------------------------------------------------------
# 8. FINALIZACAO
# ----------------------------------------------------------

echo
echo "[8/8] Verificacao final..."

if nginx -t; then
    systemctl reload nginx
    sucesso "Nginx esta com a configuracao valida."
else
    erro "O teste final do Nginx falhou. Verifique os logs."
fi

echo
echo "=========================================================="
echo "             INSTALACAO FINALIZADA"
echo "=========================================================="
echo
echo "Dominio:        $DOMAIN"
echo "Pasta do site:  $INSTALL_DIR"
echo "Arquivo ZIP:    $ZIP_FILE"
echo "Nginx:          $NGINX_SITE"
echo "PHP:            $PHP_VERSION"
echo
echo "Acesso HTTP:"
echo "http://$DOMAIN"
echo
echo "Acesso HTTPS, se o SSL foi emitido:"
echo "https://$DOMAIN"
echo

if [[ -n "$BACKUP_DIR" ]]; then
    echo "Backup anterior do site:"
    echo "$BACKUP_DIR"
    echo
fi

if [[ -n "$NGINX_BACKUP" ]]; then
    echo "Backup anterior da configuracao Nginx:"
    echo "$NGINX_BACKUP"
    echo
fi

echo "Para executar novamente:"
echo "bash instalar.sh"
echo
echo "O ZIP valido sera preservado e podera ser reutilizado."
echo "=========================================================="
