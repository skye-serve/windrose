#!/bin/bash

# --- CONFIGURATION ---
# Replace with the actual path to your Windrose log file if different
LOG_FILE="R5/Saved/Logs/R5.log"
MSG_ID_FILE="discord_message_id.txt"
LIST_FILE="current_players.tmp"
MAP_FILE="windrose_id_map.tmp"
FLAG_FILE="shutdown.flag"

# --- BRANDING ---
BOT_NAME="${BOT_NAME:-Skye Serve Monitor}"
BOT_LOGO="${BOT_LOGO:-https://raw.githubusercontent.com/parkervcp/pterodactyl-images/master/logos/windrose.png}"

# --- GHOST KILLER ---
for pid in $(pgrep -f tracker.sh); do
    if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
        kill -9 "$pid" 2>/dev/null
    fi
done

# 1. CLEAN RESET (Retains Discord Message ID to update the same message!)
rm -f "payload.json"
rm -f "$FLAG_FILE"
> "$LIST_FILE" 
touch "$MAP_FILE"

echo "--- Stable Windrose Tracker Started: $(date) ---" > tracker_debug.log

# Windrose specific ID mapping!
update_mapping() {
    local raw_line="$1"
    # Catches: ServerAccount. AccountName 'John Windrose'. AccountId AEEEA5204C...
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
    
    # Trigger #1: UE5 Shutdown Catchers (Triggered by ^C / SIGINT)
    if [[ "$line" == *"Engine exit requested"* ]] || [[ "$line" == *"LogExit: Exiting"* ]] || [[ "$line" == *"PreExit Game"* ]]; then
        echo "[SHUTDOWN] Exit sequence detected! Flagging for Discord update..." >> tracker_debug.log
        touch "$FLAG_FILE"
        pkill -P $$ sleep 2>/dev/null
    fi

    update_mapping "$line"

    # Trigger #2: Player Joins
    # Catches: LogNet: Join succeeded: John Windrose
    if [[ "$line" == *"Join succeeded:"* ]]; then
        NAME=$(echo "$line" | sed 's/.*Join succeeded: //' | tr -d '\r\n' | tr -d '"' | tr -d "'" | xargs)
        if [ -n "$NAME" ] && ! grep -qx "$NAME" "$LIST_FILE"; then
            echo "$NAME" >> "$LIST_FILE"
        fi
    fi

    # Trigger #3: Player Leaves
    # Catches: Account was disconnected. AccountId E04D7E864221...
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
TAIL_PID=$!

# --- Main Discord Loop ---
while true; do
    CUR_TIME=$(date +'%T')
    CLEAN_SNAME=$(echo "${SERVER_NAME:-Windrose Server}" | tr -d '"' | tr -dc '[:print:]')

    # === SHUTDOWN TRIGGER ===
    if [ -f "$FLAG_FILE" ]; then
        
        # Update Discord to RED immediately
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
        
        echo "Discord updated. Handing off shutdown to Pterodactyl..." >> tracker_debug.log
        rm -f "$FLAG_FILE"
        exit 0
    fi
    # === END SHUTDOWN TRIGGER ===

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
      {"name": "Online Players", "value": "\`\`\`\\n$FINAL_LIST\\n\`\`\`", "inline": false}
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

    sleep 5
done
