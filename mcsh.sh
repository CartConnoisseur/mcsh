#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

DATA_DIR="./mcsh"
mkdir -p "$DATA_DIR"

VERSIONS_DIR="$DATA_DIR/versions"
LIBRARIES_DIR="$DATA_DIR/libraries"
NATIVES_DIR="$DATA_DIR/natives"
ASSETS_DIR="$DATA_DIR/assets"
GAME_DIR="$DATA_DIR/run"

function auth (
	CLIENT_ID="9e97542c-b7d5-4a02-a656-4559dad4590a"
	DEVICE_CODE_URL="https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode"
	TOKEN_URL="https://login.microsoftonline.com/consumers/oauth2/v2.0/token"
	XBL_AUTH_URL="https://user.auth.xboxlive.com/user/authenticate"
	XSTS_TOKEN_URL="https://xsts.auth.xboxlive.com/xsts/authorize"
	MC_AUTH_URL="https://api.minecraftservices.com/authentication/login_with_xbox"

	profile="${1:-"<unknown>"}"

	if ! [[ -e "$DATA_DIR/profiles.json" ]]; then
		printf '{}\n' > "$DATA_DIR/profiles.json"
	fi

	now="$(date -u '+%s')"

	msa_token=""
	refresh_token="$(jq -r --arg profile "$profile" '.[$profile].refresh_token.token // ""' "$DATA_DIR/profiles.json")"
	refresh_token_exp="$(jq -r --arg profile "$profile" '.[$profile].refresh_token.expiration // 0' "$DATA_DIR/profiles.json")"

	xuid="$(jq -r --arg profile "$profile" '.[$profile].xuid // ""' "$DATA_DIR/profiles.json")"
	xbl_token="$(jq -r --arg profile "$profile" '.[$profile].xbl_token.token // ""' "$DATA_DIR/profiles.json")"
	xbl_token_exp="$(jq -r --arg profile "$profile" '.[$profile].xbl_token.expiration // 0' "$DATA_DIR/profiles.json")"
	xsts_token=""

	mc_token="$(jq -r --arg profile "$profile" '.[$profile].mc_token.token // ""' "$DATA_DIR/profiles.json")"
	mc_token_exp="$(jq -r --arg profile "$profile" '.[$profile].mc_token.expiration // 0' "$DATA_DIR/profiles.json")"

	function msa {
		function login (
			printf 'getting device code\n' >&2
			res="$(curl -s -X POST "$DEVICE_CODE_URL" -H 'Content-Type: application/x-www-form-urlencoded' -d "client_id=$CLIENT_ID&scope=XboxLive.signin%20offline_access")"
			device_code="$(<<<"$res" jq -r '.device_code')"
			message="$(<<<"$res" jq -r '.message')"

			printf '%s\n' "$message" >&2

			printf 'waiting for token...\n' >&2
			pending=true
			while [[ "$pending" == true ]]; do
				res="$(curl -s -X POST "$TOKEN_URL" -H 'Content-Type: application/x-www-form-urlencoded' -d "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=$CLIENT_ID&device_code=$device_code")"
				pending="$(<<<"$res" jq -r '.error == "authorization_pending"')"
				sleep 1
			done

			printf '%s\n' "$res"
		)

		if [[ "$now" -ge "$refresh_token_exp" ]]; then
			printf 'logging in\n' >&2
			res="$(login)"
		else
			printf 'refreshing msa auth\n' >&2
			refresh_token="$(jq -r --arg profile "$profile" '.[$profile].refresh_token.token // ""' "$DATA_DIR/profiles.json")"
			res="$(curl -s -X POST "$TOKEN_URL" -H 'Content-Type: application/x-www-form-urlencoded' -d "grant_type=refresh_token&client_id=$CLIENT_ID&refresh_token=$refresh_token")"
		fi

		msa_token="$(<<<"$res" jq -r '.access_token')"
		refresh_token="$(<<<"$res" jq -r '.refresh_token')"
		refresh_token_exp="$((now + 90*24*60*60))" # msa refresh tokens expire in 90 days
	}

	function xbl {
		printf 'authenticating with xbox live\n' >&2
		req="$(jq -n --arg token "$msa_token" '{"Properties": {"AuthMethod": "RPS", "SiteName": "user.auth.xboxlive.com", "RpsTicket": "d=\($token)"}, "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT"}')"
		res="$(curl -s -X POST "$XBL_AUTH_URL" -H 'Content-Type: application/json' -H 'Accept: application/json' -d "$req")"
		xuid="$(<<<"$res" jq -r '.DisplayClaims.xui[0].uhs')"
		xbl_token="$(<<<"$res" jq -r '.Token')"
		xbl_token_exp="$(date -u '+%s' -d "$(<<<"$res" jq -r '.NotAfter')")"
	}

	function xsts {
		printf 'getting xsts token\n' >&2
		req="$(jq -n --arg token "$xbl_token" '{"Properties": {"SandboxId": "RETAIL", "UserTokens": [ $token ]}, "RelyingParty": "rp://api.minecraftservices.com/", "TokenType": "JWT"}')"
		res="$(curl -s -X POST "$XSTS_TOKEN_URL" -H 'Content-Type: application/json' -H 'Accept: application/json' -d "$req")"
		xsts_token="$(<<<"$res" jq -r '.Token')"
	}

	function mc {
		printf 'authenticating with minecraft\n' >&2
		req="$(jq -n --arg xuid "$xuid" --arg token "$xsts_token" '{"identityToken": "XBL3.0 x=\($xuid);\($token)"}')"
		# req="$(jq -n --arg token "$xsts_token" '{"identityToken": "XBL3.0 x=\($token)"}')"
		res="$(curl -s -X POST "$MC_AUTH_URL" -H 'Content-Type: application/json' -H 'Accept: application/json' -d "$req")"
		mc_token="$(<<<"$res" jq -r '.access_token')"
		mc_token_exp="$((now + "$(<<<"$res" jq -r '.expires_in')"))"
	}

	if [[ "$now" -ge "$mc_token_exp" ]]; then
		if [[ "$now" -ge "$xbl_token_exp" ]]; then
			msa
			xbl
		fi

		xsts
		mc
	else
		printf 'mc token valid\n' >&2
	fi

	profiles="$(
		jq  --arg profile "$profile" \
			--arg xuid "$xuid" \
			--arg refresh_token "$refresh_token" \
			--arg refresh_token_exp "$refresh_token_exp" \
			--arg xbl_token "$xbl_token" \
			--arg xbl_token_exp "$xbl_token_exp" \
			--arg mc_token "$mc_token" \
			--arg mc_token_exp "$mc_token_exp" \
			'. + {
				$profile: .[$profile] + {
					"xuid": $xuid,
					"type": "msa",
					"refresh_token": {
						"token": $refresh_token,
						"expiration": ($refresh_token_exp | tonumber)
					},
					"xbl_token": {
						"token": $xbl_token,
						"expiration": ($xbl_token_exp | tonumber)
					},
					"mc_token": {
						"token": $mc_token,
						"expiration": ($mc_token_exp | tonumber)
					}
				}
			}' \
			"$DATA_DIR/profiles.json"
	)"
	<<<"$profiles" cat > "$DATA_DIR/profiles.json"

	printf '%s\n' "$profile"
)

function update_profile (
	MC_PROFILE_URL="https://api.minecraftservices.com/minecraft/profile"

	profile="$1"
	token="$(jq -r --arg profile "$profile" '.[$profile].mc_token.token' "$DATA_DIR/profiles.json")"

	printf 'getting minecraft profile\n' >&2
	res="$(curl -s -X GET "$MC_PROFILE_URL" -H "Authorization: Bearer $token")"
	if [[ -n "$(<<<"$res" jq -r '.error // ""')" ]]; then
		printf 'error: user does not own minecraft\n' >&2
		exit 1
	fi
	
	uuid="$(<<<"$res" jq -r '.id')"
	uuid="${uuid:0:8}-${uuid:8:4}-${uuid:12:4}-${uuid:16:4}-${uuid:20:12}"

	profiles="$(
		<<<"$res" jq \
		--arg profile "$profile" \
		--arg uuid "$uuid" \
		--slurpfile profiles "$DATA_DIR/profiles.json" \
		'$profiles[0].[$profile] as $prev
		| $profiles[0] + {
			"\(.name)": {
				"username": .name,
				"uuid": $uuid,
				"xuid": $prev.xuid,
				"type": $prev.type,
				"skins": .skins,
				"capes": .capes,
				"refresh_token": $prev.refresh_token,
				"xbl_token": $prev.xbl_token,
				"mc_token": $prev.mc_token
			}
		}
		| del(.["<unknown>"])'
	)"
	<<<"$profiles" cat > "$DATA_DIR/profiles.json"

	jq --arg profile "$profile" '.[$profile]' "$DATA_DIR/profiles.json"
)

function update_metadata (
	printf 'updating version manifest\n' >&2
	mkdir -p "$VERSIONS_DIR"
	curl --silent "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" | jq '{"latest": .latest, "versions": [.versions[] | {"key": .id, "value": .url}] | from_entries}' > "$VERSIONS_DIR/manifest.json"

	version="${1:-}"
	if [[ "$version" == "" || "$version" == "latest" || "$version" == "release" ]]; then
		version="$(jq -r '.latest.release' "$VERSIONS_DIR/manifest.json")"
	elif [[ "$version" == "snapshot" ]]; then
		version="$(jq -r '.latest.snapshot' "$VERSIONS_DIR/manifest.json")"
	fi

	printf 'updating %s meta %s\n' "$version" >&2
	mkdir -p "$VERSIONS_DIR/$version"
	curl --silent -o "$VERSIONS_DIR/$version/meta.json" "$(jq -r --arg version "$version" '.versions[$version]' $VERSIONS_DIR/manifest.json)"
	meta="$(jq -c --slurpfile info info.json -f meta.jq "$VERSIONS_DIR/$version/meta.json")"

	printf 'updating %s asset index...\n' "$version" >&2
	mkdir -p "$ASSETS_DIR/indexes"
	assets_url="$(<<<"$meta" jq -r '.asset_index')"
	curl --silent -o "$ASSETS_DIR/indexes/$(basename "$assets_url")" "$assets_url"

	printf '%s\n' "$meta"
)

function launch (
	profile="$(update_profile "$(auth "${2:-}")")"
	printf '\n' >&2

	meta="$(update_metadata "${1:-}")"

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
	version="$(<<<"$meta" jq -r '.version')"
	if ! [[ -e "$VERSIONS_DIR/$version/client.jar" ]]; then
		printf 'downloading %s client jar...\n' "$version" >&2
		<<<"$meta" jq -r '.client_url' | xargs curl --silent -o "$VERSIONS_DIR/$version/client.jar"
	fi

	printf 'downloading libraries...\n' >&2
	<<<"$meta" jq -r '.libraries[] | "\(.name) \(.path) \(.url)"' | xargs -I {} "$SHELL" -c "download_library {}"

	printf 'downloading assets...\n' >&2
	jq -r '.objects | to_entries[] | "\(.key) \(.value.hash[:2])/\(.value.hash)"' "$ASSETS_DIR/indexes/$(basename "$(<<<"$meta" jq -r '.asset_index')")" | xargs -P 10 -I {} "$SHELL" -c "download_asset {}"

	# if ! [[ -e "$VERSIONS_DIR/$version/log4j.xml" ]]; then
	#     printf 'downloading %s log4j config...\n' "$version" >&2
	#     <<<"$meta" jq -r '.logging_config' | xargs curl --silent -o "$VERSIONS_DIR/$version/log4j.xml"
	# fi

	function replace_placeholders {
		cat - | sed \
			-e "s:\${versions_directory}:$VERSIONS_DIR:g" \
			-e "s:\${libraries_directory}:$LIBRARIES_DIR:g" \
			-e "s:\${natives_directory}:$NATIVES_DIR:g" \
			-e "s:\${assets_root}:$ASSETS_DIR:g" \
			-e "s:\${game_directory}:$GAME_DIR:g" \
			\
			-e "s/\${launcher_name}/mcsh/g" \
			-e "s/\${launcher_version}/v0.1.0/g" \
			\
			-e "s/\${auth_player_name}/$(<<<"$profile" jq -r '.username')/g" \
			-e "s/\${auth_uuid}/$(<<<"$profile" jq -r '.uuid')/g" \
			-e "s/\${auth_xuid}/$(<<<"$profile" jq -r '.xuid')/g" \
			-e "s/\${user_type}/$(<<<"$profile" jq -r '.type')/g" \
			-e "s/\${auth_access_token}/$(<<<"$profile" jq -r '.mc_token.token')/g"
	}

	printf '\nstarting game :3\n\n' >&2
	<<<"$meta" jq -r '.args.jvm + [.main_class] + .args.game | join(" ")' | replace_placeholders | xargs java
)

launch "$@"
