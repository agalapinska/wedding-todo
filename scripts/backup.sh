#!/bin/bash
# Kopia zapasowa listy zadań + samonaprawa magazynu.
# Uruchamiany cyklicznie: pobiera dane z jsonblob i zapisuje je w repo.
# Gdy blob zniknie (404), tworzy nowy, zasiewa go ostatnią kopią
# i podmienia BLOB_ID w index.html.
set -euo pipefail

REPO="https://github.com/agalapinska/wedding-todo"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git clone --quiet --depth 1 "$REPO" "$TMP/repo"
cd "$TMP/repo"
mkdir -p backup

BLOB_ID=$(sed -n "s/.*var BLOB_ID = '\([^']*\)'.*/\1/p" index.html | head -1)
if [ -z "$BLOB_ID" ]; then echo "BLOB_ID nie znaleziony w index.html"; exit 1; fi

DATA=$(curl -sf "https://jsonblob.com/api/jsonBlob/$BLOB_ID" || true)

valid_json() {
  echo "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d.get("tasks"),list) and isinstance(d.get("tags"),list)' 2>/dev/null
}

if [ -n "$DATA" ] && valid_json "$DATA"; then
  # magazyn żyje — zapisz kopię, jeśli coś się zmieniło
  echo "$DATA" | python3 -m json.tool > backup/tasks.json.new
  if ! cmp -s backup/tasks.json.new backup/tasks.json 2>/dev/null; then
    mv backup/tasks.json.new backup/tasks.json
    git add backup/tasks.json
    git -c user.name="backup-bot" -c user.email="backup@wedding-todo" commit -qm "backup: $(date '+%Y-%m-%d %H:%M')"
    git push -q
    echo "kopia zaktualizowana"
  else
    rm backup/tasks.json.new
    echo "bez zmian"
  fi
else
  # magazyn padł — samonaprawa z ostatniej kopii
  SEED='{"tasks":[],"tags":[]}'
  if [ -f backup/tasks.json ]; then SEED=$(cat backup/tasks.json); fi
  NEW_ID=$(curl -s -D - -o /dev/null -X POST https://jsonblob.com/api/jsonBlob \
    -H "Content-Type: application/json" --data-binary "$SEED" \
    | grep -i '^location' | sed 's#.*/##' | tr -d '\r\n')
  if [ -z "$NEW_ID" ]; then echo "nie udało się utworzyć nowego bloba"; exit 1; fi
  sed -i '' "s/var BLOB_ID = '[^']*'/var BLOB_ID = '$NEW_ID'/" index.html
  git add index.html
  git -c user.name="backup-bot" -c user.email="backup@wedding-todo" commit -qm "samonaprawa: nowy magazyn $NEW_ID"
  git push -q
  echo "magazyn odtworzony: $NEW_ID"
fi
