#!/bin/sh
# Runs before every Frappe app container's command.
#
# Job: make sure sites/assets/ points to the built assets shipped in the
# image. Assets are moved to /home/frappe/frappe-bench/assets at image build
# time (see Dockerfile); at boot we symlink them back into the mounted
# sites/ volume so Frappe's asset URLs resolve.
#
# Fresh JuiceFS volume  → sites/assets missing → we create the symlink.
# Existing volume       → sites/assets is a real dir populated by a prior
#                         `bench build` → we leave it alone. If the operator
#                         wants to switch that volume over to the
#                         assets-from-image model, they can delete
#                         sites/assets manually and restart the containers.
set -eu

SITES_ASSETS=/home/frappe/frappe-bench/sites/assets
IMAGE_ASSETS=/home/frappe/frappe-bench/assets

if [ ! -e "$SITES_ASSETS" ]; then
    ln -sfn "$IMAGE_ASSETS" "$SITES_ASSETS"
fi

exec "$@"
