# fuji-autosave-receiver + Immich hook as one image.
#
#   scripts/fetch-deps.sh && docker build -t fuji-autosave .
#
# Runs with host networking (the camera finds the receiver by UDP broadcast);
# see compose.yaml and docs/deploy-docker.md.

FROM alpine:3.24 AS build
RUN apk add --no-cache build-base cmake samurai pkgconf libusb-dev linux-headers
WORKDIR /src
COPY . .
RUN test -f third_party/libfuji/CMakeLists.txt -a -f third_party/libpict/CMakeLists.txt \
	|| { echo "submodules missing: run scripts/fetch-deps.sh before docker build" >&2; exit 1; }
RUN cmake -G Ninja -B /build \
	&& cmake --build /build --target fuji-autosave-receiver \
	&& DESTDIR=/out cmake --install /build --prefix /usr/local

FROM alpine:3.24
RUN apk add --no-cache libusb python3 tini \
	&& adduser -D -H -u 1000 -h /var/lib/fuji-autosave -s /sbin/nologin fuji \
	&& mkdir -p /fuji /var/lib/fuji-autosave \
	&& chown fuji:fuji /fuji /var/lib/fuji-autosave
COPY --from=build /out/usr/local /usr/local
COPY --chmod=755 packaging/docker-entrypoint.sh /usr/local/bin/docker-entrypoint

# The state (seen.tsv, batch lists, library.json) lives with the photos, so
# snapshots and backups of the library cover it
ENV FUJI_INBOX=/fuji \
	FUJI_STATE_DIR=/fuji/.fuji-autosave \
	FUJI_CLIENT_NAME=fuji-inbox \
	FUJI_HOOK=/usr/local/lib/fuji-autosave/immich-hook \
	FUJI_UMASK=022 \
	PHOTO_ROOT_CONTAINER=/mnt/fuji

USER fuji
WORKDIR /var/lib/fuji-autosave
# A running hook (waiting for an Immich scan) finishes before the receiver exits
STOPSIGNAL SIGTERM
ENTRYPOINT ["/sbin/tini", "--", "docker-entrypoint"]
CMD ["receiver"]
