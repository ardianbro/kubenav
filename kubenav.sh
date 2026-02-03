#!/usr/bin/env bash
# kubenav.sh - interactive kubeconfig/context/namespace/pod selector and shell

set -euo pipefail

BASE_DIR="$HOME/.kubenav"
KUBE_DIR="$BASE_DIR/kubeconfigs"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
## per-context namespace cache files stored in $BASE_DIR/namespaces/<context>

CONTEXT_MAP="$BASE_DIR/context_map"
CURRENT_SEL="$BASE_DIR/current"

add_context_mappings_for_file() {
  local file="$1"
  mkdir -p "$BASE_DIR"
  touch "$CONTEXT_MAP"
  local ctxs
  ctxs=$(kubectl --kubeconfig="$file" config get-contexts -o name 2>/dev/null || true)
  if [ -z "$ctxs" ]; then
    return
  fi
  # For each context found in the file, ensure a single mapping exists and update any previous mapping
  while IFS= read -r ctx; do
    [ -z "$ctx" ] && continue
    # Remove any existing mapping lines for this context (to avoid duplicates)
    if [ -f "$CONTEXT_MAP" ]; then
      awk -v C="$ctx" -F"\t" 'BEGIN{OFS=FS} $1!=C {print}' "$CONTEXT_MAP" > "$CONTEXT_MAP.tmp" || true
      mv "$CONTEXT_MAP.tmp" "$CONTEXT_MAP" 2>/dev/null || true
    fi
    # Append new mapping for this context -> file
    printf "%s\t%s\n" "$ctx" "$file" >> "$CONTEXT_MAP"
  done <<< "$ctxs"
  # Normalize map to ensure unique keys (last write wins)
  normalize_context_map
}

normalize_context_map() {
  # Rewrites CONTEXT_MAP keeping only the last mapping for each context
  if [ ! -f "$CONTEXT_MAP" ]; then
    return
  fi
  awk -F"\t" '{map[$1]=$2} END{for (k in map) print k "\t" map[k]}' "$CONTEXT_MAP" > "$CONTEXT_MAP.tmp" && mv "$CONTEXT_MAP.tmp" "$CONTEXT_MAP"
}

get_context_map_lines() {
  mkdir -p "$BASE_DIR"
  touch "$CONTEXT_MAP"
  cat "$CONTEXT_MAP" 2>/dev/null || true
}

rebuild_context_map() {
  mkdir -p "$BASE_DIR"
  # Preserve previous map to detect newly added contexts/files
  local prev_map="${CONTEXT_MAP}.prev"
  if [ -f "$CONTEXT_MAP" ]; then
    cp -f "$CONTEXT_MAP" "$prev_map" 2>/dev/null || true
  else
    : > "$prev_map"
  fi

  : > "$CONTEXT_MAP"
  # If running interactively, offer to prompt rename for all files (helps when users copy files manually)
  local prompt_all=0
  if [ -t 0 ]; then
    read -rp "Prompt to rename contexts for all imported kubeconfigs? [y/N]: " _ans
    case "${_ans:-N}" in
      y|Y) prompt_all=1 ;;
      *) prompt_all=0 ;;
    esac
  fi

  for f in "$KUBE_DIR"/*; do
    [ -f "$f" ] || continue
    # determine if this file is new compared to previous map
    local is_new=0
    # if the previous map does not reference this file path, treat as new
    if ! awk -F"\t" '{print $2}' "$prev_map" | grep -Fxq "$f" 2>/dev/null; then
      is_new=1
    else
      # fallback: if any context in this file wasn't previously listed, mark as new
      local file_ctxs
      file_ctxs=$(kubectl --kubeconfig="$f" config get-contexts -o name 2>/dev/null || true)
      if [ -n "$file_ctxs" ]; then
        while IFS= read -r c; do
          [ -z "$c" ] && continue
          if ! awk -F"\t" '{print $1}' "$prev_map" | grep -Fxq "$c" 2>/dev/null; then
            is_new=1
            break
          fi
        done <<< "$file_ctxs"
      fi
    fi
    # Also consider file new if its modification time is newer than prev_map (handles manual copy)
    if [ -f "$prev_map" ]; then
      # portable mtime: GNU stat vs BSD stat
      if stat -f "%m" "$prev_map" >/dev/null 2>&1; then
        prev_mtime=$(stat -f "%m" "$prev_map")
        file_mtime=$(stat -f "%m" "$f" 2>/dev/null || echo 0)
      else
        prev_mtime=$(stat -c "%Y" "$prev_map" 2>/dev/null || echo 0)
        file_mtime=$(stat -c "%Y" "$f" 2>/dev/null || echo 0)
      fi
      if [ -n "${file_mtime:-}" ] && [ -n "${prev_mtime:-}" ] && [ "$file_mtime" -gt "$prev_mtime" ]; then
        is_new=1
      fi
    fi
    add_context_mappings_for_file "$f"
    if [ "$prompt_all" -eq 1 ] || [ "$is_new" -eq 1 ]; then
      # Prompt user to rename contexts found in this file
      rename_contexts_prompt "$f"
    fi
  done
  rm -f "$prev_map" 2>/dev/null || true
}

save_current_selection() {
  # args: kubeconfig-file, context, namespace
  local file="$1" ctx="$2" ns="$3"
  mkdir -p "$BASE_DIR"
  cat > "$CURRENT_SEL" <<EOF
KUBECONFIG=$file
CONTEXT=$ctx
NAMESPACE=$ns
EOF
}

load_saved_selection() {
  if [ ! -f "$CURRENT_SEL" ]; then
    return 0
  fi
  # read items without sourcing arbitrary code
  local file ctx ns
  file=$(awk -F= '/^KUBECONFIG=/{sub(/^[^=]+=/,""); print}' "$CURRENT_SEL" || true)
  ctx=$(awk -F= '/^CONTEXT=/{sub(/^[^=]+=/,""); print}' "$CURRENT_SEL" || true)
  ns=$(awk -F= '/^NAMESPACE=/{sub(/^[^=]+=/,""); print}' "$CURRENT_SEL" || true)
  if [ -n "$file" ] && [ -f "$file" ]; then
    export KUBECONFIG="$file"
    if [ -n "$ctx" ]; then
      kubectl --kubeconfig="$file" config use-context "$ctx" 2>/dev/null || true
    fi
    if [ -n "$ns" ]; then
      kubectl --kubeconfig="$file" config set-context --current --namespace="$ns" 2>/dev/null || true
    fi
  fi
}

current_context() {
  kubectl config current-context 2>/dev/null || echo "no-context"
}

get_namespace_cache() {
  local ctx
  ctx=$(current_context)
  # sanitize context name for filename
  ctx=${ctx//[^A-Za-z0-9_.-]/_}
  mkdir -p "$BASE_DIR/namespaces"
  echo "$BASE_DIR/namespaces/$ctx"
}

add_namespace_to_cache() {
  local newns="$1"
  local cache
  cache=$(get_namespace_cache)
  touch "$cache"
  if [ -z "$newns" ]; then
    echo "No namespace provided"; return 1
  fi
  if ! grep -qxF "$newns" "$cache" 2>/dev/null; then
    echo "$newns" >> "$cache"
    echo "Added $newns to $cache"
  else
    echo "$newns already exists in $cache"
  fi
}

list_cached_namespaces() {
  local cache
  cache=$(get_namespace_cache)
  touch "$cache"
  grep -v '^#' "$cache" | sed '/^\s*$/d' || true
}

remove_namespace_from_cache() {
  # If a namespace is provided as $1, remove it; otherwise run interactive fzf to select entries to remove.
  local cache
  cache=$(get_namespace_cache)
  touch "$cache"
  if [ -n "${1:-}" ]; then
    local tgt="$1"
    # create a temp file with all lines except the target
    awk -v EX="${tgt}" 'BEGIN{RS="\n"; ORS="\n"} $0!=EX {print}' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
    echo "Removed $tgt from $cache"
    return 0
  fi

  # interactive removal via fzf (multi-select)
  cached=()
  while IFS= read -r line; do
    [ -n "$line" ] && cached+=("$line")
  done <<< "$(list_cached_namespaces)"
  if [ ${#cached[@]} -eq 0 ]; then
    echo "No cached namespaces to remove for current context."
    return 1
  fi

  local sel
  sel=$(printf "%s\n" "${cached[@]}" | fzf --multi --prompt="Select cached namespace(s) to remove: " --height=10 --border) || return 1
  if [ -z "$sel" ]; then echo "No selection"; return 1; fi

  # remove each selected line
  while IFS= read -r line; do
    awk -v EX="$line" 'BEGIN{RS="\n"; ORS="\n"} $0!=EX {print}' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
    echo "Removed $line"
  done <<< "$sel"
}

remove_context_and_config() {
  # Usage: remove_context_and_config [--dry-run] [-y|--yes] [context]
  local DRY_RUN=0
  local SKIP_CONFIRM=0
  local tgt_ctx=""
  mkdir -p "$BASE_DIR"
  touch "$CONTEXT_MAP"

  # parse args
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      -y|--yes) SKIP_CONFIRM=1; shift ;;
      --) shift; break ;;
      -*) echo "Unknown option: $1"; return 1 ;;
      *)
        if [ -z "$tgt_ctx" ]; then tgt_ctx="$1"; shift; else echo "Multiple contexts specified"; return 1; fi
        ;;
    esac
  done

  # If no context provided, prompt interactively
  if [ -z "$tgt_ctx" ]; then
    local lines
    lines=$(get_context_map_lines)
    if [ -z "$lines" ]; then
      echo "No contexts registered to remove."; return 1
    fi
    local menu
    while IFS=$'\t' read -r ctx file; do
      [ -z "$ctx" ] && continue
      menu+="$ctx ($file)\t$ctx\t$file\n"
    done <<< "$lines"
    local sel
    sel=$(printf "%b" "$menu" | fzf --with-nth=1 --prompt="Remove context: " --height=10 --border) || return 1
    tgt_ctx=$(awk -F"\t" '{print $2}' <<< "$sel")
    if [ -z "$tgt_ctx" ]; then echo "No context selected"; return 1; fi
  fi

  # locate kubeconfig file for this context
  local file
  file=$(awk -F"\t" -v C="$tgt_ctx" '$1==C{print $2; exit}' "$CONTEXT_MAP" 2>/dev/null || true)
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo "Context $tgt_ctx not found in context map; aborting."; return 1
  fi

  # Show planned actions
  echo "Planned actions for context: $tgt_ctx"
  echo " - kubeconfig: $file"
  echo " - will delete context entry from kubeconfig"
  echo " - will remove namespace cache: $BASE_DIR/namespaces/${tgt_ctx//[^A-Za-z0-9_.-]/_}"
  echo " - will clear saved selection if it references this context"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run; no changes will be made."; return 0
  fi

  if [ "$SKIP_CONFIRM" -ne 1 ]; then
    if [ -e /dev/tty ]; then
      read -r -p "Proceed with deletion? [y/N]: " ans </dev/tty || ans=""
    else
      read -r -p "Proceed with deletion? [y/N]: " ans || ans=""
    fi
    case "${ans:-N}" in
      y|Y) ;;
      *) echo "Aborted."; return 1 ;;
    esac
  fi

  # attempt to delete context from the file
  if kubectl --kubeconfig="$file" config delete-context "$tgt_ctx" 2>/dev/null; then
    echo "Deleted context $tgt_ctx from $file"
  else
    echo "Failed to delete context $tgt_ctx from $file (continuing with cleanup)"
  fi

  # If the kubeconfig file no longer contains any contexts, remove it — but only if it's inside KUBE_DIR
  local remaining
  remaining=$(kubectl --kubeconfig="$file" config get-contexts -o name 2>/dev/null || true)
  if [ -z "$remaining" ]; then
    case "$file" in
      "$KUBE_DIR"/*)
        rm -f "$file"
        echo "Removed empty kubeconfig file $file"
        # remove all map entries referencing this file
        awk -F"\t" -v OFS="\t" -v F="$file" '$2!=F {print}' "$CONTEXT_MAP" > "$CONTEXT_MAP.tmp" && mv "$CONTEXT_MAP.tmp" "$CONTEXT_MAP"
        ;;
      *)
        echo "Note: kubeconfig $file is outside $KUBE_DIR; not removing file automatically"
        # still remove mapping for this context
        awk -F"\t" -v OFS="\t" -v C="$tgt_ctx" '$1!=C {print}' "$CONTEXT_MAP" > "$CONTEXT_MAP.tmp" && mv "$CONTEXT_MAP.tmp" "$CONTEXT_MAP"
        ;;
    esac
  else
    # just remove mapping for this single context
    awk -F"\t" -v OFS="\t" -v C="$tgt_ctx" '$1!=C {print}' "$CONTEXT_MAP" > "$CONTEXT_MAP.tmp" && mv "$CONTEXT_MAP.tmp" "$CONTEXT_MAP"
  fi

  # Remove namespace cache for this context (sanitized name)
  local sanitized
  sanitized=${tgt_ctx//[^A-Za-z0-9_.-]/_}
  local nsfile="$BASE_DIR/namespaces/$sanitized"
  if [ -f "$nsfile" ]; then
    rm -f "$nsfile"
    echo "Removed namespace cache $nsfile"
  fi

  # Clear saved current selection if it refers to this context
  if [ -f "$CURRENT_SEL" ]; then
    local cur
    cur=$(awk -F= '/^CONTEXT=/{sub(/^[^=]+=/,"",$0); print $0}' "$CURRENT_SEL" 2>/dev/null || true)
    if [ "$cur" = "$tgt_ctx" ]; then
      rm -f "$CURRENT_SEL"
      echo "Cleared saved selection $CURRENT_SEL (was using $tgt_ctx)"
      # Unset KUBECONFIG so main_menu will rebuild the aggregated config
      unset KUBECONFIG
    fi
  fi

  # If current KUBECONFIG points to the removed file, unset it
  if [ -n "${KUBECONFIG:-}" ] && [ "$KUBECONFIG" = "$file" ]; then
    unset KUBECONFIG
    echo "Unset KUBECONFIG (was pointing to removed file)"
  fi

  normalize_context_map
}

ensure_dirs() {
  mkdir -p "$KUBE_DIR"
}

install_to_system() {
  # Try copying to /usr/local/bin; fall back to sudo if needed
  if cp -f "$SCRIPT" /usr/local/bin/kubenav 2>/dev/null; then
    chmod +x /usr/local/bin/kubenav || true
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo cp -f "$SCRIPT" /usr/local/bin/kubenav && sudo chmod +x /usr/local/bin/kubenav
    return $?
  fi
  return 1
}

install_to_user() {
  mkdir -p "$HOME/bin"
  cp -f "$SCRIPT" "$HOME/bin/kubenav"
  chmod +x "$HOME/bin/kubenav" || true
}

reinstall_script() {
  # Find where kubenav is currently installed and update it
  if ! command -v kubenav >/dev/null 2>&1; then
    echo "kubenav is not currently installed on PATH"
    read -rp "Install now? [Y/n]: " ans
    case "${ans:-Y}" in
      y|Y)
        auto_install_if_needed
        return
        ;;
      *)
        echo "Aborted"
        return 1
        ;;
    esac
  fi

  local installed_path source_choice
  installed_path=$(command -v kubenav)
  echo "Current installation: $installed_path"
  echo ""
  echo "Update from:"
  echo "  1) Local script ($SCRIPT)"
  echo "  2) GitHub (latest release)"
  read -rp "Choose source [1/2]: " source_choice

  case "$source_choice" in
    2)
      update_from_github "$installed_path"
      return $?
      ;;
    1)
      echo "Script location: $SCRIPT"
      read -rp "Update $installed_path with local version? [Y/n]: " ans
      ;;
    *)
      echo "Invalid choice"
      return 1
      ;;
  esac

  case "${ans:-Y}" in
    y|Y)
      ;;
    *)
      echo "Aborted"
      return 1
      ;;
  esac

  # Determine install location and update
  case "$installed_path" in
    /usr/local/bin/*)
      echo "Updating system installation..."
      if cp -f "$SCRIPT" "$installed_path" 2>/dev/null; then
        chmod +x "$installed_path" || true
        echo "Successfully updated $installed_path"
      elif command -v sudo >/dev/null 2>&1; then
        sudo cp -f "$SCRIPT" "$installed_path" && sudo chmod +x "$installed_path"
        echo "Successfully updated $installed_path"
      else
        echo "Failed to update $installed_path (no permission)"
        return 1
      fi
      ;;
    "$HOME"/bin/*)
      echo "Updating user installation..."
      cp -f "$SCRIPT" "$installed_path"
      chmod +x "$installed_path" || true
      echo "Successfully updated $installed_path"
      ;;
    *)
      echo "Unknown installation location: $installed_path"
      echo "Manually update or reinstall using --install flag"
      return 1
      ;;
  esac
}

update_from_github() {
  local installed_path="${1:-}"
  local github_url="https://raw.githubusercontent.com/ardianbro/kubenav/main/kubenav.sh"
  local temp_file

  # Check for download tool
  local downloader=""
  if command -v curl >/dev/null 2>&1; then
    downloader="curl"
  elif command -v wget >/dev/null 2>&1; then
    downloader="wget"
  else
    echo "Error: Neither curl nor wget found. Please install one to download from GitHub."
    return 1
  fi

  echo "Downloading from GitHub: $github_url"
  temp_file=$(mktemp)

  # Download the file
  if [ "$downloader" = "curl" ]; then
    if ! curl -fsSL "$github_url" -o "$temp_file"; then
      echo "Failed to download from GitHub"
      rm -f "$temp_file"
      return 1
    fi
  else
    if ! wget -q "$github_url" -O "$temp_file"; then
      echo "Failed to download from GitHub"
      rm -f "$temp_file"
      return 1
    fi
  fi

  # Verify downloaded file is a valid bash script
  if ! head -n 1 "$temp_file" | grep -q '^#!/'; then
    echo "Downloaded file doesn't appear to be a valid script"
    rm -f "$temp_file"
    return 1
  fi

  echo "Download successful"

  # If no installed path provided, try to find it
  if [ -z "$installed_path" ]; then
    if command -v kubenav >/dev/null 2>&1; then
      installed_path=$(command -v kubenav)
    else
      echo "kubenav not found on PATH"
      read -rp "Install to /usr/local/bin (system) or $HOME/bin (user)? [s/u]: " install_choice
      case "$install_choice" in
        s|S)
          installed_path="/usr/local/bin/kubenav"
          ;;
        u|U)
          mkdir -p "$HOME/bin"
          installed_path="$HOME/bin/kubenav"
          ;;
        *)
          echo "Invalid choice"
          rm -f "$temp_file"
          return 1
          ;;
      esac
    fi
  fi

  read -rp "Install to $installed_path? [Y/n]: " ans
  case "${ans:-Y}" in
    y|Y)
      ;;
    *)
      echo "Aborted"
      rm -f "$temp_file"
      return 1
      ;;
  esac

  # Install based on location
  case "$installed_path" in
    /usr/local/bin/*|/usr/bin/*)
      echo "Installing to system location..."
      if cp -f "$temp_file" "$installed_path" 2>/dev/null && chmod +x "$installed_path" 2>/dev/null; then
        echo "Successfully updated $installed_path"
      elif command -v sudo >/dev/null 2>&1; then
        sudo cp -f "$temp_file" "$installed_path" && sudo chmod +x "$installed_path"
        echo "Successfully updated $installed_path"
      else
        echo "Failed to update $installed_path (no permission)"
        rm -f "$temp_file"
        return 1
      fi
      ;;
    *)
      echo "Installing to user location..."
      cp -f "$temp_file" "$installed_path"
      chmod +x "$installed_path" || true
      echo "Successfully updated $installed_path"
      ;;
  esac

  rm -f "$temp_file"
  echo ""
  echo "Update complete! Run 'kubenav --version' or check the script to verify."
}

uninstall_script() {
  echo "This will remove kubenav from your system."
  echo ""

  # Find where kubenav is installed
  local installed_path=""
  if command -v kubenav >/dev/null 2>&1; then
    installed_path=$(command -v kubenav)
    echo "Found kubenav at: $installed_path"
  else
    echo "kubenav is not found on PATH"
  fi

  # Check if config directory exists
  if [ -d "$BASE_DIR" ]; then
    echo "Configuration directory: $BASE_DIR"
    echo "  (contains imported kubeconfigs, context mappings, namespace caches)"
  fi

  echo ""
  read -rp "Remove kubenav binary? [y/N]: " remove_bin
  read -rp "Remove configuration directory ($BASE_DIR)? [y/N]: " remove_config

  local removed_something=0

  # Remove binary
  if [[ "${remove_bin:-N}" =~ ^[Yy]$ ]] && [ -n "$installed_path" ]; then
    case "$installed_path" in
      /usr/local/bin/*)
        echo "Removing system installation..."
        if rm -f "$installed_path" 2>/dev/null; then
          echo "Removed $installed_path"
          removed_something=1
        elif command -v sudo >/dev/null 2>&1; then
          sudo rm -f "$installed_path"
          echo "Removed $installed_path"
          removed_something=1
        else
          echo "Failed to remove $installed_path (no permission)"
        fi
        ;;
      "$HOME"/bin/*)
        echo "Removing user installation..."
        rm -f "$installed_path"
        echo "Removed $installed_path"
        removed_something=1
        ;;
      *)
        echo "Unknown installation location: $installed_path"
        echo "Please remove manually"
        ;;
    esac
  fi

  # Remove configuration directory
  if [[ "${remove_config:-N}" =~ ^[Yy]$ ]] && [ -d "$BASE_DIR" ]; then
    echo "Removing configuration directory..."
    rm -rf "$BASE_DIR"
    echo "Removed $BASE_DIR"
    removed_something=1
  fi

  if [ $removed_something -eq 1 ]; then
    echo ""
    echo "Uninstall complete."
  else
    echo ""
    echo "Nothing was removed."
  fi
}

auto_install_if_needed() {
  # Do nothing if kubenav is already on PATH
  if command -v kubenav >/dev/null 2>&1; then
    return
  fi

  echo "kubenav is not installed to your PATH. Install now?"
  read -rp "Install to /usr/local/bin (system) or $HOME/bin (user)? [s/u/N]: " ans
  case "$ans" in
    s|S)
      if install_to_system; then
        echo "Installed to /usr/local/bin/kubenav"
      else
        echo "System install failed; falling back to user install"
        install_to_user
        echo "Installed to $HOME/bin/kubenav"
      fi
      ;;
    u|U)
      install_to_user
      echo "Installed to $HOME/bin/kubenav"
      ;;
    *)
      echo "Skipping installation"
      ;;
  esac

  # Hint to add $HOME/bin to PATH if used
  if [ -d "$HOME/bin" ] && ! echo ":$PATH:" | tr ':' '\n' | grep -qx "$HOME/bin"; then
    echo "If you installed to $HOME/bin, add it to your PATH (e.g. add 'export PATH=\"$HOME/bin:\$PATH\"' to ~/.zprofile)"
  fi
}

check_deps() {
  local miss=()
  command -v kubectl >/dev/null 2>&1 || miss+=(kubectl)
  command -v fzf >/dev/null 2>&1 || miss+=(fzf)
  if [ ${#miss[@]} -ne 0 ]; then
    echo "Missing dependencies: ${miss[*]}"
    read -rp "Attempt to install missing dependencies now? [Y/n] " ans
    ans=${ans:-Y}
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      install_packages "${miss[@]}"
    else
      echo "Install them and re-run. Example (macOS): brew install kubectl fzf"
      exit 1
    fi
  fi
}

install_packages() {
  local pkgs=("$@")
  echo "Installing: ${pkgs[*]}"

  if command -v brew >/dev/null 2>&1; then
    echo "Using Homebrew"
    brew update || true
    brew install "${pkgs[@]}"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "Using apt-get"
    sudo apt-get update
    sudo apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    echo "Using dnf"
    sudo dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    echo "Using yum"
    sudo yum install -y "${pkgs[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    echo "Using pacman"
    sudo pacman -Syu --noconfirm "${pkgs[@]}"
  elif command -v apk >/dev/null 2>&1; then
    echo "Using apk"
    sudo apk add "${pkgs[@]}"
  else
    echo "No supported package manager found. Please install: ${pkgs[*]}"
    exit 1
  fi

  local still_missing=()
  for p in "${pkgs[@]}"; do
    if ! command -v "$p" >/dev/null 2>&1; then
      still_missing+=("$p")
    fi
  done
  if [ ${#still_missing[@]} -ne 0 ]; then
    echo "Some packages failed to install: ${still_missing[*]}"
    exit 1
  fi
}

list_kubeconfigs() {
  ls -1 "$KUBE_DIR" 2>/dev/null || true
}

build_kubeconfig_env() {
  # Build colon-separated KUBECONFIG from all files in kubeconfigs dir
  local files
  files=("$KUBE_DIR"/*)
  if [ -e "${files[0]}" ]; then
    KUBECONFIG=$(IFS=:; echo "${files[*]}")
    export KUBECONFIG
  else
    unset KUBECONFIG
  fi
}

import_kubeconfig() {
  echo "Opening interactive file picker..."
  src=$(choose_file_interactive "$HOME") || return 1
  # Expand and verify
  src=$(eval echo "$src")
  if [ ! -f "$src" ]; then
    echo "File not found: $src"; return 1
  fi
  ensure_dirs
  local dest="$KUBE_DIR/$(basename "$src")"
  cp -f "$src" "$dest"

  # If the imported kubeconfig contains exactly one context, rename the file
  # to the sanitized context name so it's easier to identify.
  local ctxs ctx count sanitized newdest
  ctxs=$(kubectl --kubeconfig="$dest" config get-contexts -o name 2>/dev/null || true)
  if [ -n "$ctxs" ]; then
    count=$(printf "%s\n" "$ctxs" | sed '/^\s*$/d' | wc -l | tr -d ' ')
    if [ "$count" -eq 1 ]; then
      ctx=$(printf "%s" "$ctxs" | tr -d '\r')
      sanitized=${ctx//[^A-Za-z0-9_.-]/_}
      newdest="$KUBE_DIR/$sanitized"
      # avoid clobbering existing files
      if [ -e "$newdest" ]; then
        local i=1
        while [ -e "${newdest}-$i" ]; do i=$((i+1)); done
        newdest="${newdest}-$i"
      fi
      mv -f "$dest" "$newdest"
      dest="$newdest"
      echo "Imported to $dest"
    else
      echo "Imported to $dest"
    fi
  else
    echo "Imported to $dest"
  fi

  # register contexts from this file so context selection can map to this kubeconfig
  add_context_mappings_for_file "$dest"
  # Prompt to rename contexts from this file if user wants
  rename_contexts_prompt "$dest"
  # Unset KUBECONFIG before rebuilding so new file is included in aggregated config
  unset KUBECONFIG
  build_kubeconfig_env
}

rename_contexts_prompt() {
  local file="$1"
  local ctxs
  ctxs=$(kubectl --kubeconfig="$file" config get-contexts -o name 2>/dev/null || true)
  if [ -z "$ctxs" ]; then
    return
  fi
  echo "Imported contexts found in $file:"
  printf "%s\n" "$ctxs"

  # For each imported context, prompt once for a new name (empty = keep original)
  while IFS= read -r sel; do
    [ -z "$sel" ] && continue
    # Prompt from the controlling TTY so we still get input after fzf
    if [ -e /dev/tty ]; then
      read -r -p "Rename context '$sel' (enter to keep): " newname </dev/tty || newname=""
    else
      read -r -p "Rename context '$sel' (enter to keep): " newname || newname=""
    fi
    newname=$(echo "$newname" | tr -d '\r')
    if [ -z "$newname" ]; then
      continue
    fi
    # attempt to rename using kubectl on the file
    if kubectl --kubeconfig="$file" config rename-context "$sel" "$newname" 2>/dev/null; then
      echo "Renamed $sel -> $newname in $file"
      # update context_map: replace any mapping key equal to OLD with NEW (global update)
      if [ -f "$CONTEXT_MAP" ]; then
        awk -F"\t" -v OFS="\t" -v OLD="$sel" -v NEW="$newname" '{ if($1==OLD) $1=NEW; print }' "$CONTEXT_MAP" > "$CONTEXT_MAP.tmp" && mv "$CONTEXT_MAP.tmp" "$CONTEXT_MAP"
        # ensure uniqueness after rename
        normalize_context_map
      fi
    else
      echo "Failed to rename context via kubectl. You may not have permission to write the file."
    fi
  done <<< "$ctxs"
}

choose_file_interactive() {
  # interactive picker that emulates a simple file manager using fzf
  local dir="${1:-$HOME}"
  while true; do
    # list parent entry and directory contents (show / for dirs)
    entries=()
    while IFS= read -r line; do
      entries+=("$line")
    done <<< "$(printf "../\n"; ls -Ap -- "$dir" 2>/dev/null)"
    # preview: show directory listing or file head (use bat if available)
    local preview_cmd
    preview_cmd="if [ -d \"$dir/{}\" ]; then ls -la \"$dir/{}\"; else (command -v bat >/dev/null 2>&1 && bat --style=numbers --color=always --line-range :200 \"$dir/{}\" || sed -n '1,200p' \"$dir/{}\") fi"
    local sel
    sel=$(printf "%s\n" "${entries[@]}" | fzf --prompt="Import from: $dir> " --height=10 --border --preview="$preview_cmd") || return 1
    # if user selected parent
    if [ "$sel" = "../" ]; then
      dir=$(dirname "$dir")
      continue
    fi
    # if selection is directory (ends with /)
    if [[ "$sel" == */ ]]; then
      # trim trailing slash
      sel=${sel%/}
      dir="$dir/$sel"
      continue
    fi
    # otherwise selected a file
    echo "$dir/$sel"
    return 0
  done
}

rename_context() {
  # Interactive context renaming
  local lines
  lines=$(get_context_map_lines)
  if [ -z "$lines" ]; then
    echo "No contexts registered to rename."
    return 1
  fi

  # Build menu to select context to rename
  local menu=""
  while IFS=$'\t' read -r ctx file; do
    [ -z "$ctx" ] && continue
    local base
    base=$(basename "$file")
    menu+="$ctx ($base)\t$ctx\t$file\n"
  done <<< "$lines"

  local sel
  sel=$(printf "%b" "$menu" | fzf --with-nth=1 --prompt="Select context to rename: " --height=10 --border) || return 1
  if [ -z "$sel" ]; then return 1; fi

  local old_ctx file
  old_ctx=$(awk -F"\t" '{print $2}' <<< "$sel")
  file=$(awk -F"\t" '{print $3}' <<< "$sel")

  # Prompt for new name
  local new_ctx
  if [ -e /dev/tty ]; then
    read -r -p "New name for context '$old_ctx': " new_ctx </dev/tty || new_ctx=""
  else
    read -r -p "New name for context '$old_ctx': " new_ctx || new_ctx=""
  fi
  new_ctx=$(echo "$new_ctx" | tr -d '\r')

  if [ -z "$new_ctx" ]; then
    echo "No new name provided, aborting."
    return 1
  fi

  if [ "$old_ctx" = "$new_ctx" ]; then
    echo "Name unchanged."
    return 0
  fi

  # Rename using kubectl
  if kubectl --kubeconfig="$file" config rename-context "$old_ctx" "$new_ctx" 2>/dev/null; then
    echo "Renamed context: $old_ctx → $new_ctx"
    # Update context_map
    if [ -f "$CONTEXT_MAP" ]; then
      awk -F"\t" -v OFS="\t" -v OLD="$old_ctx" -v NEW="$new_ctx" '{ if($1==OLD) $1=NEW; print }' "$CONTEXT_MAP" > "$CONTEXT_MAP.tmp" && mv "$CONTEXT_MAP.tmp" "$CONTEXT_MAP"
      normalize_context_map
    fi
    # Update saved selection if it references the old context
    if [ -f "$CURRENT_SEL" ]; then
      sed -i.bak "s/^CONTEXT=$old_ctx$/CONTEXT=$new_ctx/" "$CURRENT_SEL" 2>/dev/null || true
      rm -f "$CURRENT_SEL.bak" 2>/dev/null || true
    fi
  else
    echo "Failed to rename context."
    return 1
  fi
}

manage_context() {
  # Submenu for context management
  local options=("Select context" "Rename context" "Remove context" "Back")
  local choice
  choice=$(printf "%s\n" "${options[@]}" | fzf --prompt="Manage context> " --height=10 --border) || return 0
  case "$choice" in
    "Select context") select_context || true ;;
    "Rename context") rename_context || true ;;
    "Remove context") remove_context_and_config || true ;;
    "Back") return 0 ;;
    *) return 0 ;;
  esac
}

select_context() {
  lines=$(get_context_map_lines)
  if [ -z "$lines" ]; then
    build_kubeconfig_env
    local ctx
    ctx=$(kubectl config get-contexts -o name 2>/dev/null | fzf --prompt="Context: " --height=10 --border) || return 1
    if [ -n "$ctx" ]; then
      kubectl config use-context "$ctx"
      echo "Switched context to $ctx"
      show_status
    fi
    return
  fi

  # Build menu entries: display="context (filebasename)" then real fields context and file
  local menu=""
  while IFS=$'\t' read -r ctx file; do
    [ -z "$ctx" ] && continue
    local base
    base=$(basename "$file")
    menu+="$ctx ($base)\t$ctx\t$file\n"
  done <<< "$lines"

  local sel
  sel=$(printf "%b" "$menu" | fzf --with-nth=1 --prompt="Context: " --height=10 --border) || return 1
  if [ -z "$sel" ]; then return 1; fi

  local ctx
  local file
  ctx=$(awk -F"\t" '{print $2}' <<< "$sel")
  file=$(awk -F"\t" '{print $3}' <<< "$sel")

  export KUBECONFIG="$file"
  kubectl config use-context "$ctx" --kubeconfig="$file" 2>/dev/null || true
  echo "Switched context to $ctx (using $file)"
  # Persist selection inside kubenav config dir
  save_current_selection "$file" "$ctx" "$(kubectl --kubeconfig="$file" config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || echo '')"
  # Show status after context switch
  show_status
}

select_namespace() {
  # Simple namespace selection (from cluster if permissions allow, from cache otherwise)
  if kubectl auth can-i list namespaces >/dev/null 2>&1; then
    local ns
    ns=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | fzf --prompt="Namespace: " --height=10 --border) || return 1
    if [ -n "$ns" ]; then
      kubectl config set-context --current --namespace="$ns"
      echo "Namespace set to $ns on current context"
    fi
    return
  fi

  # No permissions - select from cache
  local NAMESPACE_CACHE cached_ns current_ctx
  NAMESPACE_CACHE=$(get_namespace_cache)
  mkdir -p "$BASE_DIR"
  touch "$NAMESPACE_CACHE"

  cached_ns=$(grep -v '^#' "$NAMESPACE_CACHE" 2>/dev/null | sed '/^\s*$/d' | fzf --prompt="Namespace (cached): " --height=10 --border) || return 1
  if [ -n "$cached_ns" ]; then
    kubectl config set-context --current --namespace="$cached_ns" 2>/dev/null || true
    echo "Namespace set to $cached_ns on current context (from cache)"
    # persist namespace selection
    if [ -n "${KUBECONFIG:-}" ]; then
      current_ctx=$(kubectl --kubeconfig="$KUBECONFIG" config current-context 2>/dev/null || true)
      save_current_selection "$KUBECONFIG" "$current_ctx" "$cached_ns"
    fi
  fi
}

add_namespace_interactive() {
  # Prompt to add a namespace to cache
  local newns
  if [ -e /dev/tty ]; then
    read -r -p "Namespace name to add: " newns </dev/tty || newns=""
  else
    read -r -p "Namespace name to add: " newns || newns=""
  fi
  newns=$(echo "$newns" | tr -d '\r')
  if [ -n "$newns" ]; then
    add_namespace_to_cache "$newns"
  else
    echo "No namespace name provided."
  fi
}

manage_namespace() {
  # Show management submenu only when user doesn't have permission to list namespaces
  if kubectl auth can-i list namespaces >/dev/null 2>&1; then
    # User has permissions, just select namespace directly
    select_namespace
    return
  fi

  # No permissions - show management submenu
  local options=("Select namespace" "Add namespace" "Remove namespace" "Back")
  local choice
  choice=$(printf "%s\n" "${options[@]}" | fzf --prompt="Manage namespace> " --height=10 --border) || return 0
  case "$choice" in
    "Select namespace") select_namespace || true ;;
    "Add namespace") add_namespace_interactive || true ;;
    "Remove namespace") remove_namespace_from_cache || true ;;
    "Back") return 0 ;;
    *) return 0 ;;
  esac
}

select_pod_and_shell() {
  local ns
  ns=$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || true)
  if [ -z "$ns" ]; then ns=default; fi
  # List pods with columns and filter to only Running pods; show NAME, STATUS, AGE
  local lines
  # Helper: format ISO creationTimestamp to "Xd Yh Zm" using shell (BSD/GNU date)
  format_age_iso() {
    local iso="$1"
    # strip fractional seconds like .123456Z -> Z
    local iso_clean
    iso_clean=$(printf "%s" "$iso" | sed -E 's/\.[0-9]+Z$/Z/')

    local epoch
    # try GNU date
    if epoch=$(date -u -d "$iso_clean" +%s 2>/dev/null); then
      :
    else
      # try BSD date (macOS)
      if epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso_clean" +%s 2>/dev/null); then
        :
      else
        # unknown format — return raw
        printf "%s" "$iso"
        return
      fi
    fi

    local now delta days hours minutes rest
    now=$(date -u +%s)
    delta=$((now - epoch))
    if [ "$delta" -lt 0 ]; then delta=0; fi
    days=$((delta / 86400))
    rest=$((delta % 86400))
    hours=$((rest / 3600))
    minutes=$(((rest % 3600) / 60))
    printf "%sd %sh %sm" "$days" "$hours" "$minutes"
  }

  # Get name, status, creationTimestamp sorted oldest first; then compute human age
  local raw
  raw=$(kubectl get pods -n "$ns" --sort-by=.metadata.creationTimestamp -o=custom-columns=NAME:.metadata.name,STATUS:.status.phase,CREATED:.metadata.creationTimestamp --no-headers 2>/dev/null || true)
  lines=""
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    # split into name status created
    name=$(awk '{print $1}' <<< "$l")
    status=$(awk '{print $2}' <<< "$l")
    # created may have spaces if parsed oddly; take the rest of the line
    created=$(echo "$l" | awk '{ $1=""; $2=""; sub(/^  */,"",$0); print $0 }')
    if [ "$status" != "Running" ]; then
      continue
    fi
    age=$(format_age_iso "$created")
    lines+="$name\t$status\t$age\n"
  done <<< "$raw"
  if [ -z "$lines" ]; then
    echo "No running pods in namespace $ns"
    return 1
  fi

  local sel
  sel=$(printf "%b" "$lines" | fzf --delimiter=$'\t' --with-nth=1,2,3 --prompt="Pod (ns:$ns): " --height=10 --border) || return 1
  if [ -z "$sel" ]; then echo "No pod selected"; return 1; fi

  local pod status age
  pod=$(awk -F"\t" '{print $1}' <<< "$sel")
  status=$(awk -F"\t" '{print $2}' <<< "$sel")
  age=$(awk -F"\t" '{print $3}' <<< "$sel")

  echo "Opening shell into pod $pod (namespace: $ns, status: $status, age: $age)"
  kubectl exec -it -n "$ns" "$pod" -- bash -l -i 2>/dev/null || kubectl exec -it -n "$ns" "$pod" -- sh
}

show_status() {
  clear
  echo "Current KUBECONFIG: ${KUBECONFIG:-(not set)}"
  # Avoid calling kubectl when no imported kubeconfigs are active.
  if [ -n "${KUBECONFIG:-}" ]; then
    echo "Current context: $(kubectl config current-context 2>/dev/null || echo '-')"
    echo "Current namespace: $(kubectl --kubeconfig="${KUBECONFIG}" config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || echo default)"
    return
  fi

  # If we have a saved selection, show it; otherwise show clean placeholders.
  if [ -f "$CURRENT_SEL" ]; then
    file=$(awk -F= '/^KUBECONFIG=/{sub(/^[^=]+=/,"",$0); print $0}' "$CURRENT_SEL" 2>/dev/null || true)
    ctx=$(awk -F= '/^CONTEXT=/{sub(/^[^=]+=/,"",$0); print $0}' "$CURRENT_SEL" 2>/dev/null || true)
    ns=$(awk -F= '/^NAMESPACE=/{sub(/^[^=]+=/,"",$0); print $0}' "$CURRENT_SEL" 2>/dev/null || true)
    echo "Saved KUBECONFIG: ${file:-(not set)}"
    echo "Saved context: ${ctx:--}"
    echo "Saved namespace: ${ns:--}"
  else
    echo "Current context: -"
    echo "Current namespace: -"
  fi
}

main_menu() {
  local options
  # Recompute menu each loop so imports / removals are reflected immediately
  while true; do
    # Only rebuild kubeconfig env if KUBECONFIG is not set (to preserve user's context selection)
    if [ -z "${KUBECONFIG:-}" ]; then
      build_kubeconfig_env
    fi
    # If no kubeconfigs imported, only show import and exit to avoid confusing options
    local files=("$KUBE_DIR"/*)
    if [ ! -e "${files[0]}" ]; then
      options=("Import kubeconfig" "Exit")
    else
      options=(
        "Import kubeconfig"
        "Manage context"
        "Manage namespace"
        "Select pod and shell"
        "Show status"
        "Exit"
      )
    fi

    local choice
    choice=$(printf "%s\n" "${options[@]}" | fzf --prompt="kubenav> " --height=10 --border) || exit 0
    case "$choice" in
      "Import kubeconfig") import_kubeconfig || true ;;
      "Manage context") manage_context || true ;;
      "Manage namespace") manage_namespace || true ;;
      "Select pod and shell") select_pod_and_shell || true ;;
      "Show status") show_status || true ;;
      "Exit") exit 0 ;;
      *) echo "No selection or unknown action" ;;
    esac
  done
}

usage() {
  cat <<EOF
kubenav.sh - interactive helper

Dependencies: kubectl, fzf

Run without args to start interactive menu.
Imported kubeconfig files are registered and contexts are mapped to their owning kubeconfig; when you select a context, kubenav will automatically use the related kubeconfig.
You can import kubeconfig files, pick a context, set namespace, then pick a pod to shell into.

Imported kubeconfigs are stored in: $KUBE_DIR

CLI flags:
  --reinstall | --update        Update/reinstall script to latest version
  --uninstall                   Remove kubenav binary and/or configuration directory
  --remove-context [CONTEXT]   Remove a context, its kubeconfig if empty, and saved namespace cache
    --dry-run                   Show planned actions without making changes
    -y|--yes                    Skip confirmation prompt and proceed

EOF
}

main() {
  # Simple, non-interactive flags
  case "${1:-}" in
    --show-saved)
      if [ -f "$CURRENT_SEL" ]; then
        cat "$CURRENT_SEL"
      else
        echo "No saved selection"
      fi
      exit 0
      ;;
    --rename-file)
      if [ -z "${2:-}" ]; then
        echo "Usage: kubenav --rename-file /path/to/kubeconfig"; exit 1
      fi
      rename_contexts_prompt "${2}"; exit 0
      ;;
    --rebuild-context-map)
      rebuild_context_map; echo "Rebuilt context map at $CONTEXT_MAP"; exit 0
      ;;
    --reinstall|--update)
      reinstall_script; exit $?
      ;;
    --uninstall)
      uninstall_script; exit $?
      ;;
    --remove-context)
      remove_context_and_config "${@:2}"; exit $?
      ;;
    --add-namespace)
      if [ -z "${2:-}" ]; then
        echo "Usage: kubenav --add-namespace <name>"; exit 1
      fi
      add_namespace_to_cache "$2"; exit 0
      ;;
    --remove-namespace)
      if [ -n "${2:-}" ]; then
        remove_namespace_from_cache "$2"; exit 0
      else
        remove_namespace_from_cache; exit $?
      fi
      ;;
    --list-namespaces)
      list_cached_namespaces; exit 0
      ;;
    --help|-h)
      usage; exit 0
      ;;
  esac

  check_deps
  ensure_dirs
  auto_install_if_needed
  build_kubeconfig_env
  # Load saved selection from script dir (if present) and show status
  load_saved_selection
  show_status
  main_menu
}

main "$@"
