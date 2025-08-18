def apply_optional: if has("rules") then
    {
        "rules": [.rules[] | {
            "action": .action,
            "match": del(.action)
        }],
        "value": del(.rules)
    } as $optional
    | if $optional.rules[].match | inside($info[0]) then
        $optional.value
    else
        empty
    end
end;

def replace_placeholders: {
    "auth_player_name": $auth[0].player_name,
    "auth_uuid": $auth[0].uuid,
    "auth_xuid": $auth[0].xuid,
    "auth_access_token": $auth[0].access_token,
    "user_type": $auth[0].type,

    "version_name": .id,
    "version_type": .type,

    "assets_index_name": .assets,

    "assets_root": "${assets_directory}",
    #"game_directory": "run",
    #"natives_directory": "natives",

    "classpath": (. as $root | [
        .libraries[] | apply_optional | "${libraries_directory}/" + .downloads.artifact.path
    ] + ["${versions_directory}/\($root.id)/client.jar"] | join(":")),
    "clientid": "idfk",

    # log4j config path
    "path": "${versions_directory}/\(.id)/log4j.xml",

    "launcher_name": "mcsh",
    "launcher_version": "v0.1.0"
} as $strings | walk(if type == "string" then
    gsub("\\${(?<key>.*)}"; "\($strings[.key] // "${\(.key)}")")
end);

replace_placeholders | {
    "args": .arguments | to_entries | [.[] | {
        "key": .key,
        "value": .value | [
            .[] | if type == "object" then
                apply_optional | .value
            end
        ] | flatten
    }] | from_entries, # as $args | $args + {"jvm": [.logging.client.argument] + $args.jvm}),
    "libraries": [.libraries[] | apply_optional | {
        "name": .name,
        "path": .downloads.artifact.path,
        "url": .downloads.artifact.url
    }],
    "version": .id,
    "asset_index": .assetIndex.url,
    "java_version": .javaVersion.majorVersion,
    "client_url": .downloads.client.url,
    "main_class": .mainClass,
    "logging_config": .logging.client.file.url
}
