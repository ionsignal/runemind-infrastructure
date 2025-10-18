#!/bin/bash
#
# This script compares local configuration files with those on the server,
# displays the differences, and asks for user confirmation before copying them.
# Run as the 'minecraft' user from the directory containing the script.

# Use an associative array to map source files to their destinations.
# This makes the list easier to manage.
declare -A files_to_copy
files_to_copy=(
    ["./configs/server.properties"]="../../../server/server.properties"
    ["./configs/bukkit.yml"]="../../../server/bukkit.yml"
    ["./configs/spigot.yml"]="../../../server/spigot.yml"
    ["./configs/paper-world-defaults.yml"]="../../../server/config/paper-world-defaults.yml"
    ["./configs/paper-global.yml"]="../../../server/config/paper-global.yml"
    ["./configs/paper-world.yml"]="../../../server/world/paper-world.yml"
    ["./plugins/configs/viaversion-config.yml"]="../../../server/plugins/ViaVersion/config.yml"
    ["./plugins/configs/terra/config.yml"]="../../../server/plugins/Terra/config.yml"
    ["./plugins/configs/terra/packs/default/pack.yml"]="../../../server/plugins/Terra/packs/default/pack.yml"
    ["./plugins/configs/terra/packs/default/biome-providers/single.yml"]="../../../server/plugins/Terra/packs/default/biome-providers/single.yml"
    ["./plugins/configs/terra/packs/default/biome/land/flat/temperate/semi-humid/lobby.yml"]="../../../server/plugins/Terra/packs/default/biome/land/flat/temperate/semi-humid/lobby.yml"
    ["./plugins/configs/terra/packs/default/features/vegetation/trees/eucalyptus_trees.yml"]="../../../server/plugins/Terra/packs/default/features/vegetation/trees/eucalyptus_trees.yml"
    ["./plugins/configs/huskclaims-config.yml"]="../../../server/plugins/HuskClaims/config.yml"
    ["./plugins/configs/huskhomes-config.yml"]="../../../server/plugins/HuskHomes/config.yml"
    ["./plugins/configs/craftengine/config.yml"]="../../../server/plugins/CraftEngine/config.yml"
    ["./plugins/configs/craftengine/default/pack.yml"]="../../../server/plugins/CraftEngine/resources/default/pack.yml"
)

# A flag to track if any changes are detected.
changes_found=false

echo "--- Checking for file differences ---"
for src in "${!files_to_copy[@]}"; do
    dest="${files_to_copy[$src]}"
    
    # Add a header for each file comparison for clarity.
    echo "==================================================================="
    echo "Comparing:"
    echo "  SOURCE: $src"
    echo "  DEST:   $dest"
    echo "-------------------------------------------------------------------"

    if [ ! -f "$dest" ]; then
        # Handle case where the destination file doesn't exist yet.
        echo "NOTICE: Destination file does not exist. It will be created."
        # Display the content of the new file, prefixed with '+' for a diff-like view.
        echo "--- /dev/null"
        echo "+++ ${dest}"
        cat "$src" | sed 's/^/+/g'
        changes_found=true
    else
        # Destination exists, so run the diff command.
        # `diff` will exit with a non-zero status code if files are different.
        # We capture the output and check the exit code.
        if ! diff_output=$(diff -u "$src" "$dest"); then
            echo "CHANGE: Differences found."
            echo "$diff_output"
            changes_found=true
        else
            echo "OK: No differences found."
        fi
    fi
    echo
done

# If no changes were found after checking all files, we can exit.
if ! $changes_found; then
    echo "All files are up to date. No action needed."
    exit 0
fi

echo "--- End of difference check ---"
echo
# Prompt the user for confirmation. The script will pause here for input.
# -p: display a prompt
# -n 1: read only one character
# -r: do not allow backslashes to escape characters
read -p "Do you want to apply the above changes and copy the files? (y/n) " -n 1 -r
echo

# Check if the user's reply was 'y' or 'Y'.
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo
    echo "--- Applying changes ---"
    for src in "${!files_to_copy[@]}"; do
        dest="${files_to_copy[$src]}"

        # Ensure the destination directory exists before copying.
        # This prevents "No such file or directory" errors from `cp`.
        dest_dir=$(dirname "$dest")
        if [ ! -d "$dest_dir" ]; then
            echo "Creating directory: $dest_dir"
            mkdir -p "$dest_dir"
        fi

        # Perform the copy operation.
        echo "Copying $src -> $dest"
        cp "$src" "$dest"
    done
    echo "--- Done. All files copied successfully. ---"
else
    echo
    echo "Operation cancelled by user. No files were changed."
fi