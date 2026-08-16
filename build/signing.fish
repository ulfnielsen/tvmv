#!/usr/bin/env fish
#
# signing.fish — shared code-signing configuration.
#
# Sourced by bundle.fish and quicklook.fish so a single build resolves ONE
# identity and every nested piece is signed the same way.
#
# Identity resolution, in priority order:
#   1. $TVMV_IDENTITY           — explicit override (any `codesign -s` argument:
#                                 a SHA-1 hash, a full cert name, or "-")
#   2. Developer ID Application — auto-detected from the keychain (releases)
#   3. "-"                      — ad-hoc fallback for local dev with no cert
#
# Ad-hoc builds run on THIS Mac only: they cannot be notarized, and Gatekeeper
# rejects them on every other machine. release.fish therefore REQUIRES a
# Developer ID identity and refuses to cut a release from an ad-hoc build.
#
# Hardened runtime is enabled in every mode, including ad-hoc. That is
# deliberate: notarization requires it, so local builds must exercise it too —
# otherwise a hardened-runtime failure would first surface in a release.
# Secure timestamps are requested only for real identities (Apple's timestamp
# server has nothing to bind an ad-hoc signature to). Timestamps are what keep
# shipped signatures valid after the signing certificate expires.
#
# Sets:
#   $tvmv_identity        resolved `codesign -s` argument
#   $tvmv_identity_name   human-readable identity description (for logging)
#   $tvmv_identity_kind   developer-id | adhoc | override
# Defines:
#   tvmv_sign <path> [extra codesign args...]

if set -q TVMV_IDENTITY
    set -g tvmv_identity $TVMV_IDENTITY
    set -g tvmv_identity_name "$TVMV_IDENTITY (TVMV_IDENTITY override)"
    if test "$TVMV_IDENTITY" = "-"
        set -g tvmv_identity_kind adhoc
    else
        set -g tvmv_identity_kind override
    end
else
    # `find-identity -v -p codesigning` lists only identities whose private key
    # is present, so a hit here means we can genuinely sign with it. Match on
    # the 40-char SHA-1 rather than the name: signing by hash stays unambiguous
    # if the keychain ever holds more than one Developer ID certificate.
    set -l di (security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application:' | head -n 1)
    if test -n "$di"
        set -g tvmv_identity (string match -r '[0-9A-F]{40}' -- $di)
        set -g tvmv_identity_name (string match -r '"([^"]*)"' -- $di)[2]
        set -g tvmv_identity_kind developer-id
    else
        set -g tvmv_identity "-"
        set -g tvmv_identity_name "ad-hoc (no Developer ID certificate found)"
        set -g tvmv_identity_kind adhoc
    end
end

if test "$tvmv_identity_kind" = adhoc
    set -g tvmv_sign_flags --options runtime
else
    set -g tvmv_sign_flags --options runtime --timestamp
end

# tvmv_sign <path> [extra codesign args...]
#
# Always --force (re-signing over a previous build is the normal case). Extra
# args are passed through verbatim — used for --entitlements on the appexes.
function tvmv_sign --description 'codesign a path with the resolved TVMV identity'
    set -l target $argv[1]
    set -l extra $argv[2..-1]
    codesign --sign $tvmv_identity --force $tvmv_sign_flags $extra $target
end

function tvmv_report_identity --description 'print the resolved signing identity'
    echo "==> signing identity: $tvmv_identity_name [$tvmv_identity_kind]"
    if test "$tvmv_identity_kind" = adhoc
        echo "    NOTE: ad-hoc build — runs on this Mac only, cannot be notarized."
    end
end
