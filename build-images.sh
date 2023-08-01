#!/bin/bash

# Terminate on error
set -e

# Prepare variables for later use
images=()
# The image will be pushed to GitHub container registry
repobase="${REPOBASE:-ghcr.io/nethserver}"
# Configure the image name
reponame="openldap"

# Create a new empty container image
container=$(buildah from scratch)

# Reuse existing nodebuilder-openldap container, to speed up builds
if ! buildah containers --format "{{.ContainerName}}" | grep -q nodebuilder-openldap; then
    echo "Pulling NodeJS runtime..."
    buildah from --name nodebuilder-openldap -v "${PWD}:/usr/src:Z" docker.io/library/node:lts
fi

if [[ -n $WITH_UI ]]; then
    echo "Build static UI files with node..."
    buildah run nodebuilder-openldap sh -c "cd /usr/src/ui && yarn install && yarn build"
else
    echo "Skip UI build..."
    mkdir -p ui/dist
    touch ui/dist/index.html
fi

# Add imageroot directory to the container image
buildah add "${container}" imageroot /imageroot
buildah add "${container}" ui/dist /ui
# Setup the entrypoint, ask to reserve one TCP port with the label and set a rootless container
buildah config --entrypoint=/ \
    --label='org.nethserver.authorizations=ldapproxy@node:accountprovider cluster:accountprovider' \
    --label="org.nethserver.tcp-ports-demand=1" \
    --label="org.nethserver.rootfull=0" \
    --label="org.nethserver.images=${repobase}/openldap-server:${IMAGETAG:-latest}" \
    --label 'org.nethserver.flags=core_module account_provider' \
    "${container}"
# Commit the image
buildah commit "${container}" "${repobase}/${reponame}"

# Append the image URL to the images array
images+=("${repobase}/${reponame}")

# Server image from Alpine OpenLDAP
reponame="openldap-server"
container=$(buildah from docker.io/library/alpine:3.15)
buildah run "${container}" sh <<'EOF'
apk add --no-cache \
    gettext \
    openldap \
    openldap-overlay-syncprov \
    openldap-overlay-ppolicy \
    openldap-overlay-dynlist \
    openldap-back-mdb \
    openldap-passwd-sha2 \
    openldap-clients
EOF

buildah add "${container}" server/ /
buildah config \
    --user=ldap:ldap \
    --workingdir=/var/lib/openldap \
    --volume=/var/lib/openldap \
    --entrypoint='["/entrypoint.sh"]' \
    --cmd='' \
    --env=FILTERS_DIR="/usr/local/lib/awk" \
    --env=TEMPLATES_DIR="/usr/local/lib/templates" \
    --env=LDAPCONF="/var/lib/openldap/ldap.conf" \
    --env=LDAP_SVCUSER="ldapservice" \
    --env=LDAP_SVCPASS="pass" \
    --env=LDAP_ADMUSER="admin" \
    --env=LDAP_ADMPASS="secret" \
    --env=LDAP_DOMAIN="nethserver.test" \
    --env=LDAP_SUFFIX="dc=nethserver,dc=test" \
    --env=LDAP_LOGLEVEL="16384" \
    --env=LDAP_DEBUGLEVEL="0" \
    "${container}"
# Commit the image
buildah commit "${container}" "${repobase}/${reponame}"

# Append the image URL to the images array
images+=("${repobase}/${reponame}")

#
# NOTICE:
#
# It is possible to build and publish multiple images.
#
# 1. create another buildah container
# 2. add things to it and commit it
# 3. append the image url to the images array
#

#
# Setup CI when pushing to Github. 
# Warning! docker::// protocol expects lowercase letters (,,)
if [[ -n "${CI}" ]]; then
    # Set output value for Github Actions
    printf "::set-output name=images::%s\n" "${images[*],,}"
else
    # Just print info for manual push
    printf "Publish the images with:\n\n"
    for image in "${images[@],,}"; do printf "  buildah push %s docker://%s:%s\n" "${image}" "${image}" "${IMAGETAG:-latest}" ; done
    printf "\n"
fi
