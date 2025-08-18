#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

VERSIONS_DIR="versions"
LIBRARIES_DIR="libraries"
NATIVES_DIR="natives"
ASSETS_DIR="assets"
GAME_DIR="run"

VERSION="1.21.8"

function update_metadata {
    printf 'updating version manifest\n' >&2
    mkdir -p "$VERSIONS_DIR"
    curl --silent "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" | jq '{"latest": .latest, "versions": [.versions[] | {"key": .id, "value": .url}] | from_entries}' > "$VERSIONS_DIR/manifest.json"

    printf 'updating %s meta %s\n' "$VERSION" >&2
    mkdir -p "$VERSIONS_DIR/$VERSION"
    curl --silent -o "$VERSIONS_DIR/$VERSION/meta.json" "$(jq -r --arg version "$VERSION" '.versions[$version]' $VERSIONS_DIR/manifest.json)"
    meta="$(jq -c --slurpfile info info.json --slurpfile auth auth.json -f meta.jq "$VERSIONS_DIR/$VERSION/meta.json")"

    printf 'updating %s asset index...\n' "$VERSION" >&2
    mkdir -p "$ASSETS_DIR/indexes"
    assets_url="$(<<<"$meta" jq -r '.asset_index')"
    curl --silent -o "$ASSETS_DIR/indexes/$(basename "$assets_url")" "$assets_url"
}

function launch (
    update_metadata

    export LIBRARIES_DIR
    function download_library {
        if ! [[ -e "$LIBRARIES_DIR/${2:-}" ]]; then
            printf '%s\n' "${1:-}" >&2
            mkdir -p "$(dirname "$LIBRARIES_DIR/${2:-}")"
            curl --silent -o "$LIBRARIES_DIR/${2:-}" "${3:-}"
        fi
    }
    export -f download_library

    export ASSETS_DIR
    function download_asset {
        if ! [[ -e "$ASSETS_DIR/objects/${2:-}" ]]; then
            printf '%s\n' "${1:-}" >&2
            mkdir -p "$(dirname "$ASSETS_DIR/objects/${2:-}")"
            curl --silent -o "$ASSETS_DIR/objects/${2:-}" "https://resources.download.minecraft.net/${2:-}"
        fi
    }
    export -f download_asset

    #TODO: check hash
    if ! [[ -e "$VERSIONS_DIR/$VERSION/client.jar" ]]; then
        printf 'downloading %s client jar...\n' "$VERSION" >&2
        <<<"$meta" jq -r '.client_url' | xargs curl --silent -o "$VERSIONS_DIR/$VERSION/client.jar"
    fi

    printf 'downloading libraries...\n' >&2
    <<<"$meta" jq -r '.libraries[] | "\(.name) \(.path) \(.url)"' | xargs -I {} "$SHELL" -c "download_library {}"

    printf 'downloading assets...\n' >&2
    jq -r '.objects | to_entries[] | "\(.key) \(.value.hash[:2])/\(.value.hash)"' "$ASSETS_DIR/indexes/$(basename "$assets_url")" | xargs -P 10 -I {} "$SHELL" -c "download_asset {}"

    # if ! [[ -e "$VERSIONS_DIR/$VERSION/log4j.xml" ]]; then
    #     printf 'downloading %s log4j config...\n' "$VERSION" >&2
    #     <<<"$meta" jq -r '.logging_config' | xargs curl --silent -o "$VERSIONS_DIR/$VERSION/log4j.xml"
    # fi

    function replace_placeholders {
        cat - | sed \
            -e "s/\${versions_directory}/$VERSIONS_DIR/g" \
            -e "s/\${libraries_directory}/$LIBRARIES_DIR/g" \
            -e "s/\${natives_directory}/$NATIVES_DIR/g" \
            -e "s/\${assets_directory}/$ASSETS_DIR/g" \
            -e "s/\${game_directory}/$GAME_DIR/g"
    }

    printf 'starting game :3\n' >&2
    <<<"$meta" jq -r '.args.jvm + [.main_class] + .args.game | join(" ")' | replace_placeholders | xargs java
)

launch
