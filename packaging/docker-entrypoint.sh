#!/bin/sh
# Container entrypoint.
#   receiver [ARGS]  run the receiver (default); ARGS are added to its options
#   check            test the Immich settings and API key (immich-hook --check)
#   hook             run the Immich hook now, e.g. to retry queued batches
#   anything else    run it as a command
set -eu
umask "${FUJI_UMASK:-022}"
HOOK=/usr/local/lib/fuji-autosave/immich-hook

cmd=${1:-receiver}
[ $# -gt 0 ] && shift
case $cmd in
receiver)
	if [ ! -d "$FUJI_INBOX" ] || [ ! -w "$FUJI_INBOX" ]; then
		echo "error: $FUJI_INBOX is missing or not writable by uid $(id -u): mount the photo library there and check its ownership (see docs/deploy-docker.md)" >&2
		exit 1
	fi
	if ! mountpoint -q "$FUJI_INBOX"; then
		echo "warning: $FUJI_INBOX is not a mount point; received files would stay inside the container" >&2
	fi
	# FUJI_EXTRA_ARGS is split into words on purpose
	# shellcheck disable=SC2086
	exec fuji-autosave-receiver --inbox "$FUJI_INBOX" --state-dir "$FUJI_STATE_DIR" \
		--name "$FUJI_CLIENT_NAME" ${FUJI_HOOK:+--hook "$FUJI_HOOK"} ${FUJI_EXTRA_ARGS:-} "$@"
	;;
check)
	exec "$HOOK" --check
	;;
hook)
	exec "$HOOK"
	;;
*)
	exec "$cmd" "$@"
	;;
esac
