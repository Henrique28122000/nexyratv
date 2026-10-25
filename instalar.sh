
#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================================
# INSTALADOR AUTOMATICO
# Ubuntu 22.04 / 24.04
# Nginx + PHP-FPM + SQLite + SSL Let's Encrypt
# ==========================================================

ZIP_URL="https://www.dropbox.com/scl/fi/6b7b0iyky4bffle14xo49/script_completo.zip?rlkey=2t3a3c9z41xz2138ru1pjipjy&st=a1melg5s&dl=1"

TMP_DIR="/tmp/instalador-site"
ZIP_FILE="$TMP_DIR/site.zip"
EXTRACT_DIR="$TMP_DIR/extracao"
PUBLISH_DIR="$TMP_DIR/publicacao"

INSTALL_DIR="/var/www/painel"
NGINX_SITE="/etc/nginx/sites-available/painel"
NGINX_LINK="/etc/nginx/sites-enabled/painel"

BACKUP_ROOT="/var/backups/instalador-site"
PHP_VERSION=""
PHP_SOCKET=""
DOMAIN=""
BACKUP_DIR=""
NGINX_BACKUP=""

# ----------------------------------------------------------
# CORES E FUNCOES
# ----------------------------------------------------------

VERDE='\033[0;32m'
AMARELO='\033[1;33m'
VERMELHO='\033[0;31m'
AZUL='\033[0;34m'
RESET='\033[0m'

info()    { echo -e "${AZUL}[INFO]${RESET} $*"; }
sucesso() { echo -e "${VERDE}[OK]${RESET} $*"; }
aviso()   { echo -e "${AMARELO}[AVISO]${RESET} $*"; }
erro()    { echo -e "${VERMELHO}[ERRO]${RESET} $*" >&2; }

trap 'rc=$?; erro "Falha na linha $LINENO (codigo $rc)."; erro "Confira as mensagens acima antes de executar novamente."; exit "$rc"' ERR

# ----------------------------------------------------------
# 1. VERIFICAR SISTEMA
# ----------------------------------------------------------

echo
echo "=========================================================="
echo "       INSTALADOR PHP + SQLITE + NGINX"
echo "=========================================================="
echo
echo "Diretorio do site: $INSTALL_DIR"
echo "Arquivo ZIP:      $ZIP_FILE"
echo

if [[ "$EUID" -ne 0 ]]; then
    erro "Execute como root: sudo bash instalar.sh"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    erro "Arquivo /etc/os-release nao encontrado."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ||
      ( "${VERSION_ID:-}" != "22.04" && "${VERSION_ID:-}" != "24.04" ) ]]; then
    erro "Este instalador aceita Ubuntu 22.04 ou 24.04."
    erro "Sistema detectado: ${PRETTY_NAME:-desconhecido}"
    exit 1
fi

sucesso "Sistema: $PRETTY_NAME"

mkdir -p "$TMP_DIR" "$BACKUP_ROOT"

# ----------------------------------------------------------
# 2. INSTALAR PHP, SQLITE, NGINX E CERTBOT
# ----------------------------------------------------------

echo
echo "[2/8] Instalando dependencias..."

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
    php-sqlite3 \
    php-curl \
    php-gd \
    php-mbstring \
    php-xml \
    php-zip \
    php-intl \
    php-bcmath \
    certbot \
    python3-certbot-nginx

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"

sucesso "PHP instalado: $PHP_VERSION"

# ----------------------------------------------------------
# 3. VERIFICAR SQLITE NO PHP
# ----------------------------------------------------------

echo
echo "[3/8] Verificando suporte ao SQLite..."

if ! php -r '
    if (!extension_loaded("pdo_sqlite")) {
        fwrite(STDERR, "Extensao pdo_sqlite nao carregada.\n");
        exit(1);
    }
    if (!extension_loaded("sqlite3")) {
        fwrite(STDERR, "Extensao sqlite3 nao carregada.\n");
        exit(1);
    }
    $pdo = new PDO("sqlite::memory:");
    $pdo->query("SELECT 1");
    echo "PDO SQLite e SQLite3 funcionando.\n";
'; then
    erro "O PHP CLI nao conseguiu inicializar o SQLite."
    erro "Verifique a instalacao do pacote php-sqlite3."
    exit 1
fi

# Confere se as configuracoes do FPM incluem os modulos.
FPM_CONF_DIR="/etc/php/${PHP_VERSION}/fpm/conf.d"

if [[ ! -e "$FPM_CONF_DIR/20-pdo_sqlite.ini" ||
      ! -e "$FPM_CONF_DIR/20-sqlite3.ini" ]]; then
    aviso "Os arquivos de configuracao SQLite do PHP-FPM nao foram localizados."
    aviso "Tentando habilitar os modulos no PHP-FPM."

    phpenmod -v "$PHP_VERSION" -s fpm pdo_sqlite sqlite3 || true
fi

systemctl enable "php${PHP_VERSION}-fpm"
systemctl restart "php${PHP_VERSION}-fpm"

if [[ ! -S "$PHP_SOCKET" ]]; then
    erro "Socket PHP-FPM nao encontrado: $PHP_SOCKET"
    exit 1
fi

sucesso "PHP-FPM iniciado. O teste do SQLite no CLI passou."

# ----------------------------------------------------------
# 4. REUTILIZAR OU BAIXAR O ZIP
# ----------------------------------------------------------

echo
echo "[4/8] Verificando o ZIP..."

REUTILIZAR_ZIP=0

if [[ -s "$ZIP_FILE" ]] &&
   unzip -tq "$ZIP_FILE" >/dev/null 2>&1; then

    echo
    sucesso "ZIP valido encontrado: $ZIP_FILE"
    echo "1) Reutilizar o ZIP existente"
    echo "2) Baixar novamente"
    echo "3) Cancelar"
    echo

    while true; do
        read -r -p "Escolha [1/2/3]: " OPCAO

        case "$OPCAO" in
            1)
                REUTILIZAR_ZIP=1
                break
                ;;
            2)
                REUTILIZAR_ZIP=0
                break
                ;;
            3)
                echo "Instalacao cancelada. ZIP preservado."
                exit 0
                ;;
            *)
                aviso "Escolha 1, 2 ou 3."
                ;;
        esac
    done
else
    aviso "Nenhum ZIP valido encontrado."
fi

if [[ "$REUTILIZAR_ZIP" -eq 0 ]]; then
    ARQUIVO_NOVO="${ZIP_FILE}.download"
    rm -f "$ARQUIVO_NOVO"

    info "Baixando o arquivo do site..."

    curl \
        --fail \
        --location \
        --show-error \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 30 \
        --output "$ARQUIVO_NOVO" \
        "$ZIP_URL"

    if [[ ! -s "$ARQUIVO_NOVO" ]] ||
       ! unzip -tq "$ARQUIVO_NOVO" >/dev/null 2>&1; then
        rm -f "$ARQUIVO_NOVO"
        erro "Download invalido. O ZIP anterior foi preservado."
        exit 1
    fi

    mv -f "$ARQUIVO_NOVO" "$ZIP_FILE"
    sucesso "Download concluido e ZIP validado."
else
    sucesso "Reutilizando o ZIP existente."
fi

# ----------------------------------------------------------
# 5. EXTRAIR, LOCALIZAR O SITE E SOLICITAR DOMINIO
# ----------------------------------------------------------

echo
echo "[5/8] Extraindo e verificando os arquivos..."

rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

unzip -oq "$ZIP_FILE" -d "$EXTRACT_DIR"

mapfile -d '' ARQUIVOS_DOMINIO < <(
    find "$EXTRACT_DIR" -type f -iname "dominio.txt" -print0
)

if [[ "${#ARQUIVOS_DOMINIO[@]}" -ne 1 ]]; then
    erro "O ZIP precisa conter exatamente um arquivo dominio.txt."
    erro "Quantidade encontrada: ${#ARQUIVOS_DOMINIO[@]}"
    exit 1
fi

PASTA_SITE="$(dirname "${ARQUIVOS_DOMINIO[0]}")"

if [[ ! -f "$PASTA_SITE/index.php" &&
      ! -f "$PASTA_SITE/index.html" &&
      ! -f "$PASTA_SITE/index.htm" ]]; then
    erro "A pasta do dominio.txt nao contem index.php, index.html ou index.htm."
    erro "Pasta: $PASTA_SITE"
    exit 1
fi

sucesso "Arquivos do site localizados."

echo
echo "Digite o dominio do painel."
echo "Exemplo: painel.exemplo.com"
echo "Somente letras e pontos."
echo

while true; do
    read -r -p "Dominio: " DOMAIN
    DOMAIN="${DOMAIN,,}"

    if [[ "$DOMAIN" =~ ^[a-z]+(\.[a-z]+)+$ ]]; then
        break
    fi

    aviso "Dominio invalido. Tente novamente."
done

sucesso "Dominio: $DOMAIN"

# ----------------------------------------------------------
# 6. PREPARAR SITE, BACKUP E BANCO SQLITE
# ----------------------------------------------------------

echo
echo "[6/8] Preparando a publicacao e o SQLite..."

mkdir -p /etc/nginx/conf.d \
         /etc/nginx/sites-available \
         /etc/nginx/sites-enabled \
         /etc/nginx/snippets

# Se a configuracao principal do Nginx estiver ausente,
# cria uma configuracao minima.
if [[ ! -f /etc/nginx/nginx.conf ]]; then
    aviso "nginx.conf nao encontrado. Criando configuracao."

    cat > /etc/nginx/nginx.conf <<'NGINX_MAIN'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINX_MAIN
fi

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

# Backup completo do site anterior.
if [[ -d "$INSTALL_DIR" ]]; then
    BACKUP_DIR="$BACKUP_ROOT/painel-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    info "Fazendo backup completo do site anterior..."
    cp -a "$INSTALL_DIR"/. "$BACKUP_DIR"/

    sucesso "Backup criado: $BACKUP_DIR"
fi

# Backup da configuracao Nginx.
if [[ -f "$NGINX_SITE" ]]; then
    NGINX_BACKUP="$BACKUP_ROOT/painel-nginx-$(date +%Y%m%d-%H%M%S).conf"
    cp -a "$NGINX_SITE" "$NGINX_BACKUP"
fi

# Preparar nova publicacao sem alterar o ZIP original.
rm -rf "$PUBLISH_DIR"
mkdir -p "$PUBLISH_DIR"

cp -a "$PASTA_SITE"/. "$PUBLISH_DIR"/

# Preservar bancos SQLite antigos, se existirem no site anterior.
# O banco anterior tem prioridade sobre uma copia do ZIP.
if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    while IFS= read -r -d '' BANCO; do
        RELATIVO="${BANCO#"$BACKUP_DIR"/}"
        DESTINO="$PUBLISH_DIR/$RELATIVO"

        mkdir -p "$(dirname "$DESTINO")"
        cp -a "$BANCO" "$DESTINO"

        # Copiar tambem os arquivos auxiliares SQLite encontrados.
        for SUFIXO in "-wal" "-shm" "-journal"; do
            if [[ -f "${BANCO}${SUFIXO}" ]]; then
                cp -a "${BANCO}${SUFIXO}" "${DESTINO}${SUFIXO}"
            fi
        done

        info "Banco SQLite preservado: $RELATIVO"
    done < <(
        find "$BACKUP_DIR" -type f \
            \( -iname "*.sqlite" -o -iname "*.sqlite3" -o -iname "*.db" \) \
            -print0
    )
fi

# Publicar sem apagar o diretorio antigo antes de existir backup.
# O site antigo permanece disponivel no backup caso haja falha.
if [[ -d "$INSTALL_DIR" ]]; then
    mv "$INSTALL_DIR" "${INSTALL_DIR}.anterior-$(date +%Y%m%d-%H%M%S)"
fi

mv "$PUBLISH_DIR" "$INSTALL_DIR"

# PHP precisa conseguir ler o site e escrever no banco SQLite.
# A permissao de escrita no diretorio e importante para arquivos WAL.
chown -R www-data:www-data "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
find "$INSTALL_DIR" -type f -exec chmod 644 {} \;

# Confirmar que o banco e as extensoes estao disponiveis.
echo
info "Bancos SQLite encontrados no site publicado:"

find "$INSTALL_DIR" -type f \
    \( -iname "*.sqlite" -o -iname "*.sqlite3" -o -iname "*.db" \) \
    -print || true

# ----------------------------------------------------------
# CONFIGURAR LOG DE ERROS PHP
# ----------------------------------------------------------

PHP_LOG="/var/log/php-errors.log"

touch "$PHP_LOG"
chown www-data:adm "$PHP_LOG" 2>/dev/null || chown www-data:www-data "$PHP_LOG"
chmod 640 "$PHP_LOG"

FPM_PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"

if [[ -f "$FPM_PHP_INI" ]]; then
    # Habilita o log sem expor erros PHP aos visitantes.
    sed -i \
        -e 's/^[;[:space:]]*log_errors[[:space:]]*=.*/log_errors = On/' \
        -e 's/^[;[:space:]]*display_errors[[:space:]]*=.*/display_errors = Off/' \
        -e 's/^[;[:space:]]*display_startup_errors[[:space:]]*=.*/display_startup_errors = Off/' \
        "$FPM_PHP_INI"

    if ! grep -Eq '^[[:space:]]*error_log[[:space:]]*=' "$FPM_PHP_INI"; then
        printf '\nerror_log = %s\n' "$PHP_LOG" >> "$FPM_PHP_INI"
    else
        sed -i \
            "s|^[;[:space:]]*error_log[[:space:]]*=.*|error_log = $PHP_LOG|" \
            "$FPM_PHP_INI"
    fi
fi

# ----------------------------------------------------------
# CONFIGURAR VIRTUAL HOST NGINX
# ----------------------------------------------------------

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

if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
fi

systemctl enable nginx
systemctl enable "php${PHP_VERSION}-fpm"

systemctl restart "php${PHP_VERSION}-fpm"

if ! nginx -t; then
    erro "Configuracao do Nginx invalida."
    erro "Configuracao anterior, se existente: ${NGINX_BACKUP:-nenhuma}"
    exit 1
fi

systemctl restart nginx

sucesso "Site publicado e Nginx/PHP-FPM configurados."

# ----------------------------------------------------------
# 7. SSL LET'S ENCRYPT
# ----------------------------------------------------------

echo
echo "[7/8] Verificando DNS para SSL..."

IP_PUBLICO="$(curl -4 -fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)"

IP_DOMINIO="$(
    getent ahostsv4 "$DOMAIN" 2>/dev/null |
    awk '{print $1}' |
    sort -u |
    head -n 1 || true
)"

if [[ -z "$IP_DOMINIO" ]]; then
    aviso "Dominio ainda nao resolve para IPv4."
    aviso "Configure o DNS A antes de emitir o SSL."
elif [[ -n "$IP_PUBLICO" && "$IP_DOMINIO" != "$IP_PUBLICO" ]]; then
    aviso "IP do dominio: $IP_DOMINIO"
    aviso "IP publico da VPS: $IP_PUBLICO"
    aviso "Confira o DNS antes de emitir o certificado."
else
    echo
    echo "Dominio encontrado no DNS."
    echo "As portas TCP 80 e 443 precisam estar acessiveis."
    read -r -p "E-mail para SSL (ENTER para pular): " EMAIL_SSL

    if [[ -n "$EMAIL_SSL" ]]; then
        if [[ "$EMAIL_SSL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
            if certbot --nginx \
                --non-interactive \
                --agree-tos \
                --redirect \
                --email "$EMAIL_SSL" \
                -d "$DOMAIN"; then

                sucesso "Certificado SSL instalado."
                systemctl enable certbot.timer 2>/dev/null || true
                systemctl start certbot.timer 2>/dev/null || true

                certbot renew --dry-run ||
                    aviso "Teste de renovacao falhou; verifique o Certbot."
            else
                aviso "Nao foi possivel emitir o SSL nesta execucao."
                aviso "Tente depois: certbot --nginx -d $DOMAIN"
            fi
        else
            aviso "E-mail invalido. SSL ignorado."
        fi
    else
        aviso "SSL ignorado por escolha do usuario."
    fi
fi

# ----------------------------------------------------------
# 8. VERIFICACAO FINAL
# ----------------------------------------------------------

echo
echo "[8/8] Verificacao final..."

systemctl is-active --quiet nginx &&
    sucesso "Nginx ativo." ||
    aviso "Nginx nao esta ativo."

systemctl is-active --quiet "php${PHP_VERSION}-fpm" &&
    sucesso "PHP-FPM ativo." ||
    aviso "PHP-FPM nao esta ativo."

if php -r '
    $pdo = new PDO("sqlite::memory:");
    $pdo->query("SELECT 1");
    echo "SQLite OK\n";
'; then
    sucesso "SQLite validado no PHP CLI."
else
    aviso "Falha no teste SQLite."
fi

nginx -t

echo
echo "=========================================================="
echo "             INSTALACAO CONCLUIDA"
echo "=========================================================="
echo
echo "Dominio:          $DOMAIN"
echo "Diretorio:        $INSTALL_DIR"
echo "ZIP reutilizavel: $ZIP_FILE"
echo "PHP:              $PHP_VERSION"
echo "Socket PHP-FPM:   $PHP_SOCKET"
echo "Log PHP:          $PHP_LOG"
echo "Log Nginx:        /var/log/nginx/painel-error.log"
echo
echo "HTTP:  http://$DOMAIN"
echo "HTTPS: https://$DOMAIN (se SSL instalado)"
echo

if [[ -n "$BACKUP_DIR" ]]; then
    echo "Backup do site anterior:"
    echo "$BACKUP_DIR"
    echo
fi

if [[ -n "$NGINX_BACKUP" ]]; then
    echo "Backup da configuracao anterior:"
    echo "$NGINX_BACKUP"
    echo
fi

echo "Para ver erros PHP:"
echo "tail -f /var/log/php-errors.log"
echo
echo "Para ver erros Nginx:"
echo "tail -f /var/log/nginx/painel-error.log"
echo
echo "Para executar novamente:"
echo "bash instalar.sh"
echo "=========================================================="
