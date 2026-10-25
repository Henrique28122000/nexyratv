
#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# INSTALADOR AUTOMATICO DO SITE
# Ubuntu 22.04 / 24.04
# NGINX + PHP + PYTHON + LET'S ENCRYPT
# ==========================================================

# ALTERE PARA O LINK DIRETO DO SEU ARQUIVO ZIP
ZIP_URL="https://SEU-DOMINIO.com/site.zip"

INSTALL_DIR="/var/www/painel"
TMP_DIR="/tmp/instalador-site"
ZIP_FILE="$TMP_DIR/site.zip"
NGINX_CONF="/etc/nginx/sites-available/painel"

trap 'echo ""; echo "[ERRO] Falha na linha $LINENO. Verifique a mensagem acima."; exit 1' ERR

if [[ $EUID -ne 0 ]]; then
    echo "Execute como root: sudo bash instalar.sh"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "Nao foi possivel identificar o sistema operacional."
    exit 1
fi

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "Este instalador foi preparado para Ubuntu."
    exit 1
fi

echo
echo "=========================================="
echo "       INSTALADOR AUTOMATICO DO SITE"
echo "=========================================="
echo

if [[ "$ZIP_URL" == *"SEU-DOMINIO.com"* ]]; then
    echo "ERRO: edite ZIP_URL no inicio do script."
    echo "Informe o link direto para baixar o ZIP."
    exit 1
fi

mkdir -p "$TMP_DIR"

echo "[1/8] Atualizando os pacotes..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    ca-certificates curl wget unzip \
    nginx python3 python3-pip python3-venv \
    php-fpm php-cli php-common \
    php-curl php-mbstring php-xml php-zip \
    php-mysql php-gd php-intl php-bcmath \
    certbot python3-certbot-nginx

echo
echo "[2/8] Baixando o site..."
curl -fL --retry 3 --connect-timeout 20 \
    "$ZIP_URL" -o "$ZIP_FILE"

if ! unzip -tq "$ZIP_FILE" >/dev/null; then
    echo "ERRO: o arquivo baixado nao e um ZIP valido."
    exit 1
fi

echo
echo "[3/8] Extraindo os arquivos..."

STAGE_DIR="$TMP_DIR/extracao"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

unzip -q "$ZIP_FILE" -d "$STAGE_DIR"

# Localiza dominio.txt dentro do conteudo extraido.
mapfile -t DOMAIN_FILES < <(
    find "$STAGE_DIR" -type f -name dominio.txt
)

if [[ ${#DOMAIN_FILES[@]} -ne 1 ]]; then
    echo "ERRO: era esperado exatamente um arquivo dominio.txt."
    echo "Arquivos encontrados: ${#DOMAIN_FILES[@]}"
    echo "Organize o ZIP e tente novamente."
    exit 1
fi

DOMAIN_FILE="${DOMAIN_FILES[0]}"
SITE_ROOT="$(dirname "$DOMAIN_FILE")"

if [[ ! -f "$SITE_ROOT/index.php" &&
      ! -f "$SITE_ROOT/index.html" &&
      ! -f "$SITE_ROOT/index.htm" ]]; then
    echo "AVISO: nao foi encontrado index.php, index.html ou index.htm"
    echo "na pasta de dominio.txt: $SITE_ROOT"
    echo "O site pode precisar de um ajuste no caminho de publicacao."
fi

echo
echo "[4/8] Solicitando o dominio do painel..."
echo "Use somente letras e pontos, por exemplo:"
echo "painel.exemplo.com"
echo

while true; do
    read -r -p "Dominio do painel: " DOMAIN
    DOMAIN="${DOMAIN,,}"

    if [[ ${#DOMAIN} -gt 253 ]]; then
        echo "Dominio muito longo."
        continue
    fi

    if [[ "$DOMAIN" =~ ^[a-z]+(\.[a-z]+)+$ ]]; then
        IFS='.' read -ra LABELS <<< "$DOMAIN"
        VALID=1

        for LABEL in "${LABELS[@]}"; do
            if [[ ${#LABEL} -gt 63 ]]; then
                VALID=0
            fi
        done

        if [[ "$VALID" -eq 1 ]]; then
            break
        fi
    fi

    echo "Dominio invalido. Digite somente letras e pontos."
done

echo
echo "[5/8] Publicando os arquivos..."

# Mantem uma copia do site anterior, caso exista.
if [[ -d "$INSTALL_DIR" ]]; then
    BACKUP_DIR="${INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
    echo "Backup do site anterior: $BACKUP_DIR"
    mv "$INSTALL_DIR" "$BACKUP_DIR"
fi

mkdir -p "$(dirname "$INSTALL_DIR")"
cp -a "$SITE_ROOT" "$INSTALL_DIR"

# Atualiza o dominio.txt sem alterar outros arquivos.
printf '%s\n' "$DOMAIN" > "$INSTALL_DIR/dominio.txt"

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"

if ! systemctl list-unit-files "$PHP_FPM_SERVICE.service" \
    --no-legend | grep -q "$PHP_FPM_SERVICE"; then
    echo "ERRO: servico PHP-FPM nao encontrado: $PHP_FPM_SERVICE"
    exit 1
fi

echo
echo "[6/8] Configurando Nginx e PHP-FPM..."

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN;

    root $INSTALL_DIR;
    index index.php index.html index.htm;

    server_tokens off;
    client_max_body_size 32M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

ln -sfn "$NGINX_CONF" /etc/nginx/sites-enabled/painel

# Desativa a configuracao padrao, se existir.
rm -f /etc/nginx/sites-enabled/default

chown -R www-data:www-data "$INSTALL_DIR"

systemctl enable nginx "$PHP_FPM_SERVICE"
systemctl restart "$PHP_FPM_SERVICE"

nginx -t
systemctl reload nginx

echo
echo "[7/8] Verificando DNS antes do SSL..."

PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)"
DOMAIN_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}' || true)"

if [[ -z "$PUBLIC_IP" ]]; then
    echo "Nao foi possivel identificar o IP publico da VPS."
    echo "O site foi instalado, mas o SSL nao foi solicitado."
elif [[ -z "$DOMAIN_IP" ]]; then
    echo "O dominio ainda nao resolve para um endereco IPv4."
    echo "Configure o DNS e execute novamente a etapa do SSL."
elif [[ "$DOMAIN_IP" != "$PUBLIC_IP" ]]; then
    echo "ATENCAO: o dominio nao aponta para o IP detectado da VPS."
    echo "IP da VPS: $PUBLIC_IP"
    echo "IP do dominio: $DOMAIN_IP"
    echo "Corrija o DNS antes de solicitar o SSL."
else
    echo
    echo "[8/8] Solicitando certificado Let's Encrypt..."

    read -r -p "E-mail para avisos de renovacao: " EMAIL

    if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        echo "E-mail invalido. O certificado nao sera solicitado."
    else
        certbot --nginx \
            --non-interactive \
            --agree-tos \
            --redirect \
            --email "$EMAIL" \
            -d "$DOMAIN"

        systemctl enable --now certbot.timer

        echo
        echo "Verificando a renovacao automatica..."
        certbot renew --dry-run
    fi
fi

echo
echo "=========================================="
echo "          INSTALACAO FINALIZADA"
echo "=========================================="
echo "Dominio:     $DOMAIN"
echo "Diretorio:   $INSTALL_DIR"
echo "Nginx:       $(systemctl is-active nginx)"
echo "PHP-FPM:     $(systemctl is-active "$PHP_FPM_SERVICE")"
echo "Python:      $(python3 --version)"
echo "PHP:         $(php -v | head -n 1)"
echo "Arquivo:     $INSTALL_DIR/dominio.txt"
echo
echo "Teste o site em: http://$DOMAIN"
echo "Se o SSL foi emitido, use: https://$DOMAIN"
echo
echo "Para testar o Nginx: nginx -t"
echo "Para testar renovacao: certbot renew --dry-run"
echo "=========================================="
