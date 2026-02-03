# kubenav

Interactive Kubernetes configuration and context manager with intuitive menu-driven navigation.

## Features

- 🔄 **Import & Manage Kubeconfigs**: Import kubeconfig files from anywhere on your system
- 🎯 **Context Management**: Switch, rename, and remove contexts with fuzzy search
- 📦 **Namespace Management**: Select namespaces with live cluster access or cached fallback
- 🐚 **Pod Shell Access**: Quick shell access to running pods with status and age display
- 📊 **Status Display**: View current context, namespace, and kubeconfig at a glance
- 🔄 **Context Mapping**: Automatic mapping of contexts to their kubeconfig files
- 💾 **Session Persistence**: Remembers your last selected context and namespace

## Requirements

- `kubectl` - Kubernetes command-line tool
- `fzf` - Command-line fuzzy finder

The script will offer to install missing dependencies automatically using your system's package manager (Homebrew, apt, dnf, yum, pacman, or apk).

## Installation

### Quick Install

Run the script directly - it will offer to install itself to your PATH:

```bash
./kubenav.sh
```

You'll be prompted to install to either:
- `/usr/local/bin/kubenav` (system-wide, requires sudo)
- `$HOME/bin/kubenav` (user-only)

### Manual Install

**System-wide:**
```bash
sudo cp kubenav.sh /usr/local/bin/kubenav
sudo chmod +x /usr/local/bin/kubenav
```

**User-only:**
```bash
mkdir -p ~/bin
cp kubenav.sh ~/bin/kubenav
chmod +x ~/bin/kubenav
# Add ~/bin to PATH if not already present:
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc  # or ~/.bashrc
```

## Usage

### Interactive Mode

Simply run:
```bash
kubenav
```

This opens an interactive menu with the following options:
- **Import kubeconfig** - Browse and import kubeconfig files
- **Manage context** - Submenu for context operations:
  - Select context - Switch between available contexts
  - Rename context - Rename contexts for clarity
  - Remove context - Remove contexts and clean up files
- **Manage namespace** - Namespace operations (adapts based on permissions):
  - With cluster permissions: Direct namespace selection
  - Without permissions: Submenu to select, add, or remove cached namespaces
- **Select pod and shell** - Shell into running pods
- **Show status** - Display current configuration
- **Exit** - Exit the program

### Command-Line Flags

```bash
# Update kubenav to latest version
kubenav --update
kubenav --reinstall

# Uninstall kubenav binary and/or configuration
kubenav --uninstall

# Remove a specific context
kubenav --remove-context CONTEXT_NAME
kubenav --remove-context CONTEXT_NAME --yes  # Skip confirmation
kubenav --remove-context CONTEXT_NAME --dry-run  # Preview changes

# Manage namespace cache
kubenav --add-namespace NAMESPACE_NAME
kubenav --remove-namespace [NAMESPACE_NAME]
kubenav --list-namespaces

# Utility commands
kubenav --show-saved  # Show saved selection
kubenav --rebuild-context-map  # Rebuild context mappings
kubenav --rename-file /path/to/kubeconfig  # Rename contexts in file
kubenav --help  # Show help
```

## How It Works

### File Organization

Kubenav stores all data in `~/.kubenav/`:
- `kubeconfigs/` - Imported kubeconfig files
- `context_map` - TSV mapping of contexts to kubeconfig files
- `current` - Saved selection (context, namespace, kubeconfig)
- `namespaces/<context>` - Per-context namespace caches

### Context Mapping

When you import a kubeconfig:
1. The file is copied to `~/.kubenav/kubeconfigs/`
2. All contexts in the file are extracted
3. A mapping is created: `context → kubeconfig file`
4. If the file contains one context, it's renamed to match

When you select a context:
1. Kubenav looks up the associated kubeconfig file
2. Sets `KUBECONFIG` to that specific file
3. Switches to the selected context
4. Auto-displays the current status

You can also rename contexts interactively through the "Manage context" menu, which updates the kubeconfig file, context map, and any saved selections.

### Namespace Management

- **With cluster permissions**: "Manage namespace" directly opens namespace selection from cluster
- **Without permissions**: Opens a management submenu for cache operations:
  - Select from cached namespaces
  - Add new namespaces to cache
  - Remove namespaces from cache
- Cache is per-context to avoid namespace confusion
- Automatically detects permissions and adjusts behavior

### Pod Shell Access

- Shows only running pods with status and age
- Formatted age display (e.g., "2d 3h 15m")
- Attempts `bash` first, falls back to `sh`
- Respects current namespace

## Examples

### Import and Switch Context

```bash
# Start interactive mode
kubenav

# Select "Import kubeconfig"
# Browse to your kubeconfig file
# Select "Manage context" → "Select context"
# Choose your desired context
```

### Quick Context Removal

```bash
# Remove a context with confirmation
kubenav --remove-context my-old-context

# Remove without confirmation prompt
kubenav --remove-context my-old-context --yes

# Preview what would be removed
kubenav --remove-context my-old-context --dry-run
```

### Namespace Cache Management

```bash
# Add a namespace manually (useful when you can't list namespaces)
kubenav --add-namespace production

# List cached namespaces for current context
kubenav --list-namespaces

# Remove a namespace from cache
kubenav --remove-namespace old-namespace
```

### Update or Uninstall

```bash
# Update to latest version
kubenav --update

# Uninstall (prompts for binary and config separately)
kubenav --uninstall
```

## Tips

- **Context Renaming**: After importing, you'll be prompted to rename contexts for clarity
- **Status Display**: After switching contexts, status is automatically shown and console is cleared
- **Session Persistence**: Your last context/namespace selection is preserved between sessions
- **Fixed Menu Heights**: All menus use consistent heights (10-12 lines) for compact display
- **Copy-Based Installation**: Uses file copy instead of symlinks for better portability

## Troubleshooting

### Dependencies Not Found
Run the script - it will detect missing dependencies and offer to install them:
```bash
./kubenav.sh
```

### Context Not Switching
If contexts aren't switching properly, rebuild the context map:
```bash
kubenav --rebuild-context-map
```

### Namespace Permissions
If you can't list namespaces, kubenav automatically switches to cache mode. Add namespaces manually:
```bash
kubenav --add-namespace my-namespace
```

### Clean Start
To start fresh, remove the configuration directory:
```bash
rm -rf ~/.kubenav
```

Or use the uninstall command:
```bash
kubenav --uninstall  # Then choose to remove config only
```

## License

MIT
