#!/bin/bash

# Set strict error handling
set -euo pipefail
IFS=$'\n\t'

# --- Constants ---
readonly VERSION="1.1.0" # Script version
readonly SCRIPT_NAME=$(basename "$0") # Name of the script
readonly LOCK_FILE="/tmp/godot_installer.lock" # Lock file to prevent multiple instances

# XDG Base Directory paths (standardized paths for user files)
readonly XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
readonly XDG_BIN_HOME="${XDG_BIN_HOME:-$HOME/.local/bin}"
readonly XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# Application paths (where Godot and its related files will be stored)
readonly BIN_DIR="$XDG_BIN_HOME" # Directory for executables (e.g., symlink to Godot)
readonly GODOT_BASE="$XDG_DATA_HOME/godot" # Base directory for Godot installations
readonly DESKTOP_DIR="$XDG_DATA_HOME/applications" # Directory for desktop entry files
readonly ICON_PATH="$XDG_DATA_HOME/icons/godot.svg" # Path for the Godot icon
readonly INSTALLER_PATH="$BIN_DIR/godot_installer.sh" # Path where this installer script will be copied

# GitHub API and download settings
readonly GITHUB_API="https://api.github.com/repos/godotengine/godot" # Godot GitHub API endpoint
readonly WGET_OPTS=(-q --retry-connrefused --tries=3 --timeout=15) # Options for wget for silent, retrying downloads
readonly REQUIRED_COMMANDS=(wget unzip ln grep sed cut head mktemp uname sha512sum) # Essential commands needed for the script to run

# Cleanup arrays for temporary files and directories
declare -a _CLEANUP_DIRS=() # Directories to clean up on exit
declare -a _CLEANUP_FILES=() # Files to clean up on exit

# --- Helper Functions ---
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        error "Another instance of the installer is running" # Prevents multiple instances from running concurrently
    fi
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" # Logs messages with a timestamp
}

error() {
    log "ERROR: $*" >&2 # Logs an error message and exits the script
    exit 1
}

cleanup() {
    local exit_code=$?
    for dir in "${_CLEANUP_DIRS[@]}"; do
        [[ -d "$dir" ]] && rm -rf "$dir" # Removes temporary directories
    done
    for file in "${_CLEANUP_FILES[@]}"; do
        [[ -f "$file" ]] && rm -f "$file" # Removes temporary files
    done
    exit "$exit_code"
}

show_help() {
    cat << EOF
Godot Engine Installer v${VERSION}

Usage: 
    $SCRIPT_NAME [COMMAND] [VERSION]

Commands:
    install [VERSION]   Install Godot (latest if no version specified)
    uninstall          Remove Godot installation
    clean              Remove old versions except current
    list               Show available versions
    help               Show this help message

Examples:
    $SCRIPT_NAME install         # Install latest version
    $SCRIPT_NAME install 4.4.1   # Install specific version
    $SCRIPT_NAME list           # Show available versions
EOF
}

# --- Core Functions ---
get_architecture() {
    local arch
    arch=$(uname -m) # Gets the system's architecture (e.g., x86_64, aarch64)
    case "$arch" in
        x86_64|amd64)    echo "x86_64" ;;
        aarch64|arm64)    echo "arm64" ;;
        armv7*|armv8l)   echo "arm32" ;;
        i386|i686)       echo "x86_32" ;;
        *)               error "Unsupported architecture: $arch" ;;
    esac
}

validate_version() {
    local version="$1"
    # Validates the version format (e.g., 4.0.0, 4.1)
    if [[ -n "$version" ]] && ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        error "Invalid version format: $version (expected X.Y[.Z])"
    fi
}

get_download_url() {
    local version="$1"
    local arch="$2"
    local url_pattern="Godot_v%s-stable_linux.%s.zip" # Expected filename pattern for Godot downloads
    local actual_version
    
    if [[ -z "$version" ]]; then
        # Fetches the latest stable version from GitHub if no version is specified
        actual_version=$(wget "${WGET_OPTS[@]}" -O- "${GITHUB_API}/releases/latest" \
            | grep "tag_name" \
            | cut -d '"' -f 4 \
            | grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?")
        version="$actual_version"  # Store the actual version
    fi
    
    local download_url
    # Fetches the download URL for the specified version and architecture from GitHub
    download_url=$(wget "${WGET_OPTS[@]}" -O- "${GITHUB_API}/releases/tags/${version}-stable" \
        | grep "browser_download_url" \
        | grep -F "$(printf "$url_pattern" "$version" "$arch")" \
        | cut -d '"' -f 4 \
        | head -n 1)
    
    if [[ -z "$download_url" ]]; then
        # Fallback for some architectures (e.g., arm32 tries arm64, x86_32 tries x86_64)
        case "$arch" in
            "arm32") get_download_url "$version" "arm64" ;;
            "x86_32") get_download_url "$version" "x86_64" ;;
            *) error "No download found for version $version and architecture $arch" ;;
        esac
    else
        # Returns both URL and the actual version found
        echo "$download_url|$version"
    fi
}

verify_download() {
    local file="$1"
    local version="$2"
    local arch="$3"
    local filename="${file##*/}"
  
    # Ensure we grep against the right name:
    local real_filename="$filename"
    # Point to the GitHub “SHA512-SUMS.txt” asset for this version:
    local sums_url="https://github.com/godotengine/godot/releases/download/${version}-stable/SHA512-SUMS.txt"
    
    log "Verifying download: $filename (version: ${version:-latest})"

    # Get the actual filename from download URL to match checksums
    log "Fetching checksums from: $sums_url"
    
    # Get checksum data from the official Godot GitHub releases to verify integrity
    local expected_hash
    expected_hash=$(wget "${WGET_OPTS[@]}" -O- "$sums_url" | grep "$real_filename" | cut -d' ' -f1)
    
    if [[ -z "$expected_hash" ]]; then
        log "ERROR: Could not find hash for $real_filename"
        log "Available files in checksum:"
        wget "${WGET_OPTS[@]}" -O- "$sums_url" | cut -d' ' -f2- | sort
        error "Could not find SHA512 hash for $real_filename"
    fi
    
    log "Computing hash of downloaded file..."
    local actual_hash
    actual_hash=$(sha512sum "$file" | cut -d' ' -f1) # Computes the SHA512 hash of the downloaded file
    
    if [[ "$expected_hash" != "$actual_hash" ]]; then
        log "Hash verification failed!"
        log "Expected: $expected_hash"
        log "Got:      $actual_hash"
        error "SHA512 verification failed for $file" # Compares computed hash with expected hash to ensure file integrity
    fi
    
    log "SHA512 verification passed"
}

download_with_retry() {
    local url="$1"
    local output_dir="$2"
    local filename="${url##*/}"
    local output_file="$output_dir/$filename"
    local max_retries=3
    local retry_delay=5
    local attempt=1
    
    while [[ $attempt -le $max_retries ]]; do
        # Attempts to download the file with retries on failure
        if wget "${WGET_OPTS[@]}" --show-progress -O "$output_file" "$url"; then
            echo "$output_file"
            return 0
        fi
        log "Download failed (attempt $attempt/$max_retries). Retrying in ${retry_delay}s..."
        sleep "$retry_delay"
        ((attempt++))
    done
    return 1
}

install_godot() {
    local version="$1"
    validate_version "$version"
    
    local arch
    arch=$(get_architecture)
    local download_info
    download_info=$(get_download_url "$version" "$arch")
    
    # Split download_info into URL and version
    local download_url actual_version
    IFS='|' read -r download_url actual_version <<< "$download_info"
    
    log "Setting up Godot ${actual_version} for $arch..."
    
    # Check if version is already installed
    local install_dir="$GODOT_BASE/${actual_version}"
    if [[ -d "$install_dir" ]]; then
        log "Godot ${actual_version} is already installed"
        local godot_bin
        godot_bin=$(find "$install_dir" -type f -name 'Godot*' -executable)
        if [[ -n "$godot_bin" ]]; then
            log "Creating symlink to existing installation"
            rm -f "$BIN_DIR/godot"
            ln -s "$godot_bin" "$BIN_DIR/godot" # Creates a symbolic link to the Godot executable in the user's bin directory
            # Update desktop integration after symlink is created
            create_desktop_entry "$actual_version"
            download_icon
            log "Godot $actual_version linked successfully"
            return 0
        fi
    fi
    
    # If not installed, proceed with download and installation
    log "Installing Godot ${actual_version}..."
    
    local tmp_dir
    tmp_dir=$(mktemp -d) # Creates a temporary directory for download and extraction
    _CLEANUP_DIRS+=("$tmp_dir")
    
    local downloaded_file
    downloaded_file=$(download_with_retry "$download_url" "$tmp_dir")
    
    verify_download "$downloaded_file" "$actual_version" "$arch"
    
    mkdir -p "$install_dir" # Creates the installation directory for the specific Godot version
    
    (cd "$tmp_dir" && unzip -q "$downloaded_file") # Unzips the downloaded Godot archive
    local godot_bin
    godot_bin=$(find "$tmp_dir" -type f -name 'Godot*' -executable)
    mv "$godot_bin" "$install_dir/" # Moves the Godot executable to its final installation directory
    chmod +x "$install_dir/$(basename "$godot_bin")" # Makes the Godot executable runnable
    
    rm -f "$BIN_DIR/godot"
    ln -s "$install_dir/$(basename "$godot_bin")" "$BIN_DIR/godot" # Creates a symbolic link in the user's bin for easy access

    # Update desktop integration after new installation
    create_desktop_entry "$actual_version"
    download_icon
    
    log "Godot $actual_version installed successfully"
}

uninstall_godot() {
    local version="$1"

    if [[ -z "$version" ]]; then
        log "Uninstalling all Godot versions..."
        # Remove all Godot installation directories if the base directory exists
        if [[ -d "$GODOT_BASE" ]]; then
            rm -rf "$GODOT_BASE"
            log "Removed all Godot installations from $GODOT_BASE"
        fi
    else
        log "Uninstalling Godot version: $version..."
        local install_dir="$GODOT_BASE/$version"
        # Check if the specific version's directory exists before attempting to remove it
        if [[ ! -d "$install_dir" ]]; then
            error "Godot version $version not found at $install_dir"
        fi
        rm -rf "$install_dir" # Removes the specified Godot version directory
        log "Removed Godot version $version"

        # Check if the uninstalled version was the one currently symlinked as 'godot'
        local current_linked_version
        current_linked_version=$(readlink -f "$BIN_DIR/godot" | sed -n 's|.*/godot/\([0-9.]\+\)/.*|\1|p')
        if [[ "$current_linked_version" == "$version" ]]; then
            log "The uninstalled version was the currently linked 'godot' executable."
            log "Removing the symlink from $BIN_DIR/godot. You may need to link a new version manually."
            rm -f "$BIN_DIR/godot" # Removes the symlink if it pointed to the uninstalled version
        fi
    fi

    # Remove general Godot related files (symlink, installer script, desktop entry, icon)
    # These removals happen regardless of whether a specific version was targeted or all.
    # Only remove the main 'godot' symlink if no other Godot versions are present in the base directory
    if [[ -f "$BIN_DIR/godot" && ! -d "$GODOT_BASE" ]]; then
        log "Removing symlink $BIN_DIR/godot (no other Godot versions found)."
        rm -f "$BIN_DIR/godot"
    fi

    if [[ -f "$INSTALLER_PATH" ]]; then
        log "Removing installer script: $INSTALLER_PATH"
        rm -f "$INSTALLER_PATH" # Removes the installer script itself
    fi

    if [[ -f "$DESKTOP_DIR/godot.desktop" ]]; then
        log "Removing desktop entry: $DESKTOP_DIR/godot.desktop"
        rm -f "$DESKTOP_DIR/godot.desktop" # Removes the desktop entry file
    fi

    if [[ -f "$ICON_PATH" ]]; then
        log "Removing icon: $ICON_PATH"
        rm -f "$ICON_PATH" # Removes the Godot icon
    fi

    log "Godot uninstallation process completed."
    log "Note: Your Godot projects and user data have not been removed."
}

clean_old_versions() {
    local current_version
    # Determines the currently linked Godot version
    current_version=$(readlink -f "$BIN_DIR/godot" | sed -n 's|.*/godot/\([0-9.]\+\)/.*|\1|p')
    
    if [[ -n "$current_version" ]]; then
        log "Current version: $current_version"
        for dir in "$GODOT_BASE"/*; do
            if [[ -d "$dir" && "$(basename "$dir")" != "$current_version" ]]; then
                log "Removing old version: $(basename "$dir")"
                rm -rf "$dir" # Removes older Godot installations, keeping only the current one
            fi
        done
    fi
}

# Add after the install_godot function
create_desktop_entry() {
    local version="$1"
    
    # Remove existing desktop entry if it exists
    rm -f "$DESKTOP_DIR/godot.desktop"
    # check if it still exists even after removing
    if [[ -f "$DESKTOP_DIR/godot.desktop" ]]; then
        error "Failed to remove existing desktop entry"
    fi

    # Creates a desktop entry file for Godot, allowing it to appear in application menus
    cat > "$DESKTOP_DIR/godot.desktop" << EOF
[Desktop Entry]
Comment=An open source game engine
Exec=$BIN_DIR/godot
Icon=$ICON_PATH
Name=Godot Engine - $version
Type=Application
Categories=Development;Game;
MimeType=application/x-godot-project;
Actions=update_godot;open_docs;

[Desktop Action update_godot]
Name=Update Godot
Exec=$INSTALLER_PATH install

[Desktop Action open_docs]
Name=Open Documentation
Exec=xdg-open https://docs.godotengine.org/
EOF
}

download_icon() {
    # Downloads the official Godot icon for the desktop entry
    wget "${WGET_OPTS[@]}" -O "$ICON_PATH" \
        "https://raw.githubusercontent.com/godotengine/godot/master/icon.svg"
}

# --- Main Script ---
main() {
    trap cleanup EXIT # Ensures cleanup function runs on script exit
    acquire_lock # Acquires a lock to prevent multiple instances
    
    case "${1:-help}" in
        "install")
            install_godot "${2:-}"
            ;;
        "uninstall")
            uninstall_godot
            ;;
        "clean")
            clean_old_versions
            ;;
        "list")
            # Lists available Godot versions from the GitHub releases
            wget "${WGET_OPTS[@]}" -O- "${GITHUB_API}/releases" \
                | grep "tag_name" \
                | cut -d '"' -f 4 \
                | grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" \
                | sort -rV
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            error "Unknown command. Use '$SCRIPT_NAME help' for usage information"
            ;;
    esac
}

# Execute main function
main "$@" # Executes the main function with all provided arguments