
#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# ==========================================================
# NEXYRA PANEL - INSTALADOR COMPLETO
# Ubuntu 22.04 / 24.04
# NGINX + PHP-FPM + SQLITE + PYTHON + SSL
# ==========================================================

ZIP_URL="https://www.dropbox.com/scl/fi/6b7b0iyky4bffle14xo49/script_completo.zip?rlkey=2t3a3c9z41xz2138ru1pjipjy&st=a1melg5s&dl=1"

INSTALL_DIR="/var/www/painel"
TMP_DIR="/tmp/instalador-site"
ZIP_FILE="$TMP_DIR/site.zip"
NGINX_CONF="/etc/nginx/sites-available/painel"
NGINX_LINK="/etc/nginx/sites-enabled/painel"
DB_REL=".nexyra-p2p/panel.sqlite"

trap 'echo; echo "[ERRO] Falha na linha $LINENO."; exit 1' ERR

if [[ "$EUID" -ne 0 ]]; then
    echo "Execute como root."
    exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "Este instalador requer Ubuntu."
    exit 1
fi

echo
echo "================================================"
echo "             NEXYRA PANEL"
echo "================================================"
echo "  1) Instalar / reinstalar preservando o SQLite"
echo "  2) LIMPAR antes de reinstalar"
echo "  3) Desinstalar o painel"
echo "  0) Sair"
echo

read -r -p "Escolha uma opcao: " OPTION

case "$OPTION" in
    1)
        PRESERVE_DB=yes
        ;;
    2)
        echo
        echo "A pasta antiga sera guardada em backup."
        echo "A limpeza remove os arquivos antigos da NOVA instalacao."
        read -r -p "Preservar o banco SQLite? [s/N]: " ANSWER
        case "${ANSWER,,}" in
            s|sim|y|yes) PRESERVE_DB=yes ;;
            *) PRESERVE_DB=no ;;
        esac
        ;;
    3)
        echo
        echo "O painel sera desativado e os arquivos serao guardados."
        read -r -p "Digite DESINSTALAR para confirmar: " CONFIRM
        [[ "$CONFIRM" == "DESINSTALAR" ]] || {
            echo "Cancelado."
            exit 0
        }

        STAMP="$(date +%Y%m%d%H%M%S)"

        if [[ -d "$INSTALL_DIR" ]]; then
            mv "$INSTALL_DIR" "${INSTALL_DIR}.desinstalado.${STAMP}"
            echo "Arquivos preservados em ${INSTALL_DIR}.desinstalado.${STAMP}"
        fi

        rm -f "$NGINX_LINK" "$NGINX_CONF"

        if nginx -t; then
            systemctl reload nginx || true
        else
            echo "AVISO: Nginx tem outro erro de configuracao."
        fi

        echo "Painel desinstalado. PHP, Nginx, bancos e certificados foram preservados."
        exit 0
        ;;
    0)
        echo "Cancelado."
        exit 0
        ;;
    *)
        echo "Opcao invalida."
        exit 1
        ;;
esac

mkdir -p "$TMP_DIR"

# ----------------------------------------------------------
# 1. Dependencias
# ----------------------------------------------------------

echo
echo "[1/9] Instalando dependencias..."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    ca-certificates curl wget unzip \
    nginx sqlite3 \
    python3 python3-pip python3-venv \
    php-fpm php-cli php-common \
    php-curl php-mbstring php-xml php-zip \
    php-mysql php-gd php-intl php-bcmath php-sqlite3 \
    certbot python3-certbot-nginx

# ----------------------------------------------------------
# 2. Baixar pacote
# ----------------------------------------------------------

echo
echo "[2/9] Baixando pacote do site..."

curl -fL --retry 3 --connect-timeout 20 "$ZIP_URL" -o "$ZIP_FILE"

if ! unzip -tq "$ZIP_FILE" >/dev/null; then
    echo "ERRO: download nao e um ZIP valido."
    exit 1
fi

# ----------------------------------------------------------
# 3. Extrair e localizar site
# ----------------------------------------------------------

echo
echo "[3/9] Extraindo arquivos..."

STAGE_DIR="$TMP_DIR/extracao"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
unzip -q "$ZIP_FILE" -d "$STAGE_DIR"

mapfile -t DOMAIN_FILES < <(find "$STAGE_DIR" -type f -name dominio.txt)

if [[ "${#DOMAIN_FILES[@]}" -ne 1 ]]; then
    echo "ERRO: esperado exatamente um dominio.txt; encontrados ${#DOMAIN_FILES[@]}."
    exit 1
fi

SITE_ROOT="$(dirname "${DOMAIN_FILES[0]}")"

if [[ ! -f "$SITE_ROOT/index.php" &&
      ! -f "$SITE_ROOT/index.html" &&
      ! -f "$SITE_ROOT/index.htm" ]]; then
    echo "ERRO: raiz do site invalida: $SITE_ROOT"
    exit 1
fi

echo "Raiz encontrada: $SITE_ROOT"

# ----------------------------------------------------------
# 4. Dominio e SSL
# ----------------------------------------------------------

echo
echo "[4/9] Dominio..."

read -r -p "Dominio (ex.: apk.exemplo.com): " DOMAIN
DOMAIN="${DOMAIN,,}"

if [[ ${#DOMAIN} -gt 253 ||
      ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    echo "ERRO: dominio invalido."
    exit 1
fi

read -r -p "E-mail para SSL (vazio para pular): " EMAIL

if [[ -n "$EMAIL" && ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "ERRO: e-mail invalido."
    exit 1
fi

# ----------------------------------------------------------
# 5. Backup e limpeza segura
# ----------------------------------------------------------

echo
echo "[5/9] Backup e publicacao..."

STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR=""
SAVED_DB="$TMP_DIR/preserved-panel.sqlite"
rm -f "$SAVED_DB"

# Preserva uma copia temporaria do SQLite antes de mover a pasta.
if [[ "$PRESERVE_DB" == yes && -s "$INSTALL_DIR/$DB_REL" ]]; then
    cp "$INSTALL_DIR/$DB_REL" "$SAVED_DB"
fi

# Nunca apaga definitivamente a instalacao anterior.
if [[ -d "$INSTALL_DIR" ]]; then
    BACKUP_DIR="${INSTALL_DIR}.backup.${STAMP}"
    mv "$INSTALL_DIR" "$BACKUP_DIR"
    echo "Backup: $BACKUP_DIR"
fi

mkdir -p "$(dirname "$INSTALL_DIR")"
cp -a "$SITE_ROOT" "$INSTALL_DIR"

mkdir -p "$INSTALL_DIR/.nexyra-p2p"

# Recupera dados anteriores se o usuario escolheu preservar SQLite.
if [[ "$PRESERVE_DB" == yes ]]; then
    if [[ -s "$SAVED_DB" ]]; then
        cp "$SAVED_DB" "$INSTALL_DIR/$DB_REL"
        echo "Banco SQLite anterior restaurado."
    elif [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR/.nexyra-p2p" ]]; then
        cp -an "$BACKUP_DIR/.nexyra-p2p/." "$INSTALL_DIR/.nexyra-p2p/"
    fi

    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR/nexyra-p2p" ]]; then
        mkdir -p "$INSTALL_DIR/nexyra-p2p"
        cp -an "$BACKUP_DIR/nexyra-p2p/." "$INSTALL_DIR/nexyra-p2p/"
    fi
else
    echo "Limpeza selecionada: o SQLite antigo nao sera copiado para a nova instalacao."
    echo "A copia antiga continua disponivel no backup."
fi

printf '%s\n' "$DOMAIN" > "$INSTALL_DIR/dominio.txt"

# ----------------------------------------------------------
# 6. Configuracao SQLite e permissoes
# ----------------------------------------------------------

echo
echo "[6/9] Configurando SQLite e permissoes..."

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
    print("SQLITE_PATH atualizado.")
else:
    print("AVISO: SQLITE_PATH nao encontrado em config.php.")
PY
    php -l "$CONFIG_PHP"
else
    echo "AVISO: config/config.php nao encontrado."
fi

# Atualiza a base do gerador somente quando o caminho antigo existir no codigo.
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
    print("Base do gerador atualizada.")
else:
    print("AVISO: caminho antigo do gerador nao encontrado; confira build.py.")
PY
fi

chown -R root:www-data "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 750 {} \;
find "$INSTALL_DIR" -type f -exec chmod 640 {} \;

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

mkdir -p "$INSTALL_DIR/.nexyra-p2p"
chown www-data:www-data "$INSTALL_DIR/.nexyra-p2p"
chmod 770 "$INSTALL_DIR/.nexyra-p2p"

if [[ -f "$INSTALL_DIR/$DB_REL" ]]; then
    chown www-data:www-data "$INSTALL_DIR/$DB_REL"
    chmod 660 "$INSTALL_DIR/$DB_REL"
fi

php -r 'exit(in_array("sqlite", PDO::getAvailableDrivers(), true) ? 0 : 1);' ||
    { echo "ERRO: PDO SQLite indisponivel."; exit 1; }

echo "PDO SQLite: OK"

# ----------------------------------------------------------
# 7. Nginx e PHP-FPM
# ----------------------------------------------------------

echo
echo "[7/9] Configurando Nginx e PHP-FPM..."

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"

systemctl cat "$PHP_FPM_SERVICE.service" >/dev/null

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
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

ln -sfn "$NGINX_CONF" "$NGINX_LINK"

# Desativa somente o site default.
rm -f /etc/nginx/sites-enabled/default

systemctl enable nginx "$PHP_FPM_SERVICE"
systemctl restart "$PHP_FPM_SERVICE"

nginx -t
systemctl reload nginx

# ----------------------------------------------------------
# 8. Testes e gerador Python
# ----------------------------------------------------------

echo
echo "[8/9] Testando SQLite e gerador..."

runuser -u www-data -- test -w "$INSTALL_DIR/.nexyra-p2p" ||
    { echo "ERRO: pasta SQLite sem permissao de escrita."; exit 1; }

if [[ -f "$INSTALL_DIR/$DB_REL" ]]; then
    CHECK_RESULT="$(sqlite3 "$INSTALL_DIR/$DB_REL" 'PRAGMA quick_check;')"
    [[ "$CHECK_RESULT" == "ok" ]] ||
        { echo "ERRO: banco SQLite com problema: $CHECK_RESULT"; exit 1; }
fi

if [[ -f "$INSTALL_DIR/nexyra/gerador/requirements.txt" ]]; then
    python3 -m venv "$INSTALL_DIR/nexyra/gerador/venv"
    "$INSTALL_DIR/nexyra/gerador/venv/bin/pip" install \
        --disable-pip-version-check \
        -r "$INSTALL_DIR/nexyra/gerador/requirements.txt"
fi

# ----------------------------------------------------------
# 9. SSL
# ----------------------------------------------------------

echo
echo "[9/9] Verificando DNS e SSL..."

PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)"
DOMAIN_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}' || true)"

if [[ -n "$EMAIL" && -n "$PUBLIC_IP" && "$DOMAIN_IP" == "$PUBLIC_IP" ]]; then
    certbot --nginx --non-interactive --agree-tos \
        --redirect --email "$EMAIL" -d "$DOMAIN"
    systemctl enable --now certbot.timer
else
    echo "SSL nao emitido automaticamente."
    echo "Verifique o DNS A de $DOMAIN para o IP $PUBLIC_IP."
    echo "Quando estiver correto, execute: certbot --nginx -d $DOMAIN"
fi

echo
echo "================================================"
echo "           INSTALACAO CONCLUIDA"
echo "================================================"
echo "Dominio:     $DOMAIN"
echo "Diretorio:   $INSTALL_DIR"
echo "PHP:         $(php -r 'echo PHP_VERSION;')"
echo "PDO:         $(php -r 'echo implode(", ", PDO::getAvailableDrivers());')"
echo "Nginx:       $(systemctl is-active nginx)"
echo "PHP-FPM:     $(systemctl is-active "$PHP_FPM_SERVICE")"
[[ -n "$BACKUP_DIR" ]] && echo "Backup:      $BACKUP_DIR"
echo
echo "Acesse: http://$DOMAIN"
echo "================================================"
