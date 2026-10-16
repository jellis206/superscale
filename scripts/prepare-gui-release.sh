#!/usr/bin/env bash
# ABOUTME: Verifies, notarizes, and packages the Developer ID GUI release.
# ABOUTME: Publication is deliberately owned by release-gui.sh after this succeeds.

set -euo pipefail

identity='Developer ID Application: Tadg Paul Ltd (2H98A242M4)'
team_id='2H98A242M4'
profile='superscale-notary'
dmg_identifier='com.tadgpaul.superscale.dmg'

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

check_notary_result() {
	local result=$1 status submission_id
	status=$(jq -er '.status // empty' "$result") || die "Notary response lacks a status: $result"
	submission_id=$(jq -er '.id // empty' "$result") || die "Notary response lacks an identifier: $result"
	printf 'Notary submission %s: %s\n' "$submission_id" "$status"
	[[ $status == Accepted ]] || die "Notary submission $submission_id was $status; inspect its log with xcrun notarytool log $submission_id --keychain-profile $profile"
}

verify_signature() {
	local target=$1 details=$2 kind=$3
	codesign --verify --deep --strict --verbose=2 "$target" || die "Invalid $kind signature: $target"
	codesign -dv --verbose=4 "$target" 2>"$details" || die "Cannot inspect $kind signature: $target"
	grep -Fxq "Authority=$identity" "$details" || die "$kind is not signed by $identity"
	grep -Fxq "TeamIdentifier=$team_id" "$details" || die "$kind has the wrong TeamIdentifier"
	grep -Eq '^Timestamp=.+$' "$details" || die "$kind lacks a secure timestamp"
	if [[ $kind == app ]]; then
		grep -Eq '^CodeDirectory .*flags=.*runtime' "$details" || die 'App lacks hardened runtime'
		codesign -d --entitlements :- "$target" 2>/dev/null |
			plutil -convert json -o - - |
			jq -e '."com.apple.security.get-task-allow" != true' >/dev/null ||
			die 'App entitlements are unreadable or enable get-task-allow'
	fi
}

if [[ ${1:-} == --check-notary-result ]]; then
	[[ $# == 2 && -f $2 ]] || die 'Usage: prepare-gui-release.sh --check-notary-result JSON_FILE'
	check_notary_result "$2"
	exit 0
fi

if [[ ${1:-} == --validate-ticket ]]; then
	[[ $# == 2 ]] || die 'Usage: prepare-gui-release.sh --validate-ticket APP_OR_DMG'
	xcrun stapler validate "$2" || die "Stapled ticket failed validation: $2"
	exit 0
fi

[[ $# -ge 2 ]] || die 'Usage: prepare-gui-release.sh APP_PATH DMG_OUTPUT [--sign-only] [--identity NAME] [--profile NAME]'
app_path=$1
dmg_output=$2
shift 2
sign_only=false
while [[ $# -gt 0 ]]; do
	case $1 in
	--sign-only)
		sign_only=true
		shift
		;;
	--identity)
		[[ $# -ge 2 ]] || die 'Missing identity name'
		identity=$2
		shift 2
		;;
	--profile)
		[[ $# -ge 2 ]] || die 'Missing profile name'
		profile=$2
		shift 2
		;;
	*) die "Unknown option: $1" ;;
	esac
done

[[ -d $app_path ]] || die "App bundle not found: $app_path"
[[ $app_path == *.app ]] || die 'Expected an .app bundle'
[[ $dmg_output == *.dmg ]] || die 'Expected a .dmg output path'
[[ ! -e $dmg_output ]] || die "DMG output already exists: $dmg_output"
security find-identity -v -p codesigning | grep -Fq "\"$identity\"" || die "Missing signing identity: $identity"

scratch=$(mktemp -d)
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

verify_signature "$app_path" "$scratch/app-signature.txt" app

if [[ $sign_only == false ]]; then
	ditto -c -k --keepParent "$app_path" "$scratch/Superscale.zip"
	if ! xcrun notarytool submit "$scratch/Superscale.zip" --keychain-profile "$profile" --wait --output-format json >"$scratch/app-notary.json"; then
		if jq -e '.id and .status' "$scratch/app-notary.json" >/dev/null 2>&1; then
			check_notary_result "$scratch/app-notary.json"
		fi
		die "App notary submission failed; check keychain profile $profile and Apple service availability"
	fi
	check_notary_result "$scratch/app-notary.json"
	xcrun stapler staple "$app_path" || die 'Could not staple app ticket'
	xcrun stapler validate "$app_path" || die 'App stapled ticket failed validation'
fi

mkdir -p "$scratch/staging"
ditto "$app_path" "$scratch/staging/Superscale.app"
ln -s /Applications "$scratch/staging/Applications"
mkdir -p "$(dirname "$dmg_output")"
hdiutil create -volname Superscale -srcfolder "$scratch/staging" -format UDZO "$dmg_output" >/dev/null
codesign --sign "$identity" --timestamp --identifier "$dmg_identifier" "$dmg_output" || die 'Could not sign DMG'
verify_signature "$dmg_output" "$scratch/dmg-signature.txt" dmg

if [[ $sign_only == false ]]; then
	if ! xcrun notarytool submit "$dmg_output" --keychain-profile "$profile" --wait --output-format json >"$scratch/dmg-notary.json"; then
		if jq -e '.id and .status' "$scratch/dmg-notary.json" >/dev/null 2>&1; then
			check_notary_result "$scratch/dmg-notary.json"
		fi
		die "DMG notary submission failed; check keychain profile $profile and Apple service availability"
	fi
	check_notary_result "$scratch/dmg-notary.json"
	xcrun stapler staple "$dmg_output" || die 'Could not staple DMG ticket'
	xcrun stapler validate "$dmg_output" || die 'DMG stapled ticket failed validation'
	verify_signature "$dmg_output" "$scratch/stapled-dmg-signature.txt" dmg
fi

printf 'Prepared GUI release DMG: %s\n' "$dmg_output"
