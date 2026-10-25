
cat > /root/instalar-painel.sh <<'INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# ==========================================================
# NEXYRA - INSTALADOR PHP + SQLITE + NGINX + SSL
# Ubuntu 22.04 / 24.04
# Preserva backups, corrige dominio.txt e testa SQLite real.
# ==========================================================

ZIP_URL="https://www.dropbox.com/scl/fi/6b7b0iyky4bffle14xo49/script_completo.zip?rlkey=2t3a3c9z41xz2138ru1pjipjy&st=a1melg5s&dl=1"

TMP_DIR="/tmp/instalador-site"
ZIP_FILE="$TMP_DIR/site.zip"
EXTRACT_DIR="$TMP_DIR/extracao"
PUBLISH_DIR="$TMP_DIR/publicacao"

INSTALL_DIR="/var/www/painel"
BACKUP_ROOT="/var/backups/instalador-site"
NGINX_SITE="/etc/nginx/sites-available/painel"
NGINX_LINK="/etc/nginx/sites-enabled/painel"

PHP_VERSION=""
PHP_SOCKET=""
DOMAIN=""
BACKUP_DIR=""
NGINX_BACKUP=""
OLD_SITE=""

info()    { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
ok()      { printf '\033[0;32m[OK]\033[0m %s\n' "$*"; }
warn()    { printf '\033[1;33m[AVISO]\033[0m %s\n' "$*"; }
die()     { printf '\033[0;31m[ERRO]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'rc=$?; echo "[ERRO] Falha na linha $LINENO (codigo $rc)." >&2; exit "$rc"' ERR

[[ "$EUID" -eq 0 ]] || die "Execute como root: bash /root/instalar-painel.sh"
[[ -f /etc/os-release ]] || die "Sistema operacional nao identificado."

. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Este instalador exige Ubuntu."
[[ "${VERSION_ID:-}" == "22.04" || "${VERSION_ID:-}" == "24.04" ]] ||
    die "Use Ubuntu 22.04 ou 24.04."

mkdir -p "$TMP_DIR" "$BACKUP_ROOT"

echo
echo "=========================================================="
echo "       INSTALADOR NEXYRA - PHP / SQLITE / NGINX"
echo "=========================================================="
echo "Sistema: $PRETTY_NAME"
echo "Site:    $INSTALL_DIR"
echo "ZIP:     $ZIP_FILE"
echo

# ----------------------------------------------------------
# 1. DEPENDENCIAS
# ----------------------------------------------------------

info "Atualizando pacotes e instalando dependencias..."
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    ca-certificates curl wget unzip zip \
    nginx python3 python3-pip python3-venv \
    php-fpm php-cli php-common \
    php-sqlite3 php-curl php-gd php-mbstring \
    php-xml php-zip php-intl php-bcmath \
    certbot python3-certbot-nginx

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"

phpenmod -v "$PHP_VERSION" -s cli pdo_sqlite sqlite3
phpenmod -v "$PHP_VERSION" -s fpm pdo_sqlite sqlite3

systemctl enable "php${PHP_VERSION}-fpm"
systemctl restart "php${PHP_VERSION}-fpm"

php -r '
if (!extension_loaded("pdo_sqlite") || !extension_loaded("sqlite3")) {
    fwrite(STDERR, "Extensoes SQLite ausentes no PHP CLI.\n");
    exit(1);
}
$pdo = new PDO("sqlite::memory:");
$pdo->query("SELECT 1");
echo "PDO SQLite e SQLite3 funcionando no CLI.\n";
' || die "SQLite nao funciona no PHP CLI."

[[ -S "$PHP_SOCKET" ]] || die "Socket PHP-FPM nao encontrado: $PHP_SOCKET"
ok "PHP $PHP_VERSION, SQLite e PHP-FPM instalados."

# ----------------------------------------------------------
# 2. BAIXAR OU REUTILIZAR ZIP
# ----------------------------------------------------------

if [[ -s "$ZIP_FILE" ]] && unzip -tq "$ZIP_FILE" >/dev/null 2>&1; then
    echo
    echo "Foi encontrado um ZIP valido:"
    echo "$ZIP_FILE"
    echo "1) Reutilizar ZIP existente"
    echo "2) Baixar novamente"
    echo "3) Cancelar"
    read -r -p "Escolha [1/2/3]: " CHOICE

    case "$CHOICE" in
        1) info "Reutilizando ZIP existente." ;;
        2) rm -f "${ZIP_FILE}.download" ;;
        3) echo "Cancelado; ZIP preservado."; exit 0 ;;
        *) die "Opcao invalida." ;;
    esac

    [[ "$CHOICE" == "1" ]] || DOWNLOAD=1
else
    DOWNLOAD=1
fi

if [[ "${DOWNLOAD:-0}" == "1" ]]; then
    info "Baixando pacote do projeto..."
    curl --fail --location --show-error \
        --retry 3 --retry-delay 2 --connect-timeout 30 \
        --output "${ZIP_FILE}.download" "$ZIP_URL"

    unzip -tq "${ZIP_FILE}.download" >/dev/null ||
        die "O ZIP baixado e invalido. ZIP anterior preservado."

    mv -f "${ZIP_FILE}.download" "$ZIP_FILE"
    ok "ZIP baixado e validado."
fi

# ----------------------------------------------------------
# 3. EXTRAIR E LOCALIZAR SITE
# ----------------------------------------------------------

info "Extraindo arquivos..."
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
unzip -oq "$ZIP_FILE" -d "$EXTRACT_DIR"

mapfile -d '' DOMAIN_FILES < <(
    find "$EXTRACT_DIR" -type f -iname dominio.txt -print0
)

[[ "${#DOMAIN_FILES[@]}" -eq 1 ]] ||
    die "O ZIP deve conter exatamente um dominio.txt; encontrados: ${#DOMAIN_FILES[@]}."

SITE_SOURCE="$(dirname "${DOMAIN_FILES[0]}")"

[[ -f "$SITE_SOURCE/index.php" || -f "$SITE_SOURCE/index.html" ||
   -f "$SITE_SOURCE/index.htm" ]] ||
    die "A pasta do dominio.txt nao parece ser a raiz do site: $SITE_SOURCE"

echo
read -r -p "Dominio do painel (ex.: apk.exemplo.com.br): " DOMAIN
DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN%.}"

# Aceita nomes DNS comuns, incluindo hifens e subdominios.
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
    die "Dominio invalido: $DOMAIN"

ok "Dominio informado: $DOMAIN"

# ----------------------------------------------------------
# 4. BACKUP DO SITE E CONFIGURACAO NGINX
# ----------------------------------------------------------

if [[ -f "$NGINX_SITE" ]]; then
    NGINX_BACKUP="$BACKUP_ROOT/painel-nginx-$(date +%Y%m%d-%H%M%S).conf"
    cp -a "$NGINX_SITE" "$NGINX_BACKUP"
    ok "Backup Nginx: $NGINX_BACKUP"
fi

if [[ -d "$INSTALL_DIR" ]]; then
    BACKUP_DIR="$BACKUP_ROOT/painel-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    info "Salvando site anterior em $BACKUP_DIR"
    cp -a "$INSTALL_DIR"/. "$BACKUP_DIR"/
    ok "Backup do site concluido."
fi

# ----------------------------------------------------------
# 5. PREPARAR PUBLICACAO E PRESERVAR BANCOS
# ----------------------------------------------------------

rm -rf "$PUBLISH_DIR"
mkdir -p "$PUBLISH_DIR"
cp -a "$SITE_SOURCE"/. "$PUBLISH_DIR"/

# Se o site antigo tinha bancos SQLite, preserva-os no mesmo
# caminho relativo quando o pacote novo ainda nao os possui.
if [[ -n "$BACKUP_DIR" ]]; then
    while IFS= read -r -d '' DB; do
        REL="${DB#"$BACKUP_DIR"/}"
        DEST="$PUBLISH_DIR/$REL"
        if [[ ! -e "$DEST" ]]; then
            mkdir -p "$(dirname "$DEST")"
            cp -a "$DB" "$DEST"
            for SUFFIX in -wal -shm -journal; do
                [[ ! -f "${DB}${SUFFIX}" ]] ||
                    cp -a "${DB}${SUFFIX}" "${DEST}${SUFFIX}"
            done
            info "Banco preservado: $REL"
        fi
    done < <(
        find "$BACKUP_DIR" -type f \
            \( -iname '*.sqlite' -o -iname '*.sqlite3' -o -iname '*.db' \) \
            -print0
    )
fi

# Grava automaticamente o dominio escolhido na raiz publicada.
printf '%s\n' "$DOMAIN" > "$PUBLISH_DIR/dominio.txt"

# ----------------------------------------------------------
# 6. CORRIGIR SQLITE_PATH CONHECIDO E MIGRAR BANCO
# ----------------------------------------------------------

TARGET_DB="$PUBLISH_DIR/.nexyra-p2p/panel.sqlite"
mkdir -p "$(dirname "$TARGET_DB")"

# Se a configuracao antiga usa /../.nexyra-p2p/panel.sqlite
# ou /var/www/.nexyra-p2p/panel.sqlite, tenta preservar o banco.
# O caminho padrao novo fica dentro da raiz do painel.
OLD_DB_CANDIDATES=(
    "$PUBLISH_DIR/.nexyra-p2p/panel.sqlite"
    "$PUBLISH_DIR/nexyra-p2p/panel.sqlite"
    "/var/www/.nexyra-p2p/panel.sqlite"
    "/.nexyra-p2p/panel.sqlite"
    "/home/binstream/.nexyra-p2p/panel.sqlite"
)

if [[ -n "$BACKUP_DIR" ]]; then
    OLD_DB_CANDIDATES+=(
        "$BACKUP_DIR/.nexyra-p2p/panel.sqlite"
        "$BACKUP_DIR/nexyra-p2p/panel.sqlite"
    )
fi

if [[ ! -s "$TARGET_DB" ]]; then
    for CANDIDATE in "${OLD_DB_CANDIDATES[@]}"; do
        if [[ -s "$CANDIDATE" && "$CANDIDATE" != "$TARGET_DB" ]]; then
            cp -a "$CANDIDATE" "$TARGET_DB"
            for SUFFIX in -wal -shm -journal; do
                [[ ! -f "${CANDIDATE}${SUFFIX}" ]] ||
                    cp -a "${CANDIDATE}${SUFFIX}" "${TARGET_DB}${SUFFIX}"
            done
            info "Banco SQLite anterior copiado para o caminho padrao."
            break
        fi
    done
fi

# Corrige somente o caminho SQLite conhecido neste projeto.
# Se a constante estiver em outra forma, nao a sobrescreve as cegas.
CONFIG_PHP="$PUBLISH_DIR/config/config.php"
if [[ -f "$CONFIG_PHP" ]]; then
    if grep -Fq "'/../.nexyra-p2p/panel.sqlite'" "$CONFIG_PHP" ||
       grep -Fq '"/../.nexyra-p2p/panel.sqlite"' "$CONFIG_PHP" ||
       grep -Fq "'/var/www/.nexyra-p2p/panel.sqlite'" "$CONFIG_PHP"; then
        cp -a "$CONFIG_PHP" "$CONFIG_PHP.backup-installer"
        python3 - "$CONFIG_PHP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
s = s.replace(
    "'/../.nexyra-p2p/panel.sqlite'",
    " __DIR__ . '/../.nexyra-p2p/panel.sqlite'"
)
s = s.replace(
    '"/../.nexyra-p2p/panel.sqlite"',
    " __DIR__ . '/../.nexyra-p2p/panel.sqlite'"
)
s = s.replace(
    "'/var/www/.nexyra-p2p/panel.sqlite'",
    " __DIR__ . '/../.nexyra-p2p/panel.sqlite'"
)
p.write_text(s)
PY
    fi
fi

# ----------------------------------------------------------
# 7. PUBLICAR SEM DEIXAR O SITE ANTIGO SEM BACKUP
# ----------------------------------------------------------

if [[ -d "$INSTALL_DIR" ]]; then
    OLD_SITE="${INSTALL_DIR}.anterior-$(date +%Y%m%d-%H%M%S)"
    mv "$INSTALL_DIR" "$OLD_SITE"
    info "Site anterior mantido em: $OLD_SITE"
fi

mv "$PUBLISH_DIR" "$INSTALL_DIR"
ok "Site publicado em $INSTALL_DIR"

# ----------------------------------------------------------
# 8. PERMISSOES SEGURAS
# ----------------------------------------------------------

# Código legível pelo PHP/Nginx, mas não gravável pelo processo web.
chown -R root:www-data "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 750 {} \;
find "$INSTALL_DIR" -type f -exec chmod 640 {} \;

# Scripts shell permanecem executáveis se forem usados manualmente.
find "$INSTALL_DIR" -type f -name '*.sh' -exec chmod 750 {} \;

# Diretórios de dados conhecidos: PHP precisa escrever neles.
for RELDIR in \
    data uploads lab-downloads \
    .nexyra-p2p nexyra-p2p \
    nexyra/gerador/generated
do
    DIR="$INSTALL_DIR/$RELDIR"
    if [[ -d "$DIR" ]]; then
        chown -R www-data:www-data "$DIR"
        find "$DIR" -type d -exec chmod 770 {} \;
        find "$DIR" -type f -exec chmod 660 {} \;
    fi
done

# O banco SQLite precisa ser gravável e sua pasta precisa permitir
# criar arquivos journal/WAL/SHM.
DB_PATH="$INSTALL_DIR/.nexyra-p2p/panel.sqlite"
mkdir -p "$(dirname "$DB_PATH")"
chown www-data:www-data "$(dirname "$DB_PATH")"
chmod 770 "$(dirname "$DB_PATH")"

if [[ -f "$DB_PATH" ]]; then
    chown www-data:www-data "$DB_PATH"
    chmod 660 "$DB_PATH"
fi

for SUFFIX in -wal -shm -journal; do
    if [[ -f "${DB_PATH}${SUFFIX}" ]]; then
        chown www-data:www-data "${DB_PATH}${SUFFIX}"
        chmod 660 "${DB_PATH}${SUFFIX}"
    fi
done

# Pastas de trabalho do gerador APK, sem modificar seus conteúdos.
GEN_DIR="$INSTALL_DIR/nexyra/gerador"
if [[ -d "$GEN_DIR" ]]; then
    mkdir -p "$GEN_DIR/generated"
    chown -R www-data:www-data "$GEN_DIR/generated"
    chmod 770 "$GEN_DIR/generated"
fi

# ----------------------------------------------------------
# 9. VALIDAR CAMINHO DO SQLITE NO PHP
# ----------------------------------------------------------

if [[ -f "$INSTALL_DIR/config/config.php" ]]; then
    echo
    info "SQLITE_PATH declarado pela aplicacao:"
    grep -n 'SQLITE_PATH' "$INSTALL_DIR/config/config.php" || true
fi

# Confere sintaxe dos PHPs essenciais.
for PHPFILE in \
    "$INSTALL_DIR/index.php" \
    "$INSTALL_DIR/config/config.php" \
    "$INSTALL_DIR/config/db.php" \
    "$INSTALL_DIR/apk.php"
do
    if [[ -f "$PHPFILE" ]]; then
        php -l "$PHPFILE" || die "Erro de sintaxe PHP: $PHPFILE"
    fi
done

# Testa a gravação como o mesmo usuário do PHP-FPM.
# Usa o banco real apenas se ele já existe; caso contrário testa
# criação de arquivo temporário na pasta do banco.
if [[ -f "$DB_PATH" ]]; then
    runuser -u www-data -- php -r '
        $f=$argv[1];
        $pdo=new PDO("sqlite:".$f);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec("PRAGMA busy_timeout=5000");
        $pdo->query("SELECT name FROM sqlite_master LIMIT 1");
        echo "Banco SQLite existente pode ser aberto por www-data.\n";
    ' "$DB_PATH" || die "www-data nao consegue abrir o banco SQLite."
else
    runuser -u www-data -- php -r '
        $d=$argv[1];
        $f=$d."/.sqlite-write-test-".bin2hex(random_bytes(4));
        $pdo=new PDO("sqlite:".$f);
        $pdo->exec("CREATE TABLE test(id INTEGER)");
        $pdo=null;
        unlink($f);
        echo "www-data consegue criar e gravar arquivos SQLite.\n";
    ' "$(dirname "$DB_PATH")" ||
        die "www-data nao consegue escrever na pasta SQLite."
fi

# ----------------------------------------------------------
# 10. LOGS PHP
# ----------------------------------------------------------

PHP_LOG="/var/log/php-errors.log"
touch "$PHP_LOG"
chown www-data:adm "$PHP_LOG" 2>/dev/null || chown www-data:www-data "$PHP_LOG"
chmod 640 "$PHP_LOG"

FPM_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
if [[ -f "$FPM_INI" ]]; then
    sed -i \
        -e 's/^[;[:space:]]*log_errors[[:space:]]*=.*/log_errors = On/' \
        -e 's/^[;[:space:]]*display_errors[[:space:]]*=.*/display_errors = Off/' \
        -e 's/^[;[:space:]]*display_startup_errors[[:space:]]*=.*/display_startup_errors = Off/' \
        "$FPM_INI"

    if grep -Eq '^[;[:space:]]*error_log[[:space:]]*=' "$FPM_INI"; then
        sed -i "s|^[;[:space:]]*error_log[[:space:]]*=.*|error_log = $PHP_LOG|" "$FPM_INI"
    else
        printf '\nerror_log = %s\n' "$PHP_LOG" >> "$FPM_INI"
    fi
fi

# ----------------------------------------------------------
# 11. CONFIGURAR NGINX
# ----------------------------------------------------------

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

cat > "$NGINX_SITE" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $INSTALL_DIR;
    index index.php index.html index.htm;
    charset utf-8;
    server_tokens off;
    client_max_body_size 32M;

    access_log /var/log/nginx/painel-access.log;
    error_log /var/log/nginx/painel-error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:$PHP_SOCKET;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINX

ln -sfn "$NGINX_SITE" "$NGINX_LINK"
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
fi

systemctl enable nginx
systemctl restart "php${PHP_VERSION}-fpm"

nginx -t || die "Configuracao Nginx invalida; nao foi reiniciado."
systemctl restart nginx
ok "Nginx e PHP-FPM iniciados."

# ----------------------------------------------------------
# 12. SSL OPCIONAL
# ----------------------------------------------------------

echo
echo "Verificando DNS para $DOMAIN..."
PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
DOMAIN_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | head -1 || true)"

if [[ -z "$DOMAIN_IP" ]]; then
    warn "Dominio ainda nao resolve para IPv4; SSL ignorado."
elif [[ -n "$PUBLIC_IP" && "$DOMAIN_IP" != "$PUBLIC_IP" ]]; then
    warn "DNS aponta para $DOMAIN_IP; IP publico da VPS e $PUBLIC_IP."
    warn "Corrija o DNS A antes de emitir o SSL."
else
    read -r -p "E-mail para Let's Encrypt (ENTER para pular SSL): " SSL_EMAIL
    if [[ -n "$SSL_EMAIL" && "$SSL_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        if certbot --nginx --non-interactive --agree-tos \
            --redirect --email "$SSL_EMAIL" -d "$DOMAIN"; then
            systemctl enable certbot.timer 2>/dev/null || true
            systemctl start certbot.timer 2>/dev/null || true
            ok "SSL instalado."
        else
            warn "Certbot falhou. Tente depois: certbot --nginx -d $DOMAIN"
        fi
    else
        warn "SSL ignorado."
    fi
fi

# ----------------------------------------------------------
# 13. TESTES FINAIS
# ----------------------------------------------------------

echo
systemctl is-active --quiet nginx || die "Nginx nao esta ativo."
systemctl is-active --quiet "php${PHP_VERSION}-fpm" || die "PHP-FPM nao esta ativo."

echo "===== DOMINIO GRAVADO ====="
cat "$INSTALL_DIR/dominio.txt"

echo
echo "===== EXTENSOES SQLITE ====="
php -r 'print_r(PDO::getAvailableDrivers());'

echo
echo "===== ESTADO DOS SERVICOS ====="
systemctl --no-pager --full status nginx | head -8
systemctl --no-pager --full status "php${PHP_VERSION}-fpm" | head -8

echo
echo "===== HTTP LOCAL ====="
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
    -H "Host: $DOMAIN" http://127.0.0.1/ || true

echo
echo "=========================================================="
echo "INSTALACAO CONCLUIDA"
echo "=========================================================="
echo "Dominio:       $DOMAIN"
echo "Site:          $INSTALL_DIR"
echo "dominio.txt:   $INSTALL_DIR/dominio.txt"
echo "PHP:           $PHP_VERSION"
echo "SQLite:        $DB_PATH"
echo "Log PHP:       $PHP_LOG"
echo "Log Nginx:     /var/log/nginx/painel-error.log"
echo "ZIP preservado: $ZIP_FILE"
[[ -z "$BACKUP_DIR" ]] || echo "Backup:        $BACKUP_DIR"
[[ -z "$OLD_SITE" ]] || echo "Site anterior: $OLD_SITE"
[[ -z "$NGINX_BACKUP" ]] || echo "Backup Nginx:  $NGINX_BACKUP"
echo
echo "Se houver erro:"
echo "tail -n 100 /var/log/nginx/painel-error.log"
echo "tail -n 100 /var/log/php-errors.log"
echo "=========================================================="
INSTALLER

chmod 700 /root/instalar-painel.sh
bash -n /root/instalar-painel.sh && echo "Instalador validado: sintaxe Bash OK."
