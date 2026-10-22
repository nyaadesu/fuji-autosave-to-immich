# petabyt/vcam (emulated Fuji camera) for tests/docker-e2e.sh; same pinned
# revision as tests/e2e-vcam.sh
FROM alpine:3.24
RUN apk add --no-cache build-base cmake samurai pkgconf libusb-dev libexif-dev linux-headers git
ARG VCAM_REV=c25376ed6f7b19a2dd430897f8008837f5e1962c
RUN git clone -q https://github.com/petabyt/vcam /vcam \
	&& git -C /vcam checkout -q "$VCAM_REV" \
	&& cmake -S /vcam -B /vcam/build -G Ninja >/dev/null \
	&& cmake --build /vcam/build
WORKDIR /vcam
ENTRYPOINT ["build/vcam"]
