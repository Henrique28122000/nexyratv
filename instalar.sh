#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

# ==========================================================
# NEXYRA PANEL + BUILD APK - INSTALADOR INTEGRADO
# Ubuntu 22.04 / 24.04
# NGINX + PHP-FPM + SQLITE + PYTHON + SSL + ANDROID BUILD TOOLS
# ==========================================================

ZIP_URL="https://www.dropbox.com/scl/fi/6b7b0iyky4bffle14xo49/script_completo.zip?rlkey=2t3a3c9z41xz2138ru1pjipjy&st=a1melg5s&dl=1"

INSTALL_DIR="/var/www/painel"
TMP_DIR="/tmp/instalador-site"
ZIP_FILE="$TMP_DIR/site.zip"
NGINX_CONF="/etc/nginx/sites-available/painel"
NGINX_LINK="/etc/nginx/sites-enabled/painel"
DB_REL=".nexyra-p2p/panel.sqlite"

GEN="$INSTALL_DIR/nexyra/gerador"
SIGN="$INSTALL_DIR/nexyra-apk-signing"
OUT="$GEN/generated"
BUILD="$GEN/build.py"
PATCH="$GEN/configurar_apk.py"
BASE="$GEN/NEXYRA-TV-P2P-BASE.apk"
DOMAIN_FILE="$INSTALL_DIR/dominio.txt"
LOG="/var/log/nexyra-build-setup.log"

trap 'echo; echo "[ERRO] Falha na linha $LINENO. Consulte também: $LOG"' ERR

if [[ "$EUID" -ne 0 ]]; then
    echo "Execute como root."
    exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "Este instalador requer Ubuntu."
    exit 1
fi

# ==========================================================
# FUNÇÕES REUTILIZÁVEIS
# ==========================================================

install_base_dependencies() {
    echo
    echo "[deps] Instalando dependências base (painel + build)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        ca-certificates curl wget unzip zip file \
        coreutils util-linux \
        nginx sqlite3 \
        python3 python3-pip python3-venv \
        php-fpm php-cli php-common \
        php-curl php-mbstring php-xml php-zip \
        php-mysql php-gd php-intl php-bcmath php-sqlite3 \
        certbot python3-certbot-nginx
}

configure_sqlite_and_permissions() {
    echo
    echo "[sqlite] Configurando SQLite e permissões..."

    local CONFIG_PHP="$INSTALL_DIR/config/config.php"

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

    local BUILD_PY="$INSTALL_DIR/nexyra/gerador/build.py"

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

    local WRITABLE_DIR
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
}

configure_nginx_php() {
    local DOMAIN="$1"
    echo
    echo "[nginx] Configurando Nginx e PHP-FPM..."

    local PHP_VERSION
    PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
    local PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"

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
    rm -f /etc/nginx/sites-enabled/default

    systemctl enable nginx "$PHP_FPM_SERVICE"
    systemctl restart "$PHP_FPM_SERVICE"

    nginx -t
    systemctl reload nginx

    # ==========================================================
    # INJEÇÃO DO .HTACCESS PARA A API (SEM .PHP)
    # ==========================================================
    echo "[api] Criando regra de roteamento limpo (.htaccess) para a API..."
    local API_DIR="$INSTALL_DIR/api"
    if [[ -d "$API_DIR" ]]; then
        cat > "$API_DIR/.htaccess" <<'HTACCESS'
<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteBase /api/
    
    # Se o arquivo .php existir, reescreve internamente
    RewriteCond %{REQUEST_FILENAME}.php -f
    RewriteRule ^(.*)$ $1.php [L,QSA]

    # Opcional: Redireciona 301 se o usuário digitar o .php na URL
    RewriteCond %{THE_REQUEST} \s/+(.+?)\.php[\s?] [NC]
    RewriteRule ^ /%1 [R=301,L]
</IfModule>
HTACCESS
        chown root:www-data "$API_DIR/.htaccess"
        chmod 640 "$API_DIR/.htaccess"
        echo "Regra da API aplicada com sucesso."
    else
        echo "AVISO: pasta $API_DIR não encontrada. Pulando regra da API."
    fi
}

# ----------------------------------------------------------
# Preparação/Reparação do build APK (equivalente ao 2º script)
# ----------------------------------------------------------
setup_apk_build() {
    echo
    echo "=================================================="
    echo " NEXYRA - PREPARAÇÃO/REPARO DO BUILD APK"
    echo "=================================================="

    # Redireciona o log a partir daqui, sem afetar o restante do instalador.
    exec > >(tee -a "$LOG") 2>&1

    echo
    echo "[apk 1/9] Verificando dependências Python..."
    apt-get install -y \
        python3 python3-venv python3-pip \
        ca-certificates unzip zip coreutils util-linux \
        file curl wget >/dev/null

    echo
    echo "[apk 2/9] Conferindo arquivos essenciais..."
    local f
    for f in "$BUILD" "$PATCH" "$BASE" "$DOMAIN_FILE" \
             "$SIGN/signing.password" "$SIGN/P2P.keystore"; do
        if [ ! -f "$f" ]; then
            echo "FALTA ARQUIVO: $f"
            echo "Nenhum arquivo de assinatura foi criado ou substituido."
            exit 1
        fi
    done
    echo "Arquivos essenciais encontrados."

    echo
    echo "[apk 3/9] Verificando bibliotecas Python..."
    python3 - <<'PY'
import argparse, datetime, fcntl, json, os, pathlib, re, shutil
import stat, subprocess, sys, tempfile, unicodedata
import urllib.parse, urllib.request, zipfile
from zoneinfo import ZoneInfo
print("OK: bibliotecas Python disponíveis.")
print("Python:", sys.version.split()[0])
PY

    echo
    echo "[apk 4/9] Preparando permissões do gerador..."
    chown root:www-data "$INSTALL_DIR"
    chmod 750 "$INSTALL_DIR"

    chown root:www-data "$INSTALL_DIR/nexyra"
    chmod 750 "$INSTALL_DIR/nexyra"

    chown www-data:www-data "$GEN"
    chmod 750 "$GEN"

    chown www-data:www-data "$OUT" 2>/dev/null || true
    install -d -o www-data -g www-data -m 700 "$OUT"

    echo
    echo "[apk 5/9] Preparando lock e pasta de assinatura..."
    touch "$GEN/build.lock"
    chown www-data:www-data "$GEN/build.lock"
    chmod 600 "$GEN/build.lock"

    chown www-data:www-data "$SIGN"
    chmod 700 "$SIGN"

    chown www-data:www-data \
        "$SIGN/signing.password" \
        "$SIGN/P2P.keystore"

    chmod 600 \
        "$SIGN/signing.password" \
        "$SIGN/P2P.keystore"

    echo "Permissões aplicadas."

    echo
    echo "[apk 6/9] Testando escrita como www-data..."
    runuser -u www-data -- python3 - "$GEN" "$OUT" <<'PY'
import pathlib, sys, tempfile

gen = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])

with tempfile.TemporaryDirectory(prefix="nexyra-permission-test-", dir=str(gen)):
    pass

with tempfile.NamedTemporaryFile(dir=str(out), prefix=".test-", delete=True):
    pass

print("OK: pasta temporária e saída permitem escrita.")
PY

    echo
    echo "[apk 7/9] Localizando ferramentas Android..."
    local TOOLS=""
    local base d

    for base in \
        /usr/lib/android-sdk/build-tools \
        /opt/android-sdk/build-tools \
        /opt/android-sdk-linux/build-tools \
        /root/Android/Sdk/build-tools \
        /home/binstream/Android/Sdk/build-tools \
        /usr/local/android-sdk/build-tools
    do
        if [ -d "$base" ]; then
            while IFS= read -r d; do
                if [ -x "$d/zipalign" ] && [ -x "$d/apksigner" ] && [ -x "$d/aapt" ]; then
                    TOOLS="$d"
                fi
            done < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V)
        fi
    done

    if command -v zipalign >/dev/null 2>&1 &&
       command -v apksigner >/dev/null 2>&1 &&
       command -v aapt >/dev/null 2>&1; then
        echo "OK: zipalign, apksigner e aapt já estão no PATH."
    elif [ -n "$TOOLS" ]; then
        echo "Ferramentas encontradas em: $TOOLS"
        local tool
        for tool in zipalign apksigner aapt; do
            ln -sfn "$TOOLS/$tool" "/usr/local/bin/$tool"
        done
        echo "Links criados em /usr/local/bin."
    else
        echo "ATENCAO: ferramentas Android nao encontradas."
        echo "Consultando pacotes disponíveis no Ubuntu..."
        apt-cache search android-sdk | head -40 || true
        echo
        echo "Não foi instalado um pacote Android presumindo um nome incorreto."
        echo "Será necessário instalar Android SDK Build Tools compatíveis."
    fi

    echo
    echo "[apk 8/9] Validando ferramentas e assinatura..."
    local tool
    for tool in zipalign apksigner aapt; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf '%s: %s\n' "$tool" "$(command -v "$tool")"
        else
            echo "PENDENTE: $tool"
        fi
    done

    echo
    echo "Verificando leitura dos arquivos de assinatura..."
    runuser -u www-data -- test -r "$SIGN/signing.password"
    runuser -u www-data -- test -r "$SIGN/P2P.keystore"
    echo "OK: www-data consegue ler os arquivos de assinatura."

    echo
    echo "[apk 9/9] Diagnóstico final..."
    echo "--- Recursos ---"
    free -h
    df -h "$INSTALL_DIR"

    echo
    echo "--- Permissões ---"
    stat -c '%A %U:%G %n' \
        "$GEN" "$GEN/build.lock" "$OUT" "$SIGN" \
        "$SIGN/signing.password" "$SIGN/P2P.keystore"

    echo
    echo "--- Testando sintaxe do build.py ---"
    python3 -m py_compile "$BUILD" "$PATCH"
    echo "OK: sintaxe Python válida."

    echo
    echo "--- Verificando comandos no ambiente do PHP ---"
    runuser -u www-data -- env PATH=/usr/local/bin:/usr/bin:/bin \
        sh -c 'command -v python3; command -v zipalign || true; command -v apksigner || true; command -v aapt || true'

    echo
    echo "=================================================="
    echo " PREPARAÇÃO DO BUILD APK CONCLUÍDA"
    echo " Log: $LOG"
    echo "=================================================="
    echo "Se alguma ferramenta Android estiver pendente, o build"
    echo "ainda não está pronto para gerar APK."

    # Restaura o redirecionamento padrão para o restante do instalador.
    exec > /dev/tty 2>&1 || true
}

uninstall_panel() {
    local CONFIRM
    echo
    echo "O painel será desativado e os arquivos serão guardados."
    read -r -p "Digite DESINSTALAR para confirmar: " CONFIRM
    [[ "$CONFIRM" == "DESINSTALAR" ]] || {
        echo "Cancelado."
        exit 0
    }

    local STAMP
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
}

# ==========================================================
# MENU
# ==========================================================

echo
echo "================================================"
echo "             NEXYRA PANEL + BUILD APK"
echo "================================================"
echo "  1) Instalar / reinstalar preservando o SQLite"
echo "  2) LIMPAR antes de reinstalar"
echo "  3) Apenas reparar/preparar o BUILD APK"
echo "  4) Desinstalar o painel"
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
        if [[ ! -d "$INSTALL_DIR" ]]; then
            echo "ERRO: $INSTALL_DIR nao existe. Instale o painel primeiro."
            exit 1
        fi
        mkdir -p "$(dirname "$LOG")"
        setup_apk_build
        exit 0
        ;;
    4)
        uninstall_panel
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
# 1. Dependências (painel + build)
# ----------------------------------------------------------
install_base_dependencies

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
# 4. Domínio e SSL
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
# 5. Backup e publicação
# ----------------------------------------------------------
echo
echo "[5/9] Backup e publicacao..."
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR=""
SAVED_DB="$TMP_DIR/preserved-panel.sqlite"
rm -f "$SAVED_DB"

if [[ "$PRESERVE_DB" == yes && -s "$INSTALL_DIR/$DB_REL" ]]; then
    cp "$INSTALL_DIR/$DB_REL" "$SAVED_DB"
fi

if [[ -d "$INSTALL_DIR" ]]; then
    BACKUP_DIR="${INSTALL_DIR}.backup.${STAMP}"
    mv "$INSTALL_DIR" "$BACKUP_DIR"
    echo "Backup: $BACKUP_DIR"
fi

mkdir -p "$(dirname "$INSTALL_DIR")"
cp -a "$SITE_ROOT" "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/.nexyra-p2p"

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
# 6. SQLite + permissões base
# ----------------------------------------------------------
echo
echo "[6/9] Configurando SQLite e permissoes base..."
configure_sqlite_and_permissions

# ----------------------------------------------------------
# 7. Nginx + PHP-FPM + Regra da API (.htaccess)
# ----------------------------------------------------------
echo
echo "[7/9] Configurando Nginx e PHP-FPM..."
configure_nginx_php "$DOMAIN"

# ----------------------------------------------------------
# 8. Testes + gerador Python + APK build setup
# ----------------------------------------------------------
echo
echo "[8/9] Testando SQLite, gerador e preparando build APK..."
runuser -u www-data -- test -w "$INSTALL_DIR/.nexyra-p2p" ||
    { echo "ERRO: pasta SQLite sem permissao de escrita."; exit 1; }

if [[ -f "$INSTALL_DIR/$DB_REL" ]]; then
    CHECK_RESULT="$(sqlite3 "$INSTALL_DIR/$DB_REL" 'PRAGMA quick_check;')"
    [[ "$CHECK_RESULT" == "ok" ]] ||
        { echo "ERRO: banco SQLite com problema: $CHECK_RESULT"; exit 1; }
fi

if [[ -f "$GEN/requirements.txt" ]]; then
    python3 -m venv "$GEN/venv"
    "$GEN/venv/bin/pip" install \
        --disable-pip-version-check \
        -r "$GEN/requirements.txt"
fi

# Prepara/repara o build APK (permissões, lock, assinatura, Android tools).
mkdir -p "$(dirname "$LOG")"
setup_apk_build

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
    echo "Quando estiver correto, execute: certbo
