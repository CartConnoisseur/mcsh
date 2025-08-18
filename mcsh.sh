#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

VERSION="1.21.8"

function update_metadata {
    printf 'updating version manifest\n'
    mkdir -p versions
    curl --silent "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" | jq '{"latest": .latest, "versions": [.versions[] | {"key": .id, "value": .url}] | from_entries}' > versions/manifest.json

    printf 'updating %s meta %s\n' "$VERSION"
    mkdir -p "versions/$VERSION"
    curl --silent -o "versions/$VERSION/meta.json" "$(jq -r --arg version "$VERSION" '.versions[$version]' versions/manifest.json)"
    meta="$(jq -c --slurpfile info info.json --slurpfile auth auth.json -f meta.jq "versions/$VERSION/meta.json")"

    printf 'updating %s asset index...\n' "$VERSION"
    mkdir -p assets/indexes
    assets_url="$(<<<"$meta" jq -r '.asset_index')"
    curl --silent -o "assets/indexes/$(basename "$assets_url")" "$assets_url"
}

function launch {
    update_metadata

    function download_library {
        if ! [[ -e "${2:-}" ]]; then
            printf '%s\n' "${1:-}"
            mkdir -p "$(dirname "${2:-}")"
            curl --silent -o "${2:-}" "${3:-}"
        fi
    }
    export -f download_library

    function download_asset {
        if ! [[ -e "assets/objects/${2:-}" ]]; then
            printf '%s\n' "${1:-}"
            mkdir -p "$(dirname "assets/objects/${2:-}")"
            curl --silent -o "assets/objects/${2:-}" "https://resources.download.minecraft.net/${2:-}"
        fi
    }
    export -f download_asset

    #TODO: check hash
    if ! [[ -e "versions/$VERSION/client.jar" ]]; then
        printf 'downloading %s client jar...\n' "$VERSION"
        <<<"$meta" jq -r '.client_url' | xargs curl --silent -o "versions/$VERSION/client.jar"
    fi

    printf 'downloading libraries...\n'
    <<<"$meta" jq -r '.libraries[] | "\(.name) libraries/\(.path) \(.url)"' | xargs -I {} "$SHELL" -c "download_library {}"

    printf 'downloading assets...\n'
    jq -r '.objects | to_entries[] | "\(.key) \(.value.hash[:2])/\(.value.hash)"' "assets/indexes/$(basename "$assets_url")" | xargs -P 10 -I {} "$SHELL" -c "download_asset {}"

    # if ! [[ -e "versions/$VERSION/log4j.xml" ]]; then
    #     printf 'downloading %s log4j config...\n' "$VERSION"
    #     <<<"$meta" jq -r '.logging_config' | xargs curl --silent -o "versions/$VERSION/log4j.xml"
    # fi

    printf 'starting game :3\n'
    <<<"$meta" jq -r '.args.jvm + [.main_class] + .args.game | join(" ")' | xargs java
}

launch
