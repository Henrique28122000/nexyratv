
#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# ==========================================================
# NEXYRA - INSTALADOR AUTOMATICO
# Ubuntu 22.04 / 24.04
# NGINX + PHP-FPM + SQLITE + PYTHON + SSL
# ==========================================================

ZIP_URL="https://www.dropbox.com/scl/fi/6b7b0iyky4bffle14xo49/script_completo.zip?rlkey=2t3a3c9z41xz2138ru1pjipjy&st=a1melg5s&dl=1"

INSTALL_DIR="/var/www/painel"
TMP_DIR="/tmp/instalador-site"
ZIP_FILE="$TMP_DIR/site.zip"
NGINX_CONF="/etc/nginx/sites-available/painel"
DB_DIR="$INSTALL_DIR/.nexyra-p2p"
DB_FILE="$DB_DIR/panel.sqlite"

trap 'echo; echo "[ERRO] Falha na linha $LINENO."; exit 1' ERR

if [[ "$EUID" -ne 0 ]]; then
    echo "Execute como root."
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "Sistema operacional nao identificado."
    exit 1
fi

source /etc/os-release

if [[ "$ID" != "ubuntu" ]]; then
    echo "Este instalador foi preparado para Ubuntu."
    exit 1
fi

echo
echo "=========================================="
echo "       INSTALADOR NEXYRA"
echo "=========================================="
echo

mkdir -p "$TMP_DIR"

echo "[1/9] Instalando dependencias..."
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    ca-certificates curl wget unzip \
    nginx \
    python3 python3-pip python3-venv \
    php-fpm php-cli php-common \
    php-curl php-mbstring php-xml php-zip \
    php-mysql php-gd php-intl php-bcmath \
    php-sqlite3 \
    certbot python3-certbot-nginx \
    sqlite3

echo
echo "[2/9] Baixando o pacote do site..."

curl -fL --retry 3 --connect-timeout 20 \
    "$ZIP_URL" -o "$ZIP_FILE"

if ! unzip -tq "$ZIP_FILE" >/dev/null; then
    echo "ERRO: o arquivo baixado nao e um ZIP valido."
    exit 1
fi

echo
echo "[3/9] Extraindo e localizando o painel..."

STAGE_DIR="$TMP_DIR/extracao"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

unzip -q "$ZIP_FILE" -d "$STAGE_DIR"

mapfile -t DOMAIN_FILES < <(
    find "$STAGE_DIR" -type f -name dominio.txt
)

if [[ "${#DOMAIN_FILES[@]}" -ne 1 ]]; then
    echo "ERRO: era esperado exatamente um dominio.txt."
    echo "Encontrados: ${#DOMAIN_FILES[@]}"
    echo "Verifique a estrutura do ZIP."
    exit 1
fi

DOMAIN_FILE="${DOMAIN_FILES[0]}"
SITE_ROOT="$(dirname "$DOMAIN_FILE")"

if [[ ! -f "$SITE_ROOT/index.php" &&
      ! -f "$SITE_ROOT/index.html" &&
      ! -f "$SITE_ROOT/index.htm" ]]; then
    echo "ERRO: a pasta de dominio.txt nao parece ser a raiz do site."
    echo "Pasta encontrada: $SITE_ROOT"
    exit 1
fi

echo "Raiz identificada: $SITE_ROOT"

echo
echo "[4/9] Configurando o dominio..."

read -r -p "Dominio do painel (ex.: apk.exemplo.com): " DOMAIN
DOMAIN="${DOMAIN,,}"

if [[ ${#DOMAIN} -gt 253 ||
      ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    echo "ERRO: dominio invalido."
    exit 1
fi

read -r -p "E-mail para o SSL (deixe vazio para pular): " EMAIL

if [[ -n "$EMAIL" && ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "ERRO: e-mail invalido."
    exit 1
fi

echo
echo "[5/9] Fazendo backup e publicando os arquivos..."

STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR=""

# Guarda o site anterior, sem apagar os arquivos.
if [[ -d "$INSTALL_DIR" ]]; then
    BACKUP_DIR="${INSTALL_DIR}.backup.${STAMP}"
    mv "$INSTALL_DIR" "$BACKUP_DIR"
    echo "Backup criado: $BACKUP_DIR"
fi

mkdir -p "$(dirname "$INSTALL_DIR")"
cp -a "$SITE_ROOT" "$INSTALL_DIR"

# Preserva o banco SQLite existente quando disponivel.
mkdir -p "$INSTALL_DIR/.nexyra-p2p"

if [[ -n "$BACKUP_DIR" ]]; then
    if [[ -d "$BACKUP_DIR/.nexyra-p2p" ]]; then
        cp -an "$BACKUP_DIR/.nexyra-p2p/." \
            "$INSTALL_DIR/.nexyra-p2p/"
    fi

    if [[ -d "$BACKUP_DIR/nexyra-p2p" ]]; then
        mkdir -p "$INSTALL_DIR/nexyra-p2p"
        cp -an "$BACKUP_DIR/nexyra-p2p/." \
            "$INSTALL_DIR/nexyra-p2p/"
    fi
fi

# Migra bancos de caminhos antigos conhecidos, se necessario.
if [[ ! -s "$DB_FILE" ]]; then
    for OLD_DB in \
        /var/www/.nexyra-p2p/panel.sqlite \
        /var/www/painel/.nexyra-p2p/panel.sqlite \
        /var/www/painel/nexyra-p2p/panel.sqlite
    do
        if [[ -s "$OLD_DB" && "$OLD_DB" != "$DB_FILE" ]]; then
            cp -an "$OLD_DB" "$DB_FILE"
            echo "Banco SQLite recuperado de: $OLD_DB"
            break
        fi
    done
fi

# Atualiza o dominio.txt dentro da raiz publicada.
printf '%s\n' "$DOMAIN" > "$INSTALL_DIR/dominio.txt"

echo
echo "[6/9] Ajustando SQLite e permissoes..."

# Corrige a configuracao mais comum do projeto.
CONFIG_PHP="$INSTALL_DIR/config/config.php"

if [[ -f "$CONFIG_PHP" ]]; then
    python3 - "$CONFIG_PHP" <<'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

pattern = r"define\s*\(\s*(['\"])SQLITE_PATH\1\s*,\s*.*?\)\s*;"
replacement = "define('SQLITE_PATH', __DIR__ . '/../.nexyra-p2p/panel.sqlite');"

updated, count = re.subn(pattern, replacement, s, count=1)

if count:
    p.write_text(updated, encoding="utf-8")
    print("SQLITE_PATH ajustado em config/config.php.")
else:
    print("AVISO: SQLITE_PATH nao encontrado; nenhuma linha foi alterada.")
PY
else
    echo "AVISO: config/config.php nao encontrado."
fi

# Corrige o caminho-base usado pelo gerador, se corresponder ao caminho antigo.
BUILD_PY="$INSTALL_DIR/nexyra/gerador/build.py"

if [[ -f "$BUILD_PY" ]]; then
    python3 - "$BUILD_PY" "$INSTALL_DIR/.nexyra-ligas" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
old = "Path('/home/binstream/.nexyra-ligas')"
new = "Path(" + repr(sys.argv[2]) + ")"

if old in s:
    p.write_text(s.replace(old, new), encoding="utf-8")
    print("Caminho-base do gerador atualizado.")
else:
    print("Caminho-base do gerador mantido; formato antigo nao encontrado.")
PY
fi

# Codigo: leitura pelo PHP-FPM via grupo www-data.
chown -R root:www-data "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 750 {} \;
find "$INSTALL_DIR" -type f -exec chmod 640 {} \;

# Diretorios que precisam aceitar gravacao pelo site.
for WRITABLE_DIR in \
    "$INSTALL_DIR/.nexyra-p2p" \
    "$INSTALL_DIR/nexyra-p2p" \
    "$INSTALL_DIR/data" \
    "$INSTALL_DIR/uploads" \
    "$INSTALL_DIR/lab-downloads" \
    "$INSTALL_DIR/.nexyra-ligas" \
    "$INSTALL_DIR/nexyra/gerador/generated"
do
    if [[ -d "$WRITABLE_DIR" ]]; then
        chown -R www-data:www-data "$WRITABLE_DIR"
        find "$WRITABLE_DIR" -type d -exec chmod 770 {} \;
        find "$WRITABLE_DIR" -type f -exec chmod 660 {} \;
    fi
done

# Permite que o gerador crie os diretorios caso nao existam.
mkdir -p "$INSTALL_DIR/.nexyra-p2p"
chown www-data:www-data "$INSTALL_DIR/.nexyra-p2p"
chmod 770 "$INSTALL_DIR/.nexyra-p2p"

# Testa suporte ao SQLite no PHP CLI.
if ! php -r 'exit(in_array("sqlite", PDO::getAvailableDrivers(), true) ? 0 : 1);'; then
    echo "ERRO: PDO SQLite nao esta disponivel no PHP."
    exit 1
fi

echo "Driver PDO SQLite: OK"

echo
echo "[7/9] Configurando Nginx e PHP-FPM..."

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"

if ! systemctl cat "$PHP_FPM_SERVICE.service" >/dev/null 2>&1; then
    echo "ERRO: servico nao encontrado: $PHP_FPM_SERVICE"
    exit 1
fi

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

# Desativa o site default, sem remover outros sites.
rm -f /etc/nginx/sites-enabled/default

systemctl enable nginx "$PHP_FPM_SERVICE"
systemctl restart "$PHP_FPM_SERVICE"

nginx -t
systemctl reload nginx

echo
echo "[8/9] Testando escrita no diretorio SQLite..."

if ! runuser -u www-data -- test -w "$INSTALL_DIR/.nexyra-p2p"; then
    echo "ERRO: www-data nao pode gravar no diretorio SQLite."
    exit 1
fi

if [[ -f "$DB_FILE" ]]; then
    chown www-data:www-data "$DB_FILE"
    chmod 660 "$DB_FILE"

    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$DB_FILE" 'PRAGMA quick_check;' || {
            echo "ERRO: o banco SQLite falhou na verificacao."
            echo "O backup foi preservado em: $BACKUP_DIR"
            exit 1
        }
    fi
else
    echo "Banco ainda nao existe; o painel podera cria-lo se o codigo suportar."
fi

# Se o site tiver requirements.txt, instala em ambiente virtual isolado.
if [[ -f "$INSTALL_DIR/nexyra/gerador/requirements.txt" ]]; then
    echo "Instalando dependencias Python do gerador..."
    python3 -m venv "$INSTALL_DIR/nexyra/gerador/venv"
    "$INSTALL_DIR/nexyra/gerador/venv/bin/pip" install \
        --disable-pip-version-check \
        -r "$INSTALL_DIR/nexyra/gerador/requirements.txt"
fi

echo
echo "[9/9] Verificando DNS e SSL..."

PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)"
DOMAIN_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}' || true)"

if [[ -n "$EMAIL" && -n "$PUBLIC_IP" && "$DOMAIN_IP" == "$PUBLIC_IP" ]]; then
    certbot --nginx \
        --non-interactive \
        --agree-tos \
        --redirect \
        --email "$EMAIL" \
        -d "$DOMAIN"

    systemctl enable --now certbot.timer
else
    echo "SSL nao emitido automaticamente."
    echo "Verifique se o DNS A de $DOMAIN aponta para $PUBLIC_IP."
    echo "Depois execute: certbot --nginx -d $DOMAIN"
fi

echo
echo "=========================================="
echo "       INSTALACAO CONCLUIDA"
echo "=========================================="
echo "Dominio:     $DOMAIN"
echo "Diretorio:   $INSTALL_DIR"
echo "dominio.txt: $INSTALL_DIR/dominio.txt"
echo "PHP:         $(php -v | head -n 1)"
echo "SQLite PHP:  $(php -r 'echo implode(", ", PDO::getAvailableDrivers());')"
echo "Nginx:       $(systemctl is-active nginx)"
echo "PHP-FPM:     $(systemctl is-active "$PHP_FPM_SERVICE")"

if [[ -n "$BACKUP_DIR" ]]; then
    echo "Backup:      $BACKUP_DIR"
fi

echo
echo "Acesse: http://$DOMAIN"
echo "Se o certificado foi emitido: https://$DOMAIN"
echo "=========================================="
