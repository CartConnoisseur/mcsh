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
    "version_name": .id,
    "version_type": .type,

    "assets_index_name": .assets,

    "classpath": (. as $root | [
        .libraries[] | apply_optional | "${libraries_directory}/" + .downloads.artifact.path
    ] + ["${versions_directory}/\($root.id)/client.jar"] | join(":")),
    "clientid": "idfk",

    # log4j config path
    "path": "${versions_directory}/\(.id)/log4j.xml"
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
