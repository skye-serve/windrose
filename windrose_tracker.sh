#!/bin/bash

# --- CONFIGURATION ---
LOG_FILE="R5/Saved/Logs/R5.log"
MSG_ID_FILE="discord_message_id.txt"
LIST_FILE="current_players.tmp"
MAP_FILE="windrose_id_map.tmp"

BOT_NAME="Skye Serve Windrose Monitor"
BOT_LOGO="https://raw.githubusercontent.com/skye-serve/windrose/refs/heads/main/resized.png"

# --- GHOST KILLER ---
for pid in $(pgrep -f windrose_tracker.sh); do
    if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
        kill -9 "$pid" 2>/dev/null
    fi
done

# CLEAN RESET
rm -f "payload.json"
> "$LIST_FILE" 
touch "$MAP_FILE"

echo "--- Stable Windrose Tracker Started: $(date) ---" > tracker_debug.log

# ========================================================
# --- SHUTDOWN INTERCEPTOR (The Fix) ---
# ========================================================
send_offline() {
    echo "[SHUTDOWN] Kill signal received! Updating Discord..." >> tracker_debug.log
    CUR_TIME=$(date +'%T')
    CLEAN_SNAME=$(echo "${SERVER_NAME:-Windrose Server}" | tr -d '"' | tr -dc '[:print:]')
    
    cat <<EOF > payload.json
{
  "username": "$BOT_NAME",
  "avatar_url": "$BOT_LOGO",
  "embeds": [{
    "title": "🎮 Windrose Live Server Status",
    "color": 15548997, 
    "fields": [
      {"name": "Server Name", "value": "$CLEAN_SNAME", "inline": false},
      {"name": "Status", "value": "🔴 Offline / Restarting", "inline": true},
      {"name": "Current Players", "value": "0", "inline": true},
      {"name": "Online Players", "value": "\`\`\`\nServer is currently offline\n\`\`\`", "inline": false}
    ],
    "footer": {"text": "Last Updated: $CUR_TIME | Skye Serve"}
  }]
}
EOF
    if [ -s "$MSG_ID_FILE" ]; then
        MESSAGE_ID=$(cat "$MSG_ID_FILE")
        curl -s -o /dev/null -X PATCH -H "Content-Type: application/json" -d @payload.json "${DISCORD_WEBHOOK}/messages/${MESSAGE_ID}"
    fi
    exit 0
}

# 🚨 This tells Linux: "If you receive a Kill signal or Exit, run 'send_offline' instantly!"
trap send_offline SIGTERM SIGINT
# ========================================================


# Windrose specific ID mapping
update_mapping() {
    local raw_line="$1"
    if [[ "$raw_line" == *"ServerAccount."*"AccountName"* ]]; then
        local t_name=$(echo "$raw_line" | sed -n "s/.*AccountName '\([^']*\)'.*/\1/p")
        local t_id=$(echo "$raw_line" | sed -n "s/.*AccountId \([A-F0-9]*\)\..*/\1/p")
        
        if [ -n "$t_name" ] && [ -n "$t_id" ]; then
            grep -vx "^$t_id:.*" "$MAP_FILE" > "${MAP_FILE}.new" 2>/dev/null
            mv "${MAP_FILE}.new" "$MAP_FILE" 2>/dev/null
            echo "$t_id:$t_name" >> "$MAP_FILE"
        fi
    fi
}

# PRE-SCAN existing logs to map IDs
while read -r line; do update_mapping "$line"; done < "$LOG_FILE"

# --- Background Listener ---
tail -F -n 0 "$LOG_FILE" 2>/dev/null | while read -r line; do
    update_mapping "$line"

    # Trigger: Player Joins
    if [[ "$line" == *"Join succeeded:"* ]]; then
        NAME=$(echo "$line" | sed 's/.*Join succeeded: //' | tr -d '\r\n' | tr -d '"' | tr -d "'" | xargs)
        if [ -n "$NAME" ] && ! grep -qx "$NAME" "$LIST_FILE"; then
            echo "$NAME" >> "$LIST_FILE"
        fi
    fi

    # Trigger: Player Leaves
    if [[ "$line" == *"Account was disconnected. AccountId"* ]]; then
        LEAVE_ID=$(echo "$line" | sed -n 's/.*AccountId \([A-F0-9]*\)\..*/\1/p')
        if [ -n "$LEAVE_ID" ]; then
            P_NAME=$(grep "^$LEAVE_ID:" "$MAP_FILE" | cut -d':' -f2 | tail -n 1 | tr -d '\r\n' | xargs)
            if [ -n "$P_NAME" ]; then
                grep -vx "$P_NAME" "$LIST_FILE" > "${LIST_FILE}.new" && mv "${LIST_FILE}.new" "$LIST_FILE"
                if grep -qx "$P_NAME" "$LIST_FILE"; then sed -i "/$P_NAME/d" "$LIST_FILE"; fi
            else
                ONLINE_COUNT=$(grep -c "[^[:space:]]" "$LIST_FILE")
                if [ "$ONLINE_COUNT" -le 1 ]; then > "$LIST_FILE"; fi
            fi
        fi
    fi
done &

# --- Main Discord Loop ---
while true; do
    CUR_TIME=$(date +'%T')
    CLEAN_SNAME=$(echo "${SERVER_NAME:-Windrose Server}" | tr -d '"' | tr -dc '[:print:]')

    # NORMAL ONLINE LOOP
    PLAYERS=$(grep -c "[^[:space:]]" "$LIST_FILE" | awk '{print $1}')
    [ -z "$PLAYERS" ] && PLAYERS=0

    if [ "$PLAYERS" -eq 0 ]; then
        FINAL_LIST="None online"
    else
        FINAL_LIST=$(sed '/^$/d' "$LIST_FILE" | tr -d '"' | paste -sd ',' - | sed 's/,/\\n/g')
    fi

    cat <<EOF > payload.json
{
  "username": "$BOT_NAME",
  "avatar_url": "$BOT_LOGO",
  "embeds": [{
    "title": "🎮 Windrose Live Server Status",
    "color": 5763719,
    "fields": [
      {"name": "Server Name", "value": "$CLEAN_SNAME", "inline": false},
      {"name": "Status", "value": "🟢 Online", "inline": true},
      {"name": "Current Players", "value": "$PLAYERS", "inline": true},
      {"name": "Online Players", "value": "\`\`\`\n$FINAL_LIST\n\`\`\`", "inline": false}
    ],
    "footer": {"text": "Last Updated: $CUR_TIME | Skye Serve"}
  }]
}
EOF

    if [ ! -s "$MSG_ID_FILE" ]; then
        RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d @payload.json "${DISCORD_WEBHOOK}?wait=true")
        NEW_ID=$(echo "$RESPONSE" | grep -o '"id":"[0-9]*"' | head -n 1 | cut -d'"' -f4)
        if [[ "$NEW_ID" =~ ^[0-9]+$ ]]; then echo "$NEW_ID" > "$MSG_ID_FILE"; fi
    else
        MESSAGE_ID=$(cat "$MSG_ID_FILE")
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH -H "Content-Type: application/json" -d @payload.json "${DISCORD_WEBHOOK}/messages/${MESSAGE_ID}")
        [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ] && rm -f "$MSG_ID_FILE"
    fi

    # Run sleep in the background and wait. This allows the 'trap' to instantly interrupt it!
    sleep 5 &
    wait $!
done
