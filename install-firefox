#!/bin/bash

INI_FILE="$HOME/.config/mozilla/firefox/profiles.ini"
BASE_DIR="$HOME/.config/mozilla/firefox"

# 1. Find the current active installation default path
ACTIVE_PATH=$(cat "$INI_FILE" | awk '/^\[Install/{flag=1;next} /^\[/{flag=0} flag' | grep '^Default=' | cut -d= -f2)

# 2. Extract profile names and their paths into arrays
mapfile -t PROFILES < <(cat "$INI_FILE" | grep -E '^Name=' | cut -d= -f2)
mapfile -t PATHS < <(cat "$INI_FILE" | grep -E '^Path=' | cut -d= -f2)

# 3. Format options dynamically (marking default)
OPTIONS=()
for i in "${!PROFILES[@]}"; do
    if [ "${PATHS[$i]}" = "$ACTIVE_PATH" ]; then
        OPTIONS+=("${PROFILES[$i]} [default]")
    else
        OPTIONS+=("${PROFILES[$i]}")
    fi
done

# 4. Display options on explicit new lines
echo "Select a Firefox profile:"
for i in "${!OPTIONS[@]}"; do
    echo "$((i+1))) ${OPTIONS[$i]}"
done

# Prompt loop using your PS3 prompt
while true; do
    read -rp "Please enter your choice (1-${#OPTIONS[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#OPTIONS[@]}" ]; then
        INDEX=$((choice-1))
        SELECTED_PROFILE="${PROFILES[$INDEX]}"
        SELECTED_PATH="${PATHS[$INDEX]}"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Build the absolute path to the target profile folder
PROFILE_DIR="$BASE_DIR/$SELECTED_PATH"

echo -e "\nSelected Profile: $SELECTED_PROFILE"
echo "Profile Directory: $PROFILE_DIR"

# Helper: fetch SOURCE (a URL or a local file path) into DEST.
# Local paths may start with ~ and may be wrapped in quotes (e.g. dragged into a terminal).
fetch_file() {
    local src="$1" dest="$2"

    # Trim surrounding whitespace, then one layer of surrounding quotes
    src="${src#"${src%%[![:space:]]*}"}"
    src="${src%"${src##*[![:space:]]}"}"
    src="${src#[\"\']}"
    src="${src%[\"\']}"

    if [[ "$src" =~ ^https?:// ]]; then
        echo "Downloading from: $src ..."
        if ! curl -fsSL -o "$dest" "$src"; then
            rm -f "$dest"
            echo "Error: download failed. Please verify the URL."
            return 1
        fi
    else
        # Expand a leading ~/ to the home directory
        if [[ "$src" == "~/"* ]]; then
            src="$HOME/${src:2}"
        fi
        if [ ! -f "$src" ]; then
            echo "Error: '$src' does not exist or is not a file."
            return 1
        fi
        echo "Copying from: $src ..."
        if ! cp "$src" "$dest"; then
            rm -f "$dest"
            echo "Error: could not copy the file."
            return 1
        fi
    fi
}

# 5. Ask for the user.js source (link or local file)
DEFAULT_URL="https://raw.githubusercontent.com/yokoffing/Betterfox/refs/heads/main/user.js"
echo -e "\nPress [ENTER] to use the default Betterfox user.js, or paste a raw GitHub link or a local file path (e.g. ~/Downloads/custom.js):"

# 6. Fetch it and install it as user.js (whatever the original file was called)
USERJS_TMP=$(mktemp)
while true; do
    read -rp "Link or path: " USERJS_SRC
    if [ -z "$USERJS_SRC" ]; then
        USERJS_SRC="$DEFAULT_URL"
        USING_DEFAULT=true
    else
        USING_DEFAULT=false
    fi

    if fetch_file "$USERJS_SRC" "$USERJS_TMP"; then
        install -m 644 "$USERJS_TMP" "$PROFILE_DIR/user.js"
        echo "Successfully installed user.js to $PROFILE_DIR/user.js"
        break
    elif $USING_DEFAULT; then
        echo "Error: Failed to fetch the default user.js. Please check your connection."
        rm -f "$USERJS_TMP"
        exit 1
    else
        echo "Please try again, or press [ENTER] to use the default."
    fi
done
rm -f "$USERJS_TMP"

# 7. Optionally install a userChrome.css
DEFAULT_CSS_URL="https://raw.githubusercontent.com/beats-beats/minimal-firefox-css/refs/heads/main/userChrome.css"
CSS_INSTALLED=false

echo
read -rp "Would you like to install a userChrome.css too? (Y/n): " css_choice
if [[ -z "$css_choice" || "$css_choice" =~ ^[Yy] ]]; then
    echo -e "\nPress [ENTER] to use the default userChrome.css, or paste a raw GitHub link or a local file path (e.g. ~/Downloads/mycss.css):"

    CSS_TMP=$(mktemp)
    while true; do
        read -rp "Link or path: " CSS_SRC
        if [ -z "$CSS_SRC" ]; then
            CSS_SRC="$DEFAULT_CSS_URL"
            USING_DEFAULT=true
        else
            USING_DEFAULT=false
        fi

        # Fetch to a temp file first so a failure never touches an existing userChrome.css
        if fetch_file "$CSS_SRC" "$CSS_TMP"; then
            # Create the chrome folder next to user.js
            CHROME_DIR="$PROFILE_DIR/chrome"
            mkdir -p "$CHROME_DIR"

            # Keep a backup of any existing userChrome.css
            if [ -f "$CHROME_DIR/userChrome.css" ]; then
                cp "$CHROME_DIR/userChrome.css" "$CHROME_DIR/userChrome.css.bak"
                echo "Existing userChrome.css backed up to $CHROME_DIR/userChrome.css.bak"
            fi

            install -m 644 "$CSS_TMP" "$CHROME_DIR/userChrome.css"
            echo "Successfully installed userChrome.css to $CHROME_DIR/userChrome.css"
            CSS_INSTALLED=true

            # Firefox ignores userChrome.css unless this pref is enabled
            if ! grep -qE '^\s*user_pref\("toolkit\.legacyUserProfileCustomizations\.stylesheets"' "$PROFILE_DIR/user.js"; then
                printf '\n// Enable userChrome.css\nuser_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);\n' >> "$PROFILE_DIR/user.js"
                echo "Enabled userChrome.css support in user.js"
            fi
            break
        elif $USING_DEFAULT; then
            echo "Error: Failed to fetch the default userChrome.css. Skipping it."
            break
        else
            echo "Please try again, or press [ENTER] to use the default."
        fi
    done
    rm -f "$CSS_TMP"
else
    echo "Skipping userChrome.css."
fi

# 8. Check if Firefox is running and prompt for a restart
if $CSS_INSTALLED; then
    APPLIED_MSG="user.js and userChrome.css"
else
    APPLIED_MSG="user.js"
fi

if pgrep -x "firefox" > /dev/null; then
    echo -e "\nFirefox is currently running."
    read -rp "Would you like to restart Firefox now to apply changes? (y/n): " restart_choice
    case "$restart_choice" in
        [Yy]* )
            echo "Closing Firefox..."
            pkill -x "firefox"
            sleep 2 # Let it cleanly unmount files
            echo "Reopening Firefox with profile '$SELECTED_PROFILE'..."
            firefox -P "$SELECTED_PROFILE" &
            ;;
        * )
            echo "Changes saved. Please manually restart Firefox later to apply the $APPLIED_MSG configurations."
            ;;
    esac
else
    # If not running, ask if they want to launch it
    read -rp "Firefox is closed. Launch it now with profile '$SELECTED_PROFILE'? (y/n): " launch_choice
    if [[ "$launch_choice" =~ ^[Yy]*$ ]]; then
        firefox -P "$SELECTED_PROFILE" &
    fi
fi
